import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../agent_inspection.dart';
import '../agent_inventory.dart';
import '../skill_files.dart';
import 'lifecycle_state_service.dart';

enum AgentDestination { native, shared }

final class AgentInstallInput {
  const new({
    required this.options,
    required this.source,
    required this.harness,
    this.destination = AgentDestination.native,
    this.output,
  });

  final LifecycleOptions options;
  final String source;
  final AgentHarness harness;
  final AgentDestination destination;
  final String? output;
}

/// Regular-file Agent lifecycle using the existing native inspection and
/// bounded inventory engines.
interface class AgentLifecycleService {
  AgentLifecycleService({
    LifecycleStateService? state,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : _fileSystem = fileSystem,
       state = state ?? LifecycleStateService(io: LifecycleIO(fs: fileSystem));

  fslib.FileSystem get fileSystem => _fileSystem;

  final fslib.FileSystem _fileSystem;
  final LifecycleStateService state;

  AgentInventoryReport managementAware(
    AgentInventoryReport report,
    AgentInventoryInput input,
  ) {
    final occurrences = report.occurrences
        .map((occurrence) => Map<String, Object?>.from(occurrence))
        .toList();
    final scopes = switch (input.scope) {
      AgentScope.project => const [LifecycleScope.project],
      AgentScope.user => const [LifecycleScope.user],
      AgentScope.all => const [LifecycleScope.project, LifecycleScope.user],
    };
    var ownershipUnverified = false;
    for (final scope in scopes) {
      final options = LifecycleOptions(
        processWorkingDirectory: input.processWorkingDirectory,
        environment: input.environment,
        scope: scope,
        cwd: input.cwd,
        projectRoot: input.projectRoot,
        home: input.home,
        claudeConfigDir: input.claudeConfigDir,
        codexHome: input.codexHome,
        piAgentDir: input.piAgentDir,
        stateDir: input.stateDir,
        readRoots: input.readRoots,
      );
      final context = LifecycleContext.resolve(
        options,
        fileSystem: _fileSystem,
      );
      var records = <InstallationRecord>[];
      try {
        records = state.records(context);
      } on Exception {
        ownershipUnverified = true;
        for (final occurrence in occurrences.where(
          (occurrence) => occurrence['scope'] == scope.name,
        )) {
          occurrence['management'] = 'ownershipUnverified';
          occurrence['modification'] = 'unableToVerify';
        }
      }
      for (final occurrence in occurrences) {
        if (occurrence['scope'] != scope.name ||
            occurrence['binding'] != null ||
            occurrence['eligibility'] != 'native') {
          continue;
        }
        final path = occurrence['path'];
        if (path is! String) continue;
        final matches = records.where(
          (record) =>
              record.kind == ArtifactKind.agentFile &&
              record.lifecycle == 'live' &&
              _fileSystem.path.equals(record.location, path),
        );
        if (matches.length > 1) {
          occurrence['management'] = 'ownershipUnverified';
          occurrence['modification'] = 'unableToVerify';
          continue;
        }
        if (matches.isEmpty) continue;
        final record = matches.single;
        occurrence['installationId'] = record.installationId;
        occurrence['management'] = 'managed';
        occurrence['modification'] = input.verify
            ? state.verify(record).name
            : 'notVerified';
      }
      for (final record in records.where(
        (record) =>
            record.kind == ArtifactKind.agentFile &&
            (input.harness == null ||
                record.nativeProfile == input.harness!.name),
      )) {
        final alreadyVisible = occurrences.any(
          (occurrence) =>
              occurrence['path'] is String &&
              _fileSystem.path.equals(
                occurrence['path']! as String,
                record.location,
              ),
        );
        if (alreadyVisible) continue;
        final missing =
            skillEntityType(
              record.location,
              followLinks: false,
              fs: _fileSystem,
            ) ==
            FileSystemEntityType.notFound;
        if (record.lifecycle == 'live' && !missing) continue;
        occurrences.add(<String, Object?>{
          'occurrenceId': 'managed:${record.installationId}',
          'installationId': record.installationId,
          'path': record.location,
          'root': record.nativeRoot,
          'scope': scope.name,
          'harness': record.nativeProfile,
          'destination': record.nativeDestination,
          'form': record.nativeForm,
          'binding': null,
          'eligibility': 'tracked-missing',
          'identity': <String, Object?>{
            'name': <String, Object?>{
              'declared': record.name,
              'resolved': record.name,
              'provenance': 'managed-record',
            },
            'description': <String, Object?>{
              'declared': null,
              'resolved': null,
              'provenance': 'not-read',
            },
          },
          'validation': <String, Object?>{
            'status': 'notRequested',
            'coverage': const <String>[],
            'diagnostics': const <Object?>[],
          },
          'management': 'managed',
          'modification': input.verify
              ? missing
                    ? 'missing'
                    : state.verify(record).name
              : 'notVerified',
        });
      }
    }
    occurrences.sort(
      (left, right) => '${left['path']}'.compareTo('${right['path']}'),
    );
    final coverage = Map<String, Object?>.from(report.coverage);
    coverage['management'] = ownershipUnverified
        ? 'ownershipUnverified'
        : 'complete';
    coverage['exclusions'] = [
      for (final exclusion in report.coverage['exclusions']! as List<Object?>)
        if (exclusion !=
            'ownership, lifecycle identity, and modification verification')
          exclusion,
    ];
    return report.withManagement(
      managedOccurrences: occurrences,
      managementVerification: input.verify ? 'requested' : 'notVerified',
      managementCoverage: coverage,
    );
  }

  LifecycleResource installationResource(AgentHarness harness) =>
      _AgentResource(harness, this);

  String installRoot(LifecycleContext context, AgentHarness harness) =>
      _defaultRoot(context, harness, AgentDestination.native);

  Future<LifecycleResult> install(AgentInstallInput input) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: _fileSystem,
    );
    _requireMutationScope(context);
    final source = context.resolvePath(input.source);
    _requireExtension(source, input.harness);
    final root = _defaultRoot(context, input.harness, input.destination);
    final location = input.output == null
        ? _fileSystem.path.normalize(
            _fileSystem.path.join(root, _fileSystem.path.basename(source)),
          )
        : context.resolvePath(input.output!);
    final authority = input.output == null
        ? root
        : _eligibleAuthority(
            context,
            location,
            input.harness,
            input.destination,
          );
    return state.install(
      resource: _AgentResource(input.harness, this),
      context: context,
      source: source,
      location: location,
      nativeRoot: authority,
      nativeDestination: input.destination.name,
    );
  }

