import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;

import 'package:mamba/mamba.dart';

import 'components/installation_approval.dart';

import 'src/agent_inspection.dart';
import 'src/services/agent_lifecycle_service.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/bound_role_service.dart';
import 'src/services/parent_config_service.dart';
import 'src/services/skill_lifecycle_service.dart';

enum LifecycleOutputFormat { text, json }

enum RecoveryAction { rollback, complete }

enum _Resource { skill, agent }

enum _Operation {
  adopt,
  replace,
  remove,
  backupList,
  restore,
  cleanup,
  recover,
}

typedef LifecycleConfirmation = Future<bool> Function(String prompt);

Future<bool> _defaultConfirmation(String prompt) =>
    InstallationApprovalComponent(label: prompt).render();

/// Shared backup group registered below both native resource groups.
final class LifecycleBackupCommand extends GroupCommand {
  LifecycleBackupCommand.skill(SkillLifecycleService service)
    : this._(_Resource.skill, service, null);
  LifecycleBackupCommand.agent(
    AgentLifecycleService service, {
    ParentConfigService? parentConfig,
    BoundRoleService? boundRole,
  }) : this._(_Resource.agent, null, service, parentConfig, boundRole);

  LifecycleBackupCommand._(
    _Resource resource,
    SkillLifecycleService? skill,
    AgentLifecycleService? agent, [
    ParentConfigService? parentConfig,
    BoundRoleService? boundRole,
  ]) : super([
         LifecycleActionCommand._(
           resource,
           _Operation.backupList,
           skill,
           agent,
           _defaultConfirmation,
           parentConfig,
           boundRole,
         ),
         LifecycleActionCommand._(
           resource,
           _Operation.restore,
           skill,
           agent,
           _defaultConfirmation,
           parentConfig,
           boundRole,
         ),
         LifecycleActionCommand._(
           resource,
           _Operation.cleanup,
           skill,
           agent,
           _defaultConfirmation,
           parentConfig,
           boundRole,
         ),
       ]);

  @override
  String get name => 'backup';

  @override
  String get shortDescription => 'List, restore, or clean retained backups.';
}

/// One retained declaration tree for each direct lifecycle command path.
final class LifecycleActionCommand extends Command {
  factory LifecycleActionCommand.skillAdopt(SkillLifecycleService service) =>
      LifecycleActionCommand._skill(_Operation.adopt, service);
  factory LifecycleActionCommand.skillReplace(SkillLifecycleService service) =>
      LifecycleActionCommand._skill(_Operation.replace, service);
  factory LifecycleActionCommand.skillRemove(SkillLifecycleService service) =>
      LifecycleActionCommand._skill(_Operation.remove, service);
  factory LifecycleActionCommand.skillRecover(SkillLifecycleService service) =>
      LifecycleActionCommand._skill(_Operation.recover, service);

  factory LifecycleActionCommand.agentAdopt(
    AgentLifecycleService service, {
    ParentConfigService? parentConfig,
    BoundRoleService? boundRole,
  }) => LifecycleActionCommand._agent(
    _Operation.adopt,
    service,
    parentConfig: parentConfig,
    boundRole: boundRole,
  );
  factory LifecycleActionCommand.agentReplace(
    AgentLifecycleService service, {
    ParentConfigService? parentConfig,
    BoundRoleService? boundRole,
  }) => LifecycleActionCommand._agent(
    _Operation.replace,
    service,
    parentConfig: parentConfig,
    boundRole: boundRole,
  );
  factory LifecycleActionCommand.agentRemove(
    AgentLifecycleService service, {
    ParentConfigService? parentConfig,
    BoundRoleService? boundRole,
  }) => LifecycleActionCommand._agent(
    _Operation.remove,
    service,
    parentConfig: parentConfig,
    boundRole: boundRole,
  );
  factory LifecycleActionCommand.agentRecover(
    AgentLifecycleService service, {
    ParentConfigService? parentConfig,
    BoundRoleService? boundRole,
  }) => LifecycleActionCommand._agent(
    _Operation.recover,
    service,
    parentConfig: parentConfig,
    boundRole: boundRole,
  );

