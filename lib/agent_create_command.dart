import 'dart:async';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'authoring_command_support.dart';
import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/agent_authoring_service.dart';
import 'src/services/bound_role_service.dart';
import 'src/services/lifecycle_state_service.dart';

final class AgentCreateCommand extends Command {
  AgentCreateCommand({
    AgentAuthoringService? service,
    BoundRoleService? boundRoleService,
    this._confirmation = defaultAuthoringConfirmation,
  }) : _service = service ?? AgentAuthoringService(),
       _boundRoleService = boundRoleService ?? BoundRoleService(),
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
         flags: const [
           _apply,
           _dryRun,
           _yes,
           _interactive,
           _showInstructions,
           _ackClientsStopped,
           _clientsStopped,
         ],
         longDescription:
             'Create a native Agent from explicit declarations or preserve '
             'the version-1 Codex bound-role creation request workflow. The '
             'canonical request is positional; --request remains a compatible '
             'alias. Planning is read-only by default.',
       );

  final AgentAuthoringService _service;
  final BoundRoleService _boundRoleService;
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
    description: 'Installation scope for the created target.',
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
  static const _ackClientsStopped = BooleanFlag(
    'ack-clients-stopped',
    description: 'Acknowledge native clients are stopped for parent writes.',
  );
  static const _clientsStopped = BooleanFlag(
    'clients-stopped',
    description: 'Compatibility alias for --ack-clients-stopped.',
  );

  @override
  String get name => 'create';

  @override
  String get shortDescription =>
      'Plan or publish a reviewed native Agent creation.';

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
    final positional = valueOf(_requestFile);
    final named = valueOf(_request);
    final requestFile = selectOperationRequest(positional, named);
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

    if (positional == null &&
        named != null &&
        isBoundRoleRequest(
          named,
          options.cwd ?? options.processWorkingDirectory,
        )) {
      if (valueOf(_apply) ||
          valueOf(_planId) != null ||
          interactive ||
          valueOf(_showInstructions)) {
        throw MambaException(
          'The bound-role compatibility path uses request planId and does not accept rich authoring flags.',
          exitCode: 1,
        );
      }
      final request = parseBoundRoleRequest(
        named,
        options.cwd ?? options.processWorkingDirectory,
      );
      if (request.operation != BoundOperation.create) {
        throw MambaException(
          'The agent create request operation must be create.',
        );
      }
      final acknowledged =
          valueOf(_ackClientsStopped) || valueOf(_clientsStopped);
      if (acknowledged != request.clientsStopped) {
        throw MambaException(
          'The request and command must agree on clientsStopped.',
          exitCode: 4,
        );
      }
      final result = await _boundRoleService.run(request, options);
      return renderAuthoringResult(result, format);
    }

    final request = parseAuthoringRequest(
      requestFile,
      options.cwd ?? options.processWorkingDirectory,
    );
    if (request.operation != AuthoringOperation.create) {
      throw MambaException('The request operation must be create.');
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
        'Apply agent create plan ${planned.result.data['planId']}?',
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
