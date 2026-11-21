import 'package:mamba/mamba.dart';

import '../../lifecycle.dart' show LifecycleOutputFormat;
import '../services/lifecycle_state_service.dart' show LifecycleScope;
import 'authoring_inputs.dart';

/// The shared command-line vocabulary of the guided create commands.
///
/// The vocabulary is named native selections. There is no operation-document
/// option: a retired JSON request is refused with migration guidance instead
/// of being reinterpreted as a body or a request.
///
/// The declarations are the documented supported subset. A flag that the
/// selected profile does not support is refused by the shared input parser,
/// which names the supported fields of that profile.
final class GuidedCreateFields {
  const GuidedCreateFields._();

  /// The native profile of the created resource.
  ///
  /// The profile is never inferred from a file name or a Markdown extension.
  static final profile = ChoiceOption(
    'profile',
    choices: AuthoringProfile.values,
    description:
        'The native profile of the created resource; it is never inferred.',
  );

  /// The harness spelling of the native profile.
  ///
  /// It selects the same profile as `--profile` so scripts can name the
  /// consuming harness directly. The two selections are mutually exclusive.
  static final harness = ChoiceOption(
    'harness',
    choices: AuthoringProfile.values,
    description: 'The harness whose native profile is authored.',
  );

  /// The scope of the created output.
  static final scope = ChoiceOption(
    'scope',
    choices: const [LifecycleScope.project, LifecycleScope.user],
    description:
        'The scope of the created output; project is the guided default.',
  );

