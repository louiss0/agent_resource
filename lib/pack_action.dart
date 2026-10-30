import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/lifecycle_state_service.dart';
import 'src/services/pack_lifecycle_service.dart';

List<Command> packLifecycleCommands(
  PackResourceType resourceType,
  PackLifecycleService service,
) => [
  for (final operation in const [
    PackOperation.install,
    PackOperation.update,
    PackOperation.remove,
    PackOperation.rollback,
    PackOperation.cleanup,
  ])
    PackActionCommand(resourceType, operation, service),
];

final class PackActionCommand extends Command {
  PackActionCommand(this._resourceType, this._operation, this._service)
    : super(
        mandatoryPositionals: [_pack],
        options: [
          _scope,
          _cwd,
          _projectRoot,
          _home,
          _state,
          _config,
          _target,
          _only,
          _method,
          _release,
          _bump,
          _keepLocal,
          _replaceLocal,
          _approveRemoval,
          _allowFolder,
          _to,
          _snapshot,
          _format,
        ],
        flags: const [
          _includePrerelease,
          _savePolicy,
          _noSave,
          _skipNew,
          _localEdits,
          _dryRun,
          _yes,
        ],
      );

  final PackResourceType _resourceType;
  final PackOperation _operation;
  final PackLifecycleService _service;

  static final _pack = NormalPositional(
    'pack',
    description: 'Configured pack key, such as owner/repository.',
  );
  static final _scope = ChoiceOption(
    'scope',
    choices: const [LifecycleScope.project, LifecycleScope.user],
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _state = FolderPathOption('state-dir');
  static final _config = FilePathOption('config');
  static final _target = StringOption('target');
  static final _only = RepeatableStringOption('only');
  static final _method = StringOption(
    'method',
    regex: RegExp(r'^(canonical|copy|source-link)$'),
  );
  static final _release = StringOption('release');
  static final _bump = StringOption(
    'bump',
    regex: RegExp(r'^(patch|minor|major)$'),
  );
  static final _keepLocal = RepeatableStringOption('keep-local');
  static final _replaceLocal = RepeatableStringOption('replace-local');
  static final _approveRemoval = RepeatableStringOption('approve-removal');
  static final _allowFolder = RepeatableStringOption('allow-folder');
  static final _to = StringOption('to');
  static final _snapshot = StringOption('snapshot');
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static const _includePrerelease = BooleanFlag('include-prerelease');
  static const _savePolicy = BooleanFlag('save-policy');
  static const _noSave = BooleanFlag('no-save');
  static const _skipNew = BooleanFlag('skip-new');
  static const _localEdits = BooleanFlag('local-edits');
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');

  @override
  String get name => switch (_operation) {
    PackOperation.install => 'install',
    PackOperation.update => 'update',
    PackOperation.sourceAssociate => 'associate',
    PackOperation.sourceChange => 'change',
    PackOperation.remove => 'remove',
    PackOperation.rollback => 'rollback',
    PackOperation.cleanup => 'cleanup',
    PackOperation.configValidate => throw StateError('Not a pack action.'),
  };

  @override
  String get shortDescription => switch (_operation) {
    PackOperation.install =>
      'Install resources from an exact configured pack lock.',
    PackOperation.update => 'Review and apply source-aware pack updates.',
    PackOperation.sourceAssociate =>
      'Associate adopted resources with a configured source.',
    PackOperation.sourceChange => 'Review a pack source or track change.',
    PackOperation.remove =>
      'Remove explicitly selected managed pack resources.',
    PackOperation.rollback => 'Restore one resource by Recorded snapshot ref.',
    PackOperation.cleanup => 'Review and prune eligible retained pack content.',
    PackOperation.configValidate => throw StateError('Not a pack action.'),
  };

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final result = await _service.execute(
      PackLifecycleRequest(
        operation: _operation,
        resourceType: _resourceType,
        pack: valueOf(_pack),
        processWorkingDirectory: Directory.current.path,
        environment: Map<String, String>.unmodifiable(Platform.environment),
        scope: valueOf(_scope),
        cwd: valueOf(_cwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        stateDir: valueOf(_state),
        configPath: valueOf(_config),
        target: valueOf(_target),
        only: valueOf(_only) ?? const <String>[],
        method: valueOf(_method),
        release: valueOf(_release),
        bump: valueOf(_bump),
        includePrerelease: valueOf(_includePrerelease),
        savePolicy: valueOf(_savePolicy),
        noSave: valueOf(_noSave),
        skipNew: valueOf(_skipNew),
        keepLocal: valueOf(_keepLocal) ?? const <String>[],
        replaceLocal: valueOf(_replaceLocal) ?? const <String>[],
        approveRemoval: valueOf(_approveRemoval) ?? const <String>[],
        allowFolder: valueOf(_allowFolder) ?? const <String>[],
        to: valueOf(_to),
        snapshot: valueOf(_snapshot),
        localEdits: valueOf(_localEdits),
        dryRun: valueOf(_dryRun),
        yes: valueOf(_yes),
        interactive:
            stdin.hasTerminal &&
            !valueOf(_yes) &&
            format == LifecycleOutputFormat.text,
      ),
    );
    return switch (format) {
      LifecycleOutputFormat.json => jsonEncode(result.envelope()),
      LifecycleOutputFormat.text => result.renderText(),
    };
  }
}
