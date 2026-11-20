// One-process port of toil_pindel v1.2.0. Toil ran `pindel.pl -process <stage>`
// as separate cluster jobs over a shared tmpPindel folder. Here one task runs
// every stage of pindel.pl, flag included, so <T>_vs_<N>.germline.bed is
// always written. Parameters mirror the pindel.pl flags one to one.

params.outdir = null
params.tumour = null
params.normal = null
params.genomefa = null
params.species = null
params.assembly = null
params.exclude = ''
params.genes = null
params.simrep = null
params.unmatched = null
// pindel.pl -filter: the genomic or the targeted rule set. A caller picks one
// with `targeted` and keeps both paths in its site config; `filter` overrides both.
params.filter = null
params.filter_genomic = null
params.filter_targeted = null
params.targeted = false
params.badloci = null
params.seqtype = 'WGS'

process PINDEL {
    container 'quay.io/wtsicgp/cgppindel:3.11.1'
    publishDir params.outdir, mode: 'copy'

    input:
    path tumour
    path normal
    path genomefa
    path genes
    path simrep
    path unmatched
    path filter
    path badloci
    path sidecars
    val species
    val assembly
    val exclude
    val seqtype

    output:
    path '*.flagged.vcf.gz', emit: vcf
    path '*.flagged.vcf.gz.tbi', emit: tbi
    path '*_mt.bam', emit: mt_bam
    path '*_mt.bam.bai', emit: mt_bai
    path '*_wt.bam', emit: wt_bam
    path '*_wt.bam.bai', emit: wt_bai
    path '*.germline.bed', emit: germline_bed

    script:
    def exclude_arg = exclude ? "-exclude '${exclude}'" : ''
    def badloci_arg = badloci ? "-badloci ${badloci}" : ''
    """
    pindel.pl \\
        -outdir . \\
        -tumour ${tumour} \\
        -normal ${normal} \\
        -reference ${genomefa} \\
        -species ${species} \\
        -assembly ${assembly} \\
        ${exclude_arg} \\
        -genes ${genes} \\
        -simrep ${simrep} \\
        -unmatched ${unmatched} \\
        ${badloci_arg} \\
        -filter ${filter} \\
        -seqtype ${seqtype} \\
        -cpus ${task.cpus}
    """

    stub:
    """
    touch T_vs_N.flagged.vcf.gz T_vs_N.flagged.vcf.gz.tbi T_vs_N.germline.bed
    touch T_vs_N_mt.bam T_vs_N_mt.bam.bai T_vs_N_wt.bam T_vs_N_wt.bam.bai
    """
}

workflow {
    main:
    def bams = [params.tumour, params.normal].collect { b -> file(b, checkIfExists: true) }
    def tabixed = [params.genes, params.simrep, params.unmatched, params.badloci].findAll { f -> f }
    // A .bas beside the BAM gives cgpPindel each read group's insert size.
    // Toil read it in place, so stage it whenever it exists.
    def sidecars = bams.collect { b -> file("${b}.bai", checkIfExists: true) } +
        bams.collect { b -> file("${b}.bas") }.findAll { f -> f.exists() } +
        tabixed.collect { f -> file("${f}.tbi", checkIfExists: true) } +
        [file("${params.genomefa}.fai", checkIfExists: true)]

    PINDEL(
        bams[0],
        bams[1],
        file(params.genomefa, checkIfExists: true),
        file(params.genes, checkIfExists: true),
        file(params.simrep, checkIfExists: true),
        file(params.unmatched, checkIfExists: true),
        file(params.filter ?: (params.targeted ? params.filter_targeted : params.filter_genomic), checkIfExists: true),
        params.badloci ? file(params.badloci, checkIfExists: true) : [],
        sidecars,
        params.species,
        params.assembly,
        params.exclude,
        params.seqtype,
    )
}
