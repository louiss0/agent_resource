# Agent Resource

Agent Resource is a Mamba command-line application for managing resources
consumed by AI coding harnesses. The current scope provides application help
and version reporting, read-only discovery of project-local and user-wide
skill candidates, inspection of a selected skill's instructions, completed
bounded validation of one selected skill, and read-only native Agent
inspection/validation for Claude, Codex, and the common Pi profile.

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
`skill` and `agent` groups; `skill --help` lists its `discover`, `inspect`, and
`validate` child commands. There are no root-level aliases, so all skill
workflows use the `skill ...` command path. Unsupported commands and options
fail with a nonzero exit status.

```text
dart run bin/agent_resource.dart skill --help
dart run bin/agent_resource.dart agent --help
```

## Commands

### Discover project-local or user-wide skills

```text
dart run bin/agent_resource.dart skill discover --project <directory>
dart run bin/agent_resource.dart skill discover --home <directory>
```

`skill discover` requires exactly one explicit root: use `--project` for
project-local discovery or `--home` for user-wide discovery. Supplying neither
or both options is rejected before scanning, and no home or other environment
variable is consulted. Relative roots are resolved against the invocation
working directory. The selected root may itself be a directory link, but
linked entries below it are excluded without following their targets.

Discovery prints a JSON object containing read-only occurrences. It inspects
only the immediate real directories under the selected root, in this fixed
product-convention order:

- `.agents/skills` (`shared`)
- `.claude/skills` (`claude`)
- `.codex/skills` (`codex`)

These destinations are Agent Resource search conventions, not a universal
multi-harness discovery profile. The shared `.agents/skills` label does not
prove that every harness reads the occurrence. The `.codex/skills` scan is
retained for legacy compatibility and is not the current documented universal
Codex root. Inventory also makes no claim about native precedence or runtime
visibility in Claude, Codex, or another consumer.

Each occurrence reports its absolute normalized path, destination,
`installationScope: "project"` for `--project` or `"user"` for `--home`, and
whether the candidate contains a regular `SKILL.md` file. Missing locations
are empty only after their parent listing positively confirms absence; a lookup
or scan failure rejects the whole invocation rather than presenting an
incomplete inventory. Files in place of configured scan directories are errors.
Linked or junction harness, skills, candidate, and marker entries are excluded,
and ordinary files at candidate level are ignored. Discovery does not recurse,
parse skill contents, validate formats, or mutate the selected root. It makes
no claim about validity, management ownership, origin, or whether a consuming
harness will discover an occurrence; a filesystem failure rejects the whole
invocation rather than returning partial JSON. The scan assumes a trusted,
stable local root and does not claim resistance to hostile concurrent
filesystem replacement.

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
linked-file/safety refusals status 4. Both operations are read-only and create
no management records, caches, logs, staging, or backups. Agent discovery,
lifecycle operations, composition, conversion, and parent changes are not yet
implemented.

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