  LifecycleActionCommand._skill(
    _Operation operation,
    SkillLifecycleService service, {
    LifecycleConfirmation confirmation = _defaultConfirmation,
  }) : this._(_Resource.skill, operation, service, null, confirmation);
  LifecycleActionCommand._agent(
    _Operation operation,
    AgentLifecycleService service, {
    LifecycleConfirmation confirmation = _defaultConfirmation,
    ParentConfigService? parentConfig,
    BoundRoleService? boundRole,
  }) : this._(
         _Resource.agent,
         operation,
         null,
         service,
         confirmation,
         parentConfig ?? ParentConfigService(),
         boundRole ?? BoundRoleService(),
       );

  LifecycleActionCommand._(
    this._resource,
    this._operation,
    this._skill,
    this._agent, [
    this._confirmation = _defaultConfirmation,
    ParentConfigService? parentConfig,
    BoundRoleService? boundRole,
  ]) : _parentConfig = parentConfig,
       _boundRole = boundRole,
       super(
         mandatoryPositionals: [
           if (_resource == _Resource.skill && _operation == _Operation.adopt)
             _sourceDirectory,
           if (_resource == _Resource.skill &&
               _operation == _Operation.replace) ...[
             _installationId,
             _replacementDirectory,
           ],
           if (_resource == _Resource.skill && _operation == _Operation.remove)
             _installationId,
           if (_operation == _Operation.restore ||
               _operation == _Operation.cleanup)
             _backupId,
         ],
         discretionaryPositionals: [
           if (_resource == _Resource.agent && _operation == _Operation.adopt)
             _agentSourceFile,
           if (_resource == _Resource.agent &&
               _operation == _Operation.replace) ...[
             _agentInstallationId,
             _agentSourceFile,
           ],
           if (_resource == _Resource.agent && _operation == _Operation.remove)
             _agentInstallationId,
           if (_operation == _Operation.recover) _transactionId,
         ],
         options: [
           if (_resource == _Resource.skill) _skillScope else _agentScope,
           if (_operation == _Operation.adopt)
             if (_resource == _Resource.skill)
               _skillDestination
             else
               _agentDestination,
           if (_resource == _Resource.agent && _operation == _Operation.adopt)
             _requiredHarness,
           if (_resource == _Resource.agent && _operation == _Operation.replace)
             _harness,
           if (_resource == _Resource.skill && _operation == _Operation.adopt)
             _skillHarnesses,
           if (_operation == _Operation.recover) _recoveryAction,
           if (_resource == _Resource.agent &&
               (_operation == _Operation.adopt ||
                   _operation == _Operation.replace ||
                   _operation == _Operation.remove))
             _boundRequest,
           if (_resource == _Resource.agent &&
               (_operation == _Operation.restore ||
                   _operation == _Operation.cleanup))
             _parentPlan,
           _format,
           _cwd,
           _projectRoot,
           _home,
           _claudeConfigDir,
           _codexHome,
           _stateDir,
           if (_resource == _Resource.agent) ...[_piAgentDir, _readRoots],
           if (_resource == _Resource.skill && _operation == _Operation.adopt)
             _readRoots,
         ],
         flags: [
           _dryRun,
           _yes,
           _interactive,
           if (_resource == _Resource.agent) ...[
             _ackClientsStopped,
             _clientsStopped,
           ],
         ],
         longDescription:
             'Offline local lifecycle management. Relative paths resolve against '
             '--cwd. Dry-run is read-only and creates no management artifacts. '
             'Destructive apply requires --yes or explicit --interactive '
             'confirmation. No prompt occurs by default. Managed replacement '
             'and removal require an unchanged baseline; no implicit rebaseline, '
             'link conversion, registration, parent-setting, or network operation '
             'is performed.',
       );

  final _Resource _resource;
  final _Operation _operation;
  final SkillLifecycleService? _skill;
  final AgentLifecycleService? _agent;
  final LifecycleConfirmation _confirmation;
  final ParentConfigService? _parentConfig;
  final BoundRoleService? _boundRole;

