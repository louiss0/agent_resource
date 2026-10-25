# Agent Resource

Agent Resource is a Mamba command-line application for managing resources
consumed by AI coding harnesses. The current scope provides application help
and version reporting plus read-only discovery of project-local skill
candidates.

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

### Discover project-local skills

```text
dart run bin/agent_resource.dart discover --project <directory>
```

`discover` requires an explicit existing project directory and prints a JSON
object containing read-only discovery occurrences. It inspects only the
immediate real directories under these project-local locations, in this fixed
order:

- `.agents/skills` (`shared`)
- `.claude/skills` (`claude`)
- `.codex/skills` (`codex`)

Each occurrence reports its absolute normalized path, destination,
`installationScope: "project"`, and whether the candidate contains a regular
`SKILL.md` file. Missing locations are empty; files in place of configured scan
directories are errors. Symlinked or junction directories and ordinary files
at candidate level are ignored. Discovery does not recurse, parse skill
contents, validate formats, or mutate the project. It makes no claim about
validity, management ownership, or whether a consuming harness will discover
an occurrence; a filesystem failure rejects the whole invocation rather than
returning partial JSON.

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
