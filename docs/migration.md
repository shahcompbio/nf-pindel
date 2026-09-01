# Migrating from toil_pindel

`shahcompbio/nf-pindel` is the Nextflow port of the `toil_pindel` Toil pipeline,
v1.1.8. Both drive **cgpPindel 3.10.0** from the same
`quay.io/wtsicgp/cgppindel:3.10.0` image, so unlike the mutect port there is no
tool-version delta — results are expected to match.

## Why there is no nf-core module here

nf-core ships `pindel/pindel`, but that is the **original Pindel** (0.2.5b9 by
Kai Ye), a different tool. It emits raw `_D`, `_SI`, `_TD` text files and cannot
produce the flagged VCF, `_mt.bam`/`_wt.bam` or germline BED that this pipeline
and the downstream `isabl_apps` contract depend on. cgpPindel is a Sanger
reimplementation with its own VCF output and flagging rules, is not on bioconda,
and has no nf-core module — so the pipeline is a single local module wrapping
`pindel.pl` in cancerit's published image.

## Two execution shapes, same output

`toil_pindel` drove cgpPindel's *targeted processing* interface, running
`pindel.pl -process X -index N` as five Toil stages over a shared `-outdir`:

```
input × 2  →  pindel × N  →  pin2vcf × N  →  merge × 1  →  flag × 1
```

where N was the contig count from the `.fai` minus `--exclude` matches. Those
stages communicate by leaving files in the shared output directory, which is
what Nextflow's isolated task directories prevent.

This pipeline offers both shapes and defaults to the scattered one.

### Scattered, `--scatter_by_contig true` (default)

Three processes, with toil's five stages fused where they are sequential on the
same data:

```
CGPPINDEL_INPUT        one task per pair   -process input -index 1,2
CGPPINDEL_CALL         one task per contig -process pindel then pin2vcf, -index 1
CGPPINDEL_MERGE_FLAG   one task per pair   -process merge then flag
```

Each `CALL` task is one contig on one core — the same scheduling shape toil
asked for, so it fits the same many-small-slots clusters.

**The trick is to stage exactly one contig per task and always pass `-index 1`.**
cgpPindel's `input` stage writes `tmpPindel/<sample>/<seq>.txt.gz`, one file per
contig per sample, so a calling task needs only its own two files rather than
the whole genome's candidate reads.

This is also more reproducible than toil was. `determine_jobs` derives the
index → contig mapping from `keys %seqs` on a Perl hash, which is order-
randomised per process, so toil's `pindel -index 3` and `pin2vcf -index 3` could
refer to different contigs. Harmless — every index runs, so every contig is
covered exactly once per stage — but not deterministic. One contig per task
removes the ambiguity, and lets `pindel` and `pin2vcf` be fused.

### Unstaged, `--scatter_by_contig false`

One `pindel.pl` per pair, letting cgpPindel do its own staging and thread across
`-cpus`. This is what cancerit's own Nextflow does. It wants a single large slot
instead of many small ones, and stages nothing between stages, so it is the
better choice when big nodes are easy to get or shared storage is slow.

### Neither is faster, past a point

A contig cannot be split, so the longest contig is the critical path either way:

| | wall-clock floor |
| --- | --- |
| scattered, N tasks | `longest contig` |
| unstaged, C cores | `max(total work / C, longest contig)` |

chr1 is ~249 Mb of GRCh37's ~3.1 Gb, about 8% of the work, so the two converge
once `C ≥ ~13`. `--pindel_cpus` therefore defaults to 16 on the unstaged path;
setting it lower is what makes that path slower, not the design.

The difference between them is scheduling shape and I/O, not throughput.

### Verified equivalent

On the bundled test data, the two paths produce byte-identical output apart from
the ID column that cgpPindel randomises: same file set, same records including
INFO and FORMAT fields, same germline BED, same `_mt`/`_wt` BAM read counts. The
test reference has a single contig, so the fan-out and fan-in are structurally
exercised but not stressed — repeat the comparison on a multi-contig reference
before trusting the scattered path for production WGS.

## Parameter mapping

