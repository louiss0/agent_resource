# Options

Use options for named inputs that take values. Mamba has four command
registration lists:

| `Command` parameter | Register |
| --- | --- |
| `options` | scalar and repeatable options |
| `pairedOptions` | all-or-nothing groups |
| `selectedOptions` | independently selectable groups |
| `accessors` | dotted option trees |

Retain and read the registered declaration, not a new declaration with the same
name. Scalar/repeatable families use the direct constructor for an optional
handle, `.required` for a non-null required handle, and `.withDefault` for a
non-null fallback. Long values accept `--name value` or `--name=value`; short
values accept `-n value` or `-n=value`. Hidden inputs remain parseable.

## Scalar options

| Family | Optional type | Required type | Defaulted type |
| --- | --- | --- | --- |
| `StringOption` | `String?` | `String` | `String` |
| `IntOption` | `int?` | `int` | `int` |
| `DoubleOption` | `double?` | `double` | `double` |
| `ChoiceOption<T>` | `T?` | `T` | `T` |

All scalar forms accept `name`, `short`, `description`, and `hidden`.
`StringOption` accepts every supplied String by default; an explicit `regex`
checks whole content. Separate option-looking string values require inline
supply. Shorts support `-o=value` and flag-prefix `-Vo=value` when `V` and `o`
are explicitly registered, not `-ofile` or `-Vo value`.
Integer options accept `range: (min: 1, max: 10)` with nullable integer bounds.
Double options use nullable double bounds in the same record and accept `step`.
Omit `range` for no bounds; use `range: (min: 0, max: null)` for a lower bound
only. Both bounds are inclusive. Bounds/defaults must be finite and meaningful;
a step must be positive and requires both ordered bounds, anchored at `range.min`.
Numeric bounds constrain values; positional `max` separately limits token count.
Choice options accept enum `choices`; defaulted choices require an offered
member. Ordinary enums use `.name`; `MambaEnumValue` implementations use their
exact String `value` without implicit name aliases. Offered entries and spellings
must be unique. See [Arguments](arguments.md#positional-api) for choice rules.

```dart
enum OutputFormat { text, json }

final output = StringOption.required(
  'output',
  short: 'o',
  regex: RegExp(r'.+'),
);
final retries = IntOption.withDefault(
  'retries',
  defaultValue: 3,
  range: (min: 0, max: 10),
);
final threshold = DoubleOption(
  'threshold',
  range: (min: 0, max: 1),
  step: 0.1,
);
final format = ChoiceOption.withDefault(
  'format',
  choices: OutputFormat.values,
  defaultValue: OutputFormat.text,
);

final class BuildCommand extends Command {
  new() : super(options: [output, retries, threshold, format]);

  @override
  String get name => 'build';

  @override
  String get shortDescription => 'Build an output.';

  @override
  String run(ValueOf valueOf, List<String> args) =>
      '${valueOf(output)}/${valueOf(retries)}/${valueOf(format).name}';
}
```

## Repeatable options

Register repeatable declarations in `options`. Each occurrence appends a value
to an immutable ordered list.

| Family | Optional type | Required type | Defaulted type |
| --- | --- | --- | --- |
| `RepeatableStringOption` | `List<String>?` | `List<String>` | `List<String>` |
| `RepeatableIntOption` | `List<int>?` | `List<int>` | `List<int>` |
| `RepeatableDoubleOption` | `List<double>?` | `List<double>` | `List<double>` |
| `RepeatableChoiceOption<T>` | `List<T>?` | `List<T>` | `List<T>` |

Use the direct constructor, `.required`, or `.withDefault` as with scalar
options. String, integer, and double validation parameters are the same as
their scalar equivalents. `RepeatableChoiceOption` takes `choices` as its
second positional argument and accepts `unique: true` to reject duplicate
members.

```dart
final labels = RepeatableStringOption('label');
final ports = RepeatableIntOption.required(
  'port',
  range: (min: 1, max: 65535),
);
final formats = RepeatableChoiceOption.withDefault(
  'format',
  OutputFormat.values,
  defaultValue: [OutputFormat.text],
  unique: true,
);

final class ServeCommand extends Command {
  new() : super(options: [labels, ports, formats]);

  @override
  String get name => 'serve';

  @override
  String get shortDescription => 'Serve on selected ports.';

  @override
  String run(ValueOf valueOf, List<String> args) =>
      valueOf(ports).join(',');
}
```

## Paired options

Use `PairedOptions<T>` when supplying any member must require every member.
Register the group in `pairedOptions`, then read the group declaration as an
immutable `Map<String, T>` keyed by member name.

The direct constructor makes the entire group optional. The `.required`
constructor requires the complete group.

```dart
final credentials = PairedOptions<String>.required(
  [
    PairStringOption('username'),
    PairStringOption('password'),
  ],
  description: 'Credentials for the remote service.',
);

final class LoginCommand extends Command {
  new() : super(pairedOptions: [credentials]);

  @override
  String get name => 'login';

  @override
  String get shortDescription => 'Log in.';

  @override
  String run(ValueOf valueOf, List<String> args) =>
      'Logged in as ${valueOf(credentials)['username']}';
}
```

Pair member APIs are:

- `PairStringOption`, with optional `regex`;
- `PairIntOption`, with optional `range`;
- `PairDoubleOption`, with optional `range` and `step`;
- `PairChoiceOption<T>`, with required enum `choices`;
- `RepeatablePairStringOption`, with optional `regex`;
- `RepeatablePairIntOption`, with optional `range`; and
- `RepeatablePairDoubleOption`, with optional `range` and `step`.

Every pair member accepts `name`, `short`, and `description`. Repeatable pair
members produce lists inside the group's map. Pair members are declarations
within the group; query the retained `PairedOptions` declaration with
`valueOf`.

## Selected options

Use `SelectedOptions<T>` when members may be supplied independently. It uses
the same `PairOption<T>` member APIs and produces an immutable
`Map<String, T>` containing the supplied members.

```dart
final output = SelectedOptions<String>.required(
  [
    PairStringOption('json'),
    PairStringOption('text'),
  ],
  description: 'Select an output destination.',
  single: true,
);

final class ExportCommand extends Command {
  new() : super(selectedOptions: [output]);

  @override
  String get name => 'export';

  @override
  String get shortDescription => 'Export to one destination.';

  @override
  String run(ValueOf valueOf, List<String> args) =>
      valueOf(output).keys.single;
}
```

The direct constructor allows zero or more members. `.required` requires at
least one. `single: true` permits at most one, so combining it with `.required`
requires exactly one.

## Accessor options

Use an `AccessorListOption` tree for dotted names. Register only the top-level
list in `accessors`; read that same top-level declaration as an immutable,
nested `Map<String, Object?>`.

```dart
final server = AccessorListOption(
  'server',
  [
    AccessorStringOption.required('host'),
    AccessorIntOption.withDefault('port', defaultValue: 443),
    AccessorListOption(
      'tls',
      [AccessorStringOption('certificate')],
    ),
  ],
  description: 'Server connection settings.',
);

final class ConnectCommand extends Command {
  new() : super(accessors: [server]);

  @override
  String get name => 'connect';

  @override
  String get shortDescription => 'Connect to a server.';

  @override
  String run(ValueOf valueOf, List<String> args) =>
      'Connected to ${valueOf(server)['host']}';
}
```

Accessor leaf families are `AccessorStringOption`, `AccessorIntOption`,
`AccessorDoubleOption`, and `AccessorChoiceOption<T>`. Each has a direct
optional constructor plus `.required` and `.withDefault` factories. String
leaves accept `regex`; choice leaves accept enum `choices`. Integer leaves
accept `range`; decimal leaves accept `range` and `step`, using scalar rules.
Read retained leaves for typed values; the container exposes a nested map.

Every accessor accepts `name` and `description`. `AccessorListOption` also
accepts `hidden`; hiding a group hides its descendant leaves from help while
preserving parsing. When overriding an inherited accessor tree, preserve every
ancestor container/leaf path with compatible types; local fields may extend it.

## Registration scope

- `Command(options: [...])` and `GroupCommand(..., options: [...])` register
  scalar or repeatable options locally.
- `GroupCommand(..., propagatedOptions: [...])` makes scalar or repeatable
  options available to the declaring group and every descendant. Compatible
  overrides preserve output type/cardinality and ancestor retained reads.
- `Executor(..., options: [...])` makes scalar or repeatable options global.
- Paired, selected, and accessor registrations belong to the command lists
  shown at the top of this page. Executor supports global accessors, but not
  paired or selected groups.

## Conflicts and presence

Use `Command.conflicts` to reject explicit CLI occurrences before `run`, not
defaulted values. Explicit negations count even when false. Applicable edges
inherit by declaration identity through compatible overrides; unavailable local
endpoints do not resurrect under unrelated matching names. Occurrence tracking
remains internal; `valueOf` reads resolved values.
Names may refer to flags, ordinary options, paired or selected members, or
accessor leaves. Positionals, variadics, and accessor group names are not valid
endpoints. Registration rejects a conflict with a required input because it
would make the other endpoint impossible to supply. Use application validation
for relationships outside Mamba's conflict/paired/selected vocabulary.
Use the full dotted name for an accessor leaf:

```dart
new()
  : super(
      flags: [local],
      accessors: [server],
      conflicts: {
        'local': ['server.tls.certificate'],
      },
    );
```

Call `valueOf(declaration)` directly: omitted optional scalar and repeatable
options return null. Defaulted options return their parsed or fallback values.
Explicit repeatable occurrences replace, rather than append to, defaults.
Paired groups, selected groups, and accessor containers always return a map;
an omitted optional group has an empty map, and omitted optional accessor leaves
return null through their handles and are absent from their containing maps.

## File, folder, and URL options

Register these in `options` locally, through `propagatedOptions` on a group, or
in the executor's global `options`. All accept `name`, `short`, `description`,
and `hidden`. Scalar forms use last-occurrence-wins behavior. Repeated forms
preserve occurrence order in immutable lists.

| Family | Optional constructor | `.required` | `.withDefault` |
| --- | --- | --- | --- |
| `FilePathOption` | `String?` | `String` | `String` |
| `FolderPathOption` | `String?` | `String` | `String` |
| `UrlOption` | `UrlValue?` | `UrlValue` | `UrlValue` |
| `RepeatableFilePathOption` | `List<String>?` | `List<String>` | `List<String>` |
| `RepeatableFolderPathOption` | `List<String>?` | `List<String>` | `List<String>` |
| `RepeatableUrlOption` | `List<UrlValue>?` | `List<UrlValue>` | `List<UrlValue>` |

Defaulted path forms take strings; URL defaults take validated
`UrlValue.parse(...)` values. Repeated defaults take lists of the corresponding
values; empty defaults are allowed. Explicit occurrences replace default lists.
`unique: true` on these repeatable families rejects exact original-text
duplicates, without case/path/URI normalization. These families supply their own
lexical validation metadata, not a user-provided `regex` parameter.

### Path and URL validation

- File paths require a final filename with a nonempty stem and extension:
  `report.txt` is accepted, `README` and `.env` are not. A dot in a directory
  name does not supply a file extension. Use `StringOption` with an appropriate
  regex if the application's accepted input differs from these rules.
- Folder paths require a trailing separator: `/` for POSIX, `/` or `\` for
  Windows. Paths retain exact text with no filesystem existence/access check,
  normalization, quote stripping, or home/environment expansion. Creating,
  opening, and checking paths are application responsibilities.
- Dialect inference is host-independent: a Windows drive prefix or leading
  backslash selects Windows; otherwise leading `/`, `./`, or `../` selects
  POSIX, then a backslash selects Windows, with POSIX as the fallback. Ordinary
  and extended drive/UNC filesystem paths are supported, not raw device
  namespaces. Do not assume a path was interpreted using the host OS.
- URLs require an explicit scheme and a nonempty ASCII DNS-style host or IP
  literal. Localhost, single-label hosts, punycode, and bracketed IPv6 work;
  any valid hosted scheme is allowed. Ports are 0–65535. Unicode outside the
  host is supported. Malformed escapes, raw whitespace/control characters,
  backslashes, scoped IPv6 zone IDs, and IPvFuture are rejected, not repaired.
- `UrlValue.parse(text)` validates without a network request. `.original`
  retains exact input and `.uri` exposes parsed components. Both may contain
  credentials or query secrets; handle them as sensitive. Automatic default
  displays and `toString()` use `[URL]`, not the original. This is redaction,
  not a usable request URL; explicitly access the value when performing work.

Defaults are checked at registration using the same validation metadata as
supplied values. Constraints apply to whole assigned tokens; declarations are
metadata, not validation callbacks. Quote paths/URLs as required by the shell:
Mamba receives tokens after shell splitting and expansion.

### File suffix hints

Every scalar/repeatable file form accepts a retained `suffixes` list.
An empty list offers all files. Each suffix must begin with a dot followed by
at least one character, with ASCII letters, digits, dots, underscores, plus,
or minus thereafter: `.json` and `.tar.gz`, not `json` or `go.mod`.
Invalid suffixes fail registration. Prefer const lists and do not mutate
configuration after registration.

Suffixes only filter completion suggestions: they do not reject manually
supplied values or defaults with another extension. Use explicit application
validation when extensions are a business requirement. See
[Completions](completion-commands.md#typed-path-and-url-completions) for dynamic
Carapace actions and native-shell limits.

```dart
final class PublishCommand extends Command {
  new() : super(options: [_source, _destination, _mirrors]);

  static final _source = FilePathOption.required(
    'source',
    suffixes: const ['.json'],
  );
  static final _destination = UrlOption.withDefault(
    'destination',
    defaultValue: UrlValue.parse('https://example.com/upload'),
  );
  static final _mirrors = RepeatableUrlOption('mirror', unique: true);

  @override
  String get name => 'publish';

  @override
  String get shortDescription => 'Publish a file to a hosted destination.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final source = valueOf(_source);
    final destination = valueOf(_destination);
    final mirrors = valueOf(_mirrors);
    return '$source -> ${destination.uri.host} (${mirrors?.length ?? 0} mirrors)';
  }
}
```

## Prepared options

`MambaPreparedOptions` supplies conventional optional declarations with no
automatic application effects:

| Factory | Spellings | Read type |
| --- | --- | --- |
| `.file(suffixes: ...)` | `--file`, `-f` | `String?` |
| `.folder()` | `--folder`, `-F` | `String?` |
| `.url()` | `--url`, `-u` | `UrlValue?` |

Each call creates a fresh identity. Retain its result, register it, and read
that same result; calling the factory again inside `run` is an unregistered
handle. Use the ordinary families for required/defaulted/repeated variants.

```dart
final class InspectCommand extends Command {
  new() : super(options: [_file, _folder, _url]);

  static final _file = MambaPreparedOptions.file(suffixes: const ['.json']);
  static final _folder = MambaPreparedOptions.folder();
  static final _url = MambaPreparedOptions.url();

  @override
  String get name => 'inspect';

  @override
  String get shortDescription => 'Inspect optional input locations.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final file = valueOf(_file);
    final folder = valueOf(_folder);
    final url = valueOf(_url);
    return '${file ?? '-'} | ${folder ?? '-'} | ${url?.uri.host ?? '-'}';
  }
}
```
