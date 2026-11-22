# Prompts

A Prompt is a manual-only resource: a Skill-shaped package whose native view
disables automatic model invocation for a harness that supports it. The same
directory can be a Prompt for one consumer and an ordinary Skill for
another; there is no universal classification.

## The three Prompt forms

- **Skill-backed Prompt** — Claude and Codex express a Prompt as a Skill
  package. Pack `--type prompt` installs valid supported Skill-backed
  Prompts through the native Skill installation and keeps the Skill
  ownership record and selectors.
- **Derived native template** — Pi's conversion form is a rendered template.
  `skill install`/`pack install --prompt-target pi` publishes a derived
  `.pi/prompts` template recorded on the parent Skill. See
  [the Skill guide](skills.md#derived-prompt-templates).
- **Global/manual-only Prompt** — a Prompt authored with the `global`
  profile has no per-harness managed form.

## Read-only surfaces

```text
agent-resource prompt inspect --path <path> [--target claude|codex|pi]
agent-resource prompt validate --path <path> [--target claude|codex|pi]
agent-resource prompt list [--scope project|user|all] [--target claude|codex|pi]
```

These report the harness-relative views of an explicit native source or the
native Prompt surfaces. With `--target` the report states the kind and
validity of that consumer; without it the report shows the differing views.
The paths never disclose an instruction body, never write a management
artifact, and never install a resource.

## Deferred operations

There is no direct `prompt install`, `prompt edit`, or prompt lifecycle
selector set — those are deliberately deferred boundaries
(`agent-resource support` lists them with explanations). Pack-installed
Prompts live under Skill ownership records; update, migrate, replace,
remove, and backup/restore act through the Skill selectors of the pack or
the parent Skill record. Author a replacement with `prompt create` or edit
the parent Skill. Antigravity exposes no native control that disables
automatic model invocation, so it refuses Prompt views rather than
fabricating one.

## Authoring

```text
agent-resource prompt create --profile claude|codex|pi|global --name <name> --description <text> --body-file <file>|--body-stdin|--body-text <text>
```

Creation takes named native selections and plain text; the profile is always
explicit and the body comes from exactly one source flag. On a usable
terminal the guided flow collects missing fields and opens the configured
editor for the body; `--unattended` and `--format json` never prompt. The
reviewed proposal names its target and declared values before publication;
`--apply --yes` publishes without a question and `--dry-run` plans without a
write. A new output is author-only unless `--manage` selects a supported
managed form.

## Conversion transactions

```text
agent-resource prompt conversion list [--scope project|user|all]
agent-resource prompt conversion inspect <transaction-id> --scope project
agent-resource prompt conversion recover <transaction-id> --scope project
agent-resource prompt conversion cleanup <transaction-id> --scope project
```

These use retained coordinator evidence. Inspection and the default
recover/cleanup invocations are read-only; apply requires the current plan
ID and explicit approval. See [the recovery guide](recovery.md).
