# shahcompbio/nf-pindel: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0.0 - [2026-09-01]

Initial release of shahcompbio/nf-pindel, the Nextflow port of the
`toil_pindel` Toil pipeline, v1.1.8.

### Added

- Indel calling and flagging with cgpPindel 3.10.0, from the same
  `quay.io/wtsicgp/cgppindel:3.10.0` image `toil_pindel` used.
- nf-core samplesheet input, grouped by patient, so several pairs run at once.
- `--flat_publish` to reproduce the `toil_pindel` output layout.
- `--seqtype`, exposing a cgpPindel option `toil_pindel` never passed. Defaults
  to `WGS`, which is what cgpPindel used regardless.
- Two execution shapes, selected by `--scatter_by_contig` (default `true`): a
  per-contig scatter reproducing how `toil_pindel` distributed cgpPindel across
  the cluster, and an unstaged single run per pair. Verified to produce identical
  output.
- nf-test suite covering both paths, the downstream result contract, the call
  set, and that flagging genuinely populates the FILTER column.

### Changed from toil_pindel

- **toil's five stages become three**: `pindel` and `pin2vcf` fuse because they
  are sequential on one contig's data, and `merge`/`flag` fuse because flag reads
  merge's output. Same tool and version, so the same output.
- `--filter` is renamed `--filter_rules`.
- `--tgd` is replaced by explicit `--pindel_cpus` / `--pindel_memory`; it only
  ever changed Toil resource requests and never reached cgpPindel.

See [docs/migration.md](docs/migration.md) for the full mapping.
