import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart'
    show LifecycleConfirmation, LifecycleOutputFormat, RecoveryAction;
import 'src/services/lifecycle_state_service.dart';
import 'src/services/skill_lifecycle_service.dart';

Future<bool> _defaultConfirmation(String prompt) async {
  stderr.write('$prompt [y/N] ');
  final answer = stdin.readLineSync()?.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

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
  final SkillLifecycleService _service;

  static final _source = FolderPathPositional('source-directory');
  static final _destination = ChoiceOption.required(
    'destination',
    choices: SkillDestination.values,
  );
  static final _mode = ChoiceOption.withDefault(
    'mode',
    choices: SkillMode.values,
    defaultValue: SkillMode.copy,
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
          _mode,
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
  String get name => 'install';
  @override
  String get shortDescription => 'Install a copied or linked Skill.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    _checkInteractive(format, valueOf(_interactive));
    final result = await _service.install(
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
        mode: valueOf(_mode),
      ),
    );
    return _render(result, format);
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
      () async => _service.remove(input(true, false)),
      _confirmation,
    );
    final result = await _service.remove(input(dryRun, approved));
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
