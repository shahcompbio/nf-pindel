#!/usr/bin/env bash
#
# Demonstrate that nf-pindel reproduces the results of the toil_pindel pipeline
# it replaces.
#
# Runs from a clean clone of nf-pindel. Nothing is assumed to be present besides
# docker, git, python3 and nextflow: the toil_pindel source is cloned on demand,
# and every pindel invocation happens inside a container, so no pre-built python
# environment is required.
#
# Both wrappers drive the same tool, cgpPindel. The version toil_pindel pins is
# read out of its own Dockerfile and used to pin the nf-pindel side too, because
# cgpPindel changes how it flags borderline calls between releases and a version
# skew would otherwise look like a porting defect.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="${REPO_DIR}/validation/toil_equivalence"

TOIL_REPO_URL="${TOIL_REPO_URL:-https://github.com/papaemmelab/toil_pindel.git}"
TOIL_REPO_REF="${TOIL_REPO_REF:-}"
TOIL_SRC_DIR="${TOIL_SRC_DIR:-}"
NEXTFLOW_CMD="${NEXTFLOW_CMD:-nextflow}"

REFERENCE_MODE="golden"
GOLDEN_SET="cgppindel-3.3.0"
GOLDEN_DIR="${SUITE_DIR}/golden"
WORK_DIR="${REPO_DIR}/validation/.work"
OUT_DIR="${REPO_DIR}/validation/output/equivalence"
KEEP_EXISTING=0

usage() {
    cat <<'EOF'
Usage: ./validate_against_toil.sh [options]

Compares nf-pindel output against the toil_pindel reference on the bundled
tumour/normal test pair, then reports whether the two are equivalent.

Options:
  --reference {golden|cgppindel|toil}
        golden (default) compares against reference output checked into this
        repo. Needs no toil checkout and no network. This is the only way to
        validate cgpPindel 3.3.0, whose original image can no longer be pulled.

        cgppindel runs cgpPindel directly at the version toil_pindel pins,
        which is the tool toil_pindel wraps. Reliable on every platform.

        toil builds the toil_pindel image from source and runs the real toil
        workflow. Most faithful, but toil's single-machine scheduler can hang
        under qemu emulation (notably Apple Silicon); prefer it on native
        linux/amd64 hosts.

  --golden-set NAME golden set to compare against (default cgppindel-3.3.0)
  --list-golden     list the available golden sets and exit
  --outdir DIR      where to write results (default validation/output/equivalence)
  --workdir DIR     scratch dir for the toil_pindel checkout (default validation/.work)
  --keep            reuse existing outputs instead of deleting them first
  -h, --help        show this message

Environment overrides:
  TOIL_SRC_DIR      use an existing toil_pindel checkout instead of cloning
  TOIL_REPO_URL     clone URL (default papaemmelab/toil_pindel)
  TOIL_REPO_REF     branch, tag or commit to check out
  NEXTFLOW_CMD      how to invoke nextflow. Must be executable from a script, so
                    use an absolute path rather than a shell function, e.g.
                    NEXTFLOW_CMD="$HOME/.local/bin/micromamba run -n nextflow nextflow"

Examples:
  ./validate_against_toil.sh
  ./validate_against_toil.sh --golden-set toil-3.10.0
  ./validate_against_toil.sh --reference toil
  TOIL_SRC_DIR=../toil_pindel ./validate_against_toil.sh --reference cgppindel
EOF
}

