# Configuration and preferences

`config` validates configuration files, reports the resolved settings with
their origins, and manages the small set of remembered preferences.

## Effective configuration

```text
agent-resource config effective [--scope project|user] [--pack <key>] [--format text|json]
```

`config effective` is read-only. It reports the resolved safe preferences,
the user and project configuration paths, and each value's **origin**:
explicit argument, project config, user config, pack config, detection, or
built-in default. Explicit `--target`, `--method`, and `--snapshot-days`
values are shown as explicit argument origins without changing
configuration. `--pack <key>` reports pack-level install overrides as
`pack-config` origins. A user path discovered from `XDG_CONFIG_HOME` reports
that variable as its source.

## Saving preferences

```text
agent-resource config prefer --scope project|user --set <key>=<value> [--apply]
agent-resource config validate [--resolve]
```

`config prefer` previews eligible changes by default; `--apply` writes only
the reviewed safe preferences to the selected configuration. The eligible
keys are `cli.install.targets`, `cli.install.skill_method`, and
`cli.retention.snapshot_days`. Applies use focused table edits that preserve
comments, indentation, and unrelated TOML sections; ambiguous inline or
dotted layouts are refused. Publication uses lifecycle coordination,
staging, backup and quarantine evidence, and rename; unsafe conditions
refuse and an interruption is recovered through `skill recover` /
`agent recover` with `--configuration-target`. Approvals, destructive
consent, credentials, and credential-like values are never remembered.

Interactive Skill, Agent, and pack installations resolve applicable
preferences and report the selected scope, targets, method, and origins in
the plan. An interactive installation may offer to save its eligible choices
after successful publication; declining does not affect the installation.
Dry runs, failed or cancelled installs, and unattended direct installs do
not save preferences — unattended invocations require explicit choices.

## Scope resolution

Scope resolution is project-first: when a project boundary is detected,
project scope is the default; explicit `--scope user|all` opts out. Use
`--cwd`, `--project-root`, `--home`, the native-home overrides, and
`--state-dir` to select an isolated context. Relative operation paths
resolve against `--cwd`.

## Pack configuration

Packs live in project-level or user-level `agent-resources.toml` alongside
install preferences:

```toml
schema_version = 1

[cli.install]
targets = ["codex"]
skill_method = "copy"

[packs."owner/repository".source]
kind = "github"
repository = "owner/repository"

[packs."owner/repository".update]
track = { kind = "branch", name = "main" }
```

Local sources use `kind = "local"` and `path = "../pack"` with
`track = { kind = "local" }`. Git sources can follow a branch or pin an
exact tag or commit; GitHub release tracks support exact releases and
explicit SemVer bump policies. Ordinary install never advances an existing
exact lock. See [the walkthroughs](walkthroughs.md) for a complete
pack-to-update flow.