  /// The output format.
  ///
  /// A machine-readable output never prompts and never writes to the output
  /// stream outside the report.
  static final format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
    description: 'The output format. A JSON output never prompts.',
  );

  static final cwd = FolderPathOption('cwd');
  static final projectRoot = FolderPathOption('project-root');
  static final home = FolderPathOption('home');
  static final claudeConfigDir = FolderPathOption('claude-config-dir');
  static final codexHome = FolderPathOption('codex-home');
  static final piAgentDir = FolderPathOption('pi-agent-dir');
  static final geminiDir = FolderPathOption('gemini-dir');
  static final stateDir = FolderPathOption('state-dir');

  /// The instruction body read from a file.
  static final bodyFile = FilePathOption(
    'body-file',
    description: 'Read the instruction body from this file.',
  );

  /// The instruction body read from standard input.
  static final bodyStdin = BooleanFlag(
    'body-stdin',
    description: 'Read the instruction body from standard input.',
  );

  /// The instruction body supplied as literal text.
  static final bodyText = StringOption(
    'body-text',
    description:
        'The instruction body as literal text. It stays in the shell '
        'history and in the process list.',
  );

  static final name = StringOption(
    'name',
    description: 'The native name of the created resource.',
  );
  static final description = StringOption(
    'description',
    description: 'The native description of the created resource.',
  );
  static final model = StringOption(
    'model',
    description: 'The provider qualified model of the created Agent.',
  );
  static final tools = RepeatableStringOption(
    'tools',
    description:
        'The complete tool list of the created Agent. A supplied list '
        'replaces the field; an omitted list preserves the source value.',
  );
  static const mainAgent = BooleanFlag(
    'main-agent',
    description:
        'Declare the Antigravity Agent as a main agent. Runtime dispatch '
        'is not verified.',
  );
  static final allowedTools = RepeatableStringOption(
    'allowed-tools',
    description:
        'The complete allowed tool list of the created Skill. A supplied '
        'list replaces the field.',
  );
  static final disallowedTools = RepeatableStringOption(
    'disallowed-tools',
    description:
        'The complete denied tool list of the created Skill. A supplied '
        'list replaces the field.',
  );
  static final metadata = RepeatableStringOption(
    'metadata',
    description:
        'One metadata entry of the created Skill as name=value. The whole '
        'metadata table is replaced by the supplied entries.',
  );
  static final skills = RepeatableStringOption(
    'skills',
    description:
        'The complete referenced skill list of the created resource. The '
        'codex Agent profile declares skills as a native table and refuses '
        'this selection.',
  );
  static final argumentHint = StringOption(
    'argument-hint',
    description: 'The argument hint of the created resource.',
  );
  static final license = StringOption(
    'license',
    description: 'The declared license of the created resource.',
  );
  static final compatibility = StringOption(
    'compatibility',
    description: 'The declared harness compatibility of the created resource.',
  );

  /// An explicit placement of the created output.
  static final output = StringOption(
    'output',
    description:
        'An explicit placement of the created output. It is resolved '
        'against the working directory.',
  );

  /// The explicit request for a managed installation record.
  static final manage = BooleanFlag(
    'manage',
    description:
        'Request a managed installation record. An author-only output is '
        'the default.',
  );

  static final apply = BooleanFlag(
    'apply',
    description: 'Publish the reviewed proposal instead of only planning it.',
  );
  static final yes = BooleanFlag(
    'yes',
    description: 'Approve the exact reviewed publication.',
  );
  static final dryRun = BooleanFlag(
    'dry-run',
    description:
        'Force a read-only plan. It never launches an editor and never '
        'creates a draft.',
  );
  static final planId = StringOption(
    'plan-id',
    description: 'The exact reviewed plan identity required for apply.',
  );
  static final interactive = BooleanFlag(
    'interactive',
    description:
        'Request the guided flow explicitly. It is the default on a usable '
        'terminal.',
  );
  static final unattended = BooleanFlag(
    'unattended',
    description:
        'Never prompt. Every required value must be supplied explicitly.',
  );
  static final editor = StringOption(
    'editor',
    description:
        'The editor command used for the instruction body. It is an '
        'executable with its arguments, never a shell expression.',
  );
  static final showInstructions = BooleanFlag(
    'show-instructions',
    description: 'Include the private instruction text deliberately.',
  );

  /// The incompatible explicit occurrences of the guided create commands.
  ///
  /// A conflict is undirected: every pair is declared once.
  static const conflicts = <String, List<String>>{
    'profile': ['harness'],
    'body-file': ['body-stdin', 'body-text'],
    'body-stdin': ['body-text'],
    'interactive': ['unattended'],
    'apply': ['dry-run'],
  };

  /// The native field values that the selected flags declare.
  ///
  /// An omitted flag declares nothing: the field keeps its source value or
  /// stays absent. The map carries only the fields the operator supplied.
  ///
  /// The mapping is native-profile aware: a native table is declared by its
  /// named entries and a native list by its repeated values. A selection
  /// whose native shape is a structured table is refused by the caller
  /// instead of being flattened.
  static Map<String, Object?> nativeFields({
    String? name,
    String? description,
    String? model,
    List<String>? tools,
    bool mainAgent = false,
    List<String>? skills,
    List<String>? allowedTools,
    List<String>? disallowedTools,
    List<String>? metadata,
    String? argumentHint,
    String? license,
    String? compatibility,
  }) => <String, Object?>{
    'name': ?name,
    'description': ?description,
    'model': ?model,
    'tools': ?tools == null ? null : List<String>.of(tools),
    if (mainAgent) 'mainAgent': true,
    'skills': ?skills == null ? null : List<String>.of(skills),
    'allowed-tools': ?allowedTools == null
        ? null
        : List<String>.of(allowedTools),
    'disallowed-tools': ?disallowedTools == null
        ? null
        : List<String>.of(disallowedTools),
    'metadata': ?metadata == null ? null : nativeEntries(metadata),
    'argument-hint': ?argumentHint,
    'license': ?license,
    'compatibility': ?compatibility,
  };

  /// The native table of the supplied named entries.
  ///
  /// Every entry is one `name=value` pair. The name must not be blank, and
  /// the value keeps every character after the first separator.
  static Map<String, Object?> nativeEntries(List<String> entries) {
    final values = <String, Object?>{};
    for (final entry in entries) {
      final separator = entry.indexOf('=');
      if (separator <= 0) {
        throw MambaException(
          'The metadata entry must be one name=value pair: $entry',
          exitCode: 4,
        );
      }
      values[entry.substring(0, separator)] = entry.substring(separator + 1);
    }
    return values;
  }

  /// The body selection of the selected flags.
  ///
  /// The three selectors are mutually exclusive; the shared input parser
  /// refuses a second one and names the supported alternative.
  static AuthoringBodySelection? bodySelection({
    String? bodyFile,
    bool bodyStandardInput = false,
    String? bodyText,
  }) {
    final selections = <AuthoringBodySelection>[
      if (bodyFile != null)
        AuthoringBodySelection(kind: BodyInputKind.file, filePath: bodyFile),
      if (bodyStandardInput)
        const AuthoringBodySelection(kind: BodyInputKind.standardInput),
      if (bodyText != null && bodyText.isNotEmpty)
        AuthoringBodySelection(kind: BodyInputKind.literal, text: bodyText),
    ];
    if (selections.length > 1) {
      throw MambaException(
        'Select exactly one body input: --body-file, --body-stdin or '
        '--body-text.',
        exitCode: 4,
      );
    }
    return selections.isEmpty ? null : selections.single;
  }
}
