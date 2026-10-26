# Agent Resource

Agent Resource is a Mamba command-line application for managing resources
consumed by AI coding harnesses. The current scope provides application help
and version reporting, management-aware Skill and Agent inventories, native
inspection/validation, copied-Skill and regular-file Agent installation and
adoption, unchanged-only replacement/removal, retained backups, explicit
restore/cleanup, and evidence-backed transaction recovery. Claude, Codex, and
the common Pi profile remain distinct native contracts.

## Requirements

- Dart SDK 3.13.2 or newer

## Get dependencies

From the package root, resolve the Dart dependencies:

```text
dart pub get
```

## Run

Run the executable directly:

```text
dart run bin/agent_resource.dart
dart run bin/agent_resource.dart --help
dart run bin/agent_resource.dart --version
```

The no-argument and `--help` invocations show root help. Root help lists the
`skill` and `agent` groups. Each group provides `list`, `inspect`, `validate`,
`install`, `adopt`, `replace`, `remove`, `backup`, and `recover` paths. There
are no root-level aliases, and `skill discover` is not retained as a second
inventory verb. Unsupported commands and options fail with a nonzero exit
status.

```text
dart run bin/agent_resource.dart skill --help
dart run bin/agent_resource.dart agent --help
```

## Commands

### Inventory Skills and Agents

```text
dart run bin/agent_resource.dart skill list [--scope user|project|all]
dart run bin/agent_resource.dart agent list [--scope project|user|all]
```

Skill scope defaults to user; Agent scope defaults to project. Use `--cwd`,
`--project-root`, `--home`, native-home overrides, and `--state-dir` to select
isolated context. Relative operation paths resolve against `--cwd`. Both
inventories distinguish unmanaged candidates, managed installations,
tracked-missing records, and ownership-unverified evidence. `--verify` performs
a fresh baseline comparison; without it, modification is `notVerified`.

Skill destinations are `.claude/skills`, `.codex/skills`, and
`.agents/skills`. Direct ordinary children are eligible for copy adoption;
nested Skill discoveries remain visible but ineligible. Linked candidates are
reported without reading their targets. Agent inventory retains its native
recursive Claude/Codex, immediate common-Pi, and config-binding observations.
Occurrence IDs are not lifecycle mutation selectors.

Inventory is bounded and read-only. Incomplete required traversal fails rather
than returning partial JSON. Shared storage and native discovery conventions
do not prove runtime activation, precedence, or harness compatibility.

### Install, adopt, and manage regular files

```text
agent_resource skill install <source-directory/> --destination claude|codex|shared
agent_resource skill adopt <existing-directory/> --destination claude|codex|shared
agent_resource skill replace <installation-id> <source-directory/>
agent_resource skill remove <installation-id>
agent_resource skill backup list
agent_resource skill backup restore <backup-id>
agent_resource skill backup cleanup <backup-id>
agent_resource skill recover [<transaction-id>] [--action rollback|complete]

agent_resource agent install <native-file> --harness claude|codex|pi [--output <file>]
agent_resource agent adopt <native-file> --harness claude|codex|pi
agent_resource agent replace <installation-id> <native-file>
agent_resource agent remove <installation-id>
agent_resource agent backup list
agent_resource agent backup restore <backup-id>
agent_resource agent backup cleanup <backup-id>
agent_resource agent recover [<transaction-id>] [--action rollback|complete]
```

Installation copies an arbitrary validated ordinary source without changing
it. Skill installation defaults to copy; `--mode link` creates a true native
directory symlink and manages only that link entry. Skill installation uses the
declared Skill name; Agent installation
preserves the source basename unless an eligible `--output` is selected.
Adoption records an eligible existing resource without rewriting its bytes.
Replacement and restoration preserve installation identity and recorded
location. Removal and replacement require a currently unchanged complete
baseline and create independent retained backups before live mutation.

Linked Skills keep target validation separate from entry ownership. Target
edits do not invalidate an unchanged link entry; removal unlinks an unchanged
entry even when its target is broken or inaccessible. Link backups retain the
entry kind and target representation, not target-content history, and restore
revalidates the target at its original parent before publication. Replacement
without `--mode` retains the recorded copy/link mode; an explicit mode change
is a reviewed conversion at the same installation ID and location.

`--dry-run` performs read-only planning and creates no locks, journals,
ledgers, staging, or backups. Replacement, removal, restore, cleanup, and
recovery actions require `--yes`, or an explicit `--interactive` reviewed
confirmation. Install and adoption do not require destructive approval.
JSON and interactive modes conflict; no prompt occurs by default. Explicit
cancellation uses status 7.

