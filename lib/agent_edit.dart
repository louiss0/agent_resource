import 'dart:async';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'authoring_command_support.dart';
import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/agent_authoring_service.dart';
import 'src/services/lifecycle_state_service.dart';

final class AgentEditCommand extends Command {
  AgentEditCommand({
    AgentAuthoringService? service,
    this._confirmation = defaultAuthoringConfirmation,
  }) : _service = service ?? AgentAuthoringService(),
       super(
         discretionaryPositionals: [_requestFile],
         options: [
           _request,
           _scope,
           _format,
           _cwd,
           _projectRoot,
           _home,
           _claudeConfigDir,
           _codexHome,
           _piAgentDir,
           _stateDir,
           _planId,
         ],
         flags: const [_apply, _dryRun, _yes, _interactive, _showInstructions],
         longDescription:
             'Edit an unchanged managed Agent through its recorded identity. '
             'Unmanaged occurrences require explicit adoption. Planning is '
             'read-only; publication uses retained lifecycle backups.',
       );

  final AgentAuthoringService _service;
  final AuthoringConfirmation _confirmation;

  static final _requestFile = FilePathPositional.optional(
    'operation-request',
    suffixes: const ['.json'],
  );
  static final _request = FilePathOption('request', suffixes: const ['.json']);
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: const [LifecycleScope.project, LifecycleScope.user],
    defaultValue: LifecycleScope.project,
    description: 'Installation scope for the managed edit.',
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
    description: 'Success output format.',
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claudeConfigDir = FolderPathOption('claude-config-dir');
  static final _codexHome = FolderPathOption('codex-home');
  static final _piAgentDir = FolderPathOption('pi-agent-dir');
  static final _stateDir = FolderPathOption('state-dir');
  static final _planId = StringOption(
    'plan-id',
    description: 'Exact reviewed plan identity required for apply.',
  );
  static const _apply = BooleanFlag(
    'apply',
    description: 'Publish the reviewed plan instead of only planning.',
  );
  static const _dryRun = BooleanFlag(
    'dry-run',
    description: 'Force read-only planning with no management artifacts.',
  );
  static const _yes = BooleanFlag(
    'yes',
    description: 'Approve the exact reviewed publication.',
  );
  static const _interactive = BooleanFlag(
    'interactive',
    description: 'Explicitly review and confirm a fresh plan.',
  );
  static const _showInstructions = BooleanFlag(
    'show-instructions',
    description: 'Include private instruction text deliberately.',
  );

  @override
  String get name => 'edit';

  @override
  String get shortDescription => 'Plan or publish a managed native Agent edit.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final interactive = valueOf(_interactive);
    validateAuthoringMode(
      apply: valueOf(_apply),
      dryRun: valueOf(_dryRun),
      interactive: interactive,
      format: format,
    );
    final requestFile = selectOperationRequest(
      valueOf(_requestFile),
      valueOf(_request),
    );
    var options = LifecycleOptions(
      processWorkingDirectory: Directory.current.path,
      environment: Map<String, String>.unmodifiable(Platform.environment),
      scope: valueOf(_scope),
      cwd: valueOf(_cwd),
      projectRoot: valueOf(_projectRoot),
      home: valueOf(_home),
      claudeConfigDir: valueOf(_claudeConfigDir),
      codexHome: valueOf(_codexHome),
      piAgentDir: valueOf(_piAgentDir),
      stateDir: valueOf(_stateDir),
      dryRun: valueOf(_dryRun),
      approved: valueOf(_yes),
    );
    final request = parseAuthoringRequest(
      requestFile,
      options.cwd ?? options.processWorkingDirectory,
    );
    if (request.operation != AuthoringOperation.edit) {
      throw MambaException('The request operation must be edit.');
    }
    final apply = valueOf(_apply);
    var planId = valueOf(_planId);
    if (interactive && apply && !options.approved) {
      final planned = await _service.plan(
        request,
        options,
        showInstructions: valueOf(_showInstructions),
      );
      if (!await _confirmation(
        'Apply agent edit plan ${planned.result.data['planId']}?',
      )) {
        throw MambaException(
          'Operation cancelled; live state is unchanged.',
          exitCode: 7,
        );
      }
      final freshPlanId = planned.result.data['planId']! as String;
      if (planId != null && planId != freshPlanId) {
        throw MambaException('The supplied plan ID is stale.', exitCode: 4);
      }
      planId = freshPlanId;
      options = options.copyWith(approved: true);
    }
    final result = await _service.run(
      request,
      options,
      apply: apply,
      planId: planId,
      showInstructions: valueOf(_showInstructions),
    );
    return renderAuthoringResult(result, format);
  }
}