  static final _sourceDirectory = FolderPathPositional(
    'source-directory',
    description: 'Ordinary Skill source or existing installation directory.',
  );
  static final _replacementDirectory = FolderPathPositional(
    'source-directory',
    description: 'Ordinary replacement Skill source directory.',
  );
  static final _agentSourceFile = FilePathPositional.optional(
    'native-file',
    suffixes: const ['.md', '.toml'],
    description: 'Native regular-file Agent definition.',
  );
  static final _installationId = NormalPositional('installation-id');
  static final _agentInstallationId = NormalPositional.optional(
    'installation-id',
  );
  static final _backupId = NormalPositional('backup-id');
  static final _transactionId = NormalPositional.optional('transaction-id');

  static final _skillScope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.user,
    description: 'Selected installation scope; mutations do not permit all.',
  );
  static final _agentScope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.project,
    description: 'Selected installation scope; mutations do not permit all.',
  );
  static final _skillDestination = ChoiceOption.required(
    'destination',
    choices: SkillDestination.values,
    description: 'Physical Skill destination.',
  );
  static final _agentDestination = ChoiceOption.withDefault(
    'destination',
    choices: AgentDestination.values,
    defaultValue: AgentDestination.native,
    description: 'Native or project-Shared Agent destination.',
  );
  static final _harness = ChoiceOption(
    'harness',
    choices: AgentHarness.values,
    description: 'Stored Agent profile check; retargeting is refused.',
  );
  static final _requiredHarness = ChoiceOption.required(
    'harness',
    choices: AgentHarness.values,
    description: 'Explicit native Agent profile; Markdown is never inferred.',
  );
  static final _skillHarnesses = RepeatableChoiceOption(
    'harness',
    SkillHarness.values,
    unique: true,
    description: 'Additional blocking Skill compatibility profile.',
  );
  static final _recoveryAction = ChoiceOption(
    'action',
    choices: RecoveryAction.values,
    description:
        'Persisted recovery transition; requires transaction ID and approval.',
  );
  static final _parentPlan = StringOption(
    'plan',
    description: 'Fresh parent-unit restore/cleanup plan ID.',
  );
  static final _boundRequest = FilePathOption(
    'request',
    suffixes: const ['.json'],
    description: 'Bound-role operation request.',
  );
  static const _ackClientsStopped = BooleanFlag(
    'ack-clients-stopped',
    description: 'Acknowledge that native clients were stopped before apply.',
  );
  static const _clientsStopped = BooleanFlag(
    'clients-stopped',
    description: 'Compatibility alias for --ack-clients-stopped.',
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
  static final _stateDir = FolderPathOption('state-dir');
  static final _piAgentDir = FolderPathOption('pi-agent-dir');
  static final _readRoots = RepeatableFolderPathOption('read-root');

  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');
  static const _interactive = BooleanFlag('interactive');

  @override
  String get name => switch (_operation) {
    _Operation.backupList => 'list',
    _Operation.recover => 'recover',
    _ => _operation.name,
  };

  @override
  String get shortDescription => switch (_operation) {
    _Operation.adopt => 'Adopt an eligible existing native resource.',
    _Operation.replace => 'Replace an unchanged managed installation.',
    _Operation.remove => 'Remove an unchanged managed installation.',
    _Operation.backupList => 'List selected-scope retained backups.',
    _Operation.restore => 'Restore a retained backup at its original location.',
    _Operation.cleanup => 'Delete intact retained backup evidence explicitly.',
    _Operation.recover => 'Inspect or apply persisted transaction recovery.',
  };

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final interactive = valueOf(_interactive);
    if (interactive && format == LifecycleOutputFormat.json) {
      throw MambaException('--interactive and --format json conflict.');
    }
    final dryRun = valueOf(_dryRun);
    final options = _options(valueOf, dryRun: dryRun, approved: valueOf(_yes));
    Future<LifecycleResult> invoke(LifecycleOptions selected) =>
        _invoke(valueOf, selected);
    final destructive =
        _destructive ||
        (_operation == _Operation.recover && valueOf(_recoveryAction) != null);
    if (destructive && interactive && !dryRun && !options.approved) {
      await invoke(_copyOptions(options, dryRun: true, approved: false));
      final confirmed = await _confirmation(
        'Apply this reviewed $name operation?',
      );
      if (!confirmed) {
        throw MambaException(
          'Operation cancelled; live state is unchanged.',
          exitCode: 7,
        );
      }
      final result = await invoke(_copyOptions(options, approved: true));
      return _render(result, format);
    }
    final result = await invoke(options);
    return _render(result, format);
  }

  bool get _destructive => switch (_operation) {
    _Operation.replace ||
    _Operation.remove ||
    _Operation.restore ||
    _Operation.cleanup => true,
    _Operation.recover => false,
    _ => false,
  };

  LifecycleOptions _options(
    ValueOf valueOf, {
    required bool dryRun,
    required bool approved,
  }) => LifecycleOptions(
    processWorkingDirectory: Directory.current.path,
    environment: Map<String, String>.unmodifiable(Platform.environment),
    scope: valueOf(_resource == _Resource.skill ? _skillScope : _agentScope),
    cwd: valueOf(_cwd),
    projectRoot: valueOf(_projectRoot),
    home: valueOf(_home),
    claudeConfigDir: valueOf(_claudeConfigDir),
    codexHome: valueOf(_codexHome),
    piAgentDir: _resource == _Resource.agent ? valueOf(_piAgentDir) : null,
    stateDir: valueOf(_stateDir),
    readRoots: _resource == _Resource.agent || _operation == _Operation.adopt
        ? valueOf(_readRoots) ?? const <String>[]
        : const <String>[],
    dryRun: dryRun,
    approved: approved,
  );

  LifecycleOptions _copyOptions(
    LifecycleOptions input, {
    bool? dryRun,
    bool? approved,
  }) => LifecycleOptions(
    processWorkingDirectory: input.processWorkingDirectory,
    environment: input.environment,
    scope: input.scope,
    cwd: input.cwd,
    projectRoot: input.projectRoot,
    home: input.home,
    claudeConfigDir: input.claudeConfigDir,
    codexHome: input.codexHome,
    piAgentDir: input.piAgentDir,
    stateDir: input.stateDir,
    readRoots: input.readRoots,
    dryRun: dryRun ?? input.dryRun,
    approved: approved ?? input.approved,
  );

  Future<LifecycleResult> _invoke(
    ValueOf valueOf,
    LifecycleOptions options,
  ) async {
    if (options.scope == LifecycleScope.all &&
        _operation != _Operation.recover) {
      throw MambaException(
        'This operation selects exactly one scope, not all.',
      );
    }
    if (_resource == _Resource.skill) {
      final service = _skill!;
      switch (_operation) {
        case _Operation.adopt:
          return service.adopt(_skillInstall(valueOf, options));
        case _Operation.replace:
          return service.replace(
            LifecycleReplaceInput(
              options: options,
              installationId: _requiredId(
                valueOf(_installationId),
                'installation',
              ),
              source: valueOf(_replacementDirectory),
            ),
          );
        case _Operation.remove:
          return service.remove(
            LifecycleIdInput(
              options: options,
              id: _requiredId(valueOf(_installationId), 'installation'),
            ),
          );
        case _Operation.backupList:
          return service.backupList(options);
        case _Operation.restore:
          return service.restore(
            LifecycleIdInput(
              options: options,
              id: _requiredId(valueOf(_backupId), 'backup'),
            ),
          );
        case _Operation.cleanup:
          return service.cleanup(
            LifecycleIdInput(
              options: options,
              id: _requiredId(valueOf(_backupId), 'backup'),
            ),
          );
        case _Operation.recover:
          return service.recover(
            options,
            transactionId: valueOf(_transactionId),
            action: valueOf(_recoveryAction)?.name,
          );
      }
    }
    final service = _agent!;
    switch (_operation) {
      case _Operation.adopt:
        final bound = valueOf(_boundRequest);
        final source = valueOf(_agentSourceFile);
        if (bound != null) {
          if (source != null) {
            throw MambaException(
              'Provide either a native file or --request, not both.',
              exitCode: 1,
            );
          }
          return _bound(valueOf, bound, options, _operation);
        }
        if (source == null) {
          throw MambaException(
            'Agent adopt requires a native-file positional.',
          );
        }
        return service.adopt(_agentInstall(valueOf, options, source));
      case _Operation.replace:
        final bound = valueOf(_boundRequest);
        final source = valueOf(_agentSourceFile);
        final directId = valueOf(_agentInstallationId);
        if (bound != null) {
          if (source != null || directId != null) {
            throw MambaException(
              'Provide either a stored ID/native file or --request, not both.',
              exitCode: 1,
            );
          }
          return _bound(valueOf, bound, options, _operation);
        }
        if (source == null) {
          throw MambaException(
            'Agent replace requires a native-file positional.',
          );
        }
        return service.replace(
          LifecycleReplaceInput(
            options: options,
            installationId: _requiredId(directId, 'installation'),
            source: source,
          ),
          harness: valueOf(_harness),
        );
      case _Operation.remove:
        final bound = valueOf(_boundRequest);
        final directId = valueOf(_agentInstallationId);
        if (bound != null) {
          if (directId != null) {
            throw MambaException(
              'Provide either a stored ID or --request, not both.',
              exitCode: 1,
            );
          }
          return _bound(valueOf, bound, options, _operation);
        }
        return service.remove(
          LifecycleIdInput(
            options: options,
            id: _requiredId(directId, 'installation'),
          ),
        );
      case _Operation.backupList:
        final result = await service.backupList(options);
        final parent = await _parentConfig!.backupList(options);
        return LifecycleResult(
          command: result.command,
          outcome: result.outcome,
          data: <String, Object?>{
            ...result.data,
            'parentBackups': parent.data['parentBackups'],
          },
        );
      case _Operation.restore:
        final parent = _parentConfig!;
        final id = _requiredId(valueOf(_backupId), 'backup');
        if (parent.hasBackup(options, id)) {
          final result = await parent.restore(
            options: options,
            backupId: id,
            planId: valueOf(_parentPlan) ?? '',
            clientsStopped:
                valueOf(_ackClientsStopped) || valueOf(_clientsStopped),
          );
          return LifecycleResult(
            command: result.command,
            outcome: result.outcome,
            data: result.data,
            diagnostics: result.diagnostics,
          );
        }
        return service.restore(LifecycleIdInput(options: options, id: id));
      case _Operation.cleanup:
        final parent = _parentConfig!;
        final id = _requiredId(valueOf(_backupId), 'backup');
        if (parent.hasBackup(options, id)) {
          final result = await parent.cleanup(options: options, backupId: id);
          return LifecycleResult(
            command: result.command,
            outcome: result.outcome,
            data: result.data,
            diagnostics: result.diagnostics,
          );
        }
        return service.cleanup(LifecycleIdInput(options: options, id: id));
      case _Operation.recover:
        return service.recover(
          options,
          transactionId: valueOf(_transactionId),
          action: valueOf(_recoveryAction)?.name,
        );
    }
  }

  Future<LifecycleResult> _bound(
    ValueOf valueOf,
    String requestFile,
    LifecycleOptions options,
    _Operation expected,
  ) {
    final request = parseBoundRoleRequest(
      requestFile,
      options.cwd ?? options.processWorkingDirectory,
    );
    final acknowledged =
        valueOf(_ackClientsStopped) || valueOf(_clientsStopped);
    if (acknowledged != request.clientsStopped) {
      throw MambaException(
        'The request and command must agree on clientsStopped.',
        exitCode: 4,
      );
    }
    if (request.operation.name != expected.name) {
      throw MambaException(
        'The bound-role request operation must match the selected command.',
        exitCode: 1,
      );
    }
    return _boundRole!.run(request, options);
  }

  SkillInstallInput _skillInstall(ValueOf valueOf, LifecycleOptions options) {
    final harnesses = valueOf(_skillHarnesses) ?? const <SkillHarness>[];
    return SkillInstallInput(
      options: options,
      source: valueOf(_sourceDirectory),
      destination: valueOf(_skillDestination),
      harnesses: harnesses,
    );
  }

  AgentInstallInput _agentInstall(
    ValueOf valueOf,
    LifecycleOptions options,
    String source,
  ) {
    final harness = valueOf(_requiredHarness);
    return AgentInstallInput(
      options: options,
      source: source,
      harness: harness,
      destination: valueOf(_agentDestination),
    );
  }

  String _requiredId(String? value, String label) {
    final id = value?.trim() ?? '';
    if (id.isEmpty) throw MambaException('The $label ID must not be blank.');
    return id;
  }

  String _render(LifecycleResult result, LifecycleOutputFormat format) =>
      switch (format) {
        LifecycleOutputFormat.json => jsonEncode(result.envelope()),
        LifecycleOutputFormat.text => result.renderText(),
      };
}
