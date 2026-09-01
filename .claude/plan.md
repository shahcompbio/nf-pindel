# Port `toil_pindel` → `shahcompbio/nf-pindel` (Nextflow DSL2, nf-core conventions)

> **Historical record.** This is the implementation plan written before building
> the pipeline, kept for provenance. `file.py:NN` references point at the
> original `toil_pindel` repository. What was actually built, and how it was
> verified, is in [results.md](results.md).

## Context

`toil_pindel` v1.1.8 is a thin Toil wrapper around **cgpPindel 3.10.0**, the
Sanger indel caller. It is being retired alongside `toil_strelka` and
`toil_mutect`.

This port differs from those two in two important ways.

**There is no usable nf-core module.** nf-core ships `pindel/pindel`, but that is
the *original* Pindel (0.2.5b9, Ye et al.) — a different tool that emits raw
`_D`/`_SI`/`_TD` text files. It cannot produce the flagged VCF, `_mt.bam`,
`_wt.bam` or germline BED that this pipeline and the downstream `isabl_apps`
contract require. cgpPindel is not on bioconda. So the pipeline is a single local
module wrapping `pindel.pl` in `quay.io/wtsicgp/cgppindel:3.10.0`, the image
`toil_pindel` itself built on.

**The tool version is preserved exactly**, unlike the mutect port. Same
cgpPindel, same container, so results are expected to match rather than merely
be comparable.

## The one real design problem

`toil_pindel` drove cgpPindel's *targeted processing* interface — `pindel.pl
-process X -index N` — as five Toil stages over a shared `-outdir`
([commands.py:99-129](toil_pindel/commands.py#L99-L129)):

```
input × 2  →  pindel × N  →  pin2vcf × N  →  merge × 1  →  flag × 1
```

N is the contig count from the `.fai` minus `--exclude` matches
([commands.py:285-298](toil_pindel/commands.py#L285-L298)). Those stages
communicate through files left in the shared directory — precisely what
Nextflow's isolated task directories prevent.

**Decision taken: run `pindel.pl` once per pair, unstaged.** `-process`/`-index`
are documented as optional, and cancerit's own `main.nf` invokes cgpPindel as a
single command with `-c ${task.cpus}`. cgpPindel then does its own staging and
threading. Output is identical; parallelism moves from per-contig-across-cluster
to per-node, which is a real WGS throughput cost and must be documented.

The alternative — staging the accumulated outdir between processes and
recombining N parallel outputs — was rejected: it depends on cgpPindel's
undocumented intermediate layout and would break on any internal change.

## Architecture

```
samplesheet ──► group by patient ──► [meta, normal bam/bai/bas, tumour bam/bai/bas]
                                              │
                    reference (fasta + fai) ──┤
        simrep, genes, unmatched, rules, badloci ──┤
                                              ▼
                                        CGPPINDEL
                                    (one pindel.pl run)
                                              │
                                              ▼
                    flagged.vcf.gz, _mt.bam, _wt.bam, germline.bed
```

One process. The metro map should show that honestly rather than dressing up
cgpPindel's internal stages as pipeline steps.

## Files to create

| Path | Purpose |
| --- | --- |
| `workflows/pindel.nf` | Reference and resource channels, call the module |
| `modules/local/cgppindel/main.nf` | Wrap `pindel.pl`, emit the full result set |
| `conf/modules.config` | `ext.args` for species/assembly/exclude/seqtype, legacy publishing |
| `conf/test.config` | The toil test, ported |
| `assets/schema_input.json`, `nextflow_schema.json` | Validation |
| `tests/data/` | Copied from `toil_pindel/tests/data/` |

## Parameter mapping

| toil_pindel | nf-pindel | Notes |
| --- | --- | --- |
| `--tumor_bam` / `--normal_bam` | samplesheet `status` 1/0 | |
| `--reference` | `--fasta` (+ `--fai`) | cgpPindel reads the `.fai` for contigs |
| `--species` / `--assembly` / `--exclude` | same | Via `ext.args` |
| `--filter` | `--filter_rules` | Renamed for clarity |
| `--genes` / `--simrep` / `--unmatched` / `--badloci` | same (+ `_tbi`) | |
| `--max_cores_usage` / `--max_memory_usage` | `--pindel_cpus` / `--pindel_memory` | |
| `--tgd` | dropped | Only ever changed Toil resource requests |
| `--short_job` | `task.time` | |
| — | `--seqtype` | New; cgpPindel option toil never passed |
| — | `--flat_publish` | |

## Output layout

`isabl_apps` globs from `--outdir` directly:

```
<outdir>/[<patient>/]<tumour>_vs_<normal>.flagged.vcf.gz(.tbi)
<outdir>/[<patient>/]<tumour>_vs_<normal>_mt.bam(.bai)
<outdir>/[<patient>/]<tumour>_vs_<normal>_wt.bam(.bai)
<outdir>/[<patient>/]<tumour>_vs_<normal>.germline.bed
```

Names come from the BAM SM tags, so publish exactly what cgpPindel writes — no
renaming.

## Tests

`toil_pindel` had a single test asserting only that
`tumor_vs_normal.flagged.vcf.gz` existed
([tests/test_commands.py:63](tests/test_commands.py#L63)). The port should assert
more: the full result contract, the call set, and that flagging actually
populated FILTER rather than leaving everything at PASS.

## Expected deltas

1. Parallelism is per-node rather than per-contig (the execution-model change).
2. `--tgd` and `--filter` are gone/renamed.
3. `--seqtype` is new, defaulting to cgpPindel's WGS default, which is what toil
   effectively used.
4. `--exclude` is genuinely optional now; in toil it was declared optional but
   `get_total_regions` would raise on `None`.

## Verification

1. `nf-test test --profile docker` green.
2. `nf-core pipelines lint` clean.
3. The toil test's assertion holds, and every `isabl_apps` glob resolves.
4. Since the cgpPindel version is unchanged, a real pair should produce matching
   calls — verify on one and record it.
