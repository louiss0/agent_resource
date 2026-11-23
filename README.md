# Agent Resource

Agent Resource is a Mamba command-line application for managing resources
consumed by AI coding harnesses — Claude, Codex, Pi, and Antigravity. It
provides management-aware inventories, native inspection and validation,
canonical/copy/source-linked Skill installation, reviewable updates and
route migrations, pack lifecycles, derived Prompt templates, MCP and Context
management, retained backups, and evidence-backed transaction recovery.
Every mutation is journaled; nothing is overwritten silently.

## Requirements

- Dart SDK 3.13.2 or newer

## Install a published release

On macOS with Homebrew:

```text
brew tap louiss0/the-code-fixer-23
brew install --cask agent-resource
```

On Windows, after the release's WinGet pull request has been merged:

```text
winget install --id louiss0.AgentResource --exact
```

Release archives and checksums are also attached to GitHub releases. See
`docs/releasing.md` for supported targets and the release process.

## Get dependencies and run

```text
dart pub get
dart run bin/agent_resource.dart --help
```

## Common first tasks

The root help lists the same tasks with exact commands
(`agent-resource --help`).

```text
agent-resource skill install <source> --target claude        # install a Skill
agent-resource pack install <pack>                           # install a Pack
agent-resource mcp register --name <svc> --harness claude --scope project --command <cmd>
agent-resource context inject <name>                         # inject a Context template
agent-resource config effective                              # resolved settings + origins
agent-resource skill update <installation-id>                # replay the recorded route
agent-resource skill migrate <installation-id> --method canonical
agent-resource skill recover                                 # inspect recovery actions
```

Interactive invocations on a usable terminal prompt for missing choices,
display the complete plan — resolved scope, targets, method, and their
origins — and ask for approval before writes. Unattended invocations supply
every required choice explicitly and approve the final plan with `--yes`;
`--dry-run` previews without approval or management writes.

Run `agent-resource support` (or `agent-resource support --format json`) for
the authoritative lifecycle boundary of every resource, and
`agent-resource <group> --help` for one group's registered surface and
boundary disclosure.

## Task guides

- [Skills](docs/guides/skills.md) — inventory, validity vs. installation
  eligibility, install methods, route replay on update, migrate
  preview/confirm, derived Prompt templates.
- [Prompts](docs/guides/prompts.md) — manual-only semantics, skill-backed
  Prompts, Pack `--type prompt`, deferred direct install/edit.
- [Agents](docs/guides/agents.md) — inventory, native profiles, copy-only
  installation, authoring/conversion, parent configuration.
- [Packs](docs/guides/packs.md) — declared packs, review rules, type
  selectors, rollback.
- [MCP](docs/guides/mcp.md) — static-only checks, credential references,
  declarative replacement.
- [Context](docs/guides/context.md) — templates and one-shot injection.
- [Configuration](docs/guides/configuration.md) — effective settings,
  origins, `config prefer`, project-first scope, pack TOML.
- [Recovery](docs/guides/recovery.md) — journaled transactions, conversion
  and authoring recovery, configuration publication evidence.
- [Walkthroughs](docs/guides/walkthroughs.md) — three end-to-end flows.

## Support matrix

The lifecycle boundary contract below is generated from the application's
declarative contract (the same source as `agent-resource support`); the test
suite fails if it drifts.

