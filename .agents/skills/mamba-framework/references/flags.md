# Flags

Use flags for named inputs that take no value. Register a flag in `flags` on a
`Command` or `GroupCommand` when it belongs to that command only.

```dart
final class DeployCommand extends Command {
  new() : super(flags: [force, verbosity]);

  static const force = BooleanFlag(
    'force',
    short: 'f',
    description: 'Replace the existing deployment.',
    negatable: true,
  );

  static const verbosity = CountFlag(
    'verbose',
    short: 'V',
    description: 'Increase output verbosity.',
  );

  @override
  String get name => 'deploy';

  @override
  String get shortDescription => 'Deploy the application.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final forceValue = valueOf(force);
    final verbosityValue = valueOf(verbosity);
    return 'force: $forceValue, verbosity: $verbosityValue';
  }
}
```

Retain each declaration and pass the same instance to
`valueOf`; declarations are identity-based typed keys.

## `BooleanFlag`

```dart
BooleanFlag(
  name,
  short: short,
  description: description,
  hidden: false,
  defaultValue: false,
  negatable: false,
);
```

A boolean flag returns `bool`. Its long spelling is `--name`; `short` adds a
one-character spelling such as `-f`. When omitted, it returns `defaultValue`.
The ordinary spelling sets it to `true`.

Set `negatable: true` to add `--no-name`, which sets the value to `false`.
Set `hidden: true` to omit it from generated help while keeping it parseable.

## `CountFlag`

```dart
CountFlag(
  name,
  short: short,
  description: description,
  hidden: false,
);
```

A count flag returns `int`. It starts at `0` and increments for each
occurrence, including repeated short aliases such as `-VV`.

## Registration scope

- `Command(flags: [...])` registers flags only for that command.
- `GroupCommand(..., flags: [...])` registers flags only for the group itself.
- `GroupCommand(..., propagatedFlags: [...])` makes flags available to the
  declaring group and every descendant. Compatible overrides preserve kind,
  output type, cardinality, and retained ancestor reads.
- `Executor(..., flags: [...])` makes flags available across the command tree.

Mamba provides these reusable declarations:

| Declaration | Spelling | Value |
| --- | --- | --- |
| `MambaPreparedFlags.dryRun` | `--dry-run` | `bool` |
| `MambaPreparedFlags.verbose` | `--verbose`, `-V` | `int` |

The executor registers no ordinary flags by default. Register
`MambaPreparedFlags.verbose` or `.dryRun` through `Executor.flags` when the
application supports verbosity or dry-run behavior, respectively. Register
them on a command or as propagated group flags when narrower scope is needed.
Always register the declaration before reading it through `valueOf`.

Help (`--help`, `-h`) and version (`--version`, `-v`) are intrinsic parser
controls, not declarations. Read `ParsedArguments.help` and `.version` rather
than `valueOf`. Every parser accepts them without registration, including in
short bundles. The registry rejects declarations claiming their long names or
short aliases. `Parser.isHelp`, `.isVersion`, and `.isControl` identify their
tokens; `Parser.controlFlags` supplies metadata for help and completions.
Registry records describe ordinary declared inputs only. Normal commands need
no help/version handle or manual control check: the executor handles these
paths before running commands and hooks. Use the dedicated
`package:mamba/parser.dart` import only when working directly with parser
results or control metadata for custom help/completions.

## Conflicts and presence

Flags may participate in a command's `conflicts` map by long name:

```dart
new()
  : super(
      flags: [force],
      options: [plan],
      conflicts: {
        'force': ['plan'],
      },
    );
```

`valueOf(flag)` always returns the resolved flag value: `false`, the configured
boolean default, or `0` when omitted. That value does not distinguish omission
from an explicit spelling producing the same value. Use `Command.conflicts`
for explicit-occurrence relationships; occurrence tracking remains internal.
