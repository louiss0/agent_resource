import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;

import 'package:mamba/mamba.dart';

import 'components/installation_approval.dart';

import 'installation_command_support.dart';
import 'lifecycle.dart'
    show LifecycleConfirmation, LifecycleOutputFormat, RecoveryAction;
import 'src/installation/installation_plan.dart';
import 'src/installation/installation_request.dart';
import 'src/services/acquisition_service.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/skill_installation_service.dart';
import 'src/services/skill_lifecycle_service.dart';

Future<bool> _defaultConfirmation(String prompt) =>
    InstallationApprovalComponent(label: prompt).render();

LifecycleOptions _options(
  LifecycleScope scope,
  String? cwd,
  String? projectRoot,
  String? home,
  String? claude,
  String? codex,
  String? state,
  List<String> readRoots,
  bool dryRun,
  bool approved,
) => LifecycleOptions(
  processWorkingDirectory: Directory.current.path,
  environment: Map<String, String>.unmodifiable(Platform.environment),
  scope: scope,
  cwd: cwd,
  projectRoot: projectRoot,
  home: home,
  claudeConfigDir: claude,
  codexHome: codex,
  stateDir: state,
  readRoots: readRoots,
  dryRun: dryRun,
  approved: approved,
);

String _render(LifecycleResult result, LifecycleOutputFormat format) =>
    switch (format) {
      LifecycleOutputFormat.json => jsonEncode(result.envelope()),
      LifecycleOutputFormat.text => result.renderText(),
    };

void _checkInteractive(LifecycleOutputFormat format, bool interactive) {
  if (interactive && format == LifecycleOutputFormat.json) {
    throw MambaException('--interactive and --format json conflict.');
  }
}

Future<bool> _confirmDestruction(
  bool interactive,
  bool dryRun,
  bool approved,
  Future<void> Function() preview,
  LifecycleConfirmation confirmation,
) async {
  if (!interactive || dryRun || approved) return approved;
  await preview();
  if (await confirmation('Apply this reviewed destructive operation?')) {
    return true;
  }
  throw MambaException(
    'Operation cancelled; live state is unchanged.',
    exitCode: 7,
  );
}

final class SkillInstallCommand extends Command {
  SkillInstallCommand(this._installation)
    : super(
        discretionaryPositionals: [_source],
        options: [
          _resources,
          _targets,
          _scope,
          _method,
          _ref,
          _subpath,
          _sourceKind,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
          _readRoots,
          _destination,
          _harness,
          _mode,
        ],
        flags: const [_allResources, _dryRun, _yes, _interactive],
        conflicts: const {
          'resource': ['all-resources'],
        },
        longDescription:
            'Install exact, discovered, or curated Skills with canonical content and tracked '
            'exposures (canonical), independent copies (copy), or durable local '
            'source links (source-link). Canonical content uses scope-specific '
            '.agents/skills; Codex consumes it directly and Claude receives a '
            'managed exposure link. Search skills/ and conventional harness folders '
            'with bounded recursive fallback. No implicit dependency '
            'installation, source execution, silent link fallback, or remote '
            'source-link is performed. Interactive user scope and canonical '
            'method are disclosed defaults. JSON and unattended execution '
            'require explicit planning choices and --yes unless --dry-run.',
      );

  final SkillInstallationService _installation;

