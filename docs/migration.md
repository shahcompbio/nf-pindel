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

## The execution model changed

`toil_pindel` drove cgpPindel's *targeted processing* interface, running
`pindel.pl -process X -index N` as five separate Toil stages over a shared
`-outdir`:

```
input × 2  →  pindel × N  →  pin2vcf × N  →  merge × 1  →  flag × 1
```

where N was the contig count from the `.fai` minus `--exclude` matches. Those
stages communicate by leaving files in the shared output directory, which is
exactly what Nextflow's isolated task directories prevent.

This pipeline instead runs **`pindel.pl` once per pair, unstaged**, letting
cgpPindel do its own staging and threading via `-cpus`. That is what cancerit's
own Nextflow implementation does, and `-process`/`-index` are documented as
optional "targeted processing" precisely for external schedulers like Toil.

**The trade-off:** parallelism is now per-node (`-cpus ${task.cpus}`) rather than
one task per contig across the cluster. For WGS this is a real throughput
reduction. Nextflow still parallelises across pairs, so a cohort run is unaffected;
a single WGS pair will take longer than it did under Toil.

If that becomes a problem, the staged design can be reintroduced by passing the
accumulated output directory between processes and recombining the N parallel
`pindel`/`pin2vcf` outputs. It was deliberately not done here because it depends
on cgpPindel's undocumented intermediate layout and would break whenever
cgpPindel changes internals.

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
| `--max_cores_usage` | `--pindel_cpus` | Becomes `task.cpus`, passed as `-cpus` |
| `--max_memory_usage` | `--pindel_memory` | Becomes `task.memory` |
| `--tgd` | `--pindel_cpus` / `--pindel_memory` | See below |
| `--short_job` | `task.time` in `conf/base.config` | |
| Toil `jobStore`, `--restart`, `--batchSystem` | `-resume`, `-profile` | Native Nextflow |
| — | `--seqtype` | New; see below |
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
