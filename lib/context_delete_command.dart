import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'components/installation_approval.dart';
import 'context_read_commands.dart';
import 'src/context/context_types.dart';
import 'src/services/context_template_service.dart';
import 'src/services/lifecycle_state_service.dart';

/// Removes one stored context template after confirmation.
final class ContextDeleteCommand extends Command {
  ContextDeleteCommand(
    this._service, {
    InstallationApprovalComponent? approval,
    ContextTemplateSelection? selectTemplate,
    bool Function()? hasTerminal,
  }) : _approval = approval ?? const InstallationApprovalComponent(),
       _selectTemplate = selectTemplate ?? selectStoredContextTemplate,
       _hasTerminal =
           hasTerminal ??
           (() =>
               approval?.hasTerminal?.call() ??
               contextHasInteractiveTerminal()),
       super(
         discretionaryPositionals: [_nameArgument],
         options: <Option<Object?>>[_nameOption, ...contextCommonOptions],
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
  final ContextTemplateSelection _selectTemplate;
  final bool Function() _hasTerminal;

  @override
  String get name => 'delete';

  @override
  String get shortDescription => 'Delete one stored context template.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(contextFormatOption);
    requireContextInteractiveFormat(valueOf(_interactive), format);
    final terminal = _hasTerminal();
    if (valueOf(_interactive) && !terminal) {
      throw MambaException(
        'INTERACTIVE_TERMINAL_REFUSED: No usable terminal for confirmation; '
        'pass --yes in unattended mode.',
        exitCode: 4,
      );
    }
    final options = contextLifecycleOptions(
      fileSystem: _service.fileSystem,
      environment: Map<String, String>.unmodifiable(Platform.environment),
      cwd: valueOf(contextCwdOption),
      home: valueOf(contextHomeOption),
      stateDir: valueOf(contextStateDirOption),
    );
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
    if (!isValidContextTemplateName(name)) {
      throw MambaException(
        'INVALID_TEMPLATE_NAME: Context template name "$name" is not portable.',
        exitCode: 4,
      );
    }

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
