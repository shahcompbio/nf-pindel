# nf-pindel

cgpPindel tumour-normal indel calling as one Nextflow task. One process runs the
full `pindel.pl` in `quay.io/wtsicgp/cgppindel:3.11.1`: input generation, pindel per
contig, VCF conversion, merge and flagging. Flagging writes `<T>_vs_<N>.germline.bed`,
which the Isabl Caveman app reads.

The parameters mirror the `pindel.pl` flags one to one. Index files (`.bai`, `.fai`,
`.tbi`) and `.bas` files are staged from beside their parent files.

```bash
nextflow run shahcompbio/nf-pindel \
    --outdir out \
    --tumour tumour.bam --normal normal.bam \
    --genomefa genome.fa \
    --species HUMAN --assembly GRCh37 \
    --exclude 'NC_007605,hs37d5,GL%' \
    --genes genes.bed.gz --simrep simpleRepeats.bed.gz \
    --unmatched normal_panel.gff3.gz --badloci bad_regions.bed.gz \
    --filter_genomic genomicRules.lst --filter_targeted targetedRules.lst \
    --seqtype WGS
```

`--targeted true` picks the targeted rule set instead of the genomic one, and
`--filter <file>` overrides both. Pass booleans through `-params-file`: on the
command line `--targeted false` arrives as a string, which counts as true.

The task asks for 16 cpus and 160 GB, doubled on the one retry after a kill.
Override `params.cpus` and `params.memory_gb` from a `-config` file. Reports go to
`<outdir>/pipeline_info/`.

Outputs land in `--outdir`: the flagged VCF with index, `_mt` and `_wt` BAMs with
indexes, and the germline BED.

Before this rewrite the repo held an nf-core template with a per-contig scatter; it is
in the git history before the `single-process` branch.
