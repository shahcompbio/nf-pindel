# shahcompbio/nf-pindel: Output

## Introduction

This document describes the output produced by the pipeline. All paths are
relative to the directory given by `--outdir`.

## Layout

By default every patient publishes into its own subtree:

```text
<outdir>/<patient>/...
```

Passing `--flat_publish` drops that level, reproducing the `toil_pindel` layout,
which wrote straight into `--outdir`. Only use it for single-pair runs — every
patient would otherwise publish to the same paths.

File names come from the **BAM headers' SM tags**, not the samplesheet, and are
published exactly as cgpPindel writes them.

## cgpPindel results

<details markdown="1">
<summary>Output files</summary>

- `<tumour>_vs_<normal>.flagged.vcf.gz(.tbi)`: indel calls with the FILTER column
  populated by the flagging rules
- `<tumour>_vs_<normal>_mt.bam(.bai)`: reads supporting calls, mutant sample
- `<tumour>_vs_<normal>_wt.bam(.bai)`: reads supporting calls, wild-type sample
- `<tumour>_vs_<normal>.germline.bed`: germline events, when cgpPindel emits any

</details>

Records are not removed by flagging — they are marked. `PASS` is the confident
set; `F001`, `F003`, `F005`, `F008` and friends come from the rules file given to
`--filter_rules`, and the specific codes depend on which rule set you supply.

## The ID column changes every run

cgpPindel stamps a freshly generated UUID into the ID column of each record, so
two runs over identical inputs produce VCFs that differ there. When diffing runs,
compare CHROM/POS/REF/ALT/FILTER and ignore ID.

## Pipeline information

<details markdown="1">
<summary>Output files</summary>

- `pipeline_info/`
  - Execution reports: `execution_report_*.html`, `execution_timeline_*.html`, `execution_trace_*.txt`, `pipeline_dag_*.html`
  - `pindel_software_versions.yml`: versions of every tool used
  - `params_*.json`: the parameters the run was launched with

</details>
