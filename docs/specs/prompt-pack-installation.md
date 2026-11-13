# Supported Prompt pack installation and Skill lifecycle compatibility

This spec records the implemented Prompt pack installation slice. It follows
the pack contract in [`pack-command-migration.md`](pack-command-migration.md),
the harness-relative Prompt views in
[`native-prompt-inspection.md`](native-prompt-inspection.md) and the publication
contract in [`safe-native-publication.md`](safe-native-publication.md).

The delivery ticket is
[#71](https://github.com/louiss0/agent_resource/issues/71).

## Scope

`pack install --type prompt` installs valid, supported skill-backed Prompts
through the existing native Skill installation and its safety machinery.

It adds:

- `lib/src/services/pack_prompt_service.dart`: the Prompt view of a pack
  candidate and the admission gates of a Prompt selection.
- the `prompt` kind of `PackResourceType` and its routing in
  `lib/src/services/pack_lifecycle_service.dart`.
- the Prompt gates of the ordinary Skill selection and of the pack
  validation.

The slice does not add a Prompt lifecycle: an installed skill-backed Prompt
keeps the existing Skill ownership, update, removal and rollback selectors. It
does not add a standalone template installation, a Pi Skill consumer adapter or
a new ordinary Pi installation target.

The slice does not add the harness-relative Prompt discovery of the pending
pack discovery slice. The prompt kind reuses the existing Skill catalog and
the existing Skill discovery: a pack declares its Prompts as declared or
discovered Skill packages.

## Selection and installation

- The prompt kind reuses the native Skill pipeline. The candidates are the
  declared or discovered skill packages of the pack; the catalog stays
  authoritative and no undeclared path is scanned.
- The prompt kind isolates its own selection: the sources of the Prompt scope
  that are a Prompt in a consumer view. An ordinary Skill of the scope is not
  a Prompt candidate and it is not part of the selection.
- Every selected resource must be a valid, supported Prompt for every
  explicitly requested target. The whole selection is refused before any
  installation effect: no resource is skipped, no kind is substituted, no
  target is dropped and no invocation control is converted.
- The prompt kind cannot be combined with another resource kind. The mixed
  selection is refused before any installation effect.
- A Pi target refuses the selection before any installation effect. The Pi
  Prompt installation stays unsupported: a Pi skill-backed Prompt is
  recognized and validated, but it is not installed for Pi.
- A standalone template Prompt is not supported for installation. A selection
  that contains one is refused.
- The original selected source and the staged output are both inspected. The
  pack admission and the root Markdown migration cannot disguise an invalid
  Prompt: a staged output that does not preserve the Prompt view of the
  reviewed source in the target view is refused.
- The classification and the validity of a resource are read per target: a
  resource that is a Prompt for one harness is not judged by the view of
  another harness. The shared target is judged by the views of every supported
  harness.
- The prompt selection requires an explicit target. Without a configured or
  requested target the selection is refused, because the Prompt view of the
  resource depends on the target.
- The ordinary Skill selection reads the targets without asking. Without a
  configured target it is checked against every supported harness, and an
  explicit `--target` narrows the check to that target.
- An ordinary Skill selection consumes the valid skill-backed Prompts of the
  pack. A manual-only resource that carries bundled resources or forbidden
  content is an invalid Prompt candidate: it is refused and never installed as
  an ordinary Skill.
- An untyped operation retains the Skill and Agent defaults. It never opts
  into the Prompt selection and never installs a standalone template.
- The prompt kind applies to `pack install` and to `pack validate`. The
  validation reports the Prompt failures of the selected resources and changes
  no managed state. The other pack operations keep the Skill and Agent
  selectors.

## Ownership and lifecycle compatibility

- An installed skill-backed Prompt keeps the native Skill ownership record,
  its baseline, its backup associations and its pack membership. The Prompt
  selection adds no extra source or membership enrollment: it records the one
  selection and the one Skill operation of the installation.
- The installed resource keeps the existing Skill lifecycle compatibility:
  update, removal, rollback and cleanup reach it through the Skill selectors.
- The ordinary lifecycle gates apply to the publication: the pending
  transaction guard, the uniqueness authority, the staged publication and the
  unchanged baseline check. A pending coordinated transaction that reserves
  the pack refuses the Prompt selection.

## Refusals

| Refusal | Status |
| --- | --- |
| A selected resource is not a Prompt for a requested target | 2 |
| A selected resource is an invalid Prompt for a requested target | 2 |
| A selected resource is a standalone template | 2 |
| A requested target is Pi | 2 |
| A staged output does not preserve the Prompt view | 2 |
| The prompt kind is combined with another resource kind | 2 |
| The prompt kind is used with an operation other than install or validate | 2 |
| The prompt kind is used without an explicit target | 2 |
| An explicitly selected name is not a Prompt candidate | 2 |
| An ordinary Skill selection would install an invalid Prompt | 2 |
| A pending coordinated transaction reserves the pack | 6 |

Every refusal happens before the installation effect: the source, the state,
the ledger and the pack membership are unchanged.

## Evidence and limits

The focused suite covers the installation of a supported skill-backed Prompt
through the native Skill installation, the refusal of a mixed kind selection,
the refusal of a Pi target, the refusal of an invalid Prompt without an
ordinary Skill fallback, the refusal of a migrated root file, the untyped
defaults, the refusal of a non-install operation, the read-only dry run, the
Prompt validation, the unchanged source and lock document on refusal, the
atomic selection, the ordinary Skill selector, the update and removal
compatibility, the pending transaction guard and the absence of an extra
membership.

The complete Dart suite passes locally on Windows with 950 passing and four
platform-skipped tests. `dart analyze` reports no findings.

The checks are static validity, ownership and readiness evidence. No Claude,
Codex or Pi runtime was exercised, and no native harness activation was
proven.

## Open questions

- The standalone template sources of a pack arrive with the harness-relative
  pack discovery slice. The template refusal is implemented and covered by the
  admission gate, but the pack cannot yet surface a template candidate.
- A Prompt installed through the prompt kind keeps the Skill record. A
  distinct Prompt ownership record would need its own lifecycle, and no
  Prompt lifecycle exists yet.
- The pack discovery of Prompt sources, including the explicit native Prompt
  entries of the catalog, belongs to the pending pack discovery slice.
- The slice does not extend the converted-source retirement and the detached
  membership tracking of the conversion flow. The Prompt selection enrolls no
  source and no membership, so it neither retires nor detaches a converted
  source; the pending transaction guard of the coordinated transactions
  refuses the selection while a transaction reserves the pack.
