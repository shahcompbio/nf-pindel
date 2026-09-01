//
// cgpPindel scattered per contig, reproducing the shape toil_pindel got from
// driving `pindel.pl -process X -index N` as separate batch jobs.
//
// toil's five stages become three processes: the two per-contig stages (pindel,
// pin2vcf) are fused because they are sequential on the same contig's data, and
// merge/flag are fused because flag consumes merge's output directly.
//

include { CGPPINDEL_INPUT      } from '../../../modules/local/cgppindel_input/main'
include { CGPPINDEL_CALL       } from '../../../modules/local/cgppindel_call/main'
include { CGPPINDEL_MERGE_FLAG } from '../../../modules/local/cgppindel_merge_flag/main'

workflow CGPPINDEL_SCATTER {

    take:
    ch_pairs        // channel: [ meta, normal_bam, normal_bai, normal_bas, tumor_bam, tumor_bai, tumor_bas ]
    ch_fasta        // channel: [ meta2, fasta, fai ]
    ch_simrep       // channel: [ simrep, tbi ]
    ch_genes        // channel: [ genes, tbi ]
    ch_unmatched    // channel: [ unmatched, tbi ]
    ch_badloci      // channel: [ badloci, tbi ] or [ [], [] ]
    ch_filter_rules // channel: path(rules)

    main:

    // ch_pairs is a queue and is needed by all three stages, so fork it once
    // rather than reading it repeatedly — a second read would split its items
    // between consumers instead of duplicating them.
    def ch_pair_fork = ch_pairs.multiMap { meta, nbam, nbai, nbas, tbam, tbai, tbas ->
        input: [meta, nbam, nbai, nbas, tbam, tbai, tbas]
        bams: [meta, nbam, nbai, nbas, tbam, tbai, tbas]
    }

    CGPPINDEL_INPUT(ch_pair_fork.input, ch_fasta, ch_badloci)

    // The BAMs are required arguments of every pindel.pl invocation, so they are
    // rejoined to each downstream stage. Keyed on meta.patient because meta.id
    // gains the contig on the scattered path.
    def ch_bams = ch_pair_fork.bams.map { meta, nbam, nbai, nbas, tbam, tbai, tbas ->
        [meta.patient, nbam, nbai, nbas, tbam, tbai, tbas]
    }

    //
    // One task per contig: group the per-contig read files by sequence name.
    // Each group holds exactly the tumour and normal file for that contig.
    //
    def ch_by_contig = CGPPINDEL_INPUT.out.reads
        .transpose()
        .map { meta, read ->
            // <sample>.<seq>.txt.gz — split on the first dot, which a sanitised
            // sample name can never contain.
            def seq = read.name.substring(read.name.indexOf('.') + 1) - '.txt.gz'
            [meta + [id: "${meta.patient}_${seq}", seq: seq], read]
        }
        // The input stage emits every contig in the BAM, including ones
        // --exclude names. On the unstaged path cgpPindel drops them itself in
        // determine_jobs; here the filter has to happen before the scatter, or a
        // task would stage an excluded contig, find zero valid sequences and die
        // in PCAP::Threaded with "Iterations must be a positive integer: 0".
        .filter { meta, _read -> !isExcluded(meta.seq) }
        .groupTuple()
        .map { meta, reads -> [meta.patient, meta, reads] }
        .combine(ch_bams, by: 0)
        .map { _p, meta, reads, nbam, nbai, nbas, tbam, tbai, tbas ->
            [meta, reads, nbam, nbai, nbas, tbam, tbai, tbas]
        }

    CGPPINDEL_CALL(ch_by_contig, ch_fasta, ch_badloci)

    //
    // Gather every contig's VCF parts back per pair.
    //
    def ch_gathered = CGPPINDEL_CALL.out.vcf_parts
        .map { meta, parts -> [meta.subMap(['id', 'patient', 'normal_id', 'tumor_id']) + [id: meta.patient], parts] }
        .groupTuple()
        .map { meta, parts -> [meta.patient, meta, parts.flatten()] }
        .combine(ch_bams, by: 0)
        .map { _p, meta, parts, nbam, nbai, nbas, tbam, tbai, tbas ->
            [meta, parts, nbam, nbai, nbas, tbam, tbai, tbas]
        }

    CGPPINDEL_MERGE_FLAG(
        ch_gathered,
        ch_fasta,
        ch_simrep,
        ch_genes,
        ch_unmatched,
        ch_badloci,
        ch_filter_rules,
    )

    emit:
    vcf          = CGPPINDEL_MERGE_FLAG.out.vcf
    tbi          = CGPPINDEL_MERGE_FLAG.out.tbi
    mt_bam       = CGPPINDEL_MERGE_FLAG.out.mt_bam
    mt_bai       = CGPPINDEL_MERGE_FLAG.out.mt_bai
    wt_bam       = CGPPINDEL_MERGE_FLAG.out.wt_bam
    wt_bai       = CGPPINDEL_MERGE_FLAG.out.wt_bai
    germline_bed = CGPPINDEL_MERGE_FLAG.out.germline_bed
}


//
// cgpPindel's --exclude is a comma-separated list where '%' is the wildcard,
// e.g. 'NC_007605,hs37d5,GL%'. Mirror that matching so the scatter covers
// exactly the contigs the unstaged path would have processed.
//
def isExcluded(seq) {
    if (!params.exclude) {
        return false
    }
    return params.exclude.tokenize(',').any { pattern ->
        def regex = pattern.trim().split('%', -1).collect { part -> java.util.regex.Pattern.quote(part) }.join('.*')
        seq ==~ regex
    }
}
