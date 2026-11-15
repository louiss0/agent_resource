# Guided text creation for Skills, Agents, and Prompts

This document describes the delivered public creation contract of Skills,
Agents, and Prompts. It replaces the JSON operation-request route of
`agent create`. The remaining authoring and conversion routes are described
in `docs/specs/agent-authoring-conversion.md` and are not changed here.

## Commands

```text
agent_resource skill create  [native selections]
agent_resource prompt create [native selections]
agent_resource agent create  [native selections]
agent_resource agent create  --role-key <key> --config-file <config.toml> --ownership definition|both --definition-source <definition.toml> [--definition-output <path>] --ack-clients-stopped
```

Every route shares one named vocabulary. There is no operation-document
option: a JSON request is not a body, not a proposal, and not an input.

| Selection | Meaning |
| --- | --- |
| `--profile` | The native profile of the created resource (`claude`, `codex`, `pi`, and `global` for Prompts only). It is never inferred. |
| `--scope` | The scope of the created output. Defaults to `project`. |
| `--name`, `--description`, `--model`, `--tools`, `--skills`, `--argument-hint`, `--license`, `--compatibility` | The documented native field subset. An omitted flag declares nothing. |
| `--allowed-tools`, `--disallowed-tools`, `--metadata` | The native Skill declarations: two complete tool lists and one metadata table of `name=value` entries. |
| `--body-file`, `--body-stdin`, `--body-text` | The instruction body. Exactly one selector is allowed. |
| `--output` | An explicit placement of the created output. |
| `--manage` | The explicit request for a managed installation record. |
| `--apply`, `--yes`, `--plan-id`, `--dry-run` | The publication controls. |
| `--interactive`, `--unattended`, `--editor`, `--show-instructions` | The interaction boundary. |

A supplied list replaces the whole native list field; an omitted list keeps
the source value. A field that the selected profile does not support is
refused with the supported field names of that profile. The mapping is
native-profile aware: `--skills` names a list of skill names where the native
form is a list, and the Codex Agent profile, whose native `skills` form is a
table, refuses that selection with the reason instead of flattening it.

## The interaction boundary

- The guided flow is the default on a usable terminal. It collects the
  missing required native fields, opens the configured editor for the
  instruction body when no body was supplied, validates the proposal, shows
  the target, the ownership and the declared native values, and asks for the
  publication confirmation in the same flow.
- `--unattended` and `--format json` never prompt and never wait. Every
  required value must be supplied explicitly. A machine-readable output
  contains the report only. A run that misses a required native field
  reports the missing field instead of asking for it.
- A usable terminal means that the input and the output streams are both a
  terminal. A redirected output is not a usable terminal: the guided flow is
  then unavailable, the run never prompts, and every value must be supplied
  explicitly. The guided flow never prompts with a redirected output.
- `--interactive` without a usable terminal is refused; the operator is told
  to supply every value explicitly instead.
- `--dry-run` plans and nothing else: it never launches an editor, never
  prepares a draft and never writes. The body must already be supplied.
- The editor is selected from an explicit choice, then `VISUAL`, then
  `EDITOR`, then the platform default. It is an executable with its
  arguments, never a shell expression. Closing the editor is never
  publication consent, and unchanged text is never an automatic
  cancellation.
- The publication consent is asked only when the run is interactive and the
  publication was not already approved with `--yes`. The consent question
  carries the reviewed target, the ownership and the native declaration
  values. The instruction body is never part of that question: only its
  length and its digest are reported.

## The standard input

`--body-stdin` selects the standard input as the instruction body. The
create routes buffer the piped standard input of the invocation, and the
buffer is used only when `--body-stdin` selects it. An interactive terminal
is never read, an invocation without a piped standard input is refused with
the reason instead of waiting, and the body is read exactly once.

## Ownership

A new output is author-only by default: no installation record, no baseline
and no adoption. `--manage` requests a managed record and is refused when the
selected form or profile has no managed lifecycle, instead of falling back to
an author-only output. An author-only output in a native root is still
checked for the native name uniqueness and the occupied-target rules.

## Drafts and cleanup

An editor-led run prepares a protected application-owned draft. The draft is
retained on cancellation, on a failed launch and on a refused proposal, and
its location is reported. Every outcome that retains a draft names it: the
planned, the rejected and the published reports carry `draftId` and
`draftPath`, and every refusal after the draft was prepared names the draft
in its message. That includes a failure of the editor session and a failure
while the collected fields are recorded: the exit code and the diagnostic of
the cause are preserved, and the retained draft is appended. The operator
can therefore resume the draft with its identity.

The fields that the guided flow collects are part of the retained intent, so
a resume rebuilds the proposal with the collected values instead of losing
them.

A successful publication removes the draft it created and never removes the
original body file of the operator. A cleanup failure is reported next to
the published output: the report states `published: true` and names the
cleanup failure instead of hiding it.

## The Agent bound-role route

The bound-role route publishes the reviewed native Codex definition of
`--definition-source` and registers the role in the declaring config of
`--config-file` only when `--ownership both` selects it. A registration
requires `--ack-clients-stopped` and its own approval. The definition source
is a stable path: the reviewed plan identity covers its digest, so the
review and the apply must name the same file with the same content.

The bound-role route accepts no standalone authoring selection. Every
standalone flag is refused before any effect, with the reason that the
standalone Agent is published first and named with `--definition-source`.
That includes the editor selection and the instruction disclosure: the
bound-role route edits no body and discloses no instruction text.

A standalone creation never changes a declaring config, never adopts a
source and never registers a role.

## The retired JSON operation request

`agent create` refuses a positional JSON operation request and the
`--request` alias with actionable migration guidance that names the
replacement selections. There is no compatibility escape and no hidden
JSON route.

### Scope judgment for the lifecycle routes

The lifecycle routes `agent adopt`, `agent replace` and `agent remove` keep
their bound-role operation envelope. That envelope is a parent and lifecycle
management surface, not the authoring operation document: its operation must
match the selected command, so a `create` operation is refused there with
"The bound-role request operation must match the selected command." There is
therefore no JSON route that creates a resource.

The plain-text authoring decision retires the JSON authoring and conversion
operation document, and this slice delivers that for the creation route. The
adoption, replacement and removal of an installed resource and its parent
registration are a different capability with their own validators, their own
plan identities and their own stopped-client acknowledgement. Migrating them
to named selections is a separate change of that surface; deleting them here
would remove a working capability that this ticket does not replace. The
stopped-client guidance names both spellings truthfully: `--ack-clients-stopped`
on the create route and `--clients-stopped` on the lifecycle routes.

## Limits

The suites run on Windows with an injected in-memory filesystem and injected
terminal, editor, and confirmation seams. No harness, provider, editor, or
other native program was launched, so no runtime activation, discovery, or
save proof is claimed. macOS and Linux runtime verification is out of scope
for this slice.
