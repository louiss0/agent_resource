# Arguments

Use positionals for unnamed command input before `--`. Tokens after the first
`--` are trailing arguments, optionally validated by a variadic declaration;
they never satisfy positional declarations.

## Register arguments

Register positionals on `Command` or `GroupCommand` in list order:

```dart
final source = NormalPositional('source');
final destination = NormalPositional.optional('destination');

final class CopyCommand extends Command {
  new()
    : super(
        mandatoryPositionals: [source],
        discretionaryPositionals: [destination],
      );

  @override
  String get name => 'copy';

  @override
  String get shortDescription => 'Copy a file.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final sourceValue = valueOf(source);
    final destinationValue = valueOf(destination);
    return 'Copy $sourceValue to ${destinationValue ?? 'the default path'}';
  }
}
```

`mandatoryPositionals` accepts `MandatoryPositional` declarations.
`discretionaryPositionals` accepts optional or defaulted
`DiscretionaryPositional` declarations. Retain each declaration and pass the
same instance to `valueOf`; declarations are identity-based typed
keys.

Register at most one `Variadic` with the `variadic` parameter. Its validated
strings are passed to `run` through `args`, not through `valueOf`.

## Positional API

All positionals accept `name` and optional `description`. Normal string
positionals accept every supplied String by default, including empty/whitespace
content. An explicit `regex` checks the complete assigned value.

| Declaration | Registration | Parsed type |
| --- | --- | --- |
| `NormalPositional(name)` | mandatory | `String` |
| `NormalPositional.optional(name)` | discretionary | `String?` |
| `ChoicePositional(name, choices: values)` | mandatory | enum `T` |
| `ChoicePositional.optional(name, choices: values)` | discretionary | `T?` |
| `ChoicePositional.withDefault(...)` | discretionary | enum `T` |
| `RepeatedStringPositional(name)` | mandatory | `List<String>` |
| `RepeatedStringPositional.optional(name)` | discretionary | `List<String>?` |
| `RepeatedChoicePositional(name, choices: values)` | mandatory | `List<T>` |
| `RepeatedChoicePositional.optional(...)` | discretionary | `List<T>?` |
| `RepeatedChoicePositional.withDefault(...)` | discretionary | `List<T>` |

Choice declarations return enum members. Ordinary enums use `.name`; enums
implementing `MambaEnumValue` use their exact String `value`, without implicit
name aliases. Offered spellings/entries must be unique:

```dart
enum OutputFormat { text, json }

final format = ChoicePositional.withDefault(
  'format',
  choices: OutputFormat.values,
  defaultValue: OutputFormat.text,
);
```

Repeated string positionals accept `regex`. Repeated choice positionals accept
`choices`; their default is a `List<T>`. Both accept `max`, which defaults to
`1` and is the maximum number of values that declaration consumes. `max`
must be positive. A mandatory repeated positional must still consume at
least one value.

Repeated positionals allocate up to `max` in registration order while
reserving one token for each following mandatory positional. Validators check
the assigned values without backtracking. Parsed lists are immutable, including
accepted empty defaults. Supplied choice/default lists are retained, not copied;
do not mutate them after registration. Explicit values replace default lists.
Cardinality and configured defaults are validated at registration, not necessarily
at declaration construction.

```dart
final sources = RepeatedStringPositional(
  'source',
  regex: RegExp(r'.+\.dart'),
  max: 3,
);

final formats = RepeatedChoicePositional.optional(
  'format',
  choices: OutputFormat.values,
  max: 2,
);

final class BuildCommand extends Command {
  new()
    : super(
        mandatoryPositionals: [sources],
        discretionaryPositionals: [formats],
      );

  @override
  String get name => 'build';

  @override
  String get shortDescription => 'Build Dart sources.';

  @override
  String run(ValueOf valueOf, List<String> args) =>
      valueOf(sources).join(',');
}
```

## Variadic API

`NormalVariadic` validates every token after the first `--`. It accepts an
optional `description` and `regex`. Without an explicit validator every supplied
trailing String is accepted. The trailing list is separate from positionals.

