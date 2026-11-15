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
| `--body-file`, `--body-stdin`, `--body-text` | The instruction body. Exactly one selector is allowed. |
| `--output` | An explicit placement of the created output. |
| `--manage` | The explicit request for a managed installation record. |
| `--apply`, `--yes`, `--plan-id`, `--dry-run` | The publication controls. |
| `--interactive`, `--unattended`, `--editor`, `--show-instructions` | The interaction boundary. |

A supplied list replaces the whole native list field; an omitted list keeps
the source value. A field that the selected profile does not support is
refused with the supported field names of that profile.

## The interaction boundary

- The guided flow is the default on a usable terminal. It collects the
  missing required native fields, opens the configured editor for the
  instruction body when no body was supplied, validates the proposal, shows
  the target, the ownership and the declared changes, and asks for the
  publication confirmation in the same flow.
- `--unattended` and `--format json` never prompt and never wait. Every
  required value must be supplied explicitly. A machine-readable output
  contains the report only.
- `--interactive` without a usable terminal is refused; the operator is told
  to supply every value explicitly instead.
- `--dry-run` plans and nothing else: it never launches an editor, never
  prepares a draft and never writes. The body must already be supplied.
- The editor is selected from an explicit choice, then `VISUAL`, then
  `EDITOR`, then the platform default. It is an executable with its
  arguments, never a shell expression. Closing the editor is never
  publication consent, and unchanged text is never an automatic
  cancellation.

## Ownership

A new output is author-only by default: no installation record, no baseline
and no adoption. `--manage` requests a managed record and is refused when the
selected form or profile has no managed lifecycle, instead of falling back to
an author-only output. An author-only output in a native root is still
checked for the native name uniqueness and the occupied-target rules.

## Drafts and cleanup

An editor-led run prepares a protected application-owned draft. The draft is
retained on cancellation, on a failed launch and on a refused proposal, and
its location is reported. A successful publication removes the draft it
created and never removes the original body file of the operator. A cleanup
failure is reported next to the published output: the report states
`published: true` and names the cleanup failure instead of hiding it.

## The Agent bound-role route

The bound-role route publishes the reviewed native Codex definition of
`--definition-source` and registers the role in the declaring config of
`--config-file` only when `--ownership both` selects it. A registration
requires `--ack-clients-stopped` and its own approval. The definition source
is a stable path: the reviewed plan identity covers its digest, so the
review and the apply must name the same file with the same content.

A standalone creation never changes a declaring config, never adopts a
source and never registers a role.

## The retired JSON operation request

`agent create` refuses a positional JSON operation request and the
`--request` alias with actionable migration guidance that names the
replacement selections. There is no compatibility escape and no hidden
JSON route.

## Limits

The suites run on Windows with an injected in-memory filesystem and injected
terminal, editor, and confirmation seams. No harness, provider, editor, or
other native program was launched, so no runtime activation, discovery, or
save proof is claimed. macOS and Linux runtime verification is out of scope
for this slice.
