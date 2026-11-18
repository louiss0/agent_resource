import 'dart:io' show Platform, stdin, stdout;

import 'package:mamba/mamba.dart';

import 'components/installation_approval.dart';
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
  ContextDeleteCommand(this._service, {InstallationApprovalComponent? approval})
    : _approval = approval ?? const InstallationApprovalComponent(),
      super(
        discretionaryPositionals: [_nameArgument],
        options: [
          _nameOption,
          _deleteFormat,
          _deleteCwd,
          _deleteHome,
          _deleteStateDir,
        ],
        flags: [_dryRun, _yes, _interactive, _unattended],
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
  static const _yes = BooleanFlag(
    'yes',
    description: 'Confirm the deletion without a prompt.',
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
  final InstallationApprovalComponent _approval;

  bool _hasTerminal() =>
      _approval.hasTerminal?.call() ??
      (stdin.hasTerminal && stdout.hasTerminal);

  @override
  String get name => 'delete';

  @override
  String get shortDescription => 'Delete one stored context template.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_deleteFormat);
    if (valueOf(_interactive) && format == ContextOutputFormat.json) {
      throw MambaException(
        'INTERACTIVE_JSON_REFUSED: Interactive confirmation cannot be used '
        'with --format json; pass --yes instead.',
        exitCode: 4,
      );
    }
    if (valueOf(_interactive) && !_hasTerminal()) {
      throw MambaException(
        'INTERACTIVE_TERMINAL_REFUSED: No usable terminal for confirmation; '
        'pass --yes in unattended mode.',
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
    final dryRun = valueOf(_dryRun);
    if (!dryRun && !valueOf(_yes)) {
      final unattended =
          valueOf(_unattended) ||
          format == ContextOutputFormat.json ||
          !_hasTerminal();
      if (unattended) {
        throw MambaException(
          'CONFIRMATION_REQUIRED: Deleting context template "$name" in '
          'unattended mode requires --yes.',
          exitCode: 4,
        );
      }
      if (!await _approval.render()) {
        throw MambaException(
          'DELETION_CANCELLED: Deletion of context template "$name" was not '
          'confirmed.',
          exitCode: 7,
        );
      }
    }
    if (!dryRun) {
      final current = _service.inspect(options, name);
      _service.fileSystem.file(current.metadata.path).deleteSync();
    }
    final result = LifecycleResult(
      command: 'context delete',
      outcome: dryRun ? 'planned' : 'deleted',
      data: <String, Object?>{
        ...template.metadata.toJson(),
        'deleted': !dryRun,
        'dryRun': dryRun,
      },
      diagnostics: <Map<String, Object?>>[
        <String, Object?>{
          'code': dryRun ? 'DRY_RUN_PLANNED' : 'TEMPLATE_DELETED',
          'category': 'operation',
          'severity': 'info',
          'field': 'deleted',
          'message': dryRun
              ? 'No context template was removed.'
              : 'Removed context template "$name".',
        },
      ],
    );
    return renderContextResult(result, format);
  }
}