  Future<LifecycleResult> adopt(AgentInstallInput input) async {
    if (input.output != null) {
      throw MambaException('--output applies only to Agent installation.');
    }
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: _fileSystem,
    );
    _requireMutationScope(context);
    final location = context.resolvePath(input.source);
    final authority = _eligibleAuthority(
      context,
      location,
      input.harness,
      input.destination,
    );
    return state.adopt(
      resource: _AgentResource(input.harness, this),
      context: context,
      location: location,
      nativeRoot: authority,
      nativeDestination: input.destination.name,
    );
  }

  /// Adopts an explicitly referenced Codex role definition within the selected
  /// project or Codex-home boundary without relocating or rewriting its bytes.
  Future<LifecycleResult> adoptBoundDefinition(AgentInstallInput input) async {
    if (input.harness != AgentHarness.codex) {
      throw MambaException(
        'Bound-definition adoption is supported only for Codex roles.',
        exitCode: 4,
      );
    }
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: _fileSystem,
    );
    _requireMutationScope(context);
    final location = context.resolvePath(input.source);
    final authority = _eligibleBoundDefinitionAuthority(context, location);
    return state.adopt(
      resource: _AgentResource(AgentHarness.codex, this),
      context: context,
      location: location,
      nativeRoot: authority,
      nativeDestination: 'codex-bound',
    );
  }

  String _eligibleBoundDefinitionAuthority(
    LifecycleContext context,
    String location,
  ) {
    _requireExtension(location, AgentHarness.codex);
    final root = _fileSystem.path.normalize(
      context.scope == LifecycleScope.project
          ? context.projectRoot
          : context.codexRoot(),
    );
    if (!_fileSystem.path.isWithin(root, location) ||
        _fileSystem.path.basename(location) == 'config.toml' ||
        _fileSystem.path.basename(location) == 'auth.json' ||
        _fileSystem.path.split(location).contains('.agent-resource')) {
      throw MambaException(
        'The Codex bound definition is outside its eligible project/configuration boundary.',
        exitCode: 4,
      );
    }
    return root;
  }

  Future<LifecycleResult> replace(
    LifecycleReplaceInput input, {
    AgentHarness? harness,
  }) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: _fileSystem,
    );
    _requireMutationScope(context);
    final record = state.recordById(context, input.installationId);
    final storedHarness = _recordHarness(record);
    if (harness != null && harness != storedHarness) {
      throw MambaException(
        'A stored Agent installation cannot be retargeted to another harness.',
        exitCode: 4,
      );
    }
    return state.replace(
      resource: _AgentResource(storedHarness, this),
      context: context,
      installationId: input.installationId,
      source: context.resolvePath(input.source),
    );
  }

  Future<LifecycleResult> remove(LifecycleIdInput input) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: _fileSystem,
    );
    _requireMutationScope(context);
    return state.remove(
      resource: _AgentResource(AgentHarness.claude, this, true),
      context: context,
      installationId: input.id,
    );
  }

  Future<LifecycleResult> restore(LifecycleIdInput input) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: _fileSystem,
    );
    _requireMutationScope(context);
    final record = state.installationForBackup(
      context,
      input.id,
      ArtifactKind.agentFile,
    );
    return state.restore(
      resource: _AgentResource(_recordHarness(record), this),
      context: context,
      backupId: input.id,
    );
  }

  Future<LifecycleResult> recover(
    LifecycleOptions options, {
    String? transactionId,
    String? action,
  }) => state.recover(
    resource: _AgentResource(AgentHarness.claude, this, true),
    context: LifecycleContext.resolve(options, fileSystem: _fileSystem),
    transactionId: transactionId,
    action: action,
  );

  Future<LifecycleResult> backupList(LifecycleOptions options) =>
      state.backupList(
        LifecycleContext.resolve(options, fileSystem: _fileSystem),
        ArtifactKind.agentFile,
      );

  Future<LifecycleResult> cleanup(LifecycleIdInput input) => state.cleanup(
    resource: _AgentResource(AgentHarness.claude, this, true),
    context: LifecycleContext.resolve(input.options, fileSystem: _fileSystem),
    backupId: input.id,
  );

  /// Inspects an unchanged recorded Agent source without acquiring any new
  /// ownership or weakening the baseline check.
  AgentInspectionReport inspectManagedSource({
    required LifecycleOptions options,
    required String installationId,
  }) {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final record = state.recordById(context, installationId);
    if (record.kind != ArtifactKind.agentFile ||
        record.nativeProfile == null ||
        state.verify(record) != ModificationStatus.unchanged) {
      throw MambaException(
        'The managed source must be an unchanged native Agent file.',
        exitCode: 4,
      );
    }
    return inspectNativeAgent(
      AgentInspectionInput(
        nativeFile: record.location,
        harness: AgentHarness.values.singleWhere(
          (value) => value.name == record.nativeProfile,
        ),
        cwd: context.cwd,
      ),
      operation: AgentOperation.inspect,
      fileSystem: _fileSystem,
    );
  }

  /// Checks native root, destination, reserved-path, extension, and scope
  /// eligibility without creating any artifact.
  void validateTarget({
    required LifecycleOptions options,
    required AgentHarness harness,
    required AgentDestination destination,
    required String output,
  }) {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    _requireMutationScope(context);
    _eligibleAuthority(
      context,
      context.resolvePath(output),
      harness,
      destination,
    );
  }

  /// Provides a protected native-volume candidate to the ordinary lifecycle
  /// operation. No candidate bytes are written before privacy is established.
  Future<T> withStagedCandidate<T>({
    required LifecycleOptions options,
    required AgentHarness harness,
    required AgentDestination destination,
    required String output,
    required String content,
    required Future<T> Function(String path) body,
  }) {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    _requireMutationScope(context);
    final location = context.resolvePath(output);
    final authority = _eligibleAuthority(
      context,
      location,
      harness,
      destination,
    );
    return state.withStagedSource(
      nativeRoot: authority,
      name: 'candidate${harness == AgentHarness.codex ? '.toml' : '.md'}',
      bytes: utf8.encode(content),
      body: body,
    );
  }

  String _defaultRoot(
    LifecycleContext context,
    AgentHarness harness,
    AgentDestination destination,
  ) {
    if (destination == AgentDestination.shared) {
      if (harness != AgentHarness.pi) {
        throw MambaException(
          'Shared Agent destinations are supported only for common-Pi project files.',
          exitCode: 4,
        );
      }
      return _fileSystem.path.normalize(context.piSharedAgentsRoot());
    }
    return _fileSystem.path.normalize(switch (harness) {
      AgentHarness.claude =>
        context.scope == LifecycleScope.project
            ? context.claudeAgentsRoot()
            : _fileSystem.path.join(context.claudeConfigRoot(), 'agents'),
      AgentHarness.codex =>
        context.scope == LifecycleScope.project
            ? context.codexAgentsRoot()
            : _fileSystem.path.join(context.codexRoot(), 'agents'),
      AgentHarness.pi => context.piAgentsRoot(),
    });
  }

  String _eligibleAuthority(
    LifecycleContext context,
    String location,
    AgentHarness harness,
    AgentDestination destination,
  ) {
    _requireExtension(location, harness);
    final candidates = <String>[];
    if (destination == AgentDestination.shared) {
      candidates.add(_defaultRoot(context, harness, destination));
    } else if (context.scope == LifecycleScope.user ||
        harness == AgentHarness.pi) {
      candidates.add(_defaultRoot(context, harness, destination));
    } else {
      var current = context.cwd;
      while (true) {
        candidates.add(switch (harness) {
          AgentHarness.claude => _fileSystem.path.join(
            current,
            '.claude',
            'agents',
          ),
          AgentHarness.codex => _fileSystem.path.join(
            current,
            '.codex',
            'agents',
          ),
          AgentHarness.pi => _fileSystem.path.join(current, '.pi', 'agents'),
        });
        if (_fileSystem.path.equals(current, context.projectRoot)) break;
        final parent = _fileSystem.path.dirname(current);
        if (_fileSystem.path.equals(parent, current) ||
            candidates.length >= 64) {
          throw MambaException(
            'Agent ancestor authority is incomplete.',
            exitCode: 3,
          );
        }
        current = parent;
      }
    }
    final containing =
        candidates
            .where((root) => _fileSystem.path.isWithin(root, location))
            .toList()
          ..sort((left, right) => right.length.compareTo(left.length));
    if (containing.isEmpty) {
      throw MambaException(
        'The Agent location is not eligible for ${harness.name}/${destination.name}.',
        exitCode: 4,
      );
    }
    final root = _fileSystem.path.normalize(containing.first);
    if (harness == AgentHarness.pi &&
        !_fileSystem.path.equals(_fileSystem.path.dirname(location), root)) {
      throw MambaException(
        'Common-Pi accepts only immediate native/shared Agent files; '
        'provider-specific deeper files are not common-Pi targets.',
        exitCode: 4,
      );
    }
    final relative = _fileSystem.path.relative(location, from: root);
    if (_fileSystem.path.split(relative).length > 17) {
      throw MambaException(
        'Agent native placement exceeds the depth budget.',
        exitCode: 3,
      );
    }
    if (_fileSystem.path.basename(location) == 'config.toml' ||
        _fileSystem.path.split(location).contains('.agent-resource')) {
      throw MambaException(
        'Reserved management or parent configuration paths are ineligible.',
        exitCode: 4,
      );
    }
    return root;
  }

  void _requireExtension(String path, AgentHarness harness) {
    final expected = harness == AgentHarness.codex ? '.toml' : '.md';
    if (_fileSystem.path.extension(path) != expected ||
        _fileSystem.path.basename(path).length <= expected.length) {
      throw MambaException(
        'The ${harness.name} Agent definition requires the exact lowercase $expected extension.',
        exitCode: 2,
      );
    }
  }

  void _validateRecordAuthority(
    InstallationRecord record,
    LifecycleContext context,
    AgentHarness harness,
  ) {
    if (record.kind != ArtifactKind.agentFile ||
        record.scope != context.scope ||
        record.nativeProfile != harness.name ||
        record.nativeForm != '${harness.name}-agent-file') {
      throw MambaException(
        'Stored Agent identity does not match its required native profile.',
        exitCode: 4,
      );
    }
    final bound = record.nativeDestination == 'codex-bound';
    final destination = bound
        ? null
        : AgentDestination.values.firstWhere(
            (value) => value.name == record.nativeDestination,
            orElse: () => throw MambaException(
              'Unsupported stored Agent destination.',
              exitCode: 4,
            ),
          );
    final authority = bound
        ? _eligibleBoundDefinitionAuthority(context, record.location)
        : _eligibleAuthority(context, record.location, harness, destination!);
    if (!_fileSystem.path.equals(authority, record.nativeRoot)) {
      throw MambaException(
        'Stored Agent native root is not current eligible authority.',
        exitCode: 4,
      );
    }
  }

  AgentHarness _recordHarness(InstallationRecord record) {
    if (record.kind != ArtifactKind.agentFile || record.nativeProfile == null) {
      throw MambaException(
        'The selected record is not a native Agent file.',
        exitCode: 4,
      );
    }
    return AgentHarness.values.firstWhere(
      (harness) => harness.name == record.nativeProfile,
      orElse: () => throw MambaException(
        'Unsupported stored Agent profile.',
        exitCode: 4,
      ),
    );
  }

  void _requireMutationScope(LifecycleContext context) {
    if (context.scope == LifecycleScope.all) {
      throw MambaException(
        'An Agent mutation requires --scope project or --scope user.',
      );
    }
  }
}

