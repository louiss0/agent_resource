import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'src/agent_inspection.dart';
import 'src/services/agent_lifecycle_service.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/skill_lifecycle_service.dart';

enum LifecycleOutputFormat { text, json }

enum RecoveryAction { rollback, complete }

enum _Resource { skill, agent }

enum _Operation {
  install,
  adopt,
  replace,
  remove,
  backupList,
  restore,
  cleanup,
  recover,
}

typedef LifecycleConfirmation = Future<bool> Function(String prompt);

Future<bool> _defaultConfirmation(String prompt) async {
  stderr.write('$prompt [y/N] ');
  final answer = stdin.readLineSync()?.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

/// Shared backup group registered below both native resource groups.
final class LifecycleBackupCommand extends GroupCommand {
  LifecycleBackupCommand.skill(SkillLifecycleService service)
    : this._(_Resource.skill, service, null);
  LifecycleBackupCommand.agent(AgentLifecycleService service)
    : this._(_Resource.agent, null, service);

  LifecycleBackupCommand._(
    _Resource resource,
    SkillLifecycleService? skill,
    AgentLifecycleService? agent,
  ) : super([
        LifecycleActionCommand._(resource, _Operation.backupList, skill, agent),
        LifecycleActionCommand._(resource, _Operation.restore, skill, agent),
        LifecycleActionCommand._(resource, _Operation.cleanup, skill, agent),
      ]);

  @override
  String get name => 'backup';

  @override
  String get shortDescription => 'List, restore, or clean retained backups.';
}

/// One retained declaration tree for each direct lifecycle command path.
final class LifecycleActionCommand extends Command {
  factory LifecycleActionCommand.skillInstall(SkillLifecycleService service) =>
      LifecycleActionCommand._skill(_Operation.install, service);
  factory LifecycleActionCommand.skillAdopt(SkillLifecycleService service) =>
      LifecycleActionCommand._skill(_Operation.adopt, service);
  factory LifecycleActionCommand.skillReplace(SkillLifecycleService service) =>
      LifecycleActionCommand._skill(_Operation.replace, service);
  factory LifecycleActionCommand.skillRemove(SkillLifecycleService service) =>
      LifecycleActionCommand._skill(_Operation.remove, service);
  factory LifecycleActionCommand.skillRecover(SkillLifecycleService service) =>
      LifecycleActionCommand._skill(_Operation.recover, service);

  factory LifecycleActionCommand.agentInstall(AgentLifecycleService service) =>
      LifecycleActionCommand._agent(_Operation.install, service);
  factory LifecycleActionCommand.agentAdopt(AgentLifecycleService service) =>
      LifecycleActionCommand._agent(_Operation.adopt, service);
  factory LifecycleActionCommand.agentReplace(AgentLifecycleService service) =>
      LifecycleActionCommand._agent(_Operation.replace, service);
  factory LifecycleActionCommand.agentRemove(AgentLifecycleService service) =>
      LifecycleActionCommand._agent(_Operation.remove, service);
  factory LifecycleActionCommand.agentRecover(AgentLifecycleService service) =>
      LifecycleActionCommand._agent(_Operation.recover, service);

  LifecycleActionCommand._skill(
    _Operation operation,
    SkillLifecycleService service, {
    LifecycleConfirmation confirmation = _defaultConfirmation,
  }) : this._(_Resource.skill, operation, service, null, confirmation);
  LifecycleActionCommand._agent(
    _Operation operation,
    AgentLifecycleService service, {
    LifecycleConfirmation confirmation = _defaultConfirmation,
  }) : this._(_Resource.agent, operation, null, service, confirmation);

  LifecycleActionCommand._(
    this._resource,
    this._operation,
    this._skill,
    this._agent, [
    this._confirmation = _defaultConfirmation,
  ]) : super(
         mandatoryPositionals: [
           if (_operation == _Operation.install ||
               _operation == _Operation.adopt)
             if (_resource == _Resource.skill)
               _sourceDirectory
             else
               _sourceFile,
           if (_operation == _Operation.replace) ...[
             _installationId,
             if (_resource == _Resource.skill)
               _replacementDirectory
             else
               _sourceFile,
           ],
           if (_operation == _Operation.remove) _installationId,
           if (_operation == _Operation.restore ||
               _operation == _Operation.cleanup)
             _backupId,
         ],
         discretionaryPositionals: [
           if (_operation == _Operation.recover) _transactionId,
         ],
         options: [
           if (_resource == _Resource.skill) _skillScope else _agentScope,
           if (_operation == _Operation.install ||
               _operation == _Operation.adopt)
             if (_resource == _Resource.skill)
               _skillDestination
             else
               _agentDestination,
           if (_resource == _Resource.agent &&
               (_operation == _Operation.install ||
                   _operation == _Operation.adopt))
             _requiredHarness,
           if (_resource == _Resource.agent && _operation == _Operation.replace)
             _harness,
           if (_resource == _Resource.skill &&
               (_operation == _Operation.install ||
                   _operation == _Operation.adopt))
             _skillHarnesses,
           if (_resource == _Resource.agent && _operation == _Operation.install)
             _output,
           if (_operation == _Operation.recover) _recoveryAction,
           _format,
           _cwd,
           _projectRoot,
           _home,
           _claudeConfigDir,
           _codexHome,
           _stateDir,
           if (_resource == _Resource.agent) ...[_piAgentDir, _readRoots],
           if (_resource == _Resource.skill &&
               (_operation == _Operation.install ||
                   _operation == _Operation.adopt))
             _readRoots,
         ],
         flags: const [_dryRun, _yes, _interactive],
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

  static final _sourceDirectory = FolderPathPositional(
    'source-directory',
    description: 'Ordinary Skill source or existing installation directory.',
  );
  static final _replacementDirectory = FolderPathPositional(
    'source-directory',
    description: 'Ordinary replacement Skill source directory.',
  );
  static final _sourceFile = FilePathPositional(
    'native-file',
    suffixes: const ['.md', '.toml'],
    description: 'Native regular-file Agent definition.',
  );
  static final _installationId = NormalPositional('installation-id');
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
  static final _output = FilePathOption(
    'output',
    suffixes: const ['.md', '.toml'],
    description: 'Eligible Agent install output; source basename by default.',
  );
  static final _recoveryAction = ChoiceOption(
    'action',
    choices: RecoveryAction.values,
    description:
        'Persisted recovery transition; requires transaction ID and approval.',
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
    _Operation.install => 'Install a validated local resource copy.',
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
    readRoots:
        _resource == _Resource.agent ||
            _operation == _Operation.install ||
            _operation == _Operation.adopt
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
        case _Operation.install:
          return service.install(_skillInstall(valueOf, options));
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
      case _Operation.install:
        return service.install(_agentInstall(valueOf, options));
      case _Operation.adopt:
        return service.adopt(_agentInstall(valueOf, options));
      case _Operation.replace:
        return service.replace(
          LifecycleReplaceInput(
            options: options,
            installationId: _requiredId(
              valueOf(_installationId),
              'installation',
            ),
            source: valueOf(_sourceFile),
          ),
          harness: valueOf(_harness),
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

  SkillInstallInput _skillInstall(ValueOf valueOf, LifecycleOptions options) {
    final harnesses = valueOf(_skillHarnesses) ?? const <SkillHarness>[];
    return SkillInstallInput(
      options: options,
      source: valueOf(_sourceDirectory),
      destination: valueOf(_skillDestination),
      harnesses: harnesses,
    );
  }

  AgentInstallInput _agentInstall(ValueOf valueOf, LifecycleOptions options) {
    final harness = valueOf(_requiredHarness);
    return AgentInstallInput(
      options: options,
      source: valueOf(_sourceFile),
      harness: harness,
      destination: valueOf(_agentDestination),
      output: _operation == _Operation.install ? valueOf(_output) : null,
    );
  }

  String _requiredId(String value, String label) {
    final id = value.trim();
    if (id.isEmpty) throw MambaException('The $label ID must not be blank.');
    return id;
  }

  String _render(LifecycleResult result, LifecycleOutputFormat format) =>
      switch (format) {
        LifecycleOutputFormat.json => jsonEncode(result.envelope()),
        LifecycleOutputFormat.text => result.renderText(),
      };
}
