# Packs

A pack is a declared consumer collection in a project- or user-level
`agent-resources.toml`, tracking its resource origin and update track
separately from machine-local installation evidence. See
[the configuration guide](configuration.md#pack-configuration) for the TOML
shape.

## Operations

```text
agent-resource pack validate <pack> [--type skill|agent|prompt] [--only <name> ...]
agent-resource pack discover <pack> [--type skill|agent|prompt] [--target claude|codex|pi]
agent-resource pack install <pack> [--type skill|agent|prompt] [--only <name> ...] [--prompt-target pi ...]
agent-resource pack update <pack> [--type skill|agent] [--only <name> ...]
agent-resource pack migrate <pack> --only <name> [--dry-run]
agent-resource pack remove <pack> --only <name> [--only <name> ...]
agent-resource pack source associate <pack> --only <name> [--only <name> ...]
agent-resource pack source change <pack> --to <configured-pack>
agent-resource pack rollback <pack> --only <name> --snapshot <recorded-ref>
agent-resource pack cleanup <pack> [--only <name> ...]
```

Canonical operations default to the Skill and Agent types; `--type prompt`
applies to `pack validate`, `pack discover`, and `pack install`. `--only`
uses native names, not catalog IDs or installation IDs. Unknown names and
cross-type ambiguous selections are rejected before publication.

`pack discover` is read-only: it reports the configured pack's candidates
and per-consumer Prompt views — including each Skill candidate's
installation admission — without writing management state. `pack validate`
separates native validity (`native:`) from installation eligibility
(`eligibility:`) in its diagnostics.

`--type prompt` installs valid, supported Skill-backed Prompts through the
native Skill installation, keeping the Skill ownership record and the
update, removal, and rollback selectors of the installed resource. Every
selected resource must be a valid Prompt for every requested target; a mixed
selection, a Pi target, or a standalone template refuses the whole selection
before any installation effect. Repeatable `--prompt-target <harness>`
derives native Prompt templates for manual-only Skills — see
[the Skill guide](skills.md#derived-prompt-templates).

## Review rules

Mutations require interactive review or explicit unattended context:
`--scope`, all required choices, and `--yes`. `--dry-run` performs inert
acquisition and review without publishing managed state. `--yes` does not
infer resource selection, local-edit decisions, extra-folder admission, or
changed same-release attachment consent. Use `--keep-local` /
`--replace-local` for whole-resource edit decisions and
`--approve-removal <name>` for reviewed upstream removals.

New upstream resources discovered by an update remain unselected unless
explicitly included; upstream removals require explicit approval.

Skill roots admit `SKILL.md`, `references/`, `scripts/`, `assets/`, and
`agents/`; additional root folders require bounded approval through review
or `--allow-folder <skill-name>:<root-folder>`.

## State and rollback

Machine-local state lives in `.agent-resource/installations.json` or the
selected user state directory: source evidence, installation baselines,
selections, approvals, operation evidence, and recorded snapshot refs.
`pack rollback` restores one resource from a recorded snapshot. Ordinary
noncurrent snapshots are eligible for retention cleanup after the configured
retention window; locally edited backups require explicit reviewed cleanup.
