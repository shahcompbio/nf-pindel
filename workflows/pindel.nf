/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { CGPPINDEL              } from '../modules/local/cgppindel/main'

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

    def ch_versions = channel.empty()

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
    // MODULE: cgpPindel, one unstaged run per tumour/normal pair
    //
    CGPPINDEL(
        ch_samplesheet,
        ch_fasta,
        ch_simrep,
        ch_genes,
        ch_unmatched,
        ch_badloci,
        ch_filter_rules,
    )

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

    def ch_collated_versions = softwareVersionsToYAML(ch_versions.mix(topic_versions.versions_file))
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${outdir}/pipeline_info",
            name:  'pindel_software_'  + 'versions.yml',
            sort: true,
            newLine: true
        )

    emit:
    vcf          = CGPPINDEL.out.vcf           // channel: [ meta, vcf ]
    mt_bam       = CGPPINDEL.out.mt_bam        // channel: [ meta, bam ]
    wt_bam       = CGPPINDEL.out.wt_bam        // channel: [ meta, bam ]
    germline_bed = CGPPINDEL.out.germline_bed  // channel: [ meta, bed ]
    versions     = ch_collated_versions        // channel: [ path(versions.yml) ]
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
