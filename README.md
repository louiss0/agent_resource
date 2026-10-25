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
