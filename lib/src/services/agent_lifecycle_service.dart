import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../agent_inspection.dart';
import '../agent_inventory.dart';
import '../harness/harness_catalog.dart';
import '../skill_files.dart';
import 'conversion_coordinator_service.dart';
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
        geminiDir: input.geminiDir,
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
        final profile = record.nativeProfile;
        final spec = profile == null
            ? null
            : _specFor(
                AgentHarness.values.firstWhere(
                  (harness) => harness.name == profile,
                ),
              );
        final relative =
            _fileSystem.path.isWithin(record.nativeRoot, record.location)
            ? _fileSystem.path.relative(
                record.location,
                from: record.nativeRoot,
              )
            : _fileSystem.path.basename(record.location);
        final layout = spec?.candidateLayout(
          relative,
          _fileSystem.path.split(relative).length - 1,
          _fileSystem.path,
        );
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
          if (spec?.nestedLayouts == true &&
              layout != null) ...<String, Object?>{
            'layout': layout.name,
            'targetName': spec!.targetName(relative, _fileSystem.path),
          },
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
            _fileSystem.path.join(
              root,
              _spec(input.harness)
                  .installationFileName(source, null, _fileSystem.path),
            ),
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
    String? planId,
  }) {
    if (transactionId?.startsWith('cvx_') == true) {
      return ConversionCoordinator(io: state.io, state: state).recoverReviewed(
        options.copyWith(dryRun: options.dryRun || action == null),
        transactionId!,
        planId: planId,
        action: action,
        editKinds: const {ArtifactKind.agentFile},
      );
    }
    return state.recover(
      resource: _AgentResource(AgentHarness.claude, this, true),
      context: LifecycleContext.resolve(options, fileSystem: _fileSystem),
      transactionId: transactionId,
      action: action,
    );
  }

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
      name: 'candidate${_spec(harness).definitionExtension}',
      bytes: utf8.encode(content),
      body: body,
    );
  }

  String _defaultRoot(
    LifecycleContext context,
    AgentHarness harness,
    AgentDestination destination,
  ) =>
      _spec(harness)
          .defaultInstallRoot(_facetContext(context), destination.name);

  List<String> _authorityRoots(
    LifecycleContext context,
    AgentHarness harness,
    AgentDestination destination,
  ) => _spec(harness).authorityRoots(_facetContext(context), destination.name);

  AgentLifecycleContext _facetContext(LifecycleContext context) =>
      AgentLifecycleContext(
        path: _fileSystem.path,
        projectRoot: context.projectRoot,
        cwd: context.cwd,
        home: context.home ?? '',
        scope: context.scope.name,
        ancestors: context.scope == LifecycleScope.project
            ? _ancestorChain(context)
            : const <String>[],
        readRoots: List<String>.unmodifiable(<String>[
          for (final root in context.options.readRoots)
            context.resolvePath(root),
        ]),
        userRoots: context,
      );

  List<String> _ancestorChain(LifecycleContext context) {
    final result = <String>[];
    var current = context.cwd;
    while (true) {
      result.add(current);
      if (_fileSystem.path.equals(current, context.projectRoot)) {
        return List<String>.unmodifiable(result);
      }
      if (result.length >= 64) {
        throw MambaException(
          'Agent ancestor authority is incomplete.',
          exitCode: 3,
        );
      }
      final parent = _fileSystem.path.dirname(current);
      if (_fileSystem.path.equals(parent, current)) {
        throw MambaException(
          'Agent ancestor authority is incomplete.',
          exitCode: 3,
        );
      }
      current = parent;
    }
  }

  AgentHarnessSpec _spec(AgentHarness harness) => _specFor(harness);

  String _eligibleAuthority(
    LifecycleContext context,
    String location,
    AgentHarness harness,
    AgentDestination destination,
  ) {
    _requireExtension(location, harness);
    final candidates = _authorityRoots(context, harness, destination);
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
    _spec(harness).acceptsInstallLocation(
      root,
      location,
      destination.name,
      _fileSystem.path,
    );
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
    final expected = _spec(harness).definitionExtension;
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
    final expectedExtension = _specFor(harness).definitionExtension;
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
    final service = owner!;
    final spec = _specFor(harness);
    service.state.checkPendingConversions(
      context,
      uniqueness: (
        kind: kind,
        name: name,
        nativeProfile: harness.name,
        roots: [
          for (final scope in [LifecycleScope.project, LifecycleScope.user])
            ...service._authorityRoots(
              LifecycleContext.resolve(
                context.options.copyWith(scope: scope),
                fileSystem: _fs,
              ),
              harness,
              AgentDestination.native,
            ),
          for (final scope in [LifecycleScope.project, LifecycleScope.user])
            ...spec.additionalUniquenessRoots(
              service._facetContext(
                LifecycleContext.resolve(
                  context.options.copyWith(scope: scope),
                  fileSystem: _fs,
                ),
              ),
            ),
        ],
      ),
    );
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
        geminiDir: context.options.geminiDir,
        readRoots: context.options.readRoots,
      ),
      fileSystem: _fs,
    );
    final comparison = spec.normalizeName(name);
    if (spec.builtinNames.any(
      (builtin) => spec.normalizeName(builtin) == comparison,
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
      final observables = spec.uniquenessNames(occurrence, _fs.path);
      if (observables.contains(comparison)) {
        throw MambaException(
          'Agent native name "$name" conflicts with ${occurrence['path']}; '
          'shadowing does not exclude a conflicting declaration.',
          exitCode: 4,
        );
      }
    }
  }
}

AgentHarnessSpec _specFor(AgentHarness harness) =>
    HarnessCatalog.instance.requireFacet(
      HarnessId.of(harness),
      HarnessFacet.agent,
    ) as AgentHarnessSpec;
