import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/installation/installation_plan.dart';
import 'src/pack/release_policy.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/pack_lifecycle_service.dart';

List<Command> packLifecycleCommands(
  PackResourceType resourceType,
  PackLifecycleService service, {
  bool canonical = false,
  void Function(String)? warning,
}) => [
  for (final operation in [
    PackOperation.install,
    PackOperation.update,
    PackOperation.remove,
    PackOperation.rollback,
    PackOperation.cleanup,
    if (canonical) PackOperation.validate,
  ])
    PackActionCommand(
      resourceType,
      operation,
      service,
      canonical: canonical,
      warning: warning,
    ),
];

final class PackActionCommand extends Command {
  PackActionCommand(
    this._resourceType,
    this._operation,
    this._service, {
    bool canonical = false,
    void Function(String)? warning,
  }) : _canonical = canonical,
       _warning = warning ?? stderr.writeln,
       super(
         mandatoryPositionals: [_pack],
         options: [
           _scope,
           _cwd,
           _projectRoot,
           _home,
           _state,
           _config,
           if (_operation != PackOperation.validate) _target,
           switch (_operation) {
             PackOperation.rollback => _rollbackOnly,
             PackOperation.remove ||
             PackOperation.sourceAssociate => _requiredOnly,
             _ => _only,
           },
           if (canonical) _type,
           if (_operation != PackOperation.validate) _method,
           _release,
           if (_operation != PackOperation.validate) _bump,
           if (_operation != PackOperation.validate) ...[
             _keepLocal,
             _replaceLocal,
             _approveRemoval,
             _allowFolder,
           ],
           if (_operation == PackOperation.sourceChange) _requiredTo,
           if (_operation == PackOperation.rollback) _requiredSnapshot,
           _format,
         ],
         flags: [
           _includePrerelease,
           if (_operation != PackOperation.validate) ...const [
             _savePolicy,
             _noSave,
             _skipNew,
             _includeNew,
             _localEdits,
           ],
           _dryRun,
           if (_operation != PackOperation.validate) _yes,
         ],
         conflicts: {
           if (_operation != PackOperation.validate)
             'include-new': const ['skip-new'],
           if (_operation == PackOperation.install ||
               _operation == PackOperation.update ||
               _operation == PackOperation.cleanup ||
               _operation == PackOperation.sourceChange)
             'only': const ['skip-new'],
         },
       );

  final bool _canonical;
  final void Function(String) _warning;
  final PackResourceType _resourceType;
  final PackOperation _operation;
  final PackLifecycleService _service;

  static final _pack = NormalPositional(
    'pack',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
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
  static final _only = RepeatableStringOption(
    'only',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
    description: 'Filter by native item name.',
  );
  static final _requiredOnly = RepeatableStringOption.required(
    'only',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
    description: 'Filter by native item name.',
  );
  static final _rollbackOnly = RepeatableStringOption.required(
    'only',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
    description: 'Select exactly one native item.',
  );
  static final _type = RepeatableChoiceOption(
    'type',
    PackResourceType.values,
    unique: true,
    description: 'Select resource kinds; defaults to skill and agent.',
  );
  static final _method = ChoiceOption(
    'method',
    choices: InstallationMethod.values,
  );
  static final _release = StringOption('release');
  static final _bump = ChoiceOption('bump', choices: ReleaseBump.values);
  static final _keepLocal = RepeatableStringOption(
    'keep-local',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
  );
  static final _replaceLocal = RepeatableStringOption(
    'replace-local',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
  );
  static final _approveRemoval = RepeatableStringOption(
    'approve-removal',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
  );
  static final _allowFolder = RepeatableStringOption(
    'allow-folder',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
  );
  static final _requiredTo = StringOption.required(
    'to',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
  );
  static final _requiredSnapshot = StringOption.required(
    'snapshot',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static const _includePrerelease = BooleanFlag('include-prerelease');
  static const _savePolicy = BooleanFlag('save-policy');
  static const _noSave = BooleanFlag('no-save');
  static const _skipNew = BooleanFlag('skip-new');
  static const _includeNew = BooleanFlag(
    'include-new',
    description: 'Include newly discovered resources.',
  );
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
    PackOperation.validate => 'validate',
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
    PackOperation.validate => 'Validate a configured pack.',
    PackOperation.configValidate => throw StateError('Not a pack action.'),
  };

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    if (!_canonical) {
      _warning(
        'Warning: ${_resourceType.name}s commands are deprecated; use pack with --type ${_resourceType.name}.',
      );
    }
    final format = valueOf(_format);
    final mutating = _operation != PackOperation.validate;
    final yes = mutating && valueOf(_yes);
    final only = switch (_operation) {
      PackOperation.rollback => valueOf(_rollbackOnly),
      PackOperation.remove ||
      PackOperation.sourceAssociate => valueOf(_requiredOnly),
      _ => valueOf(_only) ?? const <String>[],
    };
    final result = await _service.execute(
      PackLifecycleRequest(
        operation: _operation,
        resourceType: _resourceType,
        resourceTypes: _canonical
            ? (valueOf(_type) ?? PackResourceType.values)
            : [_resourceType],
        includeNew: mutating && valueOf(_includeNew),
        pack: valueOf(_pack),
        processWorkingDirectory: Directory.current.path,
        environment: Map<String, String>.unmodifiable(Platform.environment),
        scope: valueOf(_scope),
        cwd: valueOf(_cwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        stateDir: valueOf(_state),
        configPath: valueOf(_config),
        target: mutating ? valueOf(_target) : null,
        only: only,
        method: mutating ? valueOf(_method)?.wireName : null,
        release: valueOf(_release),
        bump: mutating ? valueOf(_bump)?.name : null,
        includePrerelease: valueOf(_includePrerelease),
        savePolicy: mutating && valueOf(_savePolicy),
        noSave: mutating && valueOf(_noSave),
        skipNew: mutating && valueOf(_skipNew),
        keepLocal: mutating
            ? valueOf(_keepLocal) ?? const <String>[]
            : const <String>[],
        replaceLocal: mutating
            ? valueOf(_replaceLocal) ?? const <String>[]
            : const <String>[],
        approveRemoval: mutating
            ? valueOf(_approveRemoval) ?? const <String>[]
            : const <String>[],
        allowFolder: mutating
            ? valueOf(_allowFolder) ?? const <String>[]
            : const <String>[],
        to: _operation == PackOperation.sourceChange
            ? valueOf(_requiredTo)
            : null,
        snapshot: _operation == PackOperation.rollback
            ? valueOf(_requiredSnapshot)
            : null,
        localEdits: mutating && valueOf(_localEdits),
        dryRun: valueOf(_dryRun),
        yes: yes,
        interactive:
            stdin.hasTerminal && !yes && format == LifecycleOutputFormat.text,
      ),
    );
    return switch (format) {
      LifecycleOutputFormat.json => jsonEncode(result.envelope()),
      LifecycleOutputFormat.text => result.renderText(),
    };
  }
}