final class _AgentResource implements LifecycleResource {
  const _AgentResource(this.harness, [this.owner, this.anyProfile = false]);

  final AgentHarness harness;
  final AgentLifecycleService? owner;
  final bool anyProfile;

  fslib.FileSystem get _fs =>
      owner?._fileSystem ?? const local.LocalFileSystem();

  @override
  void validateAuthority(InstallationRecord record, LifecycleContext context) {
    final service = owner;
    if (service == null) {
      throw MambaException(
        'Agent native authority cannot be revalidated without its profile service.',
        exitCode: 4,
      );
    }
    final selected = anyProfile
        ? AgentHarness.values.firstWhere(
            (value) => value.name == record.nativeProfile,
            orElse: () => throw MambaException(
              'Unsupported stored Agent native profile.',
              exitCode: 4,
            ),
          )
        : harness;
    service._validateRecordAuthority(record, context, selected);
  }

  @override
  ArtifactKind get kind => ArtifactKind.agentFile;

  @override
  Future<LifecycleCandidate> inspect(
    String path,
    LifecycleContext context, {
    String? expectedName,
    bool restoringBaseline = false,
  }) async {
    final fileSystem = owner?._fileSystem ?? const local.LocalFileSystem();
    final type = skillEntityType(path, followLinks: false, fs: fileSystem);
    if (type == FileSystemEntityType.link) {
      throw MambaException(
        'Linked Agent definitions are not managed regular files.',
        exitCode: 4,
      );
    }
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The Agent candidate is not a regular file: $path',
        exitCode: 2,
      );
    }
    final expectedExtension = harness == AgentHarness.codex ? '.toml' : '.md';
    if (_fs.path.extension(path) != expectedExtension) {
      throw MambaException(
        'The Agent file extension does not match ${harness.name}.',
        exitCode: 2,
      );
    }
    final report = inspectNativeAgent(
      AgentInspectionInput(
        nativeFile: path,
        cwd: context.cwd,
        harness: harness,
      ),
      operation: AgentOperation.validate,
      fileSystem: fileSystem,
    );
    if (report.hasErrors) {
      throw MambaException(
        'Agent validation failed: ${report.diagnostics.where((diagnostic) => diagnostic.severity == AgentDiagnosticSeverity.error).map((diagnostic) => diagnostic.code).join(', ')}',
        exitCode: 2,
      );
    }
    final identity = report.identity['name']! as Map<String, Object?>;
    final name = identity['resolved'];
    if (name is! String || name.isEmpty) {
      throw MambaException('The Agent native name is unresolved.', exitCode: 2);
    }
    if (expectedName != null && name != expectedName) {
      throw MambaException(
        'The Agent native name changed during the operation.',
        exitCode: 4,
      );
    }
    return LifecycleCandidate(
      name: name,
      nativeForm: report.form,
      validatedProfiles: [harness.name],
      knownConsumers: [harness.name],
    );
  }

  @override
  Future<void> checkUnique(
    LifecycleContext context,
    String name, {
    required String nativeDestination,
    String? excludeInstallationId,
    String? excludePath,
    Set<String> allowedPaths = const <String>{},
  }) async {
    final report = await listNativeAgents(
      AgentInventoryInput(
        processWorkingDirectory: context.options.processWorkingDirectory,
        environment: context.options.environment,
        scope: AgentScope.all,
        harness: harness,
        cwd: context.cwd,
        projectRoot: context.projectRoot,
        home: context.options.home,
        claudeConfigDir: context.options.claudeConfigDir,
        codexHome: context.options.codexHome,
        piAgentDir: context.options.piAgentDir,
        readRoots: context.options.readRoots,
      ),
      fileSystem: _fs,
    );
    final comparison = harness == AgentHarness.pi ? name.toLowerCase() : name;
    final builtins = switch (harness) {
      AgentHarness.claude => const {'Explore', 'Plan', 'general-purpose'},
      AgentHarness.codex => const {'default', 'worker', 'explorer'},
      AgentHarness.pi => const <String>{},
    };
    if (builtins.any(
      (builtin) =>
          (harness == AgentHarness.pi ? builtin.toLowerCase() : builtin) ==
          comparison,
    )) {
      throw MambaException(
        'Agent native name "$name" collides with a documented ${harness.name} builtin.',
        exitCode: 4,
      );
    }
    for (final occurrence in report.occurrences) {
      final path = occurrence['path'];
      if ((excludePath != null &&
              path is String &&
              _fs.path.equals(path, excludePath)) ||
          (path is String &&
              allowedPaths.any((allowed) => _fs.path.equals(path, allowed)))) {
        continue;
      }
      final identity = occurrence['identity']! as Map<String, Object?>;
      final nativeName = identity['name']! as Map<String, Object?>;
      final resolved = nativeName['resolved'];
      final observable = resolved is String && resolved.isNotEmpty
          ? resolved
          : _observableBasename(occurrence['path']);
      if (observable == null) continue;
      final other = harness == AgentHarness.pi
          ? observable.toLowerCase()
          : observable;
      if (other == comparison) {
        throw MambaException(
          'Agent native name "$name" conflicts with ${occurrence['path']}; '
          'shadowing does not exclude a conflicting declaration.',
          exitCode: 4,
        );
      }
    }
  }

  String? _observableBasename(Object? path) {
    if (path is! String || path.isEmpty) return null;
    final basename = _fs.path.basename(path);
    final extension = _fs.path.extension(basename);
    if (extension.isEmpty) return null;
    return basename.substring(0, basename.length - extension.length);
  }
}
