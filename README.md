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
    --filter genomicRules.lst \
    --seqtype WGS \
    --cpus 16 --memory_gb 32
```

Outputs land in `--outdir`: the flagged VCF with index, `_mt` and `_wt` BAMs with
indexes, and the germline BED.

Before this rewrite the repo held an nf-core template with a per-contig scatter; it is
in the git history before the `single-process` branch.
