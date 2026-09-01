/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { CGPPINDEL              } from '../modules/local/cgppindel/main'
include { CGPPINDEL_SCATTER      } from '../subworkflows/local/cgppindel_scatter'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PINDEL {

    take:
    ch_samplesheet // channel: [ meta, normal_bam, normal_bai, normal_bas, tumor_bam, tumor_bai, tumor_bas ]
    outdir

    main:

    //
    // Reference. cgpPindel reads the .fai directly to work out which contigs to
    // process, so it must be co-located with the FASTA.
    //
    def ch_fasta = channel.value([
        [id: 'fasta'],
        file(params.fasta, checkIfExists: true),
        file(params.fai ?: "${params.fasta}.fai", checkIfExists: true),
    ])

    //
    // Flagging resources. All four are required by toil_pindel and by the
    // flagging step; badloci is optional.
    //
    def ch_simrep = channel.value(indexedFile(params.simrep, params.simrep_tbi, 'simrep'))
    def ch_genes = channel.value(indexedFile(params.genes, params.genes_tbi, 'genes'))
    def ch_unmatched = channel.value(indexedFile(params.unmatched, params.unmatched_tbi, 'unmatched'))
    def ch_badloci = params.badloci
        ? channel.value(indexedFile(params.badloci, params.badloci_tbi, 'badloci'))
        : channel.value([[], []])

    def ch_filter_rules = channel.value(file(params.filter_rules, checkIfExists: true))

    //
    // Two execution shapes for the same tool.
    //
    // Scattered (default) reproduces what toil_pindel got from driving
    // cgpPindel's -process/-index staging: one task per contig, one core each,
    // so it schedules as many small slots.
    //
    // Unstaged runs pindel.pl once per pair and lets cgpPindel thread across
    // -cpus internally. Same output, but it wants a single large slot. Prefer it
    // when big nodes are easy to get or shared storage is slow, since it stages
    // nothing between stages.
    //
    // Both bottom out at the longest contig, which cannot be split, so neither is
    // faster than the other once the unstaged path has enough cores.
    //
    def ch_scatter = ch_samplesheet.branch { meta, _nb, _ni, _nbas, _tb, _ti, _tbas ->
        scatter: params.scatter_by_contig
        single: true
    }

    CGPPINDEL_SCATTER(
        ch_scatter.scatter,
        ch_fasta,
        ch_simrep,
        ch_genes,
        ch_unmatched,
        ch_badloci,
        ch_filter_rules,
    )

    CGPPINDEL(
        ch_scatter.single,
        ch_fasta,
        ch_simrep,
        ch_genes,
        ch_unmatched,
        ch_badloci,
        ch_filter_rules,
    )

    def ch_vcf = CGPPINDEL_SCATTER.out.vcf.mix(CGPPINDEL.out.vcf)
    def ch_mt_bam = CGPPINDEL_SCATTER.out.mt_bam.mix(CGPPINDEL.out.mt_bam)
    def ch_wt_bam = CGPPINDEL_SCATTER.out.wt_bam.mix(CGPPINDEL.out.wt_bam)
    def ch_germline_bed = CGPPINDEL_SCATTER.out.germline_bed.mix(CGPPINDEL.out.germline_bed)

    //
    // Collate and save software versions
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    def ch_collated_versions = softwareVersionsToYAML(topic_versions.versions_file)
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${outdir}/pipeline_info",
            name:  'pindel_software_'  + 'versions.yml',
            sort: true,
            newLine: true
        )

    emit:
    vcf          = ch_vcf                 // channel: [ meta, vcf ]
    mt_bam       = ch_mt_bam              // channel: [ meta, bam ]
    wt_bam       = ch_wt_bam              // channel: [ meta, bam ]
    germline_bed = ch_germline_bed        // channel: [ meta, bed ]
    versions     = ch_collated_versions   // channel: [ path(versions.yml) ]
}

//
// Resolve a tabix-indexed resource and its index, defaulting the index to
// <file>.tbi. Returns a [file, index] pair so the two always travel together.
//
def indexedFile(path, index, name) {
    def resource = file(path, checkIfExists: true)
    return [resource, file(index ?: "${path}.tbi", checkIfExists: true)]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
