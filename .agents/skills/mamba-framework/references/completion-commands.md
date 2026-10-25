# Completion commands

Use a `CompletionCommand` to turn Mamba's validated command registry into a
completion artifact for Bash, Zsh, Fish, PowerShell, or Carapace. The registry
contains the command tree and its flags, options, positionals, aliases, and
descriptions, so completion generation stays aligned with parsing and help.

## Use the preset command

Register `CompletionCommand.preset(createFile: null)` in the executor's
command list to use Mamba's built-in generators:

```dart
Future<void> main(List<String> args) => Executor(
  'my-cli',
  'Manage application resources.',
  '1.0.0',
  [CompletionCommand.preset(createFile: null)],
).create().execute(args);
```

The preset creates a `completion` command with `cmp` and `cpt` aliases. It
accepts a required shell positional followed by an optional output path:

```console
my-cli completion bash ./my-cli.bash
my-cli completion powershell ./my-cli.ps1
my-cli completion carapace ./my-cli.yaml
```

When a path is present, its extension must match the selected shell and its
file name must contain the application name:

| Shell | Extension |
| --- | --- |
| `bash` | `.bash` |
| `zsh` | `.zsh` |
| `fish` | `.fish` |
| `powershell` | `.ps1` |
| `carapace` | `.yaml` |

`CompletionCommand.shellInput` and `CompletionCommand.pathInput` expose the
same retained declarations used by the preset. Use them with
`valueOf` when extending or testing the command.

## Replace destination handling

Pass a callback through the required named `createFile` parameter when another
system should handle the validated destination:

```dart
final completion = CompletionCommand.preset(
  createFile: (path, contents) => print('Write ${contents.length} bytes to $path'),
);
```

The command always generates the script and hands the callback both the
validated `path` and the generated `contents`; the callback owns the write.
`path` is an empty string when the optional path positional was omitted, and
the default writer rejects that case rather than inventing a destination.
Extend `CompletionCommand` when custom handling also needs access to the
registry. Its shell and path declarations remain intrinsic to the command.

## Typed path and URL completions

Carapace uses declaration metadata for both options and positionals:

| `valueType` | Dynamic action |
| --- | --- |
| `file` | `$files`, or `$files([.json, .tar.gz])` for declared suffixes. |
| `folder` | `$directories`. |
| `url` | `$carapace.net.http.Urls`. |

A file's `suffixes` list is a completion filter, not parse validation. The
bracketed array in the filtered `$files` action is required. Directory
navigation candidates need not be complete file inputs. URL discovery is an
HTTP host/port editing aid, not full discovery or validation for every accepted
hosted scheme; raw URL defaults are not exposed as completion candidates.
These dynamic producers are Carapace-specific: native Bash/Zsh/Fish/PowerShell
generators do not gain them. Generated metadata and parser acceptance are not
a promise that every shell will offer every accepted value.

Manually persistent options receive these actions too; a local option with the
same spelling takes precedence. Register declarations and regenerate the
artifact instead of hand-maintaining its path/URL actions.

## Build a custom completion command

Read this section and the record details below only for custom generation or
integration work; the preset command needs no direct parser/registry usage.

Import `package:mamba/integrations.dart` for direct converters and
`package:mamba/registry.dart` to name record types. The main barrel exports
`CompletionCommand`, not those advanced APIs. Records contain declared inputs;
completion converters add help/version controls from `Parser.controlFlags`.

The executor assigns `registryRecord` before execution. Select the converter
for the requested output and call `convert()`:

```dart
final content = switch (shell) {
  ShellCompletion.bash =>
    ToBashCompletionConverter(registryRecord).convert(),
  ShellCompletion.zsh => ToZshCompletionConverter(registryRecord).convert(),
  ShellCompletion.fish =>
    ToFishCompletionConverter(registryRecord).convert(),
  ShellCompletion.powershell =>
    ToPowerShellCompletionConverter(registryRecord).convert(),
  ShellCompletion.carapace => CarapaceSpecConverter(registryRecord).convert(),
};
```

## Inspect the registry record

