# Port results: `toil_pindel` → `shahcompbio/nf-pindel`

What was built against [plan.md](plan.md), and how it was verified. Written
2026-09-01.

## Outcome

The port is complete and green. It runs **the same cgpPindel 3.10.0 from the same
container** `toil_pindel` used, so unlike the mutect port there is no
tool-version delta and results are expected to match rather than merely be
comparable.

- **2/2 nf-test cases pass**, stable on a re-run with no snapshot updates.
- **`nf-core pipelines lint`: 0 failures.**

## What was built

| Piece | Path |
| --- | --- |
| Reference and resource channels | [`workflows/pindel.nf`](../workflows/pindel.nf) |
| The whole caller | [`modules/local/cgppindel/main.nf`](../modules/local/cgppindel/main.nf) |
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
per-patient and `--flat_publish` layouts.

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

## The one behavioural change

Parallelism, not output.

`toil_pindel` drove cgpPindel's five stages itself — `input × 2 → pindel × N →
pin2vcf × N → merge → flag` — scattering N contigs across the cluster. This
pipeline runs `pindel.pl` once per pair and lets cgpPindel do its own staging and
threading over `-cpus`, which is what cancerit's own `main.nf` does.

**The cost is real for single-pair WGS**: parallelism is now bounded by one
node's cores rather than the contig count. Cohort runs are unaffected, since
Nextflow parallelises across pairs.

The staged design was rejected deliberately, not overlooked: cgpPindel's stages
communicate through a shared output directory whose intermediate layout is
undocumented, so recombining N parallel outputs would be reverse-engineering
something that breaks on any cgpPindel internal change. If WGS runtime turns out
to matter, `docs/migration.md` describes what reintroducing it would involve.

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

The map deliberately shows the four things that exist at the Nextflow level —
input, resources, `pindel.pl`, results — rather than cgpPindel's internal stages.
An earlier version drew those stages as a dashed line; it rendered as a
nine-station track with colliding labels and implied a parallelism the pipeline
does not have. The internal staging is explained in prose in the README instead,
which is where it belongs.
