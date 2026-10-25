# Agent Resource

Agent Resource is a Mamba command-line application for managing resources
consumed by AI coding harnesses. The current scope provides application help
and version reporting, read-only discovery of project-local and user-wide
skill candidates, and inspection of a selected skill's instructions.

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

The no-argument and `--help` invocations show the root help. Unsupported
commands and options fail with a nonzero exit status.

## Commands

### Discover project-local or user-wide skills

```text
dart run bin/agent_resource.dart discover --project <directory>
dart run bin/agent_resource.dart discover --home <directory>
```

`discover` requires exactly one explicit root: use `--project` for
project-local discovery or `--home` for user-wide discovery. Supplying neither
or both options is rejected before scanning, and no home or other environment
variable is consulted. Relative roots are resolved against the invocation
working directory. The selected root may itself be a directory link, but
linked entries below it are excluded without following their targets.

Discovery prints a JSON object containing read-only occurrences. It inspects
only the immediate real directories under the selected root, in this fixed
order:

- `.agents/skills` (`shared`)
- `.claude/skills` (`claude`)
- `.codex/skills` (`codex`)

Each occurrence reports its absolute normalized path, destination,
`installationScope: "project"` for `--project` or `"user"` for `--home`, and
whether the candidate contains a regular `SKILL.md` file. Missing locations
are empty; files in place of configured scan directories are errors. Linked
or junction harness, skills, candidate, and marker entries are excluded, and
ordinary files at candidate level are ignored. Discovery does not recurse,
parse skill contents, validate formats, or mutate the selected root. It makes
no claim about validity, management ownership, origin, or whether a consuming
harness will discover an occurrence; a filesystem failure rejects the whole
invocation rather than returning partial JSON.

### Inspect one skill directory

```text
dart run bin/agent_resource.dart inspect --skill <directory>
```

`inspect` requires the explicit named `--skill` directory selection. Relative
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
dart run bin/agent_resource.dart validate --skill <directory>
```

`validate` requires the explicit named `--skill` directory. It applies the
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
stderr by a status-2 failure. Malformed UTF-8 is a product diagnostic in an
invalid report, not an operational error. Filesystem/I/O and other operational
command errors are plain human-readable stderr failures with status 1, rather
than fabricated reports. ANSI styling is disabled at the executable boundary
so report JSON is directly parseable on either stream.

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
home, and configuration directories. They do not require network access after
dependencies have been resolved.