  static final _source = NormalPositional.optional(
    'source',
    description:
        'Local path, Git URL, GitHub owner/repo, download, or archive.',
  );
  static final _resources = RepeatableStringOption(
    'resource',
    description: 'Exact catalog ID or discovered relative path; repeat to select several.',
  );
  static final _targets = RepeatableChoiceOption('target', const [
    InstallationTarget.claude,
    InstallationTarget.codex,
  ], description: 'Consuming harness; repeat to select both.');
  static final _scope = ChoiceOption(
    'scope',
    choices: const [LifecycleScope.project, LifecycleScope.user],
    description: 'Installation scope; user is the interactive default.',
  );
  static final _method = ChoiceOption(
    'method',
    choices: InstallationMethod.values,
    description: 'canonical, copy, or durable local source-link.',
  );
  static final _ref = StringOption(
    'ref',
    description: 'Git branch, tag, or commit; Git sources only.',
  );
  static final _subpath = StringOption(
    'subpath',
    description: 'Source-relative root; discovery stays within this boundary.',
  );
  static final _sourceKind = ChoiceOption(
    'source-kind',
    choices: AcquisitionSourceKind.values,
    description: 'Explicit collection or exact-resource intent.',
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');
  static final _readRoots = RepeatableFolderPathOption('read-root');
  static const _allResources = BooleanFlag(
    'all-resources',
    description: 'Select every curated or discovered Skill entry.',
  );
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');

  static final _destination = StringOption('destination', hidden: true);
  static final _harness = StringOption('harness', hidden: true);
  static final _mode = StringOption('mode', hidden: true);
  static const _interactive = BooleanFlag('interactive', hidden: true);

  @override
  String get name => 'install';

  @override
  String get shortDescription => 'Discover and install Skills interactively.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    _rejectRetired(valueOf);
    final format = valueOf(_format);
    final source = valueOf(_source);
    if (source != null && source.trim().isEmpty) {
      throw MambaException('The installation source must not be blank.');
    }
    final result = await _installation.run(
      InstallationWorkflowRequest(
        source: source,
        options: LifecycleOptions(
          processWorkingDirectory: Directory.current.path,
          environment: Map<String, String>.unmodifiable(Platform.environment),
          scope: valueOf(_scope) ?? LifecycleScope.user,
          cwd: valueOf(_cwd),
          projectRoot: valueOf(_projectRoot),
          home: valueOf(_home),
          claudeConfigDir: valueOf(_claude),
          codexHome: valueOf(_codex),
          stateDir: valueOf(_state),
          readRoots: valueOf(_readRoots) ?? const <String>[],
          dryRun: valueOf(_dryRun),
          approved: valueOf(_yes),
        ),
        sourceKind: valueOf(_sourceKind),
        resourceIds: (valueOf(_resources) ?? const <String>[]).toSet().toList(),
        allResources: valueOf(_allResources),
        targets: (valueOf(_targets) ?? const <InstallationTarget>[])
            .toSet()
            .toList(),
        method: valueOf(_method),
        profile: null,
        ref: valueOf(_ref),
        subpath: valueOf(_subpath),
        scopeExplicit: valueOf(_scope) != null,
      ),
      interactive:
          format == LifecycleOutputFormat.text &&
          _installation.hasInteractiveTerminal,
    );
    return renderInstallationResult(result, format);
  }

  void _rejectRetired(ValueOf valueOf) {
    if (valueOf(_destination) != null) {
      throw MambaException(
        '--destination is retired for skill install. Use --target for '
        'consumers and --method canonical|copy|source-link for ownership; '
        'application-owned compatibility paths replace destination selection.',
      );
    }
    if (valueOf(_harness) != null) {
      throw MambaException(
        '--harness is retired for skill install and is not consuming-target '
        'authorization. Use --target claude|codex instead.',
      );
    }
    if (valueOf(_mode) != null) {
      throw MambaException(
        '--mode is retired for skill install. Use --method copy for independent '
        'copies, source-link for a durable local source, or canonical.',
      );
    }
    if (valueOf(_interactive)) {
      throw MambaException(
        '--interactive is retired: interactive installation is the default on '
        'a usable text terminal. JSON and unattended mode stay explicit.',
      );
    }
  }
}

final class SkillAdoptCommand extends Command {
  final SkillLifecycleService _service;

  static final _source = FolderPathPositional('existing-directory');
  static final _destination = ChoiceOption.required(
    'destination',
    choices: SkillDestination.values,
  );
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.user,
  );
  static final _harnesses = RepeatableChoiceOption(
    'harness',
    SkillHarness.values,
    unique: true,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');
  static final _readRoots = RepeatableFolderPathOption('read-root');
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');
  static const _interactive = BooleanFlag('interactive');

  new(this._service)
    : super(
        mandatoryPositionals: [_source],
        options: [
          _destination,
          _scope,
          _harnesses,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
          _readRoots,
        ],
        flags: const [_dryRun, _yes, _interactive],
      );

  @override
  String get name => 'adopt';
  @override
  String get shortDescription => 'Adopt an existing copied or linked Skill.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    _checkInteractive(format, valueOf(_interactive));
    final result = await _service.adopt(
      SkillInstallInput(
        options: _options(
          valueOf(_scope),
          valueOf(_cwd),
          valueOf(_projectRoot),
          valueOf(_home),
          valueOf(_claude),
          valueOf(_codex),
          valueOf(_state),
          valueOf(_readRoots) ?? const [],
          valueOf(_dryRun),
          valueOf(_yes),
        ),
        source: valueOf(_source),
        destination: valueOf(_destination),
        harnesses: valueOf(_harnesses) ?? const [],
      ),
    );
    return _render(result, format);
  }
}

