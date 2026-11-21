import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'components/installation_approval.dart';
import 'src/installation/installation_plan.dart';
import 'src/pack/release_policy.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/pack_lifecycle_service.dart';

List<Command> packLifecycleCommands(
  PackResourceType resourceType,
  PackLifecycleService service, {
  bool canonical = false,
  fslib.FileSystem fileSystem = const local.LocalFileSystem(),
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
      fileSystem: fileSystem,
    ),
];

/// The options that every pack command shares.
final class _PackContextOptions {
  static final pack = NormalPositional(
    'pack',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
    description: 'Configured pack key, such as owner/repository.',
  );
  static final scope = ChoiceOption(
    'scope',
    choices: const [LifecycleScope.project, LifecycleScope.user],
  );
  static final cwd = FolderPathOption('cwd');
  static final projectRoot = FolderPathOption('project-root');
  static final home = FolderPathOption('home');
  static final geminiDir = FolderPathOption('gemini-dir');
  static final state = FolderPathOption('state-dir');
  static final config = FilePathOption('config');
}

final class PackActionCommand extends Command {
  PackActionCommand(
    this._resourceType,
    this._operation,
    this._service, {
    bool canonical = false,
    this._fileSystem = const local.LocalFileSystem(),
    bool Function()? stdinIsTerminal,
    bool Function()? stdoutIsTerminal,
    Future<bool> Function()? offerUserScope,
  }) : _offerUserScope = offerUserScope ?? _defaultOfferUserScope,
       _stdinIsTerminal = stdinIsTerminal ?? (() => stdin.hasTerminal),
       _stdoutIsTerminal = stdoutIsTerminal ?? (() => stdout.hasTerminal),
       _canonical = canonical,
       super(
         mandatoryPositionals: [_PackContextOptions.pack],
         options: [
           _PackContextOptions.scope,
           _PackContextOptions.cwd,
           _PackContextOptions.projectRoot,
           _PackContextOptions.home,
           _PackContextOptions.geminiDir,
           _PackContextOptions.state,
           _PackContextOptions.config,
           if (_operation != PackOperation.validate) ...[_target, _harness],
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
           _approveMcpCollision,
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

  final fslib.FileSystem _fileSystem;
  final Future<bool> Function() _offerUserScope;
  final bool Function() _stdinIsTerminal;
  final bool Function() _stdoutIsTerminal;
  static Future<bool> _defaultOfferUserScope() =>
      const InstallationApprovalComponent(
        label: 'Project context is unavailable. Use user scope instead?',
      ).render();

  final bool _canonical;
  final PackResourceType _resourceType;
  final PackOperation _operation;
  final PackLifecycleService _service;
  static final _target = StringOption('target');
  static final _harness = StringOption(
    'harness',
    description: 'The consuming harness of the pack operation.',
  );
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
    description:
        'Select resource kinds; defaults to skill and agent. The prompt '
        'kind installs valid skill-backed Prompts through the native Skill '
        'installation.',
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
  static final _approveMcpCollision = RepeatableStringOption(
    'approve-mcp-collision',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
    description:
        'Explicitly resolve a reviewed MCP name collision by server name.',
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
    final format = valueOf(_format);
    final mutating = _operation != PackOperation.validate;
    final yes = mutating && valueOf(_yes);
    final interactive =
        _stdinIsTerminal() &&
        _stdoutIsTerminal() &&
        !yes &&
        format == LifecycleOutputFormat.text;
    final resolvedOptions = await resolveInteractiveUserScope(
      fileSystem: _fileSystem,
      interactive: interactive,
      scopeExplicit: valueOf(_PackContextOptions.scope) != null,
      offerUserScope: _offerUserScope,
      options: LifecycleOptions(
        processWorkingDirectory: _fileSystem.currentDirectory.path,
        environment: Map<String, String>.unmodifiable(Platform.environment),
        scope: valueOf(_PackContextOptions.scope) ?? LifecycleScope.project,
        cwd: valueOf(_PackContextOptions.cwd),
        projectRoot: valueOf(_PackContextOptions.projectRoot),
        home: valueOf(_PackContextOptions.home),
        geminiDir: valueOf(_PackContextOptions.geminiDir),
        stateDir: valueOf(_PackContextOptions.state),
      ),
    );
    final config = valueOf(_PackContextOptions.config);
    if (resolvedOptions.cwd != valueOf(_PackContextOptions.cwd) &&
        config != null &&
        !_fileSystem.path.isAbsolute(config)) {
      throw MambaException(
        'A user-scope fallback with unavailable cwd requires an absolute --config path.',
        exitCode: 4,
      );
    }
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
            ? (valueOf(_type) ?? packDefaultResourceTypes)
            : [_resourceType],
        includeNew: mutating && valueOf(_includeNew),
        pack: valueOf(_PackContextOptions.pack),
        processWorkingDirectory: resolvedOptions.processWorkingDirectory,
        environment: Map<String, String>.unmodifiable(Platform.environment),
        scopeExplicit: valueOf(_PackContextOptions.scope) != null,
        scope:
            valueOf(_PackContextOptions.scope) ??
            (resolvedOptions.scope == LifecycleScope.user
                ? LifecycleScope.user
                : null),
        cwd: resolvedOptions.cwd,
        projectRoot: resolvedOptions.projectRoot,
        home: valueOf(_PackContextOptions.home),
        geminiDir: valueOf(_PackContextOptions.geminiDir),
        stateDir: valueOf(_PackContextOptions.state),
        configPath: valueOf(_PackContextOptions.config),
        target: mutating ? valueOf(_harness) ?? valueOf(_target) : null,
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
        approveMcpCollision: valueOf(_approveMcpCollision) ?? const <String>[],
        to: _operation == PackOperation.sourceChange
            ? valueOf(_requiredTo)
            : null,
        snapshot: _operation == PackOperation.rollback
            ? valueOf(_requiredSnapshot)
            : null,
        localEdits: mutating && valueOf(_localEdits),
        dryRun: valueOf(_dryRun),
        yes: yes,
        interactive: interactive,
      ),
    );
    return switch (format) {
      LifecycleOutputFormat.json => jsonEncode(result.envelope()),
      LifecycleOutputFormat.text => result.renderText(),
    };
  }
}