```dart
final class ForwardCommand extends Command {
  new()
    : super(variadic: NormalVariadic(regex: RegExp(r'.+')));

  @override
  String get name => 'forward';

  @override
  String get shortDescription => 'Forward trailing arguments.';

  @override
  String run(ValueOf valueOf, List<String> args) => args.join(' ');
}
```

`ChoiceVariadic<T>` accepts `choices` and an optional `description`, not a
`defaultValue`. It validates at most one trailing choice spelling (the member's
name, or its exact `MambaEnumValue.value` when implemented). When omitted, it
adds nothing to `args`. `run` receives the original string rather than the
enum member:

```dart
ChoiceVariadic<OutputFormat>(
  choices: OutputFormat.values,
);
```

Without a registered variadic, Mamba passes tokens after `--` to `run`
unchanged and does not validate them.

## Optional value reads

Call `valueOf(declaration)` directly. An omitted optional positional returns
null; a defaulted positional returns its parsed or fallback value. Variadics
are read from `args`, not from declaration handles.

## Typed file, folder, and URL positionals

Use these when the positional represents a typed filesystem path or hosted URL,
not arbitrary text. [Path and URL validation](options.md#path-and-url-validation)
defines their shared lexical rules, preservation, and security boundaries.

| Family | Constructor or `.required` (mandatory) | `.optional` (discretionary) | `.withDefault` (discretionary) |
| --- | --- | --- | --- |
| `FilePathPositional` | `String` | `String?` | `String` |
| `FolderPathPositional` | `String` | `String?` | `String` |
| `UrlPositional` | `UrlValue` | `UrlValue?` | `UrlValue` |
| `RepeatedFilePathPositional` | `List<String>` | `List<String>?` | `List<String>` |
| `RepeatedFolderPathPositional` | `List<String>` | `List<String>?` | `List<String>` |
| `RepeatedUrlPositional` | `List<UrlValue>` | `List<UrlValue>?` | `List<UrlValue>` |

All accept `name` and `description`. Defaulted forms require `defaultValue`:
strings for paths, validated `UrlValue.parse(...)` values for URLs, or lists of
those values for repeated forms. Unlike named options, the direct positional
constructors are required, not optional. These typed declarations do not expose
a custom `regex` parameter; choose a string positional with `regex` when its
content is not a Mamba file/folder/URL.

Repeated forms follow the same finite allocation/reservation rules as other
repeated positionals. `max` defaults to 1 and must be positive. Required
forms consume at least one value; default lists may be empty but must fit the
maximum. Explicit values replace defaults. `unique: true` rejects identical
original strings, not normalized paths or equivalent URI spellings. Parsed
lists remain immutable.

Every file form accepts `suffixes`, including repeated/optional/defaulted
forms. These filter Carapace suggestions only, not accepted values or defaults;
see [File suffix hints](options.md#file-suffix-hints).

```dart
final class UploadCommand extends Command {
  new()
    : super(
        mandatoryPositionals: [_sources, _destination],
        discretionaryPositionals: [_folder],
      );

  static const _sources = RepeatedFilePathPositional(
    'source',
    max: 3,
    unique: true,
    suffixes: ['.json'],
  );
  static const _destination = UrlPositional('destination');
  static final _folder = FolderPathPositional.withDefault(
    'folder',
    defaultValue: './cache/',
  );

  @override
  String get name => 'upload';

  @override
  String get shortDescription => 'Upload files to a hosted destination.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final sources = valueOf(_sources);
    final destination = valueOf(_destination);
    final folder = valueOf(_folder);
    return '${sources.join(',')} -> ${destination.uri.host} ($folder)';
  }
}
```

For `upload one.json two.txt https://example.com/upload`, the repeated source
reserves the final mandatory destination token. `two.txt` is accepted despite
the `.json` completion hint. The folder defaults to `./cache/`; the URL remains
a typed value, and the example displays only its host. To supply the optional
folder in this layout, first fill all three source slots: repeated allocation
reserves mandatory suffixes, not discretionary ones, and never backtracks on
a validation failure. Prefer a named folder option if users need an unambiguous
optional destination with fewer sources. Values after `--` remain separate
trailing arguments, not additional source files.
