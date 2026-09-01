process CGPPINDEL {
    tag "${meta.id}"
    label 'process_medium'

    // cgpPindel is not on bioconda and has no nf-core module: nf-core's
    // pindel/pindel is the original Pindel, a different tool that emits raw
    // _D/_SI text files rather than a flagged VCF. Use the image cancerit
    // publish, which is what toil_pindel built on.
    container "quay.io/wtsicgp/cgppindel:3.10.0"

    input:
    tuple val(meta), path(normal_bam), path(normal_bai), path(normal_bas), path(tumor_bam), path(tumor_bai), path(tumor_bas)
    tuple val(meta2), path(fasta), path(fai)
    tuple path(simrep), path(simrep_tbi)
    tuple path(genes), path(genes_tbi)
    tuple path(unmatched), path(unmatched_tbi)
    tuple path(badloci), path(badloci_tbi)
    path filter_rules

    output:
    tuple val(meta), path("out/*.flagged.vcf.gz")    , emit: vcf
    tuple val(meta), path("out/*.flagged.vcf.gz.tbi"), emit: tbi
    tuple val(meta), path("out/*_mt.bam")            , emit: mt_bam
    tuple val(meta), path("out/*_mt.bam.bai")        , emit: mt_bai
    tuple val(meta), path("out/*_wt.bam")            , emit: wt_bam
    tuple val(meta), path("out/*_wt.bam.bai")        , emit: wt_bai
    tuple val(meta), path("out/*.germline.bed")      , emit: germline_bed, optional: true
    tuple val("${task.process}"), val('cgpPindel'), eval("pindel.pl -version 2>&1 | sed 's/^Version: //'"), topic: versions, emit: versions_cgppindel

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def badloci_arg = badloci ? "-badloci ${badloci}" : ''
    // toil_pindel drove cgpPindel's -process/-index staging to scatter its five
    // stages across a shared outdir. Run it unstaged instead, letting cgpPindel
    // do its own staging and threading — which is what cancerit's own Nextflow
    // does. Output is the same; parallelism is per-node rather than per-contig.
    //
    // Output names come from the BAM headers' SM tags, not from the samplesheet,
    // so they are published exactly as cgpPindel writes them.
    """
    mkdir -p out

    pindel.pl \\
        -outdir out \\
        -reference ${fasta} \\
        -tumour ${tumor_bam} \\
        -normal ${normal_bam} \\
        -simrep ${simrep} \\
        -filter ${filter_rules} \\
        -genes ${genes} \\
        -unmatched ${unmatched} \\
        ${badloci_arg} \\
        -cpus ${task.cpus} \\
        ${args}
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.tumor_id}_vs_${meta.normal_id}"
    """
    mkdir -p out
    echo "" | gzip > out/${prefix}.flagged.vcf.gz
    touch out/${prefix}.flagged.vcf.gz.tbi
    touch out/${prefix}_mt.bam out/${prefix}_mt.bam.bai
    touch out/${prefix}_wt.bam out/${prefix}_wt.bam.bai
    touch out/${prefix}.germline.bed
    """
}
