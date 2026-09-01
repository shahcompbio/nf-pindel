process CGPPINDEL_CALL {
    tag "${meta.id} - ${meta.seq}"
    label 'process_single'

    container "quay.io/wtsicgp/cgppindel:3.10.0"

    input:
    tuple val(meta), path(reads), path(normal_bam), path(normal_bai), path(normal_bas), path(tumor_bam), path(tumor_bai), path(tumor_bas)
    tuple val(meta2), path(fasta), path(fai)
    tuple path(badloci), path(badloci_tbi)

    output:
    tuple val(meta), path("out/tmpPindel/vcf/*"), emit: vcf_parts
    tuple val("${task.process}"), val('cgpPindel'), eval("pindel.pl -version 2>&1 | sed 's/^Version: //'"), topic: versions, emit: versions_cgppindel

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def badloci_arg = badloci ? "-badloci ${badloci}" : ''
    // Only this contig's two read files are staged, so cgpPindel's determine_jobs
    // finds exactly one sequence and -index 1 is unambiguous.
    //
    // That matters: determine_jobs derives the index -> contig mapping from
    // `keys %seqs` on a Perl hash, which is order-randomised per process. toil
    // ran `pindel -index i` and `pin2vcf -index i` as separate processes against
    // one shared directory, so index 3 could mean different contigs in the two
    // stages. Harmless there — every index runs, so every contig is covered once
    // per stage — but not reproducible. One contig per task removes the ambiguity
    // entirely, and lets pindel and pin2vcf be fused into a single task.
    """
    mkdir -p out/tmpPindel

    for f in ${reads}; do
        sample="\${f%%.*}"
        seqfile="\${f#*.}"
        mkdir -p "out/tmpPindel/\${sample}"
        cp "\${f}" "out/tmpPindel/\${sample}/\${seqfile}"
    done

    for stage in pindel pin2vcf; do
        pindel.pl \\
            -process \${stage} \\
            -index 1 \\
            -noflag \\
            -outdir out \\
            -reference ${fasta} \\
            -tumour ${tumor_bam} \\
            -normal ${normal_bam} \\
            ${badloci_arg} \\
            -cpus ${task.cpus} \\
            ${args}
    done
    """

    stub:
    """
    mkdir -p out/tmpPindel/vcf
    touch out/tmpPindel/vcf/${meta.seq}_pindel.vcf
    """
}
