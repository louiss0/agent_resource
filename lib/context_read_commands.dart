import 'dart:convert';
import 'dart:io' show Platform, stdin, stdout;

import 'package:mamba/mamba.dart';

import 'components/context_template_selector.dart';
import 'src/context/context_types.dart';
import 'src/services/context_template_service.dart';
import 'src/services/lifecycle_state_service.dart';

/// The shared declaration set for context command location and output.
final contextFormatOption = ChoiceOption.withDefault(
  'format',
  choices: ContextOutputFormat.values,
  defaultValue: ContextOutputFormat.text,
);
final contextCwdOption = FolderPathOption('cwd');
final contextHomeOption = FolderPathOption('home');
final contextStateDirOption = FolderPathOption('state-dir');

List<Option<Object?>> get contextCommonOptions => <Option<Object?>>[
  contextFormatOption,
  contextCwdOption,
  contextHomeOption,
  contextStateDirOption,
];

/// Selects one stored template name. A null answer cancels the selection.
typedef ContextTemplateSelection = Future<String?> Function(List<String> names);

/// Offers the stored names through the numbered selector component.
Future<String?> selectStoredContextTemplate(List<String> names) =>
    ContextTemplateSelectorComponent(options: names).render();

/// Refuses an explicit interactive session that requests JSON output.
void requireContextInteractiveFormat(
  bool interactive,
  ContextOutputFormat format,
) {
  if (interactive && format == ContextOutputFormat.json) {
    throw MambaException(
      'INTERACTIVE_JSON_REFUSED: Interactive selection cannot be used with '
      '--format json; supply a template name.',
      exitCode: 4,
    );
  }
}

/// Resolves the supplied name or offers the stored names through [select].
Future<String> resolveContextTemplateName({
  required String? positionalName,
  required String? optionName,
  required bool interactive,
  required LifecycleOptions options,
  required ContextTemplateService templates,
  ContextTemplateSelection? select,
}) async {
  if (positionalName != null && optionName != null) {
    throw MambaException(
      'AMBIGUOUS_TEMPLATE_NAME: Supply either <name> or --name, not both.',
      exitCode: 4,
    );
  }
  final supplied = (positionalName ?? optionName)?.trim();
  if (supplied != null) {
    if (supplied.isEmpty) {
      throw MambaException(
        'MISSING_TEMPLATE_NAME: The template name must not be blank.',
        exitCode: 4,
      );
    }
    return supplied;
  }
  if (!interactive) {
    throw MambaException(
      'MISSING_TEMPLATE_NAME: Supply a context template name as <name> '
      'or --name.',
      exitCode: 4,
    );
  }
  final names = templates
      .list(options)
      .map((template) => template.name)
      .toList(growable: false);
  if (names.isEmpty) {
    throw MambaException(
      'NO_CONTEXT_TEMPLATES: No stored context templates are available '
      'to select.',
      exitCode: 4,
    );
  }
  final chosen = await (select ?? selectStoredContextTemplate)(names);
  if (chosen == null || chosen.trim().isEmpty) {
    throw MambaException(
      'TEMPLATE_SELECTION_CANCELLED: No context template was selected.',
      exitCode: 7,
    );
  }
  return chosen.trim();
}

/// Whether the process owns a usable terminal for line prompts.
bool contextHasInteractiveTerminal() {
  try {
    return stdin.hasTerminal && stdout.hasTerminal;
  } on Object {
    return false;
  }
}

/// Lists the stored context templates in deterministic order.
final class ContextListCommand extends Command {
  ContextListCommand(this._service) : super(options: contextCommonOptions);

  final ContextTemplateService _service;

  @override
  String get name => 'list';

  @override
  String get shortDescription => 'List stored context templates.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final templates = _service.list(_options(valueOf, _service));
    final result = LifecycleResult(
      command: 'context list',
      outcome: 'listed',
      data: <String, Object?>{
        'templates': <Object?>[
          for (final template in templates) template.toJson(),
        ],
      },
    );
    return renderContextResult(result, valueOf(contextFormatOption));
  }
}

/// Reads one stored context template's metadata and complete Markdown body.
final class ContextInspectCommand extends Command {
  ContextInspectCommand(
    this._service, {
    ContextTemplateSelection? selectTemplate,
    bool Function()? hasTerminal,
  }) : _selectTemplate = selectTemplate ?? selectStoredContextTemplate,
       _hasTerminal = hasTerminal ?? contextHasInteractiveTerminal,
       super(
         discretionaryPositionals: [_nameArgument],
         options: <Option<Object?>>[_nameOption, ...contextCommonOptions],
         flags: [_interactive, _unattended],
         conflicts: {
           'interactive': ['unattended'],
         },
       );

  static final _nameArgument = NormalPositional.optional(
    'name',
    description: 'The context template name to inspect.',
  );
  static final _nameOption = StringOption(
    'name',
    description: 'The context template name to inspect.',
  );
  static const _interactive = BooleanFlag(
    'interactive',
    description: 'Select a template interactively when no name is supplied.',
  );
  static const _unattended = BooleanFlag(
    'unattended',
    description: 'Refuse interactive selection and require an explicit name.',
  );

  final ContextTemplateService _service;
  final ContextTemplateSelection _selectTemplate;
  final bool Function() _hasTerminal;

  @override
  String get name => 'inspect';

  @override
  String get shortDescription =>
      'Inspect one context template with its full Markdown body.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(contextFormatOption);
    requireContextInteractiveFormat(valueOf(_interactive), format);
    final terminal = _hasTerminal();
    if (valueOf(_interactive) && !terminal) {
      throw MambaException(
        'INTERACTIVE_TERMINAL_REFUSED: No usable terminal for interactive '
        'template selection.',
        exitCode: 4,
      );
    }
    final options = _options(valueOf, _service);
    final name = await resolveContextTemplateName(
      positionalName: valueOf(_nameArgument),
      optionName: valueOf(_nameOption),
      interactive:
          !valueOf(_unattended) &&
          format == ContextOutputFormat.text &&
          (valueOf(_interactive) || terminal),
      options: options,
      templates: _service,
      select: _selectTemplate,
    );

    final template = _service.inspect(options, name);
    final result = LifecycleResult(
      command: 'context inspect',
      outcome: 'inspected',
      data: template.toJson(),
    );
    return renderContextResult(result, format);
  }
}

LifecycleOptions _options(ValueOf valueOf, ContextTemplateService service) =>
    contextLifecycleOptions(
      fileSystem: service.fileSystem,
      environment: Map<String, String>.unmodifiable(Platform.environment),
      cwd: valueOf(contextCwdOption),
      home: valueOf(contextHomeOption),
      stateDir: valueOf(contextStateDirOption),
    );

/// Renders the house [LifecycleResult] envelope in the selected format.
String renderContextResult(
  LifecycleResult result,
  ContextOutputFormat format,
) => switch (format) {
  ContextOutputFormat.json => jsonEncode(result.envelope()),
  ContextOutputFormat.text => result.renderText(),
};
