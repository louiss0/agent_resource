# Shared native authoring inputs and read-only plans

This spec documents the implemented internal authoring slice: the shared named
native inputs and the read-only plan construction for Skill, Agent and Prompt
authoring and the approved conversions.

Canonical decisions: [shared plain-text creation](https://github.com/louiss0/agent_resource/issues/73),
[native declarations and field inputs](https://github.com/louiss0/agent_resource/issues/74),
[guided edit, clone, compose and conversion](https://github.com/louiss0/agent_resource/issues/76),
[ownership of new outputs](https://github.com/louiss0/agent_resource/issues/80),
[prompt authoring and skill reclassification](https://github.com/louiss0/agent_resource/issues/62),
[prompt to agent conversion](https://github.com/louiss0/agent_resource/issues/64),
[mixed-harness discovery and validity](https://github.com/louiss0/agent_resource/issues/77) and
[Pi skill-backed prompt installation](https://github.com/louiss0/agent_resource/issues/79).

## Scope and boundaries

The slice is internal. It adds:

- `lib/src/authoring/native_field_matrix.dart`: the supported named native
  fields for one resource kind and profile.
- `lib/src/authoring/authoring_inputs.dart`: the normalized input model and
  its parser.
- `lib/src/services/authoring_plan_service.dart`: the read-only plan builder.
- `lib/src/prompt_resource_path_scanner.dart`: the shared lexical scan for
  blocked resource path segments, now also used by the native Prompt
  inspector.

No command adapter is registered. Public frontends arrive with their own
slices, and public JSON operation-request routes are removed by those
frontend and migration tickets rather than by this module. Planning writes
nothing: no draft, no staging entry, no journal and no installation record.

## Inputs

Inputs are named values, not an operation document. A serialized operation
document is not an accepted input seam, and there is no generic `--set`
mini-language.

- **Source**: a path or an installation identifier, never both. A tracked path
  stays tracked; selecting it does not make it unmanaged. A path source
  carries explicit native context; the profile is never inferred from a
  Markdown file alone. The native profile of the source is explicit when it
  differs from the target profile, and the source is read with its own
  profile before the target analysis.
- **Body**: a body file, explicitly selected standard input or literal text,
  never more than one. Multiline bytes are preserved exactly. An unattended
  plan that selects standard input without a supplied reader fails instead of
  waiting.
- **Fields**: named native fields of the selected kind and profile. A field
  that the profile does not support is refused with the supported names.
- **Composition**: `append`, `replace` or `retain`, required for a compose
  operation. `retain` cannot be combined with a supplied body.
- **Operation**: `create`, `edit`, `clone`, `compose` or `convert`. A clone
  refuses a body-changing input. A strict conversion refuses a supplied body:
  the conversion preserves the source instructions, and a rewrite is a
  separate reviewed source edit.

### Field semantics

- A supplied repeatable list describes the complete target field. A source
  with `Read` and `Write` and a supplied `Read` proposes `Read` only.
- An omitted field preserves the source value where the profile supports it.
- An explicit clear removes the field and is accepted only where the native
  form supports absence.
- An explicit inherit keeps the source value and records that intent in the
  plan identity, so a deliberate choice is distinguishable from an omission.
- A supplied field is itself the field-specific mapping intent. No second
  opaque decision token repeats it.
- A source declaration without a named input is preserved when the target
  profile accepts and validates it. A declaration the profile cannot
  represent is a blocker: it is never dropped silently. The manual-only
  controls and the invocation surface of a Prompt are accounted for by the
  disclosed Prompt to Agent mechanism change.

## Supported native field matrix

Skills:

| Field | Claude | Codex | Pi |
| --- | --- | --- | --- |
| `name` | required | required | required |
| `description` | required | required | required |
| `license` | optional | optional | optional |
| `compatibility` | optional | optional | optional |
| `metadata` | optional | optional | optional |
| `allowed-tools` | optional | optional | optional |
| `disallowed-tools` | optional | — | — |

Prompts:

| Field | Claude | Codex | Global | Pi template |
| --- | --- | --- | --- | --- |
| `name` | required | required | required | required (file name only) |
| `description` | required | required | required | required |
| `license` | optional | optional | optional | — |
| `compatibility` | optional | optional | optional | — |
| `argument-hint` | optional | — | optional | optional |

Agents:

| Field | Claude | Codex | Pi |
| --- | --- | --- | --- |
| `name` | required | required | required |
| `description` | required | optional | required |
| `model` | optional | optional | required |
| `tools` | optional | — | required |
| `skills` | optional | optional | — |
| `mcpServers` / `mcp_servers` | optional | optional | — |

A global profile applies to prompts only. The manual-only controls are derived
from the selected profile, not supplied as fields: Claude and Pi skill-backed
Prompts declare `disable-model-invocation: true`, and Codex and Global
Prompts declare `policy.allow_implicit_invocation: false` in
`agents/openai.yaml`. No Agent Resource classification metadata is written.

## Plan semantics

- **Ownership**: a new output is author-only by default. Management requires
  an explicit request and a supported form and location. Managed publication
  is supported for Claude and Codex skills and for agents; prompt publication
  has no managed lifecycle yet and is refused, including the Pi template
  form. A request that lacks management support fails instead of silently
  falling back to author-only output.
- **Placement**: the default target is the native root of the selected kind,
  profile and scope. An explicit output override places the output in a pack
  or source folder; a package override names the package directory, unless it
  names the marker of the package itself. A placement does not prove native
  discovery or activation.
- **Occupancy**: an occupied target is refused. A new output never takes over
  an existing entry, not even one with identical bytes. Only an edit and a
  strict conversion may place their target on the source: a clone and a
  compose always produce a separate output. An edit of a tracked installation
  replaces that recorded location and requires an unchanged baseline.
  Uniqueness is checked at the selected target location; a same-named entry
  in another discovery root is not resolved by this slice.
- **Unmanaged edits** stay unmanaged. They do not require adoption and they
  do not create an installation record.
- **Conversions**:
  - A Skill to Prompt edit dispatches the Skill to Prompt conversion, and a
    Prompt to Skill edit is refused.
  - Skill to Prompt reclassifies in place for the Claude, Codex and Global
    forms and requires a resource-free source: only `SKILL.md` and a
    validated `agents/openai.yaml` may exist, and the instructions must not
    reference `references`, `scripts` or `assets` path segments. A Pi
    conversion produces a standalone native template and records that the
    source must be removed after a successful publication, so that a second
    active resource is not kept.
  - Prompt to Agent refuses active template arguments and dynamic injection,
    and discloses the two inherent changes: the instructions become the Agent
    instruction role, and manual invocation becomes normal delegation. The
    resulting Agent does not claim manual-only enforcement.
  - Agent to Agent refuses a source field that the target profile does not
    support, and an unresolved reference change requires an explicit
    per-reference choice.
  - A Prompt to Skill reclassification has no supported direction.
- **Identity**: the plan identity is a SHA-256 digest over the canonical
  operation, kind, profile, scope, conversion, source observation, target
  placement and its current occupancy observation, ownership, merged fields,
  field intents, body digest, decisions,
  reference mappings, role and delegation observations, reference choices and
  cross-scope observations. The source observation binds the marker digest
  and the reviewed package member manifest of the source, and the target
  placement binds the package directory of the placement. Equal proposals
  produce the same identity; a changed proposal or target-occupancy observation
  produces a different one. The occupancy binding applies to every authoring
  operation, not just draft resumption. Plan identities issued before this
  binding was added are stale: rebuild and review the current plan rather than
  reusing an old publication token or overriding the comparison.
- **Package members**: the reviewed manifest of a package source binds every
  owned member by relative path, type, length and content digest. The
  manifest is bounded: a link, an unsupported entry, an exhausted entry,
  depth or size budget refuses the review instead of publishing an
  unreviewed package.
- **Scope**: the resolved lifecycle scope is authoritative. A selected scope
  that disagrees with it is refused, and the reported scope is the resolved
  one.
- **Missing fields**: a missing required field is reported as a diagnostic.
  The plan stays unready and reports no target until the field is supplied.

## Evidence and limits

- The proposed Agent content is validated by the existing native Agent
  inspector and graph service. A proposal whose native dependency graph is not
  ready is refused. Proposed Skill and Prompt content is checked against the
  documented field rules and the shared blocked-path scan; the native Prompt
  inspector validates on-disk sources, and a source that the target profile
  cannot read blocks the plan.
- The typed plan carries the proposed content for the later publication step.
  The report withholds instruction text unless it is deliberately requested.
- The composition modes are defined on the proposed body: `append` joins the
  base body and the new body with a single newline, `replace` uses the new
  body, and `retain` keeps the base body.
- The checks are static validity and readiness evidence. They are not harness
  runtime verification, not activation proof and not a package-install
  readiness check.
- The checks were run locally on Windows. No harness, editor or native
  platform behaviour was exercised.