```text
<!-- support-matrix:start -->
skill:
  create: supported (skill create)
  inspect: supported (skill inspect)
  validate: supported (skill validate)
  install: supported (skill install)
  adopt: supported (skill adopt)
  update: supported (skill update)
  migrate: supported (skill migrate)
  replace: supported (skill replace)
  remove: supported (skill remove)
  backup-restore: supported (skill backup)
  recover: supported (skill recover)
  edit: supported (skill edit)
  sync: deferred — Managed installations are refreshed through update; there is no separate destination-sync operation.
  note: Native validity and installation eligibility are reported separately; a natively valid Skill can still be ineligible for a selected target or method.
prompt:
  create: supported (prompt create)
  inspect: supported (prompt inspect)
  validate: supported (prompt validate)
  install: supported (pack install)
  adopt: deferred — Pack-installed Prompts live under Skill ownership records; manage them through the Skill selectors of the pack.
  update: deferred — Pack-installed Prompts live under Skill ownership records; manage them through the Skill selectors of the pack.
  migrate: deferred — Pack-installed Prompts live under Skill ownership records; manage them through the Skill selectors of the pack.
  replace: deferred — Pack-installed Prompts live under Skill ownership records; manage them through the Skill selectors of the pack.
  remove: deferred — Pack-installed Prompts live under Skill ownership records; manage them through the Skill selectors of the pack.
  backup-restore: deferred — Managed Prompt artifacts are backed up and restored through their parent Skill records; conversion restore covers only conversion transactions.
  recover: supported (prompt conversion recover)
  edit: deferred — There is no direct prompt edit; author a replacement with prompt create or edit the parent Skill.
  sync: deferred — Pack-installed Prompts live under Skill ownership records; manage them through the Skill selectors of the pack.
  note: Skill-backed Prompts publish through `pack install --type prompt` and derived Pi templates through `skill install`/`pack install --prompt-target`; only a direct `prompt install` is deferred. Both routes record Skill ownership.
agent:
  create: supported (agent create)
  inspect: supported (agent inspect)
  validate: supported (agent validate)
  install: supported (agent install)
  adopt: supported (agent adopt)
  update: deferred — Agents have no source-bound update; re-author the definition and replace the managed installation.
  migrate: deferred — agent convert republishes across harnesses; there is no installation-route migration for Agents.
  replace: supported (agent replace)
  remove: supported (agent remove)
  backup-restore: supported (agent backup)
  recover: supported (agent recover)
  edit: supported (agent edit)
  sync: deferred — Registrations are refreshed through replace; there is no separate destination-sync operation.
mcp:
  create: supported (mcp register)
  inspect: supported (mcp inspect)
  validate: supported (mcp validate)
  install: supported (mcp register)
  adopt: supported (mcp adopt)
  update: deferred — Registrations have no in-place update; replace the registration.
  migrate: deferred — mcp convert republishes across harnesses; there is no registration-route migration.
  replace: supported (mcp replace)
  remove: supported (mcp unregister)
  backup-restore: supported (mcp backup)
  recover: supported (mcp recover)
  edit: deferred — Ordinary editing of registrations is not offered; unregister and register the corrected entry.
  sync: deferred — Registrations are refreshed through replace; there is no separate destination-sync operation.
  note: MCP inspection and validation are static checks; they make no runtime, connectivity or credential-success claims.
  note: Claude user and local MCP scopes are inspect-only for mutation.
context:
  create: supported (context create)
  inspect: supported (context inspect)
  validate: deferred — Templates are validated during create and edit; there is no standalone validation.
  install: deferred — Templates are local files; context inject publishes a copy into a destination instead of installing.
  adopt: deferred — Context templates are not adopted into a managed ledger.
  update: deferred — Edit the template and inject it again; injected destination files are not tracked.
  migrate: deferred — Context templates have no installation routes.
  replace: deferred — Context templates are edited in place, not replaced.
  remove: supported (context delete)
  backup-restore: deferred — Context templates have no managed backup ledger.
  recover: deferred — Context templates run no managed transactions; there is nothing to recover.
  edit: supported (context edit)
  sync: deferred — context inject is a one-shot publication; editing a template does not update files it was previously injected into.
<!-- support-matrix:end -->
```

Harness × resource support from the catalog:

<!-- harness-matrix:start -->
| Harness | Skill | Prompt | Agent | MCP | Context |
| --- | --- | --- | --- | --- | --- |
| claude | install | skill-backed | supported | supported | supported |
| codex | install | skill-backed | supported | supported | supported |
| pi | — | template | supported | supported | supported |
| antigravity | install | — | supported | supported | supported |
<!-- harness-matrix:end -->

Pi Skills are read through canonical shared content or other managed routes;
it has no direct Skill installation target. Antigravity has no native
control that disables automatic model invocation, so it has no Prompt form.

## Safety boundaries

- Interactive components never prompt without a usable input **and** output
  terminal; redirected output means no prompts.
- Mutations require interactive review or explicit `--yes`; `--yes` grants
  no selection, takeover, repair, or consent authority.
- Changed or foreign artifacts are retained and reported, never silently
  removed; recovery acts only on validated persisted evidence.
- Static checks (Skill/Agent/MCP inspection and validation) claim no runtime
  activation, connectivity, credential success, or harness compatibility.
- Credential literals are rejected where a native reference is required;
  secrets are never echoed or stored.

## Analyze, format, test

```text
dart analyze
dart format --output=none --set-exit-if-changed lib bin test
dart test
```

Build and execute the sanitized production-artifact release gate with:

```text
dart compile exe bin/agent_resource.dart -o build/agent_resource.exe
dart run test/support/release_gate.dart build/agent_resource.exe build/release-evidence.json
```

Use `build/agent_resource` without `.exe` on macOS/Linux. A local run
produces native-job evidence with `revision: local-working-tree` and no CI
job provenance, so it is not an integrated release verdict. CI runs this
gate on all three native operating systems and uploads only the sanitized
evidence JSON. `docs/release-qualification.md` contains the
behavior/evidence index, current blockers, and explicit readiness decision;
green tests alone do not qualify a release.

The process-boundary tests run the executable with isolated temporary
working, home, and configuration directories, initializing all of those
environment directories before taking full snapshots. They compare entries,
types, and bytes rather than access timestamps; read-only behavior does not
claim that SDK/file-system reads cause no physical access-time updates. They
do not require network access after dependencies have been resolved.
