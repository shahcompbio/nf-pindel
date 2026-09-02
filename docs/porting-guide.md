# Porting a Toil pipeline to Nextflow

Practical guidance for replacing a Toil pipeline with a Nextflow one while being
able to *prove* the replacement produces the same results.

The advice is general. Examples are drawn from the `toil_pindel` → `nf-pindel`
port, which wraps cgpPindel, and are marked **In this port**.

The hardest part of a port like this is rarely writing the workflow. It is
establishing a trustworthy baseline to compare against, and resisting plausible
but wrong explanations when the comparison fails.

---

## 1. Establish what the legacy pipeline actually ran

Before writing any comparison, determine the exact tool version the old pipeline
executed. Everything downstream depends on this being right.

- **Read the version out of the legacy pipeline's own definition** rather than
  assuming it. A Toil wrapper usually declares its tool in a `Dockerfile`,
  a container setting, or a CLI default.
- **Distinguish what the repo pins from what production ran.** Toil wrappers
  built on `toil_container` accept `--docker` / `--singularity` at runtime, so
  the deployed image can differ from the one baked into the repo.
- **Confirm against the deployment config**, not just source control — the
  application layer that invokes the pipeline is the authority on production.
- **Prefer provenance the tool emits itself.** Many tools stamp their version
  into output headers, which is stronger evidence than any config file.

> **In this port.** `toil_pindel`'s `Dockerfile` is `FROM
> quay.io/wtsicgp/cgppindel:3.10.0`, but production ran **3.3.0**, injected at
> runtime through a different image. The flagged VCF header records the truth:
> `##source_20260901.1=pindel_2_combined_vcf.pl_v3.10.0`. The validation script
> now parses the base image out of the Toil `Dockerfile` and pins the Nextflow
> side to the same image so both sides always match.

---

## 2. Prove differences before explaining them

A failing comparison invites a comfortable explanation. Insist on evidence.

- **Run the new pipeline several times before blaming nondeterminism.** If every
  run is byte-identical, the difference is deterministic and therefore a
  configuration, version, or logic difference. This single check separates the
  two most common causes.
- **Compare tool versions first.** Make a version match an explicit, machine
  checked assertion in the comparison itself, so a skew can never be mistaken
  for a porting defect.
- **Identify nondeterministic fields early and exclude them.** Byte comparison of
  outputs usually fails for uninteresting reasons.
- **Compare semantically:** record coordinates, filter/status columns, read
  counts, and file contents — the things a downstream consumer relies on.

> **In this port.** One call flipped between `F005` and `PASS`. The first
> explanation offered was run-to-run variability. That was wrong: five repeat
> runs were identical, and the VCF headers showed cgpPindel 3.10.0 on one side
> and 3.3.0 on the other. Regenerating the baseline at a matching version made
> every check pass. Separately, cgpPindel writes a fresh UUID into the VCF `ID`
> column on every run, so that column must be ignored.

---

## 3. Audit the legacy container before trusting it

Container images age badly, and the ways they fail are not obvious.

- **Old images may no longer be pullable.** Registry manifest formats get
  retired, and modern container runtimes refuse them outright.
- **Check `ENTRYPOINT` and `ENV`.** Nextflow supplies its own command, so an
  image whose `ENTRYPOINT` is the tool needs that entrypoint neutralised — but
  the environment the tool depends on (`PATH`, library paths, interpreter paths)
  must be preserved.
- **Do not rely on engine-specific escapes.** Docker's `--entrypoint ""` has no
  Singularity/Apptainer equivalent. If an image needs fixing, rebuild it with a
  cleared `ENTRYPOINT` and the environment baked in, then push it. That works
  under every engine.
- **Handle CPU architecture explicitly.** Most bioinformatics images are
  `linux/amd64` only. On other hosts, pin the platform at *every* step — pull,
  `FROM`, and build — because each layer of tooling checks it independently.
- **Validate on the target architecture where possible.** Emulation can do more
  than slow things down; schedulers and process-reaping logic may hang outright.

> **In this port.** `quay.io/wtsicgp/cgppindel:3.3.0` cannot be pulled at all on
> current Docker: it is published with a Docker v1 manifest, which containerd
> 2.1+ rejects. A repackaged image was substituted, but its first build shipped
> an empty config, so `pindel.pl: command not found` — the original image had
> baked `PATH`, `PERL5LIB` and `LD_LIBRARY_PATH` that the copy had dropped.
> Rebuilding with those baked in removed the need for any Docker-only flags.
> On Apple Silicon the same architecture mismatch surfaced three separate times:
> a Singularity SIF build refusing the platform, BuildKit's
> `InvalidBaseImagePlatform`, and Toil's scheduler hanging under qemu.

---

## 4. Translate the execution model, do not transliterate it

Toil and Nextflow parallelise differently, and the difference is structural.

- **Toil stages often share a working directory**; Nextflow isolates every task.
  A staged pipeline that communicates through a shared output directory cannot
  be mapped one-to-one.
- **Consider offering more than one execution shape.** A fine-grained scatter and
  a single coarse task can produce identical output while suiting very different
  schedulers.
- **Find the real critical path before tuning.** If the smallest indivisible unit
  of work dominates, extra cores stop helping at a computable point.
- **Audit legacy resource flags for fiction.** Wrapper-level resource options
  frequently affect only the scheduler request and never reach the tool.
