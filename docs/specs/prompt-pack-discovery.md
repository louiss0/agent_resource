> **Historical design record** — this document may not describe
> current behavior. See [README.md](../README.md) and
> [docs/guides/](guides/) for current guidance.

# Harness-relative pack discovery and validation

This spec records the implemented harness-relative pack discovery and the
prompt-aware pack validation. It follows the Prompt views of
[`native-prompt-inspection.md`](native-prompt-inspection.md), the Prompt
installation of [`prompt-pack-installation.md`](prompt-pack-installation.md) and
the pack contract of
[`pack-command-migration.md`](pack-command-migration.md).

The delivery ticket is
[#90](https://github.com/louiss0/agent_resource/issues/90).

## Scope

`pack discover <pack>` is a bounded read-only view of the candidates of a pack
source. `pack validate <pack> --type prompt` is the prompt-aware validation of
the same scope.

It adds:

- `lib/src/pack/pack_discovery.dart`: the discovery report, its candidates and
  their per-consumer views.
- `lib/src/services/pack_discovery_service.dart`: the Prompt scope of a pack
  source and the discovered candidates.
- `lib/src/installation/prompt_source_discovery.dart`: the bounded discovery of
  the Prompt sources of a root.
- the `prompts` scope of the pack source catalog and the
  `discovery.prompts_directory` root of the pack configuration.
- `PackLifecycleService.discover`: the read-only discovery of a configured
  pack.

The slice does not add a Prompt lifecycle, a Prompt installation target or a
standalone template installation. The discovery and the validation never write
a management state, never enroll a membership and never advance an inventory.

## The Prompt scope of a pack

- A declared catalog is authoritative: the discovery inspects the declared
  paths only, and an undeclared path is never scanned.
- Without a declared catalog the discovery scans the discovery roots: the
  `skills` root, the `agents` root and the configurable `prompts` root. The
  Prompt root traversal is bounded to the direct entries plus one group
  level, it refuses linked entries and it applies the existing entry,
  directory and resource budgets. The Agent root keeps the existing
  depth-16 traversal of the pack lifecycle.
- A declared Skill entry with native manual-only controls is a per-harness
  Prompt view of that source. It is not a second resource: every source is
  reported once with its views.
- A declared Prompt entry is an explicit native Prompt source. A standalone
  template needs its native profile: without one the candidate stays
  unclassified instead of assuming Pi. The `prompts` root holds skill-backed
  Prompt packages and standalone templates.
- The same source path declared as a Skill and as a Prompt is a conflicting
  declaration and it is refused. The same source path found under two
  discovery roots is reported once.

## The per-consumer views

- Every candidate reports its views for Claude, Codex and Pi. A source that is
  a Prompt for Claude can be an ordinary Skill for Codex, and the report shows
  that difference instead of one universal classification.
- The classification and the validity of a view are read from the native
  controls of the source. The resource-free shape, the path-shaped content
  blockers and the validated sidecar apply to a Prompt view only: an ordinary
  Skill view of another consumer is not invalidated by them.
- The global compatibility of the native form and the observed placement are
  reported separately. A globally compatible source of a pack is not an
  installed occurrence: the placement of a pack source is `uninstalled`.
- Recognition and installation support are separate. A Pi skill-backed Prompt
  is recognized and validated, and it is not installable. A standalone
  template is not installable for any consumer.
- A malformed control leaves the classification unknown, and a verified
  optional absence uses the documented native defaults.
- The first operational inspection failure aborts the discovery. A native
  validation error stays a diagnosable candidate.

## The validation

- The prompt kind validates the Prompt selection of the scope: the sources
  that are a Prompt in a consumer view, plus the sources whose evidence is
  insufficient to classify them. An ordinary Skill view of the scope is not
  part of the Prompt selection.
- Every selected source must be a valid, supported Prompt for every requested
  target.
- The validation inspects the reviewed source and its staged output, so the
  pack admission and the root Markdown migration cannot disguise an invalid
  Prompt.
- An ordinary Skill selection never falls back past the Prompt checks: a
  selected Skill that is an invalid Prompt in a target view is refused, the
  same way the installation refuses it. The Prompt policy never reaches a
  target whose view of that source is an ordinary Skill.
- The validation reports the failures of the selected sources and changes no
  managed state.

## Refusals

| Refusal | Status |
| --- | --- |
| A conflicting declaration of one source path | 2 |
| A selected Skill is an invalid Prompt in a target view | 2 |
| A selected source is not a valid Prompt for a requested target | 2 |
| A selected source is a standalone template | 2 |
| A requested target is Pi | 2 |
| A staged output does not preserve the Prompt view | 2 |
| An operational inspection failure | 3 |
| A linked source entry | 2 |
| An unsupported discovery target | 2 |

## Evidence and limits

The focused suites cover the mixed-control matrix, the type and profile
filters, the explicit catalog conflicts, the root, empty-directory and
resource-path cases, the unknown scope, the selected invalid view, the budget
and IO refusals, the unchanged source and lock document, the pending
transaction guard, the discovery of the Prompt root, the standalone template
without a profile and the CLI registration.

The focused suites of this slice are
`test/src/services/pack_discovery_service_test.dart`,
`test/src/services/pack_discovery_validation_test.dart`,
`test/src/services/pack_prompt_service_test.dart`,
`test/src/installation/prompt_source_discovery_test.dart`,
`test/pack_test.dart` and `test/pack_action_test.dart`. `dart analyze` reports
no findings. The complete Dart suite is not claimed here: the repository
baseline of the parent session recorded one timing-sensitive editor failure
under concurrent load.

The checks are static validity, ownership and readiness evidence. No Claude,
Codex or Pi runtime was exercised, and no native harness activation was
proven.

## Open questions

- The discovery reports the Prompt scope of a pack. The Prompt installation of
  #71 consumes the same scope, and the ordinary Skill and Agent lifecycles
  stay unchanged.
- The catalog of a pack declares the Prompt sources of the pack. The
  harness-relative Prompt discovery of the *project* configuration belongs to
  the pending Prompt inspection slice.