/// Reports the discovered candidates of a configured pack.
///
/// The discovery is a bounded read-only view: it never writes a management
/// state, never enrolls a membership and never advances an inventory.
final class PackDiscoverCommand extends Command {
  PackDiscoverCommand(
    this._service, {
    this._fileSystem = const local.LocalFileSystem(),
  }) : super(
         mandatoryPositionals: [_PackContextOptions.pack],
         options: [
           _PackContextOptions.scope,
           _PackContextOptions.cwd,
           _PackContextOptions.projectRoot,
           _PackContextOptions.home,
           _PackContextOptions.geminiDir,
           _PackContextOptions.state,
           _PackContextOptions.config,
           _target,
           PackActionCommand._harness,
           _type,
           _format,
         ],
       );

  final fslib.FileSystem _fileSystem;
  final PackLifecycleService _service;
  static final _target = StringOption(
    'target',
    description:
        'The consuming harness of the discovery. A standalone template needs '
        'an explicit target or a declared native profile.',
  );
  static final _type = RepeatableChoiceOption(
    'type',
    PackResourceType.values,
    unique: true,
    description:
        'Select resource kinds; defaults to skill, agent and prompt. The '
        'prompt kind reports the sources that are a Prompt in a consumer view.',
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );

  @override
  String get name => 'discover';

  @override
  String get shortDescription =>
      'Report the discovered candidates of a configured pack.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final report = await _service.discover(
      PackDiscoveryRequest(
        pack: valueOf(_PackContextOptions.pack),
        types: valueOf(_type) ?? const <PackResourceType>[],
        target: valueOf(PackActionCommand._harness) ?? valueOf(_target),
        processWorkingDirectory: _fileSystem.currentDirectory.path,
        environment: Map<String, String>.unmodifiable(Platform.environment),
        scope: valueOf(_PackContextOptions.scope),
        cwd: valueOf(_PackContextOptions.cwd),
        projectRoot: valueOf(_PackContextOptions.projectRoot),
        home: valueOf(_PackContextOptions.home),
        geminiDir: valueOf(_PackContextOptions.geminiDir),
        stateDir: valueOf(_PackContextOptions.state),
        configPath: valueOf(_PackContextOptions.config),
      ),
    );
    return switch (format) {
      LifecycleOutputFormat.json => jsonEncode(report.toJson()),
      LifecycleOutputFormat.text => report.renderText(),
    };
  }
}
