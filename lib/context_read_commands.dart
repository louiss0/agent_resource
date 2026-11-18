import 'dart:convert';
import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'src/context/context_types.dart';
import 'src/services/context_template_service.dart';
import 'src/services/lifecycle_state_service.dart';

final _format = ChoiceOption.withDefault(
  'format',
  choices: ContextOutputFormat.values,
  defaultValue: ContextOutputFormat.text,
);
final _cwd = FolderPathOption('cwd');
final _home = FolderPathOption('home');
final _stateDir = FolderPathOption('state-dir');

/// Lists the stored context templates in deterministic order.
final class ContextListCommand extends Command {
  ContextListCommand(this._service)
    : super(options: [_format, _cwd, _home, _stateDir]);

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
    return renderContextResult(result, valueOf(_format));
  }
}

/// Reads one stored context template's metadata and complete Markdown body.
final class ContextInspectCommand extends Command {
  ContextInspectCommand(this._service)
    : super(
        discretionaryPositionals: [_nameArgument],
        options: [_nameOption, _format, _cwd, _home, _stateDir],
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

  @override
  String get name => 'inspect';

  @override
  String get shortDescription =>
      'Inspect one context template with its full Markdown body.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    if (valueOf(_interactive) && format == ContextOutputFormat.json) {
      throw MambaException(
        'INTERACTIVE_JSON_REFUSED: Interactive selection cannot be used '
        'with --format json; supply a template name.',
        exitCode: 4,
      );
    }

    final positionalName = valueOf(_nameArgument);
    final optionName = valueOf(_nameOption);
    if (positionalName != null && optionName != null) {
      throw MambaException(
        'AMBIGUOUS_TEMPLATE_NAME: Supply either <name> or --name, not both.',
        exitCode: 4,
      );
    }
    final name = positionalName ?? optionName;
    if (name == null) {
      throw MambaException(
        'MISSING_TEMPLATE_NAME: Supply a context template name as <name> '
        'or --name.',
        exitCode: 4,
      );
    }

    final template = _service.inspect(_options(valueOf, _service), name);
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
      cwd: valueOf(_cwd),
      home: valueOf(_home),
      stateDir: valueOf(_stateDir),
    );

/// Renders the house [LifecycleResult] envelope in the selected format.
String renderContextResult(
  LifecycleResult result,
  ContextOutputFormat format,
) => switch (format) {
  ContextOutputFormat.json => jsonEncode(result.envelope()),
  ContextOutputFormat.text => result.renderText(),
};
