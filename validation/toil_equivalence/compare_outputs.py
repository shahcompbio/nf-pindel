#!/usr/bin/env python3
"""Compare cgpPindel outputs produced by the toil_pindel and nf-pindel wrappers.

Both wrappers drive the same underlying tool, so an equivalent port must produce
the same calls, the same flagging, and the same supporting BAMs. This script
checks that.

The VCF ID column is ignored: cgpPindel stamps a freshly generated UUID into it
on every run, so it is never reproducible and carries no analytical meaning.

Usage:
    compare_outputs.py <toil_dir> <nextflow_dir> [--image IMAGE] [--platform P]

Exit status is 0 only when every check passes.
"""

import argparse
import gzip
import re
import subprocess
import sys
from pathlib import Path

PREFIX = "tumor_vs_normal"

EXPECTED_FILES = [
    f"{PREFIX}.flagged.vcf.gz",
    f"{PREFIX}.flagged.vcf.gz.tbi",
    f"{PREFIX}_mt.bam",
    f"{PREFIX}_mt.bam.bai",
    f"{PREFIX}_wt.bam",
    f"{PREFIX}_wt.bam.bai",
    f"{PREFIX}.germline.bed",
]

# cgpPindel writes its version into the VCF header. A version skew between the
# two sides silently changes flagging behaviour, so it is surfaced explicitly.
VERSION_RE = re.compile(r"^##source_\d+\.\d+=pindel_2_combined_vcf\.pl_v(\S+)")


def resolve_output_dir(base: Path) -> Path:
    """Accept either a published dir or a parent holding one patient dir."""
    if (base / f"{PREFIX}.flagged.vcf.gz").exists():
        return base
    for child in sorted(p for p in base.glob("*") if p.is_dir()):
        if (child / f"{PREFIX}.flagged.vcf.gz").exists():
            return child
    return base


def read_vcf_lines(vcf_path: Path):
    with gzip.open(vcf_path, "rt") as handle:
        yield from handle


def cgppindel_version(vcf_path: Path) -> str:
    for line in read_vcf_lines(vcf_path):
        if not line.startswith("#"):
            break
        match = VERSION_RE.match(line)
        if match:
            return match.group(1)
    return "unknown"


def parse_vcf_records(vcf_path: Path) -> list[dict]:
    records = []
    for line in read_vcf_lines(vcf_path):
        if line.startswith("#"):
            continue
        fields = line.rstrip("\n").split("\t")
        records.append(
            {
                "chrom": fields[0],
                "pos": fields[1],
                "ref": fields[3],
                "alt": fields[4],
                "filter": fields[6],
            }
        )
    return sorted(
        records, key=lambda r: (r["chrom"], int(r["pos"]), r["ref"], r["alt"])
    )


