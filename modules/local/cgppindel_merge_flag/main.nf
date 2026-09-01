process CGPPINDEL_MERGE_FLAG {
    tag "${meta.id}"
    label 'process_single'

    container "quay.io/wtsicgp/cgppindel:3.10.0"

    input:
    tuple val(meta), path(vcf_parts), path(normal_bam), path(normal_bai), path(normal_bas), path(tumor_bam), path(tumor_bai), path(tumor_bas)
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
    // merge reads only tmpPindel/vcf and emits the merged VCF plus the _mt/_wt
    // BAMs; flag then reads merge's output. Neither needs the per-contig read
    // files, so only the vcf parts are gathered here.
    //
    // The flag stage also runs cgpPindel's own cleanup, which drops the
    // unflagged <stub>.vcf.gz and leaves exactly the file set toil published.
    """
    mkdir -p out/tmpPindel/vcf

    for f in ${vcf_parts}; do
        cp "\${f}" out/tmpPindel/vcf/
    done

    pindel.pl \\
        -process merge \\
        -index 1 \\
        -noflag \\
        -outdir out \\
        -reference ${fasta} \\
        -tumour ${tumor_bam} \\
        -normal ${normal_bam} \\
        ${badloci_arg} \\
        -cpus ${task.cpus} \\
        ${args}

    pindel.pl \\
        -process flag \\
        -index 1 \\
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