- **Nextflow validates resource requests against what is available.** A request
  that a Toil scheduler would have queued can fail immediately.
- **Set `resourceLimits` for test profiles** so the same pipeline runs on a
  laptop and a cluster without editing the process definitions.

> **In this port.** `toil_pindel` drove five stages over a shared `-outdir`
> (`input → pindel → pin2vcf → merge → flag`). The Nextflow port offers a
> scattered path (one task per contig) and an unstaged path (one invocation per
> pair). A contig cannot be split, so the longest contig bounds both shapes and
> cores beyond roughly 13 buy nothing. Toil's `--tgd` flag turned out to change
> only Toil's resource request and never reached cgpPindel; it was replaced by
> explicit `--pindel_cpus` / `--pindel_memory`. Requesting 16 CPUs on a 2-CPU
> host failed outright with `req: 16; avail: 2`.

---

## 5. Let the tool's version dictate which shape is available

Tool CLIs gain options over time, and an execution shape can silently depend on
one of them.

- **The production version may not support the shape you developed against.**
  Options used by a fine-grained scatter are exactly the kind of thing added in
  later releases.
- **Test each execution shape against the production version**, not only the
  newest one, or you will ship a default configuration that cannot run.
- **Record the constraint where it is enforced**, so the coupling between version
  and execution shape is not folk knowledge.
- **Map application vocabulary to tool vocabulary explicitly.** Internal
  labels rarely match a tool's accepted values, and a schema will catch the
  mismatch at launch rather than mid-run.

> **In this port.** cgpPindel 3.3.0 predates `-noflag`, which the scattered
> path's input stage passes, so 3.3.0 **cannot** run scattered — the reason
> production sets `scatter_by_contig = false`. That was implicit until the
> validation harness ran the production version and hit `Unknown option: noflag`.
> Separately, the application's `TD` sequencing-method label had to be mapped to
> cgpPindel's `TGD`; the pipeline schema rejected the unmapped value with
> `--seqtype (TD): Expected any of [WGS, WXS, TGD]`.

---

## 6. Preserve the downstream contract

A port is only correct if whatever consumes the results cannot tell the
difference.

- **Some output names are derived from the data, not from configuration.** They
  must not be "improved" during a port.
- **Reproduce the legacy published layout** when downstream systems glob fixed
  paths, even if a nicer layout is available — and make the legacy layout
  selectable if you also want the nicer one.
- **Enumerate the exact files the consumer expects** and assert every one of them
  in tests.

> **In this port.** cgpPindel names outputs from the BAM header `SM` tags rather
> than the samplesheet, and the downstream application globs six specific
> artefacts straight out of the output directory. A `--flat_publish` option
> reproduces the flat layout `toil_pindel` produced, alongside the default
> per-patient layout.

---

## 7. Build a validation harness that outlives the legacy pipeline

This is the deliverable that makes the port defensible after the old pipeline is
gone.

- **Capture reference output while the legacy pipeline still runs.** Once its
  image cannot be pulled or its environment cannot be rebuilt, no new baseline
  can ever be produced. This is time-sensitive: do it early.
- **Make the harness runnable from a clean clone.** No sibling checkout, no
  pre-built interpreter environment, no manual setup. Clone the legacy repo on
  demand and run every tool step in a container.
- **Use the new repository's own test data**, after verifying it is byte-identical
  to the legacy repo's copy, so the harness does not depend on the old checkout
  for inputs.
- **Check in recorded reference output when it cannot be regenerated.** These
  files are usually tiny relative to their value.
- **Make recorded data self-describing.** Store the tool version, the image and
  digest that reproduces it, any required execution settings, whether it is
  reproducible, and *why* it was recorded rather than regenerated.
- **Prefer a recorded run of the real legacy pipeline** over a reconstruction —
  and where you must use a reconstruction, label it honestly.
- **Fail with actionable messages.** Environment problems dominate real usage.

> **In this port.** `validate_against_toil.sh` clones `toil_pindel` on demand,
> reads the pinned cgpPindel image from its `Dockerfile`, pins the Nextflow run
> to the same image, and compares. Two recorded reference sets are committed: a
> genuine `toil_pindel` run at 3.10.0, and a cgpPindel 3.3.0 set matching
> production, which is committed precisely because 3.3.0 can no longer be pulled.
> Each carries a `PROVENANCE` file naming the image, digest, and the profile the
> set requires. A late discovery: `micromamba` is a shell function, so it does
> not exist inside a script — the harness detects that and says so instead of
> failing obscurely.

---

## Checklist

Before declaring a port complete:

- [ ] The tool version the legacy pipeline ran is known and documented
- [ ] Production's version is confirmed, not just the version in the legacy repo
- [ ] Both sides of every comparison are pinned to the same tool version
- [ ] The comparison asserts the version match programmatically
- [ ] Nondeterministic output fields are identified and excluded
- [ ] Repeat runs confirm the new pipeline is deterministic
- [ ] Reference output was captured while the legacy pipeline could still run
- [ ] Recorded reference data carries provenance and is version-controlled
- [ ] Every execution shape has been tested against the production tool version
- [ ] Legacy resource flags were audited for whether they reached the tool
- [ ] Container entrypoint and environment work under every engine you support
- [ ] Output filenames and published layout match the downstream contract
- [ ] The validation harness runs from a clean clone with no manual setup