Lifecycle state is stored per project at `.agent-resource` or in the selected
user state directory. Native files never receive management receipts.
Recovery acts only on validated persisted evidence and exact current-path
guards. It cannot overwrite new occupants, erase newer edits, or guess an
interrupted outcome. Successful recovery reports the state established rather
than claiming the original operation succeeded. Backup cleanup is never
automatic and does not promise secure erasure.

The implementation uses bounded local-disk IO, same-filesystem staging,
protected intent, independent backups, quarantine, and per-scope coordination.
It does not claim hostile-writer resistance, joint resource-plus-ledger
atomicity, universal metadata fidelity, or guaranteed power-loss durability.
Windows linked installations require a true directory symlink and actionable
privilege diagnostics; junctions, unknown reparse forms, and copy fallback are
refused. Registration/parent-setting changes, rich Agent composition, and
remote origins remain outside this checkpoint.

### Inspect one skill directory

```text
dart run bin/agent_resource.dart skill inspect --skill <directory>
```

`skill inspect` requires the explicit named `--skill` directory selection. Relative
paths are resolved against the current working directory and returned as
normalized absolute lexical paths; a selected directory link is allowed without
canonicalizing its returned path. The command checks only the immediate exact
`SKILL.md` entry. An absent marker, directory, or link reports
`"hasSkillFile": false` and `"content": null`; a regular file reports
`"hasSkillFile": true` and its exact decoded text, including line endings,
trailing whitespace, and empty content.

Successful output is exactly one JSON object with these fields:

```json
{"path":"/absolute/selected/directory","hasSkillFile":true,"content":"..."}
```

Marker reads are strict UTF-8 (with the standard leading UTF-8 BOM behavior)
and are limited to 1,048,576 bytes; a file requiring more bytes is rejected.
The implementation reads at most one byte beyond that limit to detect an
oversized marker. Failures are reported on stderr with a nonzero status and do
not produce partial JSON on stdout.

Inspection is read-only and non-recursive. It does not follow a linked
`SKILL.md`, read nested markers, parse frontmatter, validate skill content,
infer destination or installation scope, record management ownership, or claim
compatibility with any consuming harness.

### Validate one skill directory

```text
dart run bin/agent_resource.dart skill validate --skill <directory>
```

`skill validate` requires the explicit named `--skill` directory. It applies the
named bounded product profile `agentskills-core-ascii-v1` against the pinned
Agent Skills baseline at commit
`69ef37e9424c0a7ea9dd2293b559e43ec8176379`. A selected skill directory may be
a directory link, but its immediate `SKILL.md` marker must be a regular,
non-link file; linked markers are a product restriction. The command is
read-only: it does not execute scripts, inspect
or follow references, make network requests, fetch dependencies, or mutate the
skill directory. It makes no claim of full Agent Skills compliance, runtime
safety, harness acceptance, or filesystem sandboxing.

The profile uses literal `name`/directory-basename matching and counts their
Unicode scalar values. It requires the required metadata fields and their
bounds: `name` is a non-empty string of 1–64 characters with the required
lowercase/hyphen shape and matching basename; `description` is a non-empty
string of 1–1024 characters; `compatibility`, when present, is a string of
1–500 characters; `license` and `allowed-tools`, when present, are strings;
and `metadata`, when present, is a map with string keys and string values. The
profile's bounded-ASCII name restriction is product policy, not a claim that
the upstream specification universally rejects non-ASCII names. Unknown
frontmatter fields are advisory diagnostics, not an automatic invalidation;
`metadata` is the documented extension map.

Input is strict UTF-8, with standard leading-BOM behavior, and is capped at
1 MiB (1,048,576 bytes). The YAML frontmatter is capped at 64 KiB (65,536
bytes) and must use exact standalone delimiter lines (`---` at the beginning
and closing the frontmatter); LF and CRLF line endings are accepted. The
remaining content is Markdown. No additional body, script, reference, or
asset compliance is inferred from this check.

A completed validation returns exactly one JSON report with these top-level keys:

```json
{
  "path": "/absolute/selected/directory",
  "profile": "agentskills-core-ascii-v1",
  "baseline": "69ef37e9424c0a7ea9dd2293b559e43ec8176379",
  "valid": true,
  "diagnostics": []
}
```