| toil_pindel | nf-pindel | Notes |
| --- | --- | --- |
| `--tumor_bam` / `--normal_bam` | samplesheet `status` 1/0 | Grouped by `patient` |
| `--outdir` | `--outdir` | |
| `--reference` | `--fasta` (+ `--fai`) | cgpPindel reads the `.fai` to enumerate contigs |
| `--species` | `--species` | Read from the BAM header when unset |
| `--assembly` | `--assembly` | Read from the BAM header when unset |
| `--exclude` | `--exclude` | |
| `--filter` | `--filter_rules` | Renamed; `--filter` is ambiguous next to the flagging resources |
| `--genes` / `--simrep` / `--unmatched` | same names (+ `_tbi`) | Indexes default to `<file>.tbi` |
| `--badloci` | `--badloci` (+ `--badloci_tbi`) | Optional |
| `--max_cores_usage` | `--pindel_cpus` | Unstaged path only; becomes `task.cpus`, passed as `-cpus` |
| `--max_memory_usage` | `--pindel_memory` | Becomes `task.memory` |
| `--tgd` | `--pindel_cpus` / `--pindel_memory` | See below |
| `--short_job` | `task.time` in `conf/base.config` | |
| Toil `jobStore`, `--restart`, `--batchSystem` | `-resume`, `-profile` | Native Nextflow |
| — | `--seqtype` | New; see below |
| — | `--scatter_by_contig` | Choose the execution shape; default `true` |
| — | `--flat_publish` | Drop the `<patient>/` publish level |

### `--tgd` was only a resource switch

It looked like a data-type flag, but `--tgd` never reached cgpPindel. All it did
was lower the Toil request from 30G to 6G and shorten the runtime for the
`input`, `pindel` and `pin2vcf` stages. `--pindel_cpus` and `--pindel_memory`
replace it explicitly.

### `--seqtype` is new, and defaults to toil's behaviour

cgpPindel takes `-seqtype` (WGS, WXS, TGD), but `toil_pindel` never passed it —
so cgpPindel always ran in its `WGS` default, even for targeted data. `--seqtype`
makes the choice available and still defaults to `WGS`, so behaviour is unchanged
unless you set it.

## Output layout

`toil_pindel` wrote cgpPindel's results straight into `--outdir`, and the
`isabl_apps` contract globs them from there. With `--flat_publish`:

```text
<outdir>/<tumour>_vs_<normal>.flagged.vcf.gz(.tbi)
<outdir>/<tumour>_vs_<normal>_mt.bam(.bai)
<outdir>/<tumour>_vs_<normal>_wt.bam(.bai)
<outdir>/<tumour>_vs_<normal>.germline.bed
```

Without it each patient gets its own `<outdir>/<patient>/` subtree, which is what
makes multi-pair runs possible.

Those names come from the **BAM headers' SM tags**, not from the samplesheet, so
outputs are published exactly as cgpPindel writes them and no renaming is done.

## The VCF is not byte-reproducible

cgpPindel stamps a freshly generated UUID into the ID column of every record on
every run. Two runs over identical inputs produce VCFs that differ in that
column. When comparing this pipeline's output against toil's, compare
CHROM/POS/REF/ALT/FILTER and ignore the ID field — the test suite does exactly
that.

## Other deltas

1. **`--exclude` is now genuinely optional.** In toil it was declared optional
   but `get_total_regions` called `.split(",")` on it, so omitting it raised an
   AttributeError. Here it is simply not passed when unset.
2. **No `.bas` requirement.** cgpPindel's usage mentions co-located `bas` files;
   the samplesheet has an optional `bas` column that is staged when given.
3. **No hand-rolled cleanup.** Nextflow keeps intermediates in the work
   directory, managed by `nextflow clean`.

## Updating isabl_apps

`isabl_apps`' `Pindel` class builds a `toil_pindel` command string. Switching
over means emitting a `nextflow run shahcompbio/nf-pindel` command plus a
generated two-row samplesheet, passing `--flat_publish`, and renaming `--filter`
to `--filter_rules`. `get_analysis_results` needs no change — it globs, and the
globs still resolve.