Treat `registryRecord` as an immutable typed description, not a map. The root
is a `RegistryRecord`; its `commands` recursively contain `RegistryCommand`
objects. Nullable collections mean that the command has no entries of that
kind, so traverse them with `?? const []`.

### `RegistryCommand`

A `RegistryCommand` is one command-tree node. Use:

- `name` for its canonical command token and `aliases` for equivalent tokens;
- `description` for its combined short and optional long help text;
- `commands` for direct children;
- `positionals` and `variadic` for ordered and post-`--` values;
- `flags`, `options`, `optionGroups`, and `accessors` for its named inputs; and
- `persistentFlags` and `persistentOptions` for inputs that converters should
  carry into descendants.

Build the command path while recursing through `commands`. Records produced by
`CommandRegistry.toRecord()` already place effective inherited inputs in each
command's `flags`, `options`, and `accessors`; their `persistentFlags` and
`persistentOptions` are left `null`, so a manually built record is the only way
to state them. `optionGroups` carries both kinds of group: a paired set and a
selected set, so a selected group no longer arrives as members that merely
look independent.

### `RegistryPositional`

List order determines the parse position. `name` and `description` provide
display text, while `required` distinguishes mandatory from discretionary
values. Offer `choices` directly when present. `defaultValue` is textual,
`pattern` contains the whole-token validation expression, including path
patterns. `repeatable == true` pairs with `max` for the positive finite
maximum, not an exact count. `valueType` identifies the string/choice/file/
folder/URL kind, `suffixes` carries file-completion filters, and `unique` marks
exact-text duplicate rejection for repeated typed paths/URLs. URL defaults
are redacted display text, not raw values.

### `RegistryFlag`

`name` and `short` omit their leading dashes. `defaultValue` and `negatable`
describe boolean flags; both are `null` for flag kinds without boolean
semantics. A negatable flag also has a `--no-<name>` spelling. Suppress an
entry when `hidden` is true and use `description` as candidate help text.

### `RegistryOption`

Use `name`, `short`, `hidden`, and `description` for spelling and display.
`required`, `repeatable`, and `unique` describe cardinality. Interpret
`valueType` as `string`, `int`, `double`, `choice`, `file`, `folder`, `path`,
or `url`, then use the applicable validation metadata. Prefer the exported
file/folder families for application paths; generic `path` is advanced metadata:

- offer `choices` as finite candidates;
- treat `defaultValue` as display text, including comma-separated list defaults
  and redacted URLs, not a lossless value serialization;
- retain `pattern` for whole-token string/path validation;
- use `min`, `max`, and `step` for bounded numeric candidates; and
- use `suffixes` only for file-completion filtering (empty means unfiltered
  files, null means another kind), with dynamic actions as described above.

`pairedOptions` names every member of the same all-or-nothing paired group.

### `RegistryOptionGroup`

`members` lists the option names in one `PairedOptions` or `SelectedOptions`
declaration. A paired group is all-or-nothing: supplying one member requires
all members, and `required` controls whether the whole group may be omitted. A
selected group requires at least one member when `required` is true, and
accepts at most one when `single` is true. All members also appear in `options`.
In registry-produced records, a member's `pairedOptions` is empty for a
selected group and lists the partners for a paired group. Infer the group
kind from that metadata; `single: false` alone does not distinguish them.
The current converters preserve these relationships in the record but do not
enforce group selection or exclusivity in shell completions.

### `RegistryAccessor`

Switch on `kind` before reading variant fields:

- A `group` has `name`, `hidden`, `description`, and recursive `options`.
- A `value` has `name`, `valueType`, `description`, `choices`, `defaultValue`,
  and `pattern`.

Join ancestor and leaf names with `.` to form the long spelling. For example,
the `certificate` value below `server` and `tls` becomes
`--server.tls.certificate`. A hidden group hides its descendant leaves.

The unnamed `CompletionCommand` constructor accepts destination handling,
long description, and aliases, not custom positionals or options. Read its
retained `shellInput` and `pathInput` handles in an override. Access
`registryRecord` during `run`, after the executor initializes the command tree.