final class SkillReplaceCommand extends Command {
  final SkillLifecycleService _service;
  final LifecycleConfirmation _confirmation;

  static final _id = NormalPositional('installation-id');
  static final _source = FolderPathPositional('source-directory');
  static final _mode = ChoiceOption('mode', choices: SkillMode.values);
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.user,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');
  static const _interactive = BooleanFlag('interactive');

  new(this._service, {this._confirmation = _defaultConfirmation})
    : super(
        mandatoryPositionals: [_id, _source],
        options: [
          _mode,
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
        ],
        flags: const [_dryRun, _yes, _interactive],
      );

  @override
  String get name => 'replace';
  @override
  String get shortDescription => 'Replace an unchanged managed Skill.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    _checkInteractive(format, valueOf(_interactive));
    final interactive = valueOf(_interactive);
    final dryRun = valueOf(_dryRun);
    final yes = valueOf(_yes);
    LifecycleReplaceInput input(bool planned, bool approved) =>
        LifecycleReplaceInput(
          options: _options(
            valueOf(_scope),
            valueOf(_cwd),
            valueOf(_projectRoot),
            valueOf(_home),
            valueOf(_claude),
            valueOf(_codex),
            valueOf(_state),
            const [],
            planned,
            approved,
          ),
          installationId: valueOf(_id),
          source: valueOf(_source),
        );
    final approved = await _confirmDestruction(
      interactive,
      dryRun,
      yes,
      () async => _service.replace(input(true, false), mode: valueOf(_mode)),
      _confirmation,
    );
    final result = await _service.replace(
      input(dryRun, approved),
      mode: valueOf(_mode),
    );
    return _render(result, format);
  }
}

final class SkillRemoveCommand extends Command {
  final SkillLifecycleService _service;
  final LifecycleConfirmation _confirmation;

  static final _id = NormalPositional('installation-id');
  static final _target = ChoiceOption(
    'target',
    choices: SkillHarness.values,
    description: 'Detach one managed canonical exposure (Claude only).',
  );
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.user,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');
  static const _interactive = BooleanFlag('interactive');

  new(this._service, {this._confirmation = _defaultConfirmation})
    : super(
        mandatoryPositionals: [_id],
        options: [
          _target,
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
        ],
        flags: const [_dryRun, _yes, _interactive],
      );

  @override
  String get name => 'remove';
  @override
  String get shortDescription => 'Remove an unchanged managed Skill entry.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    _checkInteractive(format, valueOf(_interactive));
    final interactive = valueOf(_interactive);
    final dryRun = valueOf(_dryRun);
    final yes = valueOf(_yes);
    LifecycleIdInput input(bool planned, bool approved) => LifecycleIdInput(
      options: _options(
        valueOf(_scope),
        valueOf(_cwd),
        valueOf(_projectRoot),
        valueOf(_home),
        valueOf(_claude),
        valueOf(_codex),
        valueOf(_state),
        const [],
        planned,
        approved,
      ),
      id: valueOf(_id),
    );
    final approved = await _confirmDestruction(
      interactive,
      dryRun,
      yes,
      () async => _service.remove(input(true, false), target: valueOf(_target)),
      _confirmation,
    );
    final result = await _service.remove(
      input(dryRun, approved),
      target: valueOf(_target),
    );
    return _render(result, format);
  }
}

final class SkillRecoverCommand extends Command {
  final SkillLifecycleService _service;
  final LifecycleConfirmation _confirmation;

  static final _id = NormalPositional.optional('transaction-id');
  static final _action = ChoiceOption('action', choices: RecoveryAction.values);
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.user,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');
  static const _interactive = BooleanFlag('interactive');

  new(this._service, {this._confirmation = _defaultConfirmation})
    : super(
        discretionaryPositionals: [_id],
        options: [
          _action,
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
        ],
        flags: const [_dryRun, _yes, _interactive],
      );

