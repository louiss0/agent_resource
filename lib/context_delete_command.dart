import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'context_read_commands.dart';
import 'src/context/context_types.dart';
import 'src/services/context_template_service.dart';
import 'src/services/lifecycle_state_service.dart';

final _deleteFormat = ChoiceOption.withDefault(
  'format',
  choices: ContextOutputFormat.values,
  defaultValue: ContextOutputFormat.text,
);
final _deleteCwd = FolderPathOption('cwd');
final _deleteHome = FolderPathOption('home');
final _deleteStateDir = FolderPathOption('state-dir');

/// Removes one stored context template after confirmation.
final class ContextDeleteCommand extends Command {
  ContextDeleteCommand(this._service)
    : super(
        discretionaryPositionals: [_nameArgument],
        options: [
          _nameOption,
          _deleteFormat,
          _deleteCwd,
          _deleteHome,
          _deleteStateDir,
        ],
        flags: [_dryRun, _interactive, _unattended],
        conflicts: {
          'interactive': ['unattended'],
        },
      );

  static final _nameArgument = NormalPositional.optional(
    'name',
    description: 'The context template name to delete.',
  );
  static final _nameOption = StringOption(
    'name',
    description: 'The context template name to delete.',
  );
  static const _dryRun = BooleanFlag(
    'dry-run',
    description: 'Report the deletion without changing the filesystem.',
  );
  static const _interactive = BooleanFlag(
    'interactive',
    description: 'Require a usable terminal and confirm interactively.',
  );
  static const _unattended = BooleanFlag(
    'unattended',
    description: 'Never prompt; require --yes for a real deletion.',
  );

  final ContextTemplateService _service;

  @override
  String get name => 'delete';

  @override
  String get shortDescription => 'Delete one stored context template.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_deleteFormat);
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
    if (!isValidContextTemplateName(name)) {
      throw MambaException(
        'INVALID_TEMPLATE_NAME: Context template name "$name" is not portable.',
        exitCode: 4,
      );
    }

    final options = contextLifecycleOptions(
      fileSystem: _service.fileSystem,
      environment: Map<String, String>.unmodifiable(Platform.environment),
      cwd: valueOf(_deleteCwd),
      home: valueOf(_deleteHome),
      stateDir: valueOf(_deleteStateDir),
    );
    final template = _service.inspect(options, name);
    final result = LifecycleResult(
      command: 'context delete',
      outcome: 'planned',
      data: <String, Object?>{
        ...template.metadata.toJson(),
        'deleted': false,
        'dryRun': true,
      },
      diagnostics: <Map<String, Object?>>[
        <String, Object?>{
          'code': 'DRY_RUN_PLANNED',
          'category': 'operation',
          'severity': 'info',
          'field': 'deleted',
          'message': 'No context template was removed.',
        },
      ],
    );
    return renderContextResult(result, format);
  }
}