list_golden() {
    printf 'Available golden sets in %s:\n\n' "${GOLDEN_DIR#"${REPO_DIR}/"}"
    for dir in "$GOLDEN_DIR"/*/; do
        [[ -f "${dir}PROVENANCE" ]] || continue
        printf '  %s\n' "$(basename "$dir")"
        sed -nE 's/^(cgppindel_version|producer|nf_container|reproducible)=/    \1=/p' "${dir}PROVENANCE"
        printf '\n'
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reference)   REFERENCE_MODE="${2:?--reference needs a value}"; shift 2 ;;
        --golden-set)  GOLDEN_SET="${2:?--golden-set needs a value}"; shift 2 ;;
        --list-golden) list_golden; exit 0 ;;
        --outdir)      OUT_DIR="${2:?--outdir needs a value}"; shift 2 ;;
        --workdir)     WORK_DIR="${2:?--workdir needs a value}"; shift 2 ;;
        --keep)        KEEP_EXISTING=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$REFERENCE_MODE" in
    golden|cgppindel|toil) ;;
    *) echo "ERROR: --reference must be 'golden', 'cgppindel' or 'toil'" >&2; exit 2 ;;
esac

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --

log "Checking prerequisites"

for tool in docker git python3; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not on PATH."
done

docker info >/dev/null 2>&1 || die "Docker is installed but not running."

# NEXTFLOW_CMD may be a multi-word launcher, so probe it as written. Shell
# functions and aliases (conda/micromamba activate wrappers) do not exist in a
# non-interactive shell, so point PATH at the environment instead.
read -r NEXTFLOW_LAUNCHER _ <<<"$NEXTFLOW_CMD"
if ! command -v "$NEXTFLOW_LAUNCHER" >/dev/null 2>&1; then
    die "'${NEXTFLOW_LAUNCHER}' is not an executable on PATH.
       If it is a shell function (e.g. micromamba/conda), put the environment on
       PATH instead, for example:
         PATH=\"\$HOME/micromamba/envs/nextflow/bin:\$PATH\" ./validate_against_toil.sh"
fi

# shellcheck disable=SC2086
$NEXTFLOW_CMD -version >/dev/null 2>&1 \
    || die "'${NEXTFLOW_CMD}' is on PATH but failed to run (is a Java runtime available?)."

info "docker    $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo present)"
info "nextflow  via '${NEXTFLOW_CMD}'"
info "python3   $(python3 --version 2>&1)"

# cgpPindel is published for linux/amd64 only; emulate it elsewhere.
DOCKER_PLATFORM=""
NF_PLATFORM_PROFILE=""
if [[ "$(uname -m)" != "x86_64" ]]; then
    DOCKER_PLATFORM="linux/amd64"
    NF_PLATFORM_PROFILE=",emulate_amd64"
    info "host is $(uname -m); forcing linux/amd64 containers"
fi

DATA_DIR="${REPO_DIR}/tests/data"
[[ -d "$DATA_DIR" ]] || die "Test data not found at ${DATA_DIR}."

# ------------------------------------------------------------ reference side --

if [[ "$REFERENCE_MODE" == "golden" ]]; then
    log "Using checked-in golden reference"

    GOLDEN_PATH="${GOLDEN_DIR}/${GOLDEN_SET}"
    [[ -d "$GOLDEN_PATH" ]] \
        || die "Unknown golden set '${GOLDEN_SET}'. Run --list-golden to see the options."
    [[ -f "${GOLDEN_PATH}/PROVENANCE" ]] \
        || die "Golden set '${GOLDEN_SET}' has no PROVENANCE file."

    # The golden set declares which image reproduces it, so the nf-pindel side
    # is pinned from the data rather than guessed.
    golden_field() {
        sed -n "s/^$1=//p" "${GOLDEN_PATH}/PROVENANCE" | head -n1
    }

    CGPPINDEL_IMAGE="$(golden_field nf_container)"
    GOLDEN_VERSION="$(golden_field cgppindel_version)"
    GOLDEN_PRODUCER="$(golden_field producer)"
    GOLDEN_PROFILES="$(golden_field nf_profiles)"
    [[ -n "$CGPPINDEL_IMAGE" ]] \
        || die "Golden set '${GOLDEN_SET}' does not declare nf_container."

    info "set        ${GOLDEN_SET}"
    info "produced by ${GOLDEN_PRODUCER:-unknown} at cgpPindel ${GOLDEN_VERSION:-unknown}"
    info "matching image ${CGPPINDEL_IMAGE}"
    [[ -n "$GOLDEN_PROFILES" ]] && info "required profiles ${GOLDEN_PROFILES}"
else
    log "Locating toil_pindel source"

    mkdir -p "$WORK_DIR"

    if [[ -n "$TOIL_SRC_DIR" ]]; then
        [[ -d "$TOIL_SRC_DIR" ]] || die "TOIL_SRC_DIR '${TOIL_SRC_DIR}' does not exist."
        TOIL_SRC="$(cd "$TOIL_SRC_DIR" && pwd)"
        info "using existing checkout: ${TOIL_SRC}"
    else
        TOIL_SRC="${WORK_DIR}/toil_pindel"
        if [[ -d "${TOIL_SRC}/.git" ]]; then
            info "reusing checkout: ${TOIL_SRC}"
        else
            info "cloning ${TOIL_REPO_URL}"
            rm -rf "$TOIL_SRC"
            git clone --quiet "$TOIL_REPO_URL" "$TOIL_SRC"
        fi
        if [[ -n "$TOIL_REPO_REF" ]]; then
            git -C "$TOIL_SRC" fetch --quiet --all --tags
            git -C "$TOIL_SRC" checkout --quiet "$TOIL_REPO_REF"
        fi
    fi

    [[ -f "${TOIL_SRC}/Dockerfile" ]] || die "No Dockerfile in ${TOIL_SRC}; is that a toil_pindel checkout?"

    info "toil_pindel commit $(git -C "$TOIL_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"

    # The Dockerfile's base image is the authoritative statement of which cgpPindel
    # toil_pindel ran, so both sides of the comparison are pinned from it.
    CGPPINDEL_IMAGE="$(awk '/^[[:space:]]*FROM[[:space:]]/ {print $2; exit}' "${TOIL_SRC}/Dockerfile")"
    [[ -n "$CGPPINDEL_IMAGE" ]] || die "Could not read the base image from ${TOIL_SRC}/Dockerfile."
    info "cgpPindel pinned by toil_pindel: ${CGPPINDEL_IMAGE}"
fi

# ------------------------------------------------------------------ outputs --

NF_OUT="${OUT_DIR}/nextflow"

if [[ "$REFERENCE_MODE" == "golden" ]]; then
    TOIL_OUT="$GOLDEN_PATH"
else
    TOIL_OUT="${OUT_DIR}/toil"
    if [[ "$KEEP_EXISTING" -eq 0 ]]; then
        rm -rf "$TOIL_OUT"
    fi
    mkdir -p "$TOIL_OUT"
fi

if [[ "$KEEP_EXISTING" -eq 0 ]]; then
    rm -rf "$NF_OUT"
fi
mkdir -p "$NF_OUT"

docker_run() {
    local args=(docker run --rm)
    [[ -n "$DOCKER_PLATFORM" ]] && args+=(--platform "$DOCKER_PLATFORM")
    args+=("$@")
    "${args[@]}"
}

# ------------------------------------------------------------- toil-side run --

if [[ "$REFERENCE_MODE" == "golden" ]]; then
    :
elif [[ "$REFERENCE_MODE" == "cgppindel" ]]; then
    log "Running cgpPindel reference (${CGPPINDEL_IMAGE})"
    info "this is the tool toil_pindel wraps, at the version it pins"

    if [[ -f "${TOIL_OUT}/tumor_vs_normal.flagged.vcf.gz" ]]; then
        info "reusing existing reference output (--keep)"
    else
        docker_run \
            -v "${DATA_DIR}:/data:ro" \
            -v "${TOIL_OUT}:/outdir" \
            --entrypoint pindel.pl \
            "$CGPPINDEL_IMAGE" \
            -outdir /outdir \
            -reference /data/reference/reference.fasta \
            -tumour /data/tumor/tumor.bam \
            -normal /data/normal/normal.bam \
            -simrep /data/pindel/simrep.bed.gz \
            -filter /data/pindel/filter.lst \
            -genes /data/pindel/genes.bed.gz \
            -unmatched /data/pindel/unmatched.vcf.gz \
            -assembly GRCH37D5 \
            -species HUMAN \
            -exclude 'NC_007605,hs37d5,GL%' \
            -cpus 2
    fi
else
    log "Building toil_pindel image from source"
    TOIL_IMAGE="nf-pindel-validation/toil_pindel:local"
    build_args=(docker build -t "$TOIL_IMAGE")
    [[ -n "$DOCKER_PLATFORM" ]] && build_args+=(--platform "$DOCKER_PLATFORM")
    build_args+=("$TOIL_SRC")
    "${build_args[@]}"

    log "Running toil_pindel workflow"
    info "if this stalls, your platform cannot run toil reliably;"
    info "re-run with --reference cgppindel"
    if [[ -f "${TOIL_OUT}/tumor_vs_normal.flagged.vcf.gz" ]]; then
        info "reusing existing reference output (--keep)"
    else
        docker_run \
            -v "${DATA_DIR}:/data:ro" \
            -v "${TOIL_OUT}:/outdir" \
            --entrypoint toil_pindel \
            "$TOIL_IMAGE" \
            /outdir/jobstore \
            --max_cores_usage 2 \
            --max_memory_usage 1 \
            --outdir /outdir \
            --tumor_bam /data/tumor/tumor.bam \
            --normal_bam /data/normal/normal.bam \
            --species HUMAN \
            --assembly GRCH37D5 \
            --exclude 'NC_007605,hs37d5,GL%' \
            --reference /data/reference/reference.fasta \
            --filter /data/pindel/filter.lst \
            --genes /data/pindel/genes.bed.gz \
            --simrep /data/pindel/simrep.bed.gz \
            --unmatched /data/pindel/unmatched.vcf.gz \
            --tgd \
            --short_job 10
        rm -rf "${TOIL_OUT}/jobstore" "${TOIL_OUT}/tmpPindel"
    fi
fi

[[ -f "${TOIL_OUT}/tumor_vs_normal.flagged.vcf.gz" ]] \
    || die "No flagged VCF found in ${TOIL_OUT}."

# ------------------------------------------------------------- nf-pindel run --

log "Running nf-pindel"

PIN_CONFIG="${WORK_DIR}/pin_cgppindel.config"
mkdir -p "$WORK_DIR"
cat > "$PIN_CONFIG" <<EOF
// Generated by validate_against_toil.sh: match the cgpPindel that toil_pindel pins.
process {
    withName: '.*CGPPINDEL.*' {
        container = '${CGPPINDEL_IMAGE}'
    }
}
EOF

info "pinning nf-pindel to ${CGPPINDEL_IMAGE}"

# A golden set may require a particular execution shape, e.g. cgpPindel releases
# predating -noflag cannot run the scattered path.
NF_PROFILES="test,docker${NF_PLATFORM_PROFILE}"
if [[ -n "${GOLDEN_PROFILES:-}" ]]; then
    NF_PROFILES="${NF_PROFILES},${GOLDEN_PROFILES}"
fi
info "profiles: ${NF_PROFILES}"

# shellcheck disable=SC2086
$NEXTFLOW_CMD run "${REPO_DIR}/main.nf" \
    -profile "$NF_PROFILES" \
    -c "$PIN_CONFIG" \
    --outdir "$NF_OUT"

# ------------------------------------------------------------------ compare --

log "Comparing outputs"

compare_args=("${SUITE_DIR}/compare_outputs.py" "$TOIL_OUT" "$NF_OUT" --image "$CGPPINDEL_IMAGE")
[[ -n "$DOCKER_PLATFORM" ]] && compare_args+=(--platform "$DOCKER_PLATFORM")

set +e
python3 "${compare_args[@]}"
COMPARE_STATUS=$?
set -e

log "Summary"
info "reference mode : ${REFERENCE_MODE}"
[[ "$REFERENCE_MODE" == "golden" ]] && info "golden set     : ${GOLDEN_SET}"
info "cgpPindel      : ${CGPPINDEL_IMAGE}"
info "reference out  : ${TOIL_OUT}"
info "nf-pindel out  : ${NF_OUT}"

if [[ $COMPARE_STATUS -eq 0 ]]; then
    info "result         : EQUIVALENT"
else
    info "result         : DIFFERENCES FOUND"
fi

exit "$COMPARE_STATUS"
