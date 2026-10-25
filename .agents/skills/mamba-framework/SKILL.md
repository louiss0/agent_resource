---
name: mamba
description: Develop and test Dart CLI applications that use Mamba. Use when adding or changing executors, commands, command groups, typed inputs, injected dependencies, hooks, context, standard input, output, errors, help, shell completions, or prompt components.
compatibility: requires mamba cli and dart cli
---

# Mamba framework

Use this skill for Mamba's application API. The application's `AGENTS.md`
documents driving the scaffolding CLI; keep command recipes there.

## Start with the application

1. Inspect the command, tests, and composition root relevant to the task. For
   registration or executor changes, locate the executable's `main` and follow
   its command tree. A new application may need this entry point created:

   ```dart
   import 'package:mamba/mamba.dart';

   Future<void> main(List<String> args) => Executor(
     'acme',
     'Manage Acme deployments.',
     '1.0.0',
     [], // Register the application's commands here.
   ).create().execute(args);
   ```

   Multiple executables are valid. Ask which to change only when the request
   and code leave multiple plausible targets.
2. Read the matching reference before choosing input declarations, changing
   hooks, generating completions, or writing tests; see [Task references](#task-references).
3. Retain each declaration, register it at the intended scope, and read that
   exact instance through `valueOf`. Keep declaration fields private and give
   parsed values domain names inside `run`.
4. Register new root commands with the executor and children with their parent
   group. Validate the affected invocation paths through `fake()` in tests.

Keep process-facing `create()` at the executable entry point and `fake()` in
application tests. These are authoring conventions, not API placement checks.

## Choose the input shape

Choose by the user's workflow and accepted syntax, then read the linked
reference for concrete types and constraints:

| Requirement | Choose |
| --- | --- |
| Obvious required unnamed input | A mandatory [positional](references/arguments.md). |
| Optional unnamed input with an unambiguous place | A discretionary positional; use a named option if repetition makes its position ambiguous. |
| Named setting, filter, or value with unclear positional order | A scalar or repeatable [option](references/options.md), required or optional as appropriate. |
| Valueless on/off control | A boolean [flag](references/flags.md). |
| Occurrence-based control such as verbosity | A count flag. |
| Members required together | Paired options. |
| Independently selected members, optionally at most/exactly one | Selected options. |
| Nested named settings | Accessor options with dotted leaf paths. |
| A file/folder path or explicit-scheme hosted URL | The matching typed option or positional, if its lexical rules fit the application. |
| Forward raw tokens after `--` | Trailing arguments, optionally validated by a variadic declaration. |

Use declared conflicts for incompatible explicit occurrences. Business rules
outside Mamba's declaration relationships belong in application validation
before performing effects, not in a custom replacement parser.

## Executor: configuration and execution

`Executor` is the application's composition root. Pass its name, short
description, semantic version, and root commands in that order:

```dart
Future<void> main(List<String> args) => Executor(
  'acme',
  'Manage Acme deployments.',
  '1.0.0',
  [Deploy(), Workspace()],
).create().execute(args);
```

Construction validates the entire command tree, declarations, spelling
collisions, and default paths, not just the command that will eventually run.
Invalid configuration raises a registry error before execution. The version
must be Semantic Version 2.0.0-shaped, such as `1.0.0-rc.1`.

### Configure root behavior

| Parameter | Application responsibility |
| --- | --- |
| `flags`, `options`, `accessors` | Declare inputs available throughout the command tree. |
| `defaultCommandPath` | Select a relative command path when no root child is named. |
| `context` | Supply retained scalar hook state; it is not a dependency container. |
| `helpFormatter` | Replace help rendering; see [Help customization](#help-customization). |
| `longDescription` | Supply detailed root help text. |

Retain root input declarations outside the executor call so commands can read
the same handles:

```dart
final profile = StringOption.withDefault(
  'profile',
  defaultValue: 'development',
);

Future<void> main(List<String> args) => Executor(
  'acme',
  'Manage Acme deployments.',
  '1.0.0',
  [DeployCommand()],
  options: [profile],
  flags: [MambaPreparedFlags.dryRun],
).create().execute(args);
```

Help (`-h`, `--help`) and version (`-v`, `--version`) are intrinsic controls;
they need no registration and reserve those spellings. No ordinary flags are
registered by default. Register `MambaPreparedFlags.verbose` (`-V`, `--verbose`)
or `.dryRun` explicitly when the application implements their effects.
[Flags](references/flags.md) defines their scope and read behavior.

### Follow an invocation

1. Resolve the named command path and applicable defaults. Invocation tokens
   exclude the application name. Aliases select canonical command paths.
2. Parse and validate the selected command's inputs, producing an
   invocation-bound `ValueOf` reader and a separate immutable trailing list.
   Parse failures prevent hooks and command behavior.
3. Handle help/version as framework output without running hooks, reading
   command stdin, or requiring ordinary mandatory inputs. Help describes the
   explicitly requested scope, not its implicit default child.
4. Run persistent pre-hooks from outer group inward, then the selected
   command's pre-hook (including processed stdin), `run`, ordinary post-hook,
   and concurrent persistent post-hooks, subject to success of earlier phases.
   Read [Hooks](references/hook-runners.md) for failure and concurrency rules.
5. Return a structured result through `fake()`, or deliver it to the process
   through `create()`.

With no selected command or root default, execution renders root help. A
selected group uses its own `defaultSubCommandPath` if configured; otherwise
its default `run` renders group help. Default paths are relative to their
scope, may chain through groups' defaults, and must resolve to an executable
command. A root without a default does not implicitly select a group's default.

### Distinguish the adapters

Both adapters use the same parsing, hooks, and command execution:

| Adapter | Delivery boundary |
| --- | --- |
| `create()` | Reads piped stdin for a selected command pre-hook; writes non-null output unchanged to stdout; writes failure diagnostics to stderr in Chalk red when color is enabled; assigns the failure exit code. Success leaves the existing process exit code untouched. It does not terminate the process. |
| `fake(standardInput: ...)` | Supplies the provided processed stdin (otherwise null) and returns `MambaSuccessResult` or `MambaFailureResult` without Mamba reading process stdin, writing process streams, or setting the process exit code. |

`run` may return `String?` synchronously or asynchronously. Return null for
silence, a string for successful output, and throw `MambaException` for a
user-facing failure, optionally with a nonzero `exitCode`. Returning an error
message as a string is still success. Other `Exception`s become failures with
status 1; Dart `Error`s escape instead of becoming result variants.

Failure metadata records one exception, its original stack trace, execution
phase, and canonical path including the application name. If `run` succeeded
before a post-hook failed, its output is retained and production still delivers
it. Post-hooks are success-only behavior; application-owned `try`/`finally`
handles mandatory cleanup. See [Testing](references/testing.md) for assertions.

### Own dependencies and shared state

Inject domain services, file/network clients, configuration loaders, and
prompt services through application-owned constructors or callbacks. Mamba
constructs neither your services nor a dependency-injection container. It
resolves argv declarations and defaults, not environment variables, config
files, or precedence between those sources.

`fake()` detaches Mamba's delivery boundary only: commands and hooks still
perform their own file, network, prompt, progress, and other effects. Supply
application fakes for those dependencies when isolation is needed; see the
[dependency-injection example](#inject-an-application-operation).

One configured executor's adapters share retained context and command
instances across calls. Overlapping and reentrant invocations are allowed;
they are not automatically isolated or serialized. Command instances may also
be shared across executors and tree placements, sharing mutable fields and
framework-injected metadata. A shared completion command's registry can be
replaced by another configuration; group help is assigned for its selected
placement. Prefer fresh commands and contexts in separate configurations when
isolation is required.

Context stores only String, bool, int, and double values under retained typed
keys, not domain objects. Persistent pre-hooks can write it; ordinary hooks
and persistent post-hooks receive a read-only view. See
[Hooks](references/hook-runners.md) for the key/value API.

### Retain configuration safely

Supplied configuration lists are retained, not copied: commands, aliases,
inputs, choices, defaults, accessor/group members, suffixes, and default paths.
Prefer const lists and do not mutate configuration after registration; later
mutations are not automatically revalidated. A const-capable constructor used
without `const` can still retain a mutable list. Parsed collections and
generated registry snapshots remain immutable; configured defaults are frozen
when producing parsed values, not when declaring inputs.

## Commands and groups

Use `Command` for an executable action and `GroupCommand` for a named branch.
Start a command in its own file; keep related child commands with their group.
Declare each input once and register it through `super`:

```dart
final class Deploy extends Command {
  new() : super(mandatoryPositionals: [_environment], flags: [_force]);

  static final _environment = NormalPositional('environment');
  static final _force = BooleanFlag(
    'force',
    short: 'f',
    description: 'Replace the current deployment.',
  );

  @override
  String get name => 'deploy';

  @override
  String get shortDescription => 'Deploy the application.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final environment = valueOf(_environment);
    final force = valueOf(_force);
    return 'Deploying to $environment (force: $force).';
  }
}
```

A `ValueOf` reader belongs to one invocation. Optional handles read nullable
values; required/defaulted handles read non-null values. An unregistered
handle raises `StateError`; recreating a declaration with the same name does
not recreate its identity. There is no string lookup or `contains` API.

Register required positionals in `mandatoryPositionals`, optional/defaulted
ones in `discretionaryPositionals`, switches in `flags`, named values in
`options`, relationships in `pairedOptions`/`selectedOptions`, and dotted trees
in `accessors`. `args` contains only tokens after the first `--`; extra ordinary
tokens before it are rejected, not collected as variadics.

A group receives children as the first `super` argument:

```dart
final class Workspace extends GroupCommand {
  new() : super([Deploy()]);

  @override
  String get name => 'workspace';

  @override
  String get shortDescription => 'Manage workspaces.';
}
```

Group-local inputs apply only when that group is selected. Use
`propagatedFlags` and `propagatedOptions` for the group and its descendants;
token placement before a child does not propagate a local input. Compatible
local overrides preserve ancestor handle reads. Positionals are ordered input,
not inherited child arguments. See [Options](references/options.md) for
scope, accessor, override, and conflict rules.

Names and aliases use letter-led alphanumeric segments separated by single
hyphens or underscores; sibling spellings must be unambiguous. Use `aliases`
and `longDescription` for alternate command tokens and detailed help. The
executor initializes `GroupCommand.help`; calling `run` or `callChildRun`
directly bypasses parsing and the executor lifecycle, so exercise application
behavior through the executor.

## Inject an application operation

Pass a service or a focused callback into a command instead of constructing
clients inside `run`. This command depends on one publishing operation:

```dart
final class ReleaseCommand(final Future<String> Function(String) _publish)
    extends Command {
  this : super(mandatoryPositionals: [_environment]);

  static final _environment = NormalPositional(
    'environment',
    regex: RegExp(r'.+'),
  );

  @override
  String get name => 'release';

  @override
  String get shortDescription => 'Publish a release to an environment.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) {
    final environment = valueOf(_environment);
    return _publish(environment);
  }
}
```

At the production entry point, bind the existing application service's method.
`ReleaseService` represents application-owned code, not a Mamba type:

```dart
Future<void> main(List<String> args) {
  final releases = ReleaseService();
  return Executor(
    'acme',
    'Manage Acme deployments.',
    '1.0.0',
    [ReleaseCommand(releases.publish)],
  ).create().execute(args);
}
```

In tests, replace that operation and assert both the effect request and the
complete result. Import the command, `package:mamba/mamba.dart`,
`package:mamba/executor.dart`, and `package:test/test.dart`; put this case
inside the `acme` → `release` test groups:

```dart
test('publishes through the injected operation', () async {
  final published = <String>[];
  final command = ReleaseCommand((environment) async {
    published.add(environment);
    return 'Published to $environment.';
  });
  final result = await Executor(
    'acme',
    'Manage Acme deployments.',
    '1.0.0',
    [command],
  ).fake().execute(['release', 'staging']);

  expect(published, ['staging']);
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', 'Published to staging.'),
  );
});
```

The injected operation controls publishing; `fake()` only changes Mamba's
process delivery. Also verify that parse rejection and help requests never
call the operation, and that its domain failures surface as command failures;
see [Testing](references/testing.md).

## Prompt components

Prompt components collect interactive input or report progress. Mamba creates
reusable components with async `render()` methods; their answers remain
application-owned values, separate from parsed argv. Read
[Prompt components](references/prompt-components.md) for the generated component
contracts, additional prompt types, and interaction boundaries.

## Help customization

A `HelpFormatter` turns the selected command registry into complete help text.
`Executor.helpFormatter` installs the application's renderer in place of the
default `MambaHelpFormatter`. A custom formatter owns presentation mechanics
while preserving the CLI's meaning. Read
[Help formatter inspection](references/help-formatter.md) before inspecting,
changing, or reviewing help rendering and its design philosophy.

## Before finishing

A task is complete when the affected behavior is wired, exercised, and checked:

- New commands are registered at the intended root or parent path; aliases
  and defaults still resolve to the intended command.
- Every input read uses a retained handle registered at its intended scope;
  local inputs have not accidentally been treated as propagated inputs.
- Affected success and rejection paths have meaningful tests following
  [Testing](references/testing.md), including complete results and observable
  calls to injected dependencies. Check rules before effects, not just output.
- Changed help remains truthful at the affected root/group/leaf scopes,
  including inherited inputs and intrinsic controls; use
  [Help formatter inspection](references/help-formatter.md) for rendering changes.
- Affected completion artifacts are regenerated using the application's
  generation workflow when declarations change; inspect the relevant results.
- The repository's relevant formatting, analysis, and test checks pass. Report
  unavailable checks or unrelated failures explicitly rather than claiming an
  unverified pass.

## Task references

- Read [Arguments](references/arguments.md) for mandatory/discretionary inputs,
  typed file/folder/URL positionals, bounded repetition, or tokens after `--`.
- Read [Flags](references/flags.md) for boolean switches, counts, prepared flags,
  and intrinsic help/version controls.
- Read [Options](references/options.md) for scalar, repeatable, path/URL,
  prepared, paired, selected, or dotted accessor values and conflicts.
- Read [Completions](references/completion-commands.md) to register completion
  generation or work with advanced converter/registry metadata.
- Read [Hooks](references/hook-runners.md) for lifecycle behavior, processed
  stdin, context, concurrent post-hooks, and failure boundaries.
- Read [Help formatter inspection](references/help-formatter.md) to inspect or
  customize help presentation, check inherited rendering mechanics, or review
  theme and semantic styling.
- Read [Prompt components](references/prompt-components.md) when using generated
  prompts, selectors, directory pickers, or progress indicators, or choosing
  additional interactive input components.
- Read [Testing](references/testing.md) before writing or changing command
  tests: command-tree groups, parameterized cases, input/hook coverage, and
  complete result assertions.