  @override
  String get name => 'recover';
  @override
  String get shortDescription => 'Inspect or recover Skill transactions.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    _checkInteractive(format, valueOf(_interactive));
    final action = valueOf(_action)?.name;
    final interactive = valueOf(_interactive);
    final dryRun = valueOf(_dryRun);
    final yes = valueOf(_yes);
    LifecycleOptions options(bool planned, bool approved) => _options(
      valueOf(_scope),
      valueOf(_cwd),
      valueOf(_projectRoot),
      valueOf(_home),
      valueOf(_claude),
      valueOf(_codex),
      valueOf(_state),
      const [],
      planned,
      approved,
    );
    final approved = action == null
        ? yes
        : await _confirmDestruction(
            interactive,
            dryRun,
            yes,
            () async => _service.recover(
              options(true, false),
              transactionId: valueOf(_id),
              action: action,
            ),
            _confirmation,
          );
    final result = await _service.recover(
      options(dryRun, approved),
      transactionId: valueOf(_id),
      action: action,
    );
    return _render(result, format);
  }
}

final class SkillBackupCommand extends GroupCommand {
  SkillBackupCommand(SkillLifecycleService service)
    : super([
        SkillBackupListCommand(service),
        SkillBackupRestoreCommand(service),
        SkillBackupCleanupCommand(service),
      ]);

  @override
  String get name => 'backup';
  @override
  String get shortDescription => 'Manage retained Skill backup evidence.';
}

final class SkillBackupListCommand extends Command {
  final SkillLifecycleService _service;

  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.user,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');

  new(this._service)
    : super(
        options: [
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
        ],
      );

  @override
  String get name => 'list';
  @override
  String get shortDescription => 'List retained Skill backups.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final result = await _service.backupList(
      _options(
        valueOf(_scope),
        valueOf(_cwd),
        valueOf(_projectRoot),
        valueOf(_home),
        valueOf(_claude),
        valueOf(_codex),
        valueOf(_state),
        const [],
        false,
        false,
      ),
    );
    return _render(result, valueOf(_format));
  }
}

final class SkillBackupRestoreCommand extends Command {
  final SkillLifecycleService _service;
  final LifecycleConfirmation _confirmation;

  static final _id = NormalPositional('backup-id');
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.user,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');
  static const _interactive = BooleanFlag('interactive');

  new(this._service, {this._confirmation = _defaultConfirmation})
    : super(
        mandatoryPositionals: [_id],
        options: [
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
        ],
        flags: const [_dryRun, _yes, _interactive],
      );

  @override
  String get name => 'restore';
  @override
  String get shortDescription => 'Restore a retained Skill artifact.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    _checkInteractive(format, valueOf(_interactive));
    final interactive = valueOf(_interactive);
    final dryRun = valueOf(_dryRun);
    final yes = valueOf(_yes);
    LifecycleIdInput input(bool planned, bool approved) => LifecycleIdInput(
      options: _options(
        valueOf(_scope),
        valueOf(_cwd),
        valueOf(_projectRoot),
        valueOf(_home),
        valueOf(_claude),
        valueOf(_codex),
        valueOf(_state),
        const [],
        planned,
        approved,
      ),
      id: valueOf(_id),
    );
    final approved = await _confirmDestruction(
      interactive,
      dryRun,
      yes,
      () async => _service.restore(input(true, false)),
      _confirmation,
    );
    final result = await _service.restore(input(dryRun, approved));
    return _render(result, format);
  }
}

final class SkillBackupCleanupCommand extends Command {
  final SkillLifecycleService _service;
  final LifecycleConfirmation _confirmation;

  static final _id = NormalPositional('backup-id');
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.user,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');
  static const _interactive = BooleanFlag('interactive');

  new(this._service, {this._confirmation = _defaultConfirmation})
    : super(
        mandatoryPositionals: [_id],
        options: [
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
        ],
        flags: const [_dryRun, _yes, _interactive],
      );

  @override
  String get name => 'cleanup';
  @override
  String get shortDescription => 'Clean intact retained Skill evidence.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    _checkInteractive(format, valueOf(_interactive));
    final interactive = valueOf(_interactive);
    final dryRun = valueOf(_dryRun);
    final yes = valueOf(_yes);
    LifecycleIdInput input(bool planned, bool approved) => LifecycleIdInput(
      options: _options(
        valueOf(_scope),
        valueOf(_cwd),
        valueOf(_projectRoot),
        valueOf(_home),
        valueOf(_claude),
        valueOf(_codex),
        valueOf(_state),
        const [],
        planned,
        approved,
      ),
      id: valueOf(_id),
    );
    final approved = await _confirmDestruction(
      interactive,
      dryRun,
      yes,
      () async => _service.cleanup(input(true, false)),
      _confirmation,
    );
    final result = await _service.cleanup(input(dryRun, approved));
    return _render(result, format);
  }
}
