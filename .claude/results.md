# Port results: `toil_pindel` → `shahcompbio/nf-pindel`

What was built against [plan.md](plan.md), and how it was verified. Written
2026-09-01.

## Outcome

The port is complete and green. It runs **the same cgpPindel 3.10.0 from the same
container** `toil_pindel` used, so unlike the mutect port there is no
tool-version delta and results are expected to match rather than merely be
comparable.

Two execution shapes are available and verified equivalent — see below. Both are
covered by the test suite.

- **3/3 nf-test cases pass.**
- **`nf-core pipelines lint`: 0 failures.**

## What was built

| Piece | Path |
| --- | --- |
| Reference and resource channels | [`workflows/pindel.nf`](../workflows/pindel.nf) |
| Unstaged caller, one run per pair | [`modules/local/cgppindel/main.nf`](../modules/local/cgppindel/main.nf) |
| Per-contig scatter | [`subworkflows/local/cgppindel_scatter/main.nf`](../subworkflows/local/cgppindel_scatter/main.nf) |
| Scatter stages | [`modules/local/cgppindel_input`](../modules/local/cgppindel_input/main.nf), [`_call`](../modules/local/cgppindel_call/main.nf), [`_merge_flag`](../modules/local/cgppindel_merge_flag/main.nf) |
| Samplesheet grouping | [`subworkflows/local/utils_nfcore_pindel_pipeline/main.nf`](../subworkflows/local/utils_nfcore_pindel_pipeline/main.nf) |
| Legacy publishing, cgpPindel arguments | [`conf/modules.config`](../conf/modules.config) |

**Zero nf-core modules.** nf-core's `pindel/pindel` is the original Pindel
0.2.5b9 — a different tool emitting raw `_D`/`_SI` text files, which cannot
produce the flagged VCF or the `_mt`/`_wt` BAMs the downstream contract needs.
cgpPindel is not on bioconda. The pipeline wraps cancerit's published image
directly, which is the honest answer here rather than a compromise.

## Verification

**The toil test's assertion holds.** `tumor_vs_normal.flagged.vcf.gz` is
produced. That was the *only* thing `toil_pindel`'s test checked; this suite goes
further.

**Every `isabl_apps` glob resolves** — all six of `*.flagged.vcf.gz`, `*_mt.bam`,
`*_mt.bam.bai`, `*_wt.bam`, `*_wt.bam.bai`, `*.germline.bed`, in both the
per-patient and `--flat_publish` layouts, on both execution paths.

**Flagging genuinely ran.** The six calls carry real FILTER values from the rules
file — `PASS`, `F005`, `F001;F003;F005;F008`, `F001;F008` — rather than a
uniform PASS, which is what a silently misconfigured `-filter` would produce. The
test asserts both that some record is PASS and that some record carries an `F0*`
flag, so a broken rules file fails the suite.

**cgpPindel 3.10.0 is recorded** in the emitted `pindel_software_versions.yml`,
confirming the pinned version actually ran.

## Deviations from the plan

**cgpPindel's VCF is not byte-reproducible.** It stamps a freshly generated UUID
into the ID column of every record on every run:

```
2  529  4ec5880c-a5aa-11f1-94c3-d12f099759fc  G  GT  16680  PASS  ...
```

My first pass at the golden-record assertions matched whole line prefixes
assuming `.` in the ID field, and failed. They now compare CHROM/POS/REF/ALT
tuples. This matters beyond the test suite: **anyone diffing this pipeline's
output against toil's must ignore the ID column**, or every record will look
changed. It is called out in `docs/migration.md`, `docs/output.md` and
`docs/CONTRIBUTING.md`.

Also worth recording: the nf-core template again generated hyphenated workflow
identifiers (`NF-PINDEL`, `SHAHCOMPBIO_NF-PINDEL`) from the pipeline name, which
are not valid Nextflow identifiers and would not parse. Same fix as the mutect
port — renamed to `PINDEL` / `SHAHCOMPBIO_NFPINDEL`, and the generated
`utils_nfcore_nf-pindel_pipeline` directory with it. This is a template bug for
any pipeline whose name contains a hyphen.

## Correction: the parallelism claim, and the default behind it

**This section originally said the single-task design cost real WGS throughput,
and justified not building the scatter by calling cgpPindel's intermediate
layout undocumented and fragile. Both were wrong.** They were challenged, and
reading the source rather than defending them showed:

**1. The layout is deterministic, not fragile.** From
`Sanger/CGP/Pindel/Implement.pm`, every per-index write is keyed by contig name
and strictly disjoint — `input` writes `tmpPindel/<sample>/<seq>.txt.gz` (one
file per contig per sample), `pindel` writes `pout/<seq>_*`, `pin2vcf` writes
`vcf/<seq>_pindel.*`. `merge_and_bam` reads only `vcf/`, and `flag` only merge's
output. `PCAP::Threaded` marker files are `<caller_sub>.<index>`, namespaced per
function, and exist precisely so an external scheduler can run indices
independently — which is exactly what toil was doing. Nothing needed reverse
engineering.

