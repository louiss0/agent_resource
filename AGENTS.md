# AGENTS.md

This project is a Mamba command-line application. The `mamba` skill installed
in this project documents the Mamba API; this file documents driving the
`mamba` CLI.

## The mamba CLI

Use the generators below to start files, then implement their behavior.
Run `mamba --help` for the full surface.

| Command | Writes | Use it to |
| --- | --- | --- |
| `mamba command <name>` | `lib/<name>.dart` | Start a command. |
| `mamba command <name> --group` | `lib/<name>.dart` | Start a command that owns child commands. |
| `mamba command <name> --test` | `lib/<name>.dart` and its suite | Start a command with tests. |
| `mamba command <name> --append <file>` | appends to `<file>` | Add a command to an existing file. |
| `mamba test <name>` | `test/<name>_test.dart` | Add a suite for an existing command. |
| `mamba binary <name>` | `bin/<name>.dart` | Add a second executable. |
| `mamba class <name>` | `lib/src/<name>.dart` | Start an ordinary Dart class. |
| `mamba service <name>` | `lib/src/services/<name>_service.dart` | Start a concrete interface-class service. |
| `mamba component prompt <name>` | `lib/components/<name>.dart` | Wrap Clix line input. |
| `mamba component selector <name>` | `lib/components/<name>.dart` | Select or filter numbered choices. |
| `mamba component picker <name>` | `lib/components/<name>.dart` | Browse directories with numbered choices. |
| `mamba component indicator <name>` | `lib/components/<name>.dart` | Wrap a Clix spinner. |

A component is a plain class that owns one question or one piece of progress,
and exposes one async `render` that a command awaits. Input, selectors, and
pickers use line input; a blank answer cancels. Use `ClixInput` for the toolkit
text prompt: `Input` remains Mamba's typed declaration.

`<file>` and `--append` require each other, so pass both or neither. `mamba
test` mirrors `lib/a/b.dart` to `test/a/b_test.dart` and rejects a source file
outside `lib/`. Syntax-aware append rejects invalid Dart, duplicate top-level
names, part layouts, and unsupported test suites before changing files.
This checks syntax, not types or dependency resolution.

An action-command skeleton requires a `value` positional, trims it, and throws
`MambaException` for blank input. Replace that example with your command's real
contract. With `mamba command <name> --test`, runnable tests exercise success
and command-level validation as well as help and parser rejection. Standalone
`mamba test` and empty group scaffolds provide only generic smoke tests; add
application behavior tests yourself.

## Classes and services

Run these commands from the package root with a valid `pubspec.yaml` declaring
Dart 3.13 or newer. Use lower_snake_case names: `auth_token` becomes `AuthToken`;
service `auth` or `auth_service` becomes `AuthService` in `auth_service.dart`.

- `mamba class <name> --kind <kind>` selects `plain`, `final` (default),
  `interface`, `abstract`, `abstract-interface`, `base`, or `sealed`.
- `mamba class <name> --directory lib/src/auth` chooses an eligible directory.
  Classes cannot target `lib/` itself, `lib/components/` or its descendants,
  or `lib/src/services/` or its descendants. Missing eligible directories are
  created. Services always live directly in `lib/src/services/`.
- Both commands support `<file> --append` and `--test`. Append uses an existing
  eligible Dart library; services can append only directly in their directory.
  `--directory` and `--append` cannot be combined. Existing files are never
  overwritten in create mode.
- `--test` mirrors the library path under `test/`, including `src/`, and adds a
  grouped, explicitly skipped behavior-test placeholder. Replace the placeholder
  with real tests. The package must provide `package:test`; generation does not
  install dependencies. The standalone `mamba test` remains command-specific.
- Templates contain only a const constructor. Add application behavior and
  dependencies yourself; wire services through constructors or focused callbacks.
  Public exports and consumer imports remain application-owned. These commands
  use in-process parsing and formatting without launching subprocesses; older
  generators retain their existing formatter behavior.

## What not to do

- **Start supported declarations with their matching generator.** Use `mamba
  command`, `mamba component`, `mamba class`, or `mamba service`, with `--test`
  where supported; use `mamba test` for existing commands. Then edit the generated
  files to implement behavior and replace starter tests.
- **Do not leave a scaffolded command unwired.** It runs nothing until its
  instance reaches the executor's command list or its parent's constructor.
- **Do not call `Executor.fake()` from `bin/`.** Call `create()` in the
  executable and keep `fake()` in `test/`.
- **Do not report a rejected invocation by returning a string.** Return the
  success message, and throw `MambaException` when the invocation cannot be
  honoured.
- **Do not expect scaffolding to run the application.** `mamba create` runs
  `dart pub get` only when installation is accepted, always installs the
  framework skill, and optionally initializes Git. Every other command only
  writes files.