`path` is the normalized absolute lexical selected directory. `diagnostics` is
an array. Each diagnostic has exactly `code`, `category`, `severity`, `field`,
and `message`; `category` is `specification`, `product`, or `advisory`,
`severity` is `error` or `warning`, and `field` is either the affected field
name or `null`. `valid` is true exactly when there are no error diagnostics;
advisory warnings alone remain valid. Valid reports are written to stdout with
status 0. An invalid report is still the same JSON shape, but is written to
stderr by a status-2 failure. Malformed UTF-8 is a product diagnostic in that
invalid report and therefore also uses status 2, not operational status 1.
Filesystem/I/O and other operational command errors are plain human-readable
stderr failures with status 1, rather than fabricated reports. At the
executable boundary, color is disabled on Mamba's exported Chalk instance, so
report JSON is raw and directly parseable on either stream.

### Discover native Agent occurrences

```text
dart run bin/agent_resource.dart agent list
dart run bin/agent_resource.dart agent list --scope user --home <directory/>
dart run bin/agent_resource.dart agent list --scope all --format json
```

`agent list` defaults to project scope and supports explicit `user` and `all`
scopes plus an optional harness filter. Claude and Codex project inventory uses
the bounded working-directory-to-project-root ancestor chain; Pi uses the
selected project boundary. Explicit context options cover cwd, project root,
home, Claude config, Codex home, Pi Agent home, and additional Claude read
roots. Environment-provided native homes are used only when corresponding
options are absent.

Inventory includes recursive Claude/Codex candidates, Codex config-declared
roles, and Pi native/Shared candidates. Immediate Pi files are distinguished
from deeper provider-specific candidates. Reports contain stable occurrence
IDs, source/binding provenance, native identity and validation observations,
collisions, and explicit coverage. Occurrence IDs are not managed installation
IDs or mutation selectors. Every occurrence remains `unmanaged` and
`notVerified`; `--verify` does not invent a baseline.

Traversal is limited to 64 ancestors, depth 16, 20,000 entries, 2,000
directories, and 64 MiB of aggregate metadata. Linked candidates are reported
without reading their targets; linked roots are refused. Missing roots are
confirmed absent. Malformed candidates remain visible in a successful static
inventory, while inaccessible required coverage or budget exhaustion fails
with status 3 and no partial JSON. Inventory does not claim runtime activation,
native precedence, uniqueness winners, ownership, or modification status.

### Inspect or validate a native Agent definition

```text
dart run bin/agent_resource.dart agent inspect ./reviewer.md --harness claude
dart run bin/agent_resource.dart agent validate ./reviewer.toml --harness codex --format json
dart run bin/agent_resource.dart agent inspect ./reviewer.md --harness pi --show-instructions
dart run bin/agent_resource.dart agent inspect --request ./bound-role.json
```

Native Agent files require an explicit harness: `claude`, `codex`, or `pi`.
Markdown is not auto-detected. The common Pi profile requires name,
description, a qualified `provider/model-id`, and a nonempty CSV using the
currently evidenced shared tools `read`, `grep`, `find`, and `ls`. Claude,
Codex standalone, and Codex config-bound roles retain their distinct native
schemas; Skill naming and directory rules are not applied to Agents.

A bound Codex role is selected with a versioned JSON request containing its
declaring config, role key, operation, and explicit working-directory context.
Its native `config_file` remains relative to the declaring config. Bound roles
may use native name/description/instruction fallback; standalone files may not.
The request schema and exact examples are documented in
`docs/specs/native-agent-inspection.md`.

Agent output defaults to text. `--format json` produces a versioned success
envelope with native form/evidence, source and binding provenance, validation
coverage, references, capabilities, and parent requirements. These are static
observations, not proof of runtime activation, model/tool availability,
permissions, sandboxing, or harness compatibility. No Agent, hook, MCP server,
extension, credential helper, model registry, or network service is executed
or probed.

Reports omit instruction bodies by default and instead include byte/scalar
lengths and SHA-256. `agent inspect --show-instructions` explicitly includes
the exact free-form instructions, which may be private. Unknown or sensitive
declarations are not dumped.

A complete `agent inspect` may succeed with `ready: false` and failed candidate
diagnostics. `agent validate` is the correctness gate and returns status 2 for
blocking violations without a success JSON report. Usage/general failures use
status 1, incomplete required analysis or exhausted budgets status 3, and
linked-file/safety refusals status 4. Inspection, validation, and inventory
are read-only. Regular-file lifecycle operations are documented above;
composition, conversion, registration, and parent changes remain unimplemented.

## Analyze

```text
dart analyze
```

## Check formatting

```text
dart format --output=none --set-exit-if-changed lib bin test
```

## Test

```text
dart test
```

The process-boundary tests run the executable with isolated temporary working,
home, and configuration directories, initializing all of those environment
directories before taking full snapshots. They compare entries, types, and
bytes rather than access timestamps; read-only behavior does not claim that
SDK/file-system reads cause no physical access-time updates. They do not
require network access after dependencies have been resolved.