**2. The efficiency gap was overstated, and my default caused it.** A contig
cannot be split, so the longest contig is the critical path in both shapes:
scattered bottoms out at `longest contig`, unstaged at
`max(total/C, longest contig)`. chr1 is ~8% of GRCh37, so they converge at
`C ≥ ~13`. I had set `pindel_cpus = 4`, which put the unstaged path at ~3× the
floor — a bad default I then rationalised as inherent to the design. It came
from cgpPindel's *"recommend max 4 during 'input'"* note, which is scoped to a
stage that has two work items and that cgpPindel caps itself
(`add_function('input', ..., 2)`).

The lesson worth keeping: I rejected a viable design on a guess about code I
had not read, and presented the guess as a finding.

## Both paths now exist

`--scatter_by_contig` (default `true`) selects between them:

| | processes | shape |
| --- | --- | --- |
| Scattered | `CGPPINDEL_INPUT` → `CGPPINDEL_CALL` (per contig) → `CGPPINDEL_MERGE_FLAG` | many 1-core slots, as toil |
| Unstaged | `CGPPINDEL` | one large slot, as cancerit's own Nextflow |

toil's five stages become three: `pindel` and `pin2vcf` fuse because they are
sequential on one contig's data, and `merge`/`flag` fuse because flag consumes
merge's output.

**The design trick**: stage exactly one contig per task and always pass
`-index 1`. `determine_jobs` derives index → contig from `keys %seqs` on a Perl
hash, which is order-randomised per process — so toil's `pindel -index 3` and
`pin2vcf -index 3` could mean different contigs. Harmless there, but not
reproducible. One contig per task removes the ambiguity entirely and is why the
two per-contig stages can be fused.

**Excluded contigs must be filtered in Nextflow.** The input stage emits every
contig in the BAM. On the unstaged path cgpPindel drops the excluded ones itself
in `determine_jobs`; on the scattered path a task staging an excluded contig
would find zero valid sequences and die inside `PCAP::Threaded` with
"Iterations must be a positive integer: 0". The subworkflow mirrors cgpPindel's
`%`-wildcard matching before scattering.

## Equivalence, verified

The two paths were run on the same test data and compared:

| check | result |
| --- | --- |
| published file set | identical |
| VCF records incl. INFO and FORMAT (ID blanked) | identical, 6 records |
| germline BED | identical |
| `_mt.bam` / `_wt.bam` read counts | 522 / 1237 both |

The ID column is excluded because cgpPindel randomises it per run.

**Caveat worth stating plainly:** the test reference has one contig, so N=1 and
the fan-out/fan-in are structurally exercised but not stressed. The suite asserts
the task counts per path so a silent collapse to one task would fail, but the
comparison should be repeated on a multi-contig reference before the scattered
path is trusted for production WGS.

## Two findings about toil_pindel worth keeping

1. **`--tgd` never reached cgpPindel.** It reads like a data-type flag, but all
   it did was lower the Toil memory request from 30G to 6G and shorten the
   runtime for three stages. Replaced by explicit `--pindel_cpus` /
   `--pindel_memory`.
2. **`--exclude` was effectively required despite being declared optional.**
   `get_total_regions` called `.split(",")` on it, so omitting it raised an
   AttributeError rather than processing all contigs. Here it is simply not
   passed when unset, which is what the declaration implied.

Related: `toil_pindel` never passed `-seqtype`, so cgpPindel ran in its `WGS`
default even for targeted data. `--seqtype` now exposes the option and still
defaults to `WGS`, so nothing changes unless you set it.

## Open items

- **No GitHub remote.** `gh` was unavailable, so the repo is local-only. Pushing
  needs `git remote add origin` plus `git push --all origin`, which also pushes
  the `dev` and `TEMPLATE` branches the nf-core template creates.
- **`manifest.version = '1.0.0'`** draws a lint warning; nf-core wants unreleased
  pipelines on `1.0.0dev`. A release-tagging call.
- **The scatter has only been exercised at N=1.** See the caveat above: repeat
  the cross-path comparison on a multi-contig reference before production WGS.
- **Concordance against a real pair is not yet done.** Because the cgpPindel
  version is unchanged, the expectation is equality — but that expectation should
  be checked once on a real analysis that already has toil output, comparing
  CHROM/POS/REF/ALT/FILTER and ignoring ID.
- **The container is not multi-arch.** `quay.io/wtsicgp/cgppindel:3.10.0` is
  amd64 only, so on Apple silicon the `emulate_amd64` profile is required.

## Regenerating the metro map

```bash
pip install nf-metro
nf-metro render docs/images/nf-pindel_metro_map.mmd -o docs/images/nf-pindel_metro_map.svg
```

The map shows the scattered path, which is the default and the interesting one:
input, the per-contig call, merge+flag, with the flagging resources joining only
at the end because that is the only stage that reads them.

An earlier version tried to draw cgpPindel's internal stages as a dashed line
alongside a single process station. It rendered as a nine-station track with
colliding labels and implied a parallelism that version did not have. Now that
the scatter is real, the processes and the diagram agree.
