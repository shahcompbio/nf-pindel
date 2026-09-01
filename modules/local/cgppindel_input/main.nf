process CGPPINDEL_INPUT {
    tag "${meta.id}"
    label 'process_low'

    container "quay.io/wtsicgp/cgppindel:3.10.0"

    input:
    tuple val(meta), path(normal_bam), path(normal_bai), path(normal_bas), path(tumor_bam), path(tumor_bai), path(tumor_bas)
    tuple val(meta2), path(fasta), path(fai)
    tuple path(badloci), path(badloci_tbi)

    output:
    // cgpPindel writes tmpPindel/<sample>/<seq>.txt.gz — one file per contig per
    // sample. Both samples use the same basename, so the sample is folded into
    // the filename here to survive Nextflow's flat staging. A sanitised sample
    // name can only contain [a-z0-9_-], so the first '.' is an unambiguous
    // separator even though contig names often contain dots (GL000191.1).
    tuple val(meta), path("reads/*.txt.gz"), emit: reads
    tuple val("${task.process}"), val('cgpPindel'), eval("pindel.pl -version 2>&1 | sed 's/^Version: //'"), topic: versions, emit: versions_cgppindel

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def badloci_arg = badloci ? "-badloci ${badloci}" : ''
    // -noflag skips validation of the flagging resources, which this stage does
    // not use, so simrep/genes/unmatched need not be staged here.
    // cgpPindel caps this stage at two work items regardless of -cpus.
    """
    mkdir -p out reads

    for index in 1 2; do
        pindel.pl \\
            -process input \\
            -index \${index} \\
            -noflag \\
            -outdir out \\
            -reference ${fasta} \\
            -tumour ${tumor_bam} \\
            -normal ${normal_bam} \\
            ${badloci_arg} \\
            -cpus ${task.cpus} \\
            ${args}
    done

    for dir in out/tmpPindel/*/; do
        sample=\$(basename "\${dir}")
        if [[ "\${sample}" == *.* ]]; then
            echo "ERROR: BAM SM tag '\${sample}' contains '.', which breaks the contig scatter. Rename the sample." >&2
            exit 1
        fi
        for f in "\${dir}"*.txt.gz; do
            [ -e "\${f}" ] || continue
            mv "\${f}" "reads/\${sample}.\$(basename \${f})"
        done
    done
    """

    stub:
    """
    mkdir -p reads
    echo "" | gzip > reads/tumor.2.txt.gz
    echo "" | gzip > reads/normal.2.txt.gz
    """
}