def bam_read_count(bam_path: Path, image: str, platform: str | None) -> int:
    bam_path = bam_path.resolve()
    cmd = ["docker", "run", "--rm"]
    if platform:
        cmd += ["--platform", platform]
    cmd += [
        "-v",
        f"{bam_path.parent}:/data:ro",
        "--entrypoint",
        "samtools",
        image,
        "view",
        "-c",
        f"/data/{bam_path.name}",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return int(result.stdout.strip())


def read_bed(bed_path: Path) -> list[str]:
    return sorted(bed_path.read_text().splitlines())


class Report:
    def __init__(self) -> None:
        self.ok = True

    def check(self, name: str, passed: bool, detail: str = "") -> None:
        self.ok &= bool(passed)
        line = f"  [{'PASS' if passed else 'FAIL'}] {name}"
        if detail:
            line += f"  ({detail})"
        print(line)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("toil_dir", type=Path)
    parser.add_argument("nextflow_dir", type=Path)
    parser.add_argument(
        "--image",
        default="quay.io/wtsicgp/cgppindel:3.10.0",
        help="image providing samtools for BAM read counts",
    )
    parser.add_argument(
        "--platform", default=None, help="docker --platform value, e.g. linux/amd64"
    )
    args = parser.parse_args()

    toil = resolve_output_dir(args.toil_dir)
    nextflow = resolve_output_dir(args.nextflow_dir)

    print(f"toil:     {toil}")
    print(f"nextflow: {nextflow}")
    print()

    report = Report()

    print("File existence:")
    for name in EXPECTED_FILES:
        report.check(f"toil/{name}", (toil / name).exists())
        report.check(f"nextflow/{name}", (nextflow / name).exists())
    print()

    toil_vcf = toil / f"{PREFIX}.flagged.vcf.gz"
    nf_vcf = nextflow / f"{PREFIX}.flagged.vcf.gz"

    if not (toil_vcf.exists() and nf_vcf.exists()):
        print("Cannot continue: flagged VCF missing on one or both sides.")
        sys.exit(1)

    # Surfaced before the call comparison because a version skew is the most
    # common cause of a FILTER-only difference.
    print("cgpPindel provenance:")
    toil_version = cgppindel_version(toil_vcf)
    nf_version = cgppindel_version(nf_vcf)
    report.check(
        "version match", toil_version == nf_version, f"toil={toil_version}, nextflow={nf_version}"
    )
    if toil_version != nf_version:
        print(
            "    Different cgpPindel versions flag borderline calls differently.\n"
            "    Re-run both sides on the same version before judging equivalence."
        )
    print()

    print("VCF records:")
    toil_records = parse_vcf_records(toil_vcf)
    nf_records = parse_vcf_records(nf_vcf)

    report.check(
        "record count",
        len(toil_records) == len(nf_records),
        f"toil={len(toil_records)}, nextflow={len(nf_records)}",
    )

    toil_calls = [(r["chrom"], r["pos"], r["ref"], r["alt"]) for r in toil_records]
    nf_calls = [(r["chrom"], r["pos"], r["ref"], r["alt"]) for r in nf_records]
    report.check("CHROM/POS/REF/ALT", toil_calls == nf_calls)
    if toil_calls != nf_calls:
        only_toil = set(toil_calls) - set(nf_calls)
        only_nf = set(nf_calls) - set(toil_calls)
        if only_toil:
            print(f"    Only in toil: {sorted(only_toil)}")
        if only_nf:
            print(f"    Only in nextflow: {sorted(only_nf)}")

    toil_filters = [(r["chrom"], r["pos"], r["filter"]) for r in toil_records]
    nf_filters = [(r["chrom"], r["pos"], r["filter"]) for r in nf_records]
    report.check("FILTER values", toil_filters == nf_filters)
    if toil_filters != nf_filters and toil_calls == nf_calls:
        for toil_rec, nf_rec in zip(toil_records, nf_records):
            if toil_rec["filter"] != nf_rec["filter"]:
                print(
                    f"    {toil_rec['chrom']}:{toil_rec['pos']} "
                    f"{toil_rec['ref']}>{toil_rec['alt']} "
                    f"toil={toil_rec['filter']} nextflow={nf_rec['filter']}"
                )

    print(f"    Calls ({len(toil_records)}):")
    for record in toil_records:
        print(
            f"      {record['chrom']}:{record['pos']} "
            f"{record['ref']}>{record['alt']}  FILTER={record['filter']}"
        )
    print()

    print("BAM read counts:")
    for suffix in ["_mt.bam", "_wt.bam"]:
        toil_bam = toil / f"{PREFIX}{suffix}"
        nf_bam = nextflow / f"{PREFIX}{suffix}"
        if toil_bam.exists() and nf_bam.exists():
            toil_count = bam_read_count(toil_bam, args.image, args.platform)
            nf_count = bam_read_count(nf_bam, args.image, args.platform)
            report.check(
                suffix,
                toil_count == nf_count,
                f"toil={toil_count}, nextflow={nf_count}",
            )
        else:
            report.check(suffix, False, "file(s) missing")
    print()

    print("Germline BED:")
    toil_bed = toil / f"{PREFIX}.germline.bed"
    nf_bed = nextflow / f"{PREFIX}.germline.bed"
    if toil_bed.exists() and nf_bed.exists():
        toil_lines = read_bed(toil_bed)
        nf_lines = read_bed(nf_bed)
        report.check(
            "content",
            toil_lines == nf_lines,
            f"toil={len(toil_lines)} lines, nextflow={len(nf_lines)} lines",
        )
    else:
        report.check("content", False, "file(s) missing")
    print()

    if report.ok:
        print("RESULT: ALL CHECKS PASSED — toil and nf-pindel outputs are equivalent.")
    else:
        print("RESULT: SOME CHECKS FAILED — see details above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
