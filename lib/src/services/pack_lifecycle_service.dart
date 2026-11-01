import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../../components/installation_approval.dart';
import '../agent_inspection.dart';
import '../installation/installation_plan.dart';
import '../installation/resource_catalog.dart';
import '../pack/github_release_resolver.dart';
import '../pack/pack_change_set.dart';
import '../pack/pack_configuration.dart';
import '../pack/pack_models.dart';
import '../pack/pack_state.dart';
import '../pack/release_policy.dart' as release_policy;
import '../pack/skill_admission.dart';
import '../skill_files.dart';
import '../skill_validation.dart';
import '../validation/validation_diagnostics.dart';
import 'acquisition_service.dart';
import 'agent_lifecycle_service.dart';
import 'lifecycle_state_service.dart';
import 'skill_lifecycle_service.dart';

const _legacyRecoveryExitCode = 6;

enum PackResourceType { skill, agent }

enum PackOperation {
  install,
  update,
  sourceAssociate,
  sourceChange,
  remove,
  rollback,
  cleanup,
  validate,
  configValidate,
}

final class const PackPrompts({
  final Future<bool> Function(String label)? confirmation,
  final Future<String?> Function(String label, List<String> choices)? choice,
});

final class const PackLifecycleRequest({
  required final PackOperation operation,
  required final PackResourceType resourceType,
  final List<PackResourceType> resourceTypes = const <PackResourceType>[],
  final bool includeNew = false,
  required final String processWorkingDirectory,
  final Map<String, String> environment = const <String, String>{},
  final String? pack,
  final LifecycleScope? scope,
  final String? cwd,
  final String? projectRoot,
  final String? home,
  final String? stateDir,
  final String? configPath,
  final String? target,
  final List<String> only = const <String>[],
  final String? method,
  final String? release,
  final String? bump,
  final bool includePrerelease = false,
  final bool savePolicy = false,
  final bool noSave = false,
  final bool skipNew = false,
  final List<String> keepLocal = const <String>[],
  final List<String> replaceLocal = const <String>[],
  final List<String> approveRemoval = const <String>[],
  final List<String> allowFolder = const <String>[],
  final String? to,
  final String? snapshot,
  final bool localEdits = false,
  final bool resolve = false,
  final bool dryRun = false,
  final bool yes = false,
  final bool interactive = false,
});

interface class PackLifecycleService {
  PackLifecycleService()
    : _acquisition = null,
      _state = null,
      _admission = const SkillAdmission(),
      _releaseResolver = null,
      prompts = const PackPrompts(),
      operatingSystem = Platform.operatingSystem;

  PackLifecycleService.withDependencies({
    this._acquisition = const AcquisitionService(),
    this._state,
    this._admission = const SkillAdmission(),
    this._releaseResolver = const GithubReleaseResolver(),
    this.prompts = const PackPrompts(),
    this.operatingSystem,
  });

  final AcquisitionService? _acquisition;
  final LifecycleStateService? _state;
  final SkillAdmission _admission;
  final GithubReleaseResolver? _releaseResolver;
  final PackPrompts prompts;
  final String? operatingSystem;

  late final LifecycleStateService _lifecycleState =
      _state ?? LifecycleStateService();
  late final SkillLifecycleService _skills = SkillLifecycleService(
    state: _lifecycleState,
  );
  late final AgentLifecycleService _agents = AgentLifecycleService(
    state: _lifecycleState,
  );
  AcquisitionService get _acquirer =>
      _acquisition ?? const AcquisitionService();
  GithubReleaseResolver get _releases =>
      _releaseResolver ?? const GithubReleaseResolver();

  Future<PackOperationResult> execute(PackLifecycleRequest request) async {
    _validateRequest(request);
    final context = _context(request);
    final configuration = _loadConfiguration(request, context);
    if (request.operation == PackOperation.configValidate) {
      return _validateConfiguration(request, configuration);
    }
    final pack = configuration.findPack(request.pack!);
    if (pack == null) {
      throw MambaException(
        'No configured pack matches ${request.pack} in ${configuration.configPath}.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.operation == PackOperation.validate) {
      return _validatePack(request, context, configuration, pack);
    }
    if (request.scope == null && !request.interactive) {
      throw MambaException(
        'Noninteractive mutations require explicit --scope project|user.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (!request.dryRun && !request.yes && !request.interactive) {
      throw MambaException(
        'Unattended mutation requires --yes after all special choices are explicit.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }

    _validateModeConflicts(request, pack);
    try {
      return await switch (request.operation) {
        PackOperation.install || PackOperation.update => _installOrUpdate(
          request,
          context,
          configuration,
          pack,
        ),
        PackOperation.remove => _remove(request, context, configuration, pack),
        PackOperation.sourceAssociate || PackOperation.sourceChange =>
          _associateSource(request, context, configuration, pack),
        PackOperation.rollback => _rollback(
          request,
          context,
          configuration,
          pack,
        ),
        PackOperation.cleanup => _cleanup(
          request,
          context,
          configuration,
          pack,
        ),
        PackOperation.validate ||
        PackOperation.configValidate => throw StateError('Handled above.'),
      };
    } on MambaException catch (error) {
      if (!request.dryRun) rethrow;
      final names = request.only.isEmpty ? <String>[pack.key] : request.only;
      final plan = PackPlan.create(
        operation: '${request.resourceType.name}s.${request.operation.name}',
        context: _contextJson(request, context, configuration),
        source: {'pack': pack.key, 'track': _trackJson(pack.update.track)},
        resources: [
          for (final name in names)
            PackResourcePlan(
              type: request.resourceType.name,
              name: name,
              action: 'blocked',
              blockers: [error.message],
            ),
        ],
      );
      throw MambaException(
        'Dry-run is blocked; no managed state was published.\n${plan.renderText()}',
        exitCode: error.exitCode,
      );
    }
  }

  Future<PackOperationResult> _validatePack(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackConfiguration configuration,
    PackDefinition pack,
  ) async {
    final acquired = await _acquire(pack, configuration, request: request);
    final workspace = acquired.workspace;
    try {
      final inspected = <_InspectedPackResource>[];
      for (final type in _requestResourceTypes(request)) {
        for (final candidate in await _validationCandidates(
          workspace,
          pack,
          type,
        )) {
          inspected.add(_inspectPackResource(candidate, pack));
        }
      }
      _requireUniqueValidationNames(inspected, pack);
      final selected = _selectValidatedResources(request, pack, inspected);
      final failures = <String>[
        for (final resource in selected)
          ...resource.failures.map((failure) => '${resource.label}: $failure'),
      ];
      if (failures.isNotEmpty) {
        throw MambaException(
          'Pack validation failed for ${pack.key}; no managed state was changed.\n'
          '${failures.map((failure) => '- $failure').join('\n')}',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      return PackOperationResult(
        operation: 'pack.validate',
        outcome: 'valid',
        context: _contextJson(request, context, configuration),
        source: _sourceJson(pack, workspace.provenance),
        resources: [
          for (final resource in selected)
            PackResourceResult(
              type: resource.candidate.type.name,
              name: resource.name!,
              disposition: PackDisposition.validated,
            ),
        ],
        warnings: [
          for (final resource in selected)
            for (final warning in resource.warnings)
              PackWarning(
                id: '${resource.candidate.type.name}-${resource.name}-$warning',
                message: '${resource.name}: $warning',
              ),
        ],
        dryRun: true,
      );
    } finally {
      await workspace.close();
    }
  }

  Future<PackOperationResult> _validateConfiguration(
    PackLifecycleRequest request,
    PackConfiguration configuration,
  ) async {
    if (request.resolve) {
      for (final pack in configuration.packs) {
        final source = pack.source;
        if (pack.update.track is ReleaseTrack && source is GitHubPackSource) {
          try {
            await _releases.inspect(source: source);
          } on GithubReleaseResolverException catch (error) {
            throw MambaException(
              error.message,
              exitCode: PackProcessStatus.invalidInput.code,
            );
          }
          continue;
        }
        final acquired = await _acquire(pack, configuration, request: request);
        await acquired.workspace.close();
      }
    }
    return PackOperationResult(
      operation: 'config.validate',
      outcome: 'valid',
      context: {
        'scope': configuration.scope.name,
        'configPath': configuration.configPath,
        'resolved': request.resolve,
      },
      source: {'packs': configuration.packs.length},
      resources: const [],
      dryRun: true,
    );
  }

  Future<PackOperationResult> _installOrUpdate(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackConfiguration configuration,
    PackDefinition pack,
  ) async {
    final existing = _targetedRecords(
      request,
      _packRecords(context, pack.key, request.resourceType),
    ).where((record) => record.lifecycle == 'live').toList();
    if (request.operation == PackOperation.install) {
      final replay = _exactLockReplay(
        request,
        context,
        configuration,
        pack,
        existing,
      );
      if (replay != null) return replay;
    }
    final acquired = await _acquire(
      pack,
      configuration,
      request: request,
      existing: existing,
    );
    final workspace = acquired.workspace;
    try {
      final catalog = _readSourceCatalog(workspace);
      final reusableFolders = _reusableFolderApprovals(
        request,
        context,
        configuration,
        existing,
        pack,
        workspace.provenance,
      );
      final candidates = await _candidates(
        request,
        context,
        workspace,
        catalog,
        pack,
        acquired.release,
        reusableFolders: reusableFolders,
      );
      _requireAcceptedSource(
        pack,
        workspace.provenance,
        existing,
        acquired.release,
      );
      final selectionDecisions = _selectionDecisions(
        context,
        pack.key,
        request.resourceType,
      );
      final selected = _selectCandidates(
        request,
        pack,
        candidates,
        existing,
        selectionDecisions,
      );
      _preflightRecords(request, selected, existing);
      final warnings = _modeWarnings(request, pack);
      final results = <PackResourceResult>[];
      final failures = <String>[];
      final candidateNames = candidates
          .map((candidate) => candidate.name)
          .toSet();
      final absent =
          request.operation == PackOperation.update && request.only.isEmpty
          ? existing
                .where(
                  (record) =>
                      record.lifecycle == 'live' &&
                      !candidateNames.contains(record.name),
                )
                .toList()
          : <InstallationRecord>[];
      final approvedRemoval = {...request.approveRemoval};
      if (request.interactive && !request.yes) {
        for (final record in absent.where(
          (record) => !approvedRemoval.contains(record.name),
        )) {
          if (await _promptYesNo(
            '${record.name} is absent upstream. Approve its removal?',
          )) {
            approvedRemoval.add(record.name);
          }
        }
      }
      final unapprovedAbsence = absent
          .where((record) => !approvedRemoval.contains(record.name))
          .map((record) => record.name)
          .toList();
      if (unapprovedAbsence.isNotEmpty) {
        throw MambaException(
          'Upstream absence requires explicit removal approval for: ${unapprovedAbsence.join(', ')}. No resource was published.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      final actions = <String, String>{};
      final installMethods = <String, SkillInstallMethod?>{};
      final installTargets = <String, List<String>>{};
      final declinedCandidates = <_PackCandidate>[];
      final planResources = <PackResourcePlan>[];
      for (final candidate in selected) {
        final records = existing
            .where((record) => record.name == candidate.name)
            .toList();
        if (records.length > 1) {
          throw MambaException(
            'Duplicate managed installations for ${candidate.name}; select an unambiguous target.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        final record = records.isEmpty ? null : records.single;
        final changedPaths = record == null
            ? PackChangeSet.between(null, _candidateBaseline(candidate))
            : record.kind == ArtifactKind.skillLink
            ? const <PackChangedPath>[]
            : PackChangeSet.between(
                record.baseline,
                _candidateBaseline(candidate),
              );
        if (record == null) {
          if (request.operation == PackOperation.update &&
              !request.only.contains(candidate.name) &&
              selectionDecisions[candidate.name] != true) {
            if (request.skipNew) {
              actions[candidate.name] = 'skipped';
              continue;
            }
            final includeNew =
                request.includeNew ||
                request.interactive &&
                    !request.yes &&
                    await _promptYesNo(
                      '${candidate.name} is new upstream. Include it?',
                    );
            if (!includeNew) {
              declinedCandidates.add(candidate);
              actions[candidate.name] = 'observed';
              warnings.add(
                PackWarning(
                  id: 'new-resource-unselected',
                  message:
                      '${candidate.name} is new and was not selected; use --only to review inclusion.',
                ),
              );
              planResources.add(
                PackResourcePlan(
                  type: request.resourceType.name,
                  name: candidate.name,
                  action: 'observed',
                  changedPaths: changedPaths,
                ),
              );
              continue;
            }
          }
          final targets = await _targets(
            request,
            pack,
            configuration,
            candidate,
            null,
          );
          final method = await _method(
            request,
            pack,
            configuration,
            candidate,
            null,
          );
          actions[candidate.name] = 'install';
          installTargets[candidate.name] = targets;
          installMethods[candidate.name] = method;
          planResources.add(
            PackResourcePlan(
              type: request.resourceType.name,
              name: candidate.name,
              action: 'install',
              method: method?.name,
              targets: targets,
              changedPaths: changedPaths,
              blockers: request.dryRun ? const <String>[] : const <String>[],
            ),
          );
          continue;
        }
        final modification = _lifecycleState.verify(record);
        final sameBytes = record.kind == ArtifactKind.skillLink
            ? record.origin['contentDigest'] == candidate.digest
            : candidate.digest == record.baseline.digest;
        final originChanged =
            jsonEncode(record.origin) != jsonEncode(candidate.origin);
        final action = request.operation == PackOperation.install
            ? 'unchanged'
            : record.kind == ArtifactKind.skillLink &&
                  modification == ModificationStatus.unchanged
            ? 'observed'
            : sameBytes &&
                  modification == ModificationStatus.unchanged &&
                  !originChanged
            ? 'unchanged'
            : modification != ModificationStatus.unchanged &&
                  request.keepLocal.contains(record.name)
            ? 'keptLocal'
            : modification != ModificationStatus.unchanged
            ? 'replaceLocal'
            : 'update';
        actions[candidate.name] = action;
        final previousSnapshot = _currentSnapshotRef(context, record);
        planResources.add(
          PackResourcePlan(
            type: request.resourceType.name,
            name: candidate.name,
            action: action,
            method: _recordMethod(record.kind),
            targets: record.validatedProfiles,
            previousSnapshot: previousSnapshot,
            snapshot:
                action == 'unchanged' ||
                    action == 'observed' ||
                    action == 'keptLocal'
                ? previousSnapshot
                : null,
            localEdit: modification == ModificationStatus.unchanged
                ? null
                : modification.name,
            linkOnly: record.kind == ArtifactKind.skillLink,
            changedPaths: record.kind == ArtifactKind.skillLink
                ? const <PackChangedPath>[]
                : changedPaths,
          ),
        );
      }
      for (final record in absent) {
        actions[record.name] = 'remove';
        planResources.add(
          PackResourcePlan(
            type: request.resourceType.name,
            name: record.name,
            action: 'remove',
            method: _recordMethod(record.kind),
            targets: record.validatedProfiles,
            previousSnapshot: _currentSnapshotRef(context, record),
            changedPaths: PackChangeSet.between(record.baseline, null),
            linkOnly: record.kind == ArtifactKind.skillLink,
          ),
        );
      }
      final plan = PackPlan.create(
        operation: '${request.resourceType.name}s.${request.operation.name}',
        context: _contextJson(request, context, configuration),
        source: _sourceJson(pack, workspace.provenance),
        resources: planResources,
        warnings: warnings,
        policy: _policyChange(request, pack),
      );
      await _confirmPlan(request, plan);
      if (!request.dryRun && !request.noSave) {
        for (final candidate in declinedCandidates) {
          _recordSelectionChoice(
            context,
            pack.key,
            request.resourceType,
            candidate.name,
            selected: false,
            reason: 'declined',
          );
        }
      }

      var recoveryRequired = false;
      for (final candidate in selected) {
        if (recoveryRequired) {
          results.add(_result(request, candidate.name, 'notAttempted'));
          continue;
        }
        final action = actions[candidate.name];
        final records = existing
            .where((record) => record.name == candidate.name)
            .toList();
        try {
          if (action == null || action == 'skipped') continue;
          final record = records.isEmpty ? null : records.single;
          final changedPaths = record == null
              ? PackChangeSet.between(null, _candidateBaseline(candidate))
              : record.kind == ArtifactKind.skillLink
              ? const <PackChangedPath>[]
              : PackChangeSet.between(
                  record.baseline,
                  _candidateBaseline(candidate),
                );
          if (record == null) {
            if (action == 'observed') {
              results.add(
                _result(
                  request,
                  candidate.name,
                  'observed',
                  changedPaths: changedPaths,
                ),
              );
              continue;
            }
            final outcome = await _installCandidate(
              request,
              context,
              pack,
              candidate,
              configuration,
              targets: installTargets[candidate.name]!,
              method: installMethods[candidate.name],
            );
            final snapshot = request.dryRun
                ? null
                : _recordSnapshots(context, pack.key, candidate);
            results.add(
              _result(
                request,
                candidate.name,
                outcome,
                snapshot: snapshot,
                linkOnly: _isSourceLink(context, pack.key, candidate),
                changedPaths: changedPaths,
              ),
            );
          } else {
            final previousSnapshot = _currentSnapshotRef(context, record);
            final outcome = await _updateCandidate(
              request,
              context,
              pack,
              candidate,
              record,
            );
            final snapshot = request.dryRun || outcome == 'keptLocal'
                ? previousSnapshot
                : _recordSnapshots(context, pack.key, candidate);
            results.add(
              _result(
                request,
                candidate.name,
                outcome,
                previousSnapshot: previousSnapshot,
                snapshot: snapshot,
                linkOnly: record.kind == ArtifactKind.skillLink,
                changedPaths: changedPaths,
              ),
            );
          }
        } on MambaException catch (error) {
          failures.add('${candidate.name}: ${error.message}');
          results.add(_result(request, candidate.name, 'failed'));
          if (error.exitCode == _legacyRecoveryExitCode ||
              error.exitCode == PackProcessStatus.recoveryRequired.code) {
            recoveryRequired = true;
          }
        }
      }

      for (final record in absent) {
        if (recoveryRequired) {
          results.add(_result(request, record.name, 'notAttempted'));
          continue;
        }
        if (!request.dryRun) {
          await _removeRecord(request, context, record);
          PackState(stateDirectory: context.stateRoot())
              .markInstallationNoncurrent(record.installationId);
        }
        results.add(
          _result(
            request,
            record.name,
            'removed',
            changedPaths: PackChangeSet.between(record.baseline, null),
          ),
        );
      }

      if (!request.dryRun) {
        _persistPackOperation(
          context: context,
          plan: plan,
          results: results,
          outcome: failures.isEmpty ? 'completed' : 'failed',
          packKey: pack.key,
          type: request.resourceType,
          provenance: workspace.provenance,
          candidates: candidates,
          noSave: request.noSave,
        );
      }
      if (failures.isNotEmpty) {
        throw MambaException(
          'Pack operation completed with resource failures: ${failures.join(' | ')}',
          exitCode: recoveryRequired
              ? PackProcessStatus.recoveryRequired.code
              : PackProcessStatus.failure.code,
        );
      }
      if (!request.dryRun &&
          request.operation == PackOperation.update &&
          request.savePolicy &&
          !request.noSave) {
        _savePolicy(configuration, pack, request);
      }
      return PackOperationResult(
        operation: '${request.resourceType.name}s.${request.operation.name}',
        outcome: request.dryRun
            ? 'preview'
            : results.every(
                (result) => result.disposition == PackDisposition.unchanged,
              )
            ? 'no-op'
            : 'completed',
        context: _contextJson(request, context, configuration),
        source: _sourceJson(pack, workspace.provenance),
        resources: results,
        warnings: warnings,
        dryRun: request.dryRun,
        plan: plan,
      );
    } finally {
      await workspace.close();
    }
  }

  void _preflightRecords(
    PackLifecycleRequest request,
    List<_PackCandidate> selected,
    List<InstallationRecord> existing,
  ) {
    final selectedNames = selected.map((candidate) => candidate.name).toSet();
    for (final choice in [...request.keepLocal, ...request.replaceLocal]) {
      if (!selectedNames.contains(choice)) {
        throw MambaException(
          'Local-edit choice is outside the selected resources: $choice.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
    for (final candidate in selected) {
      final records = existing
          .where((record) => record.name == candidate.name)
          .toList();
      if (records.length > 1) {
        throw MambaException(
          'Duplicate managed installations for ${candidate.name}; select an unambiguous target.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      if (records.isEmpty) continue;
      final record = records.single;
      final modification = _lifecycleState.verify(record);
      if (request.operation == PackOperation.install &&
          ((record.kind != ArtifactKind.skillLink &&
                  candidate.digest != record.baseline.digest) ||
              modification != ModificationStatus.unchanged)) {
        throw MambaException(
          'Ordinary install cannot advance or replace the exact locked state for ${record.name}; use update.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      if (request.operation == PackOperation.update &&
          modification != ModificationStatus.unchanged &&
          !request.keepLocal.contains(record.name) &&
          !request.replaceLocal.contains(record.name)) {
        throw MambaException(
          'Local edits to ${record.name} require --keep-local or --replace-local before any resource is published.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
  }

  PackOperationResult? _exactLockReplay(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackConfiguration configuration,
    PackDefinition pack,
    List<InstallationRecord> existing,
  ) {
    if (existing.isEmpty || pack.update.track is ReleaseTrack) return null;
    final expectedLocator = _expectedLocator(pack);
    final selected = request.only.isEmpty
        ? existing.where((record) => record.lifecycle == 'live').toList()
        : existing
              .where(
                (record) =>
                    record.lifecycle == 'live' &&
                    request.only.contains(record.name),
              )
              .toList();
    if (selected.isEmpty ||
        (request.only.isNotEmpty && selected.length != request.only.length)) {
      return null;
    }
    for (final record in selected) {
      final source = record.origin['source'];
      if (source is! Map<String, Object?> ||
          source['requestedLocator'] != expectedLocator ||
          jsonEncode(record.origin['track']) !=
              jsonEncode(_trackJson(pack.update.track)) ||
          _lifecycleState.verify(record) != ModificationStatus.unchanged) {
        return null;
      }
    }
    final source = <String, Object?>{
      'pack': pack.key,
      'track': _trackJson(pack.update.track),
      'exactLockReplay': true,
    };
    final snapshotRefs = {
      for (final record in selected)
        record.name: _currentSnapshotRef(context, record),
    };
    final plan = PackPlan.create(
      operation: '${request.resourceType.name}s.install',
      context: _contextJson(request, context, configuration),
      source: source,
      resources: [
        for (final record in selected)
          PackResourcePlan(
            type: request.resourceType.name,
            name: record.name,
            action: 'unchanged',
            method: _recordMethod(record.kind),
            targets: record.validatedProfiles,
            previousSnapshot: snapshotRefs[record.name],
            snapshot: snapshotRefs[record.name],
            linkOnly: record.kind == ArtifactKind.skillLink,
          ),
      ],
    );
    return PackOperationResult(
      operation: '${request.resourceType.name}s.install',
      outcome: 'no-op',
      context: _contextJson(request, context, configuration),
      source: source,
      resources: [
        for (final record in selected)
          _result(
            request,
            record.name,
            'unchanged',
            snapshot: snapshotRefs[record.name],
            linkOnly: record.kind == ArtifactKind.skillLink,
          ),
      ],
      dryRun: request.dryRun,
      plan: plan,
    );
  }

  String _expectedLocator(PackDefinition pack) => switch (pack.source) {
    LocalPackSource local => local.path,
    GitHubPackSource github => 'https://${github.host}/${github.repository}',
    GitPackSource git => git.url,
    DownloadPackSource download => download.url,
  };

  Future<String> _installCandidate(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackDefinition pack,
    _PackCandidate candidate,
    PackConfiguration configuration, {
    required List<String> targets,
    required SkillInstallMethod? method,
  }) async {
    if (request.dryRun) return 'installed';
    final unit = _installationUnit(
      context,
      candidate,
      method,
      targets,
      request.resourceType,
    );
    final resource = _resourceFor(candidate, method, unit);
    final outcome = await _lifecycleState.installResourceUnit(
      resource: resource,
      context: context,
      unit: unit,
    );
    return switch (outcome.status) {
      InstallationUnitStatus.installed => 'installed',
      InstallationUnitStatus.unchanged => 'unchanged',
      _ => throw MambaException(
        'Publication ended as ${outcome.status.wireName}; transaction ${outcome.transactionId}.',
        exitCode: outcome.status == InstallationUnitStatus.recoveryRequired
            ? PackProcessStatus.recoveryRequired.code
            : PackProcessStatus.failure.code,
      ),
    };
  }

  Future<String> _updateCandidate(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackDefinition pack,
    _PackCandidate candidate,
    InstallationRecord record,
  ) async {
    final sameBytes = record.kind == ArtifactKind.skillLink
        ? record.origin['contentDigest'] == candidate.digest
        : candidate.digest == record.baseline.digest;
    if (request.operation == PackOperation.install) {
      if (!sameBytes ||
          _lifecycleState.verify(record) != ModificationStatus.unchanged) {
        throw MambaException(
          'Ordinary install cannot advance or replace the exact locked state for ${record.name}; use update.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      return 'unchanged';
    }
    final modification = _lifecycleState.verify(record);
    final originChanged =
        jsonEncode(record.origin) != jsonEncode(candidate.origin);
    if (sameBytes &&
        modification == ModificationStatus.unchanged &&
        !originChanged) {
      return 'unchanged';
    }
    if (record.kind == ArtifactKind.skillLink &&
        modification == ModificationStatus.unchanged) {
      if (!request.dryRun) {
        await _lifecycleState.updateOrigin(
          context: context,
          installationId: record.installationId,
          expectedOrigin: record.origin,
          origin: {
            ...candidate.origin,
            'targetObservation': {
              'contentDigest': candidate.digest,
              'ownership': 'user-owned-target',
            },
          },
        );
      }
      return 'observed';
    }
    if (sameBytes && modification == ModificationStatus.unchanged) {
      if (!request.dryRun) {
        await _lifecycleState.updateOrigin(
          context: context,
          installationId: record.installationId,
          expectedOrigin: record.origin,
          origin: candidate.origin,
        );
      }
      return 'updated';
    }
    if (modification != ModificationStatus.unchanged) {
      if (request.keepLocal.contains(record.name)) return 'keptLocal';
      if (!request.replaceLocal.contains(record.name)) {
        throw MambaException(
          'Local edits to ${record.name} require --keep-local or --replace-local.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
    if (request.dryRun) return 'updated';
    if (modification != ModificationStatus.unchanged) {
      _recordEditedSnapshot(context, record);
    }
    final resource = _resourceForRecord(candidate, record);
    await _replaceRecord(request, context, resource, record, candidate);
    return 'updated';
  }

  Future<PackOperationResult> _associateSource(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackConfiguration configuration,
    PackDefinition pack,
  ) async {
    final changing = request.operation == PackOperation.sourceChange;
    final destination = changing ? configuration.findPack(request.to!) : pack;
    if (destination == null) {
      throw MambaException(
        'The --to pack is not configured: ${request.to}.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final acquired = await _acquire(
      destination,
      configuration,
      request: request,
      existing: _packRecords(context, pack.key, request.resourceType),
    );
    final workspace = acquired.workspace;
    try {
      final candidates = await _candidates(
        request,
        context,
        workspace,
        _readSourceCatalog(workspace),
        destination,
        acquired.release,
      );
      final byName = {
        for (final candidate in candidates) candidate.name: candidate,
      };
      final records = changing
          ? _packRecords(
              context,
              pack.key,
              request.resourceType,
            ).where((record) => record.lifecycle == 'live').toList()
          : _lifecycleState.records(context).where((record) {
              final expectedKind =
                  request.resourceType == PackResourceType.skill
                  ? const {
                      ArtifactKind.skillCopy,
                      ArtifactKind.skillLink,
                      ArtifactKind.skillCanonical,
                    }
                  : const {ArtifactKind.agentFile};
              return request.only.contains(record.name) &&
                  expectedKind.contains(record.kind) &&
                  record.lifecycle == 'live' &&
                  record.origin['status'] == 'unknown';
            }).toList();
      if (records.isEmpty ||
          (!changing && records.length != request.only.length)) {
        throw MambaException(
          'Source association requires unambiguous adopted records with unknown origin.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      for (final record in records) {
        final candidate = byName[record.name];
        if (candidate == null || candidate.digest != record.baseline.digest) {
          throw MambaException(
            'The reviewed source does not match the complete installed baseline for ${record.name}.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        if (_lifecycleState.verify(record) != ModificationStatus.unchanged) {
          throw MambaException(
            'Local edits must be reviewed before source association for ${record.name}.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
      }
      final plan = PackPlan.create(
        operation:
            '${request.resourceType.name}s.source.${changing ? 'change' : 'associate'}',
        context: _contextJson(request, context, configuration),
        source: _sourceJson(destination, workspace.provenance),
        resources: [
          for (final record in records)
            PackResourcePlan(
              type: request.resourceType.name,
              name: record.name,
              action: changing ? 'sourceChange' : 'sourceAssociate',
              method: _recordMethod(record.kind),
              targets: record.validatedProfiles,
              previousSnapshot: _currentSnapshotRef(context, record),
              snapshot: _currentSnapshotRef(context, record),
              linkOnly: record.kind == ArtifactKind.skillLink,
            ),
        ],
      );
      await _confirmPlan(request, plan);
      final results = <PackResourceResult>[];
      for (final record in records) {
        final candidate = byName[record.name]!;
        await _lifecycleState.updateOrigin(
          context: context,
          installationId: record.installationId,
          expectedOrigin: record.origin,
          origin: candidate.origin,
        );
        results.add(_result(request, record.name, 'updated'));
      }
      if (!request.dryRun) {
        _persistPackOperation(
          context: context,
          plan: plan,
          results: results,
          outcome: 'completed',
          packKey: destination.key,
          type: request.resourceType,
          provenance: workspace.provenance,
          candidates: candidates,
          noSave: request.noSave,
        );
      }
      return PackOperationResult(
        operation:
            '${request.resourceType.name}s.source.${changing ? 'change' : 'associate'}',
        outcome: request.dryRun ? 'preview' : 'completed',
        context: _contextJson(request, context, configuration),
        source: _sourceJson(destination, workspace.provenance),
        resources: results,
        dryRun: request.dryRun,
        plan: plan,
      );
    } finally {
      await workspace.close();
    }
  }

  void _requireAcceptedSource(
    PackDefinition pack,
    AcquisitionProvenance provenance,
    List<InstallationRecord> records,
    _ReleaseEvidence? release,
  ) {
    for (final record in records) {
      final source = record.origin['source'];
      final acceptedLocator = source is Map<String, Object?>
          ? source['requestedLocator']
          : null;
      final acceptedSource = switch (pack.update.track) {
        ReleaseTrack() => () {
          final configured = pack.source;
          final provider = record.origin['provider'];
          return configured is GitHubPackSource &&
              release != null &&
              configured.host.toLowerCase() ==
                  release.repositoryHost.toLowerCase() &&
              configured.repository.toLowerCase() ==
                  release.repositoryName.toLowerCase() &&
              provider is Map<String, Object?> &&
              provider['host'] == release.repositoryHost &&
              provider['repositoryId'] == release.repositoryId;
        }(),
        _ => acceptedLocator == provenance.requestedLocator,
      };
      if (jsonEncode(record.origin['track']) !=
              jsonEncode(_trackJson(pack.update.track)) ||
          !acceptedSource) {
        throw MambaException(
          'Configured source or track differs from the accepted lock for ${record.name}; use source change.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      if (pack.update.track is TagTrack &&
          source is Map<String, Object?> &&
          source['resolvedCommit'] != provenance.resolvedCommit) {
        throw MambaException(
          'The pinned tag moved for ${record.name}; explicit source review is required.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
  }

  Future<PackOperationResult> _rollback(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackConfiguration configuration,
    PackDefinition pack,
  ) async {
    final name = request.only.single;
    final records =
        _targetedRecords(
              request,
              _packRecords(context, pack.key, request.resourceType),
            )
            .where(
              (record) => record.name == name && record.lifecycle == 'live',
            )
            .toList();
    if (records.length != 1) {
      throw MambaException(
        'Rollback requires one unambiguous managed installation for $name.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final record = records.single;
    final previousRef = _currentSnapshotRef(context, record);
    final state = PackState(stateDirectory: context.stateRoot());
    final RecordedSnapshot snapshot;
    final String artifact;
    try {
      snapshot = state.snapshot(
        installationId: record.installationId,
        ref: request.snapshot!,
      );
      artifact = state.snapshotArtifactPath(
        installationId: record.installationId,
        ref: request.snapshot!,
      );
    } on FormatException catch (error) {
      throw MambaException(
        error.message,
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on StateError catch (error) {
      throw MambaException(
        error.message,
        exitCode: PackProcessStatus.failure.code,
      );
    }
    final modification = _lifecycleState.verify(record);
    final rollbackChanges = PackChangeSet.between(
      record.baseline,
      ArtifactBaseline.fromJson(snapshot.baseline),
    );
    final plan = PackPlan.create(
      operation: '${request.resourceType.name}s.rollback',
      context: _contextJson(request, context, configuration),
      source: {'pack': pack.key, 'snapshot': snapshot.ref},
      resources: [
        PackResourcePlan(
          type: request.resourceType.name,
          name: name,
          action: modification == ModificationStatus.unchanged
              ? 'rollback'
              : request.keepLocal.contains(name)
              ? 'keptLocal'
              : 'replaceLocalAndRollback',
          method: _recordMethod(record.kind),
          targets: record.validatedProfiles,
          previousSnapshot: previousRef,
          snapshot: snapshot.ref,
          localEdit: modification == ModificationStatus.unchanged
              ? null
              : modification.name,
          linkOnly: record.kind == ArtifactKind.skillLink,
          changedPaths: rollbackChanges,
        ),
      ],
    );
    if (modification != ModificationStatus.unchanged) {
      if (request.keepLocal.contains(name)) {
        return PackOperationResult(
          operation: '${request.resourceType.name}s.rollback',
          outcome: 'no-op',
          context: _contextJson(request, context, configuration),
          source: {'pack': pack.key, 'snapshot': snapshot.ref},
          resources: [_result(request, name, 'keptLocal')],
          dryRun: request.dryRun,
          plan: plan,
        );
      }
      if (!request.replaceLocal.contains(name)) {
        throw MambaException(
          'Rollback over local edits requires --replace-local $name.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
    if (snapshot.retentionClass != 'source') {
      throw MambaException(
        'Rollback selects ordinary source snapshots, not local-edit backup refs.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final evidenceSource = snapshot.sourceEvidence['source'];
    final origin = evidenceSource is Map<String, Object?>
        ? Map<String, Object?>.unmodifiable(evidenceSource)
        : snapshot.sourceEvidence;
    final historical = snapshot.sourceEvidence['installation'];
    final historicalRecord =
        record.kind == ArtifactKind.skillCanonical &&
            historical is Map<String, Object?>
        ? InstallationRecord.fromJson(historical)
        : null;
    if (historicalRecord != null &&
        (historicalRecord.installationId != record.installationId ||
            historicalRecord.location != record.location ||
            historicalRecord.nativeRoot != record.nativeRoot)) {
      throw MambaException(
        'Recorded canonical snapshot belongs to different installation authority.',
        exitCode: PackProcessStatus.recoveryRequired.code,
      );
    }
    final extras = origin['approvedExtraFolders'] is List
        ? (origin['approvedExtraFolders']! as List).whereType<String>().toSet()
        : <String>{};
    var sourcePath = artifact;
    if (record.kind == ArtifactKind.agentFile) {
      final files = Directory(artifact)
          .listSync(followLinks: false)
          .whereType<File>()
          .toList();
      if (files.length != 1) {
        throw MambaException(
          'Recorded Agent snapshot does not contain exactly one native file.',
          exitCode: PackProcessStatus.recoveryRequired.code,
        );
      }
      sourcePath = files.single.path;
    } else if (record.kind == ArtifactKind.skillLink) {
      final linkEvidence = File(p.join(artifact, 'link.json'));
      final decoded = jsonDecode(linkEvidence.readAsStringSync());
      if (decoded is! List || decoded.length != 1) {
        throw MambaException(
          'Recorded link snapshot is invalid.',
          exitCode: PackProcessStatus.recoveryRequired.code,
        );
      }
      final target = (decoded.single as Map<String, Object?>)['target'];
      if (target is! String) {
        throw MambaException(
          'Recorded link snapshot has no target.',
          exitCode: PackProcessStatus.recoveryRequired.code,
        );
      }
      sourcePath = target;
    }
    final candidate = _PackCandidate(
      type: request.resourceType,
      name: record.name,
      path: sourcePath,
      profile: null,
      digest: record.baseline.digest,
      extraFolders: extras,
      origin: origin,
      historicalInstallation: historicalRecord,
    );
    await _confirmPlan(request, plan);
    if (!request.dryRun) {
      if (modification != ModificationStatus.unchanged) {
        _recordEditedSnapshot(context, record);
      }
      await _replaceRecord(
        request,
        context,
        _resourceForRecord(candidate, record),
        record,
        candidate,
      );
    }
    final resultingRef = request.dryRun
        ? snapshot.ref
        : _recordSnapshot(
            context,
            _lifecycleState.recordById(context, record.installationId),
          ).ref;
    final results = [
      _result(
        request,
        name,
        'rolledBack',
        previousSnapshot: previousRef,
        snapshot: resultingRef,
        linkOnly: record.kind == ArtifactKind.skillLink,
        changedPaths: rollbackChanges,
      ),
    ];
    if (!request.dryRun) {
      _persistPackOperation(
        context: context,
        plan: plan,
        results: results,
        outcome: 'completed',
        packKey: pack.key,
        type: request.resourceType,
        noSave: request.noSave,
      );
    }
    return PackOperationResult(
      operation: '${request.resourceType.name}s.rollback',
      outcome: request.dryRun ? 'preview' : 'completed',
      context: _contextJson(request, context, configuration),
      source: {'pack': pack.key, 'snapshot': snapshot.ref},
      resources: results,
      dryRun: request.dryRun,
      plan: plan,
    );
  }

  Future<PackOperationResult> _cleanup(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackConfiguration configuration,
    PackDefinition pack,
  ) async {
    final records = _packRecords(context, pack.key, request.resourceType)
        .where(
          (record) =>
              request.only.isEmpty || request.only.contains(record.name),
        )
        .toList();
    if (request.only.isNotEmpty &&
        request.only.any(
          (name) => records.every((record) => record.name != name),
        )) {
      throw MambaException(
        'Cleanup contains an unknown native name in this pack context.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final state = PackState(stateDirectory: context.stateRoot());
    final snapshots = state.snapshots();
    final installationIds = records
        .map((record) => record.installationId)
        .toSet();
    final eligible = state.cleanup(
      retentionDays: configuration.cli.retention.snapshotDays,
      localEdits: request.localEdits,
      installationIds: installationIds,
      dryRun: true,
    );
    final warnings = <PackWarning>[
      if (request.localEdits)
        const PackWarning(
          id: 'local-edit-cleanup',
          message: 'Explicitly selected locally edited backups are unrecoverable after cleanup.',
        ),
    ];
    final plan = PackPlan.create(
      operation: '${request.resourceType.name}s.cleanup',
      context: _contextJson(request, context, configuration),
      source: {'pack': pack.key},
      resources: [
        for (final record in records)
          PackResourcePlan(
            type: request.resourceType.name,
            name: record.name,
            action: 'cleanup',
            method: _recordMethod(record.kind),
            targets: record.validatedProfiles,
            linkOnly: record.kind == ArtifactKind.skillLink,
          ),
      ],
      warnings: warnings,
      cleanupRefs: eligible,
    );
    if (!request.dryRun) await _confirmPlan(request, plan);
    final pruned = request.dryRun
        ? eligible
        : state.cleanup(
            retentionDays: configuration.cli.retention.snapshotDays,
            localEdits: request.localEdits,
            installationIds: installationIds,
          );
    final results = <PackResourceResult>[];
    for (final record in records) {
      final refs = pruned.where((ref) {
        return snapshots.any(
          (snapshot) =>
              snapshot.ref == ref &&
              snapshot.installationId == record.installationId,
        );
      }).toList();
      if (refs.isNotEmpty) {
        results.add(
          _result(request, record.name, 'removed', snapshot: refs.join(',')),
        );
      }
    }
    if (!request.dryRun) {
      _persistPackOperation(
        context: context,
        plan: plan,
        results: results,
        outcome: pruned.isEmpty ? 'no-op' : 'completed',
        packKey: pack.key,
        type: request.resourceType,
        noSave: request.noSave,
      );
    }
    return PackOperationResult(
      operation: '${request.resourceType.name}s.cleanup',
      outcome: request.dryRun
          ? 'preview'
          : pruned.isEmpty
          ? 'no-op'
          : 'completed',
      context: _contextJson(request, context, configuration),
      source: {'pack': pack.key, 'prunedSnapshotRefs': pruned},
      resources: results,
      warnings: warnings,
      dryRun: request.dryRun,
      plan: plan,
    );
  }

  Future<PackOperationResult> _remove(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackConfiguration configuration,
    PackDefinition pack,
  ) async {
    final records = _packRecords(context, pack.key, request.resourceType)
        .where(
          (record) =>
              record.lifecycle == 'live' && request.only.contains(record.name),
        )
        .toList();
    final missing = request.only
        .where((name) => records.every((record) => record.name != name))
        .toList();
    if (missing.isNotEmpty) {
      throw MambaException(
        'Unknown managed native name(s): ${missing.join(', ')}.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final plan = PackPlan.create(
      operation: '${request.resourceType.name}s.remove',
      context: _contextJson(request, context, configuration),
      source: {'pack': pack.key},
      resources: [
        for (final record in records)
          PackResourcePlan(
            type: request.resourceType.name,
            name: record.name,
            action: 'remove',
            method: _recordMethod(record.kind),
            targets: record.validatedProfiles,
            previousSnapshot: _currentSnapshotRef(context, record),
            linkOnly: record.kind == ArtifactKind.skillLink,
            changedPaths: PackChangeSet.between(record.baseline, null),
          ),
      ],
    );
    await _confirmPlan(request, plan);
    final results = <PackResourceResult>[];
    for (final record in records) {
      if (!request.dryRun) {
        await _removeRecord(request, context, record);
        PackState(stateDirectory: context.stateRoot())
            .markInstallationNoncurrent(record.installationId);
      }
      results.add(
        _result(
          request,
          record.name,
          'removed',
          changedPaths: PackChangeSet.between(record.baseline, null),
        ),
      );
    }
    if (!request.dryRun) {
      _persistPackOperation(
        context: context,
        plan: plan,
        results: results,
        outcome: 'completed',
        packKey: pack.key,
        type: request.resourceType,
        noSave: request.noSave,
      );
    }
    return PackOperationResult(
      operation: '${request.resourceType.name}s.remove',
      outcome: request.dryRun ? 'preview' : 'completed',
      context: _contextJson(request, context, configuration),
      source: {'pack': pack.key},
      resources: results,
      dryRun: request.dryRun,
      plan: plan,
    );
  }

  Future<void> _removeRecord(
    PackLifecycleRequest request,
    LifecycleContext context,
    InstallationRecord record,
  ) async {
    final resource = _resourceForExisting(record);
    if (record.kind == ArtifactKind.skillCanonical) {
      await _lifecycleState.removeCanonical(
        resource: resource,
        context: context,
        installationId: record.installationId,
      );
    } else {
      final modified =
          _lifecycleState.verify(record) != ModificationStatus.unchanged;
      if (modified) _recordEditedSnapshot(context, record);
      await _lifecycleState.remove(
        resource: resource,
        context: context,
        installationId: record.installationId,
        allowModified: modified,
      );
    }
  }

  Future<void> _replaceRecord(
    PackLifecycleRequest request,
    LifecycleContext context,
    LifecycleResource resource,
    InstallationRecord record,
    _PackCandidate candidate,
  ) async {
    if (record.kind == ArtifactKind.skillCanonical) {
      await _lifecycleState.replaceCanonical(
        resource: resource,
        context: context,
        installationId: record.installationId,
        source: candidate.path,
        origin: candidate.origin,
        exposures: candidate.historicalInstallation?.exposures,
        knownConsumers: candidate.historicalInstallation?.knownConsumers,
        validatedProfiles: candidate.historicalInstallation?.validatedProfiles,
        allowModified:
            _lifecycleState.verify(record) != ModificationStatus.unchanged,
      );
    } else {
      await _lifecycleState.replace(
        resource: resource,
        context: context,
        installationId: record.installationId,
        source: candidate.path,
        origin: candidate.origin,
        allowModified:
            _lifecycleState.verify(record) != ModificationStatus.unchanged,
        allowedPaths: {
          for (final other in _packRecords(
            context,
            record.origin['packKey']! as String,
            request.resourceType,
          ))
            if (other.installationId != record.installationId &&
                other.lifecycle == 'live' &&
                other.name == record.name)
              other.location,
        },
      );
    }
  }

  InstallationUnitPlan _installationUnit(
    LifecycleContext context,
    _PackCandidate candidate,
    SkillInstallMethod? method,
    List<String> targets,
    PackResourceType type,
  ) {
    if (type == PackResourceType.agent) {
      final harness = _harness(candidate.profile!);
      final root = _agents.installRoot(context, harness);
      final location = p.join(root, p.basename(candidate.path));
      return InstallationUnitPlan(
        resourceType: InstallationResourceType.agent,
        resourceId: candidate.name,
        nativeName: candidate.name,
        profile: candidate.profile!.wireName,
        method: InstallationMethod.copy,
        status: InstallationUnitStatus.planned,
        installationIds: const [],
        entries: [
          InstallationEntryPlan(
            path: location,
            kind: InstallationEntryKind.copy,
            action: InstallationEntryAction.createCopy,
            target: harness.name,
            nativeRoot: root,
            nativeDestination: 'native',
            artifactKind: OwnedArtifactKind.agentFile,
          ),
        ],
        sourcePath: candidate.path,
        sourceDigest: candidate.digest,
        origin: candidate.origin,
      );
    }

    final selectedMethod = method!;
    final entries = <InstallationEntryPlan>[];
    if (selectedMethod == SkillInstallMethod.canonical) {
      final root = p.normalize(context.sharedSkillsRoot());
      final canonical = p.join(root, candidate.name);
      entries.add(
        InstallationEntryPlan(
          path: canonical,
          kind: InstallationEntryKind.content,
          action: InstallationEntryAction.createContent,
          target: targets.contains('codex') ? 'codex' : null,
          nativeRoot: root,
          nativeDestination: 'canonical',
          artifactKind: OwnedArtifactKind.skillCanonical,
        ),
      );
      if (targets.contains('claude')) {
        final claudeRoot = p.normalize(context.claudeSkillsRoot());
        entries.add(
          InstallationEntryPlan(
            path: p.join(claudeRoot, candidate.name),
            kind: InstallationEntryKind.link,
            action: InstallationEntryAction.createLink,
            target: 'claude',
            linkTarget: canonical,
            nativeLinkKind: _nativeDirectoryLinkKind,
            nativeRoot: claudeRoot,
            nativeDestination: 'claude',
            artifactKind: OwnedArtifactKind.skillLink,
          ),
        );
      }
      if (targets.contains('codex')) {
        entries.add(
          InstallationEntryPlan(
            path: canonical,
            kind: InstallationEntryKind.consumer,
            action: InstallationEntryAction.recordConsumer,
            target: 'codex',
          ),
        );
      }
    } else {
      for (final target in targets) {
        final root = p.normalize(
          target == 'claude'
              ? context.claudeSkillsRoot()
              : context.sharedSkillsRoot(),
        );
        entries.add(
          InstallationEntryPlan(
            path: p.join(root, candidate.name),
            kind: selectedMethod == SkillInstallMethod.copy
                ? InstallationEntryKind.copy
                : InstallationEntryKind.link,
            action: selectedMethod == SkillInstallMethod.copy
                ? InstallationEntryAction.createCopy
                : InstallationEntryAction.createLink,
            target: target,
            linkTarget: selectedMethod == SkillInstallMethod.sourceLink
                ? candidate.path
                : null,
            nativeLinkKind: selectedMethod == SkillInstallMethod.sourceLink
                ? _nativeDirectoryLinkKind
                : null,
            nativeRoot: root,
            nativeDestination: target == 'claude' ? 'claude' : 'shared',
            artifactKind: selectedMethod == SkillInstallMethod.copy
                ? OwnedArtifactKind.skillCopy
                : OwnedArtifactKind.skillLink,
          ),
        );
      }
    }
    return InstallationUnitPlan(
      resourceType: InstallationResourceType.skill,
      resourceId: candidate.name,
      nativeName: candidate.name,
      profile: null,
      method: switch (selectedMethod) {
        SkillInstallMethod.canonical => InstallationMethod.canonical,
        SkillInstallMethod.copy => InstallationMethod.copy,
        SkillInstallMethod.sourceLink => InstallationMethod.sourceLink,
      },
      status: InstallationUnitStatus.planned,
      installationIds: const [],
      entries: entries,
      sourcePath: candidate.path,
      sourceDigest: candidate.digest,
      origin: candidate.origin,
    );
  }

  LifecycleResource _resourceFor(
    _PackCandidate candidate,
    SkillInstallMethod? method,
    InstallationUnitPlan unit,
  ) {
    if (candidate.type == PackResourceType.agent) {
      return _agents.installationResource(_harness(candidate.profile!));
    }
    return _skills.installationResource(
      targets: [for (final entry in unit.entries) ?entry.target],
      kind: switch (method!) {
        SkillInstallMethod.canonical => ArtifactKind.skillCanonical,
        SkillInstallMethod.copy => ArtifactKind.skillCopy,
        SkillInstallMethod.sourceLink => ArtifactKind.skillLink,
      },
      allowedExtraFolders: candidate.extraFolders,
    );
  }

  LifecycleResource _resourceForRecord(
    _PackCandidate candidate,
    InstallationRecord record,
  ) {
    if (record.kind == ArtifactKind.agentFile) {
      return _agents.installationResource(
        AgentHarness.values.firstWhere(
          (value) => value.name == record.nativeProfile,
        ),
      );
    }
    return _skills.installationResource(
      targets:
          candidate.historicalInstallation?.validatedProfiles ??
          record.validatedProfiles,
      kind: record.kind,
      allowedExtraFolders: candidate.extraFolders,
    );
  }

  LifecycleResource _resourceForExisting(InstallationRecord record) {
    if (record.kind == ArtifactKind.agentFile) {
      return _agents.installationResource(
        AgentHarness.values.firstWhere(
          (value) => value.name == record.nativeProfile,
        ),
      );
    }
    return _skills.installationResource(
      targets: record.validatedProfiles,
      kind: record.kind,
    );
  }

  Future<List<_PackValidationCandidate>> _validationCandidates(
    AcquisitionWorkspace workspace,
    PackDefinition pack,
    PackResourceType type,
  ) async {
    final catalogPath = p.join(
      workspace.selectedRoot,
      packConfigurationFileName,
    );
    final catalogType = skillEntityType(catalogPath, followLinks: false);
    if (catalogType == FileSystemEntityType.link) {
      throw MambaException(
        'The publisher catalog must not be a linked source alias.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final catalog = catalogType == FileSystemEntityType.notFound
        ? null
        : _readSourceCatalog(workspace, type: type);
    final paths = switch (type) {
      PackResourceType.skill => [
        for (final entry in catalog?.skills ?? const <SkillCatalogEntry>[])
          (entry.path, null),
      ],
      PackResourceType.agent => [
        for (final entry in catalog?.agents ?? const <AgentCatalogEntry>[])
          (entry.path, entry.profile),
      ],
    };
    if (catalog?.declared == true) {
      return [
        for (final (relative, profile) in paths)
          _PackValidationCandidate(
            type: type,
            relativePath: relative,
            path: _validationSourcePath(workspace, relative),
            profile: profile,
          ),
      ];
    }
    final relativeRoot = type == PackResourceType.skill
        ? pack.discovery.skillsDirectory
        : pack.discovery.agentsDirectory;
    final root = _validationSourcePath(workspace, relativeRoot);
    final rootType = skillEntityType(root, followLinks: false);
    if (rootType == FileSystemEntityType.notFound) return const [];
    if (rootType != FileSystemEntityType.directory) {
      throw MambaException(
        'Pack discovery root must be a real directory: '
        '${ValidationDiagnostics.escape(relativeRoot)}.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final result = <_PackValidationCandidate>[];
    var entries = 0;
    Future<void> visit(Directory directory, String relative, int depth) async {
      if (depth > 16) {
        throw MambaException(
          'Pack discovery exceeds its depth-16 budget.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      final children = <FileSystemEntity>[];
      await for (final child in directory.list(followLinks: false)) {
        if (++entries > 20000) {
          throw MambaException(
            'Pack discovery exceeds its 20,000-entry budget.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        children.add(child);
      }
      children.sort((left, right) => left.path.compareTo(right.path));
      for (final child in children) {
        final childRelative = p.posix.join(relative, p.basename(child.path));
        final childType = skillEntityType(child.path, followLinks: false);
        if (childType == FileSystemEntityType.link) {
          throw MambaException(
            'Pack discovery refuses linked source entries: '
            '${ValidationDiagnostics.escape(childRelative)}.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        if (type == PackResourceType.skill) {
          if (childType == FileSystemEntityType.directory) {
            result.add(
              _PackValidationCandidate(
                type: type,
                relativePath: childRelative,
                path: child.path,
                profile: null,
              ),
            );
            if (result.length > 1000) {
              throw MambaException(
                'Pack discovery exceeds its 1,000-resource budget.',
                exitCode: PackProcessStatus.invalidInput.code,
              );
            }
          }
          continue;
        }
        if (childType == FileSystemEntityType.directory) {
          await visit(child as Directory, childRelative, depth + 1);
        } else if (childType == FileSystemEntityType.file &&
            const {'.md', '.toml'}.contains(p.extension(child.path))) {
          result.add(
            _PackValidationCandidate(
              type: type,
              relativePath: childRelative,
              path: child.path,
              profile: null,
            ),
          );
          if (result.length > 1000) {
            throw MambaException(
              'Pack discovery exceeds its 1,000-resource budget.',
              exitCode: PackProcessStatus.invalidInput.code,
            );
          }
        }
      }
    }

    await visit(Directory(root), relativeRoot, 0);
    return result;
  }

  String _validationSourcePath(
    AcquisitionWorkspace workspace,
    String relative,
  ) {
    if (relative == '.') return workspace.selectedRoot;
    final path = _catalogPath(workspace, relative);
    var current = workspace.selectedRoot;
    if (relative != '.') {
      for (final segment in p.posix.split(relative)) {
        current = p.join(current, segment);
        if (skillEntityType(current, followLinks: false) ==
            FileSystemEntityType.link) {
          throw MambaException(
            'Pack source paths must not contain linked aliases: '
            '${ValidationDiagnostics.escape(relative)}.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
      }
    }
    return path;
  }

  _InspectedPackResource _inspectPackResource(
    _PackValidationCandidate candidate,
    PackDefinition pack,
  ) {
    String? name;
    final failures = <String>[];
    final warnings = <String>[];
    try {
      if (candidate.type == PackResourceType.skill) {
        name = readDeclaredSkillName(candidate.path);
        final approvedExtraFolders = pack.resources.skills.overrides
            .where((override) => override.name == name)
            .expand((override) => override.extraFolders)
            .toSet();
        _admission.inspect(
          candidate.path,
          approvedExtraFolders: approvedExtraFolders,
        );
        final report = validateSkill(candidate.path);
        for (final diagnostic in report.diagnostics) {
          final label = _validationDiagnosticLabel(
            diagnostic.code,
            diagnostic.field,
          );
          if (diagnostic.severity == DiagnosticSeverity.error) {
            failures.add(label);
          } else {
            warnings.add(label);
          }
        }
      } else if (candidate.profile == null) {
        failures.add(
          'NATIVE_PROFILE_REQUIRED: discovered Agents require an explicit '
          'catalog profile (claude, codex, or pi-common); no profile was inferred',
        );
      } else {
        final report = inspectNativeAgent(
          AgentInspectionInput(
            nativeFile: candidate.path,
            harness: _harness(candidate.profile!),
          ),
          operation: AgentOperation.validate,
        );
        final identity = report.identity['name'];
        if (identity is Map<String, Object?>) {
          name = identity['resolved'] as String?;
        }
        if (name == null) failures.add('NATIVE_NAME_UNRESOLVED');
        for (final diagnostic in report.diagnostics) {
          final label = _validationDiagnosticLabel(
            diagnostic.code,
            diagnostic.field,
          );
          if (diagnostic.severity == AgentDiagnosticSeverity.error) {
            failures.add(label);
          } else {
            warnings.add(label);
          }
        }
      }
    } on MambaException catch (error) {
      failures.add(
        candidate.type == PackResourceType.skill
            ? 'SKILL_SOURCE_REJECTED (source): the Skill root, marker, name, '
                  'or tree was not admitted (status ${error.exitCode})'
            : 'NATIVE_INSPECTION_INCOMPLETE: validation could not complete '
                  'safely (status ${error.exitCode})',
      );
    }
    return _InspectedPackResource(
      candidate: candidate,
      name: name,
      failures: failures,
      warnings: warnings,
    );
  }

  String _validationDiagnosticLabel(String code, String? field) => field == null
      ? ValidationDiagnostics.escape(code)
      : '${ValidationDiagnostics.escape(code)} '
            '(${ValidationDiagnostics.escape(field)})';

  void _requireUniqueValidationNames(
    List<_InspectedPackResource> resources,
    PackDefinition pack,
  ) {
    final names = <String, List<_InspectedPackResource>>{};
    for (final resource in resources) {
      if (resource.name != null) {
        names.putIfAbsent(resource.name!, () => []).add(resource);
      }
    }
    final duplicates = names.entries
        .where(
          (entry) =>
              entry.value.length > 1 &&
              entry.value
                      .map((resource) => resource.candidate.type)
                      .toSet()
                      .length !=
                  entry.value.length,
        )
        .map((entry) => entry.key)
        .toList();
    if (duplicates.isNotEmpty) {
      throw MambaException(
        'Duplicate native name(s) in pack ${pack.key}: '
        '${duplicates.map(ValidationDiagnostics.escape).join(', ')}.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  List<_InspectedPackResource> _selectValidatedResources(
    PackLifecycleRequest request,
    PackDefinition pack,
    List<_InspectedPackResource> resources,
  ) {
    if (request.only.isNotEmpty) {
      final unknown = request.only
          .where((name) => resources.every((resource) => resource.name != name))
          .toList();
      if (unknown.isNotEmpty) {
        throw MambaException(
          'Unknown native name(s) in pack ${pack.key}: '
          '${unknown.map(ValidationDiagnostics.escape).join(', ')}.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      final ambiguous = request.only.where((name) {
        final matches = resources
            .where((resource) => resource.name == name)
            .toList();
        return matches.length > 1;
      }).toList();
      if (ambiguous.isNotEmpty) {
        throw MambaException(
          'Ambiguous native name(s) across selected types: '
          '${ambiguous.map(ValidationDiagnostics.escape).join(', ')}; '
          'select one --type.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      return resources
          .where(
            (resource) =>
                resource.name == null || request.only.contains(resource.name),
          )
          .toList();
    }
    return resources.where((resource) {
      final name = resource.name;
      if (name == null) return true;
      final rules = resource.candidate.type == PackResourceType.skill
          ? pack.resources.skills
          : pack.resources.agents;
      return !rules.exclusions.contains(name);
    }).toList();
  }

  Future<List<_PackCandidate>> _candidates(
    PackLifecycleRequest request,
    LifecycleContext context,
    AcquisitionWorkspace workspace,
    SourceCatalog catalog,
    PackDefinition pack,
    _ReleaseEvidence? release, {
    Map<String, Set<String>> reusableFolders = const <String, Set<String>>{},
  }) async {
    final paths = request.resourceType == PackResourceType.skill
        ? catalog.skills.map((entry) => (entry.path, null)).toList()
        : catalog.agents.map((entry) => (entry.path, entry.profile)).toList();
    final folderApprovals = _folderApprovals(request.allowFolder);
    final rules = request.resourceType == PackResourceType.skill
        ? pack.resources.skills
        : pack.resources.agents;
    final requestedFolders = <String, Set<String>>{
      for (final override in rules.overrides)
        override.name: override.extraFolders.toSet(),
    };
    final result = <_PackCandidate>[];
    final names = <String, String>{};
    for (final (relative, profile) in paths) {
      final path = _catalogPath(workspace, relative);
      final String name;
      var extraFolders = <String>{};
      if (request.resourceType == PackResourceType.skill) {
        name = readDeclaredSkillName(path);
        extraFolders = {...?folderApprovals[name], ...?reusableFolders[name]};
        extraFolders = await _promptExtraFolders(
          request,
          path,
          name,
          extraFolders,
          requestedFolders: requestedFolders[name] ?? const <String>{},
        );
        _admission.inspect(path, approvedExtraFolders: extraFolders);
      } else {
        final resource = _agents.installationResource(_harness(profile!));
        name = (await resource.inspect(path, context)).name;
      }
      final previous = names[name];
      if (previous != null) {
        throw MambaException(
          'Duplicate native name $name in pack ${pack.key}: $previous and $relative.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      names[name] = relative;
      final digest = _lifecycleState.contentDigest(
        path,
        request.resourceType == PackResourceType.skill
            ? ArtifactKind.skillCopy
            : ArtifactKind.agentFile,
      );
      final origin = <String, Object?>{
        'status': 'evidenced',
        'schemaVersion': 1,
        'packKey': pack.key,
        'resourceType': request.resourceType.name,
        'resourceName': name,
        'catalogPath': relative,
        if (extraFolders.isNotEmpty)
          'approvedExtraFolders': extraFolders.toList()..sort(),
        'source': workspace.provenance.toJson(),
        'track': _trackJson(pack.update.track),
        if (release != null) ...release.toEvidenceJson(),
        'contentDigest': digest,
        if (profile != null) 'profile': profile.wireName,
      };
      result.add(
        _PackCandidate(
          type: request.resourceType,
          name: name,
          path: path,
          profile: profile,
          digest: digest,
          extraFolders: extraFolders,
          origin: origin,
        ),
      );
    }
    return result;
  }

  List<_PackCandidate> _selectCandidates(
    PackLifecycleRequest request,
    PackDefinition pack,
    List<_PackCandidate> candidates,
    List<InstallationRecord> existing,
    Map<String, bool> selectionDecisions,
  ) {
    final rules = request.resourceType == PackResourceType.skill
        ? pack.resources.skills
        : pack.resources.agents;
    if (request.only.isNotEmpty) {
      final known = <String>{
        ...candidates.map((candidate) => candidate.name),
        ...existing.map((record) => record.name),
      };
      final unknown = request.only
          .where((name) => !known.contains(name))
          .toList();
      if (unknown.isNotEmpty) {
        throw MambaException(
          'Unknown native name(s) in pack ${pack.key}: ${unknown.join(', ')}.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      return candidates
          .where((candidate) => request.only.contains(candidate.name))
          .toList();
    }
    return candidates.where((candidate) {
      if (rules.exclusions.contains(candidate.name) ||
          selectionDecisions[candidate.name] == false) {
        return false;
      }
      if (selectionDecisions[candidate.name] == true) return true;
      if (request.operation == PackOperation.update &&
          existing.every((record) => record.name != candidate.name)) {
        return true;
      }
      return true;
    }).toList();
  }

  Map<String, Set<String>> _reusableFolderApprovals(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackConfiguration configuration,
    List<InstallationRecord> records,
    PackDefinition pack,
    AcquisitionProvenance provenance,
  ) {
    final approvals = PackState(stateDirectory: context.stateRoot())
        .read()
        .approvals
        .where((approval) {
          return approval['packKey'] == pack.key &&
              approval['resourceType'] == request.resourceType.name &&
              approval['scope'] == context.scope.name &&
              approval['sourceRequested'] == provenance.requestedLocator &&
              approval['sourceResolved'] == provenance.resolvedLocator;
        })
        .toList();
    final result = <String, Set<String>>{};
    for (final approval in approvals) {
      final name = approval['resourceName'];
      final folder = approval['folder'];
      if (name is! String || folder is! String) continue;
      final matchingRecords = records
          .where((record) => record.name == name)
          .toList();
      final requestedTargets = request.target != null
          ? <String>{request.target!}
          : pack.install.targets.isNotEmpty
          ? pack.install.targets.toSet()
          : configuration.cli.install.targets.toSet();
      final destinationMatches = matchingRecords.isEmpty
          ? requestedTargets.contains(approval['destination']) ||
                (requestedTargets.contains('codex') &&
                    const {
                      'shared',
                      'canonical',
                    }.contains(approval['destination']))
          : matchingRecords.any(
              (record) => record.nativeDestination == approval['destination'],
            );
      if (!destinationMatches) continue;
      result.putIfAbsent(name, () => <String>{}).add(folder);
    }
    return result;
  }

  Map<String, bool> _selectionDecisions(
    LifecycleContext context,
    String packKey,
    PackResourceType type,
  ) {
    final result = <String, bool>{};
    for (final selection in PackState(
      stateDirectory: context.stateRoot(),
    ).read().selections) {
      if (selection['packKey'] != packKey ||
          selection['resourceType'] != type.name ||
          selection['scope'] != context.scope.name ||
          selection['resourceName'] is! String) {
        continue;
      }
      final name = selection['resourceName']! as String;
      if (selection['excluded'] == true ||
          (selection['reason'] == 'declined' &&
              selection['selected'] == false)) {
        result[name] = false;
      } else if (selection['selected'] == true) {
        result[name] = true;
      }
    }
    return result;
  }

  void _recordSelectionChoice(
    LifecycleContext context,
    String packKey,
    PackResourceType type,
    String name, {
    required bool selected,
    required String reason,
  }) {
    PackState(stateDirectory: context.stateRoot()).recordSelections([
      {
        'packKey': packKey,
        'resourceType': type.name,
        'resourceName': name,
        'scope': context.scope.name,
        'selected': selected,
        'reason': reason,
        'excluded': !selected,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      },
    ]);
  }

  List<InstallationRecord> _targetedRecords(
    PackLifecycleRequest request,
    Iterable<InstallationRecord> records,
  ) {
    final target = request.target;
    if (target == null) return records.toList();
    return records.where((record) {
      return record.validatedProfiles.contains(target) ||
          record.nativeDestination == target ||
          target == 'codex' && record.nativeDestination == 'shared';
    }).toList();
  }

  List<InstallationRecord> _packRecords(
    LifecycleContext context,
    String packKey,
    PackResourceType type,
  ) => _lifecycleState
      .records(context)
      .where(
        (record) =>
            record.origin['packKey'] == packKey &&
            record.origin['resourceType'] == type.name,
      )
      .toList();

  Future<_AcquiredSource> _acquire(
    PackDefinition pack,
    PackConfiguration configuration, {
    required PackLifecycleRequest request,
    List<InstallationRecord> existing = const <InstallationRecord>[],
  }) async {
    final source = pack.source;
    final track = pack.update.track;
    var locator = switch (source) {
      LocalPackSource local => local.path,
      GitHubPackSource github => 'https://${github.host}/${github.repository}',
      GitPackSource git => git.url,
      DownloadPackSource download => download.url,
    };
    var ref = switch (track) {
      BranchTrack branch => branch.name,
      TagTrack tag => tag.name,
      CommitTrack commit => commit.commit,
      _ => null,
    };
    _ReleaseEvidence? release;
    if (track is ReleaseTrack) {
      if (source is! GitHubPackSource) {
        throw MambaException(
          'Release tracks require a GitHub repository source.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      final current = existing.isEmpty
          ? null
          : switch (existing.first.origin['release']) {
              final Map<String, Object?> value =>
                release_policy.ReleaseCandidate(
                  literalTag: value['literalTag']! as String,
                  id: value['id']?.toString(),
                  isDraft: value['draft'] == true,
                  isPrerelease: value['prerelease'] == true,
                ),
              _ => null,
            };
      final requestedBump = request.bump ?? pack.update.bump?.name;
      if (request.release == null && current != null && requestedBump == null) {
        if (!request.interactive || request.yes) {
          throw MambaException(
            'A release update requires --bump or a saved update.bump policy; '
            'no implicit latest or major bump is assumed.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
      }
      final bump = requestedBump ?? await _promptReleaseBump(request);
      try {
        final resolution = await _releases.resolve(
          source: source,
          track: track,
          policy: release_policy.ReleasePolicy(
            bump: switch (bump) {
              'patch' => release_policy.ReleaseBump.patch,
              'minor' => release_policy.ReleaseBump.minor,
              'major' => release_policy.ReleaseBump.major,
              null => release_policy.ReleaseBump.major,
              final value => throw MambaException(
                'Unsupported release bump: $value.',
                exitCode: PackProcessStatus.invalidInput.code,
              ),
            },
            includePrerelease:
                request.includePrerelease || pack.update.includePrerelease,
          ),
          current: current,
          exactTag: request.release,
        );
        release = _ReleaseEvidence.fromResolution(resolution);
        switch (resolution.acquisition) {
          case GithubArchiveAcquisition archive:
            locator = archive.repositoryUri.toString();
            ref = archive.commit ?? archive.gitRef;
          case GithubAttachmentAcquisition attachment:
            locator = attachment.downloadUri.toString();
            ref = null;
            await _requireAttachmentIdentity(
              request,
              existing,
              attachment,
              resolution.release,
            );
        }
      } on GithubReleaseResolverException catch (error) {
        throw MambaException(
          error.message,
          exitCode: PackProcessStatus.invalidInput.code,
        );
      } on release_policy.ReleaseSelectionException catch (error) {
        throw MambaException(
          error.message,
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
    final workspace = await _acquirer.acquire(
      AcquisitionRequest(
        locator: locator,
        cwd: p.dirname(configuration.configPath),
        resourceType: CatalogResourceType.skill,
        sourceKind: AcquisitionSourceKind.collection,
        ref: ref,
        subpath: source.subpath,
      ),
    );
    final expectedDigest = release?.attachmentDigest;
    final actualDigest = workspace.provenance.downloadDigest;
    if (expectedDigest != null &&
        actualDigest != null &&
        expectedDigest != 'sha256:$actualDigest') {
      await workspace.close();
      throw MambaException(
        'Downloaded attachment bytes do not match the provider digest.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    return _AcquiredSource(workspace, release);
  }

  static const _nativeSkillFolders = <String>{
    'references',
    'scripts',
    'assets',
    'agents',
  };

  Future<Set<String>> _promptExtraFolders(
    PackLifecycleRequest request,
    String path,
    String name,
    Set<String> approved, {
    Set<String> requestedFolders = const <String>{},
  }) async {
    if (!request.interactive || request.yes) return approved;
    final result = {...approved};
    final actual = <String>{
      for (final entity in listSkillDirectory(path))
        if (skillEntityType(entity.path, followLinks: false) ==
            FileSystemEntityType.directory)
          p.basename(entity.path),
    };
    final folders = {...actual, ...requestedFolders}.toList()..sort();
    for (final folder in folders) {
      if (folder == 'SKILL.md' ||
          _nativeSkillFolders.contains(folder) ||
          result.contains(folder) ||
          !actual.contains(folder)) {
        continue;
      }
      final requested = requestedFolders.contains(folder);
      if (await _promptYesNo(
        requested
            ? 'Skill $name requests extra root folder $folder. Allow it?'
            : 'Skill $name has unexpected root folder $folder. Allow it?',
      )) {
        result.add(folder);
      }
    }
    return result;
  }

  Future<bool> _promptYesNo(String label) async {
    final injected = prompts.confirmation;
    if (injected != null) return injected(label);
    return InstallationApprovalComponent(label: label).render();
  }

  Future<String?> _promptChoice(String label, List<String> choices) async {
    final injected = prompts.choice;
    if (injected != null) return injected(label, choices);
    while (true) {
      stdout.write('$label ');
      final answer = stdin.readLineSync()?.trim().toLowerCase();
      if (answer == null || answer.isEmpty) return null;
      if (choices.contains(answer)) return answer;
    }
  }

  Future<String?> _promptReleaseBump(PackLifecycleRequest request) async {
    if (request.operation == PackOperation.validate ||
        !request.interactive ||
        request.yes) {
      return null;
    }
    final answer = await _promptChoice(
      'Release bump [patch/minor/major]:',
      const ['patch', 'minor', 'major'],
    );
    if (answer == null) {
      throw MambaException(
        'Release update cancelled; no implicit bump was selected.',
        exitCode: PackProcessStatus.cancelled.code,
      );
    }
    return answer;
  }

  Future<void> _requireAttachmentIdentity(
    PackLifecycleRequest request,
    List<InstallationRecord> existing,
    GithubAttachmentAcquisition attachment,
    GithubReleaseEvidence release,
  ) async {
    final previous = existing
        .map((record) => record.origin['attachment'])
        .whereType<Map<String, Object?>>()
        .where((value) => value['name'] == attachment.name)
        .toList();
    if (previous.isEmpty) return;
    final recorded = previous.first;
    if (recorded['releaseId'] != release.id) return;
    final same =
        recorded['digest'] == attachment.digest &&
        recorded['id'] == attachment.id;
    if (same) return;
    if (!request.interactive || request.yes) {
      throw MambaException(
        'Changed or unverified same-release attachment bytes require live interactive acceptance; unattended --yes cannot accept them.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final accepted = await _promptYesNo(
      'The same release attachment ${attachment.name} has changed or unverified bytes. Accept this exact candidate?',
    );
    if (!accepted) {
      throw MambaException(
        'Changed attachment review cancelled; no resource was published.',
        exitCode: PackProcessStatus.cancelled.code,
      );
    }
    GithubReleaseResolver.requireAcceptedAttachmentChange(
      previous: GithubAttachmentEvidence(
        releaseId: recorded['releaseId'] is int
            ? recorded['releaseId']! as int
            : -1,
        attachmentId: recorded['id'] is int ? recorded['id']! as int : -1,
        attachmentName: recorded['name'] is String
            ? recorded['name']! as String
            : attachment.name,
        digest: recorded['digest'] is String
            ? recorded['digest']! as String
            : '',
      ),
      candidate: GithubReleaseResolution(
        release: release,
        acquisition: attachment,
      ),
      interactive: true,
      accepted: true,
    );
  }

  SourceCatalog _readSourceCatalog(
    AcquisitionWorkspace workspace, {
    PackResourceType? type,
  }) {
    final path = p.join(workspace.selectedRoot, packConfigurationFileName);
    if (skillEntityType(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw MambaException(
        'The acquired pack has no $packConfigurationFileName publisher catalog.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final bytes = File(path).readAsBytesSync();
    if (bytes.length > 1024 * 1024) {
      throw MambaException(
        'The publisher catalog exceeds the 1 MiB budget.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    try {
      return PackConfiguration.parse(
        utf8.decode(bytes, allowMalformed: false),
        configPath: path,
        catalogType: switch (type) {
          PackResourceType.skill => CatalogResourceType.skill,
          PackResourceType.agent => CatalogResourceType.agent,
          null => null,
        },
      ).catalog;
    } on PackConfigurationException catch (error) {
      throw MambaException(
        'Invalid publisher catalog ${error.configPath}: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on FormatException catch (error) {
      throw MambaException(
        'Invalid publisher catalog: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  String _catalogPath(AcquisitionWorkspace workspace, String relative) {
    if (relative == '.' ||
        relative.startsWith('../') ||
        p.posix.isAbsolute(relative)) {
      throw MambaException(
        'Catalog path escapes the package: $relative',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final path = p.normalize(
      p.joinAll([workspace.selectedRoot, ...p.posix.split(relative)]),
    );
    if (!p.isWithin(workspace.selectedRoot, path)) {
      throw MambaException(
        'Catalog path escapes the package: $relative',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (skillEntityType(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw MambaException(
        'Catalog entries must not be linked aliases: $relative',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    for (final omitted in workspace.omittedLinkPaths) {
      if (omitted == relative || omitted.startsWith('$relative/')) {
        throw MambaException(
          'The selected resource contains an unsafe source link: $omitted',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
    return path;
  }

  PackConfiguration _loadConfiguration(
    PackLifecycleRequest request,
    LifecycleContext context,
  ) {
    final scope = request.scope ?? LifecycleScope.project;
    try {
      return PackConfiguration.load(
        scope: scope == LifecycleScope.project
            ? PackConfigurationScope.project
            : PackConfigurationScope.user,
        projectRoot: context.projectRoot,
        explicitPath: request.configPath,
        workingDirectory: context.cwd,
        environment: request.environment,
      );
    } on PackConfigurationException catch (error) {
      throw MambaException(
        'Configuration validation failed for ${error.configPath}:\n${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  LifecycleContext _context(PackLifecycleRequest request) =>
      LifecycleContext.resolve(
        LifecycleOptions(
          processWorkingDirectory: request.processWorkingDirectory,
          environment: request.environment,
          scope: request.scope ?? LifecycleScope.project,
          cwd: request.cwd,
          projectRoot: request.projectRoot,
          home: request.home,
          stateDir: request.stateDir,
          dryRun: request.dryRun,
          approved: request.yes || request.interactive,
        ),
      );

  Future<void> _confirmPlan(PackLifecycleRequest request, PackPlan plan) async {
    if (!request.interactive || request.yes || request.dryRun) return;
    stdout.writeln(plan.renderText());
    final approved = await _promptYesNo(
      'Apply this reviewed pack ${request.operation.name}?',
    );
    if (!approved) {
      throw MambaException(
        'Operation cancelled; no pack or installation state was published.',
        exitCode: PackProcessStatus.cancelled.code,
      );
    }
  }

  String _recordMethod(ArtifactKind kind) => switch (kind) {
    ArtifactKind.skillCanonical => 'canonical',
    ArtifactKind.skillLink => 'source-link',
    _ => 'copy',
  };

  PackPolicyChange? _policyChange(
    PackLifecycleRequest request,
    PackDefinition pack,
  ) {
    if (request.operation != PackOperation.update ||
        !request.savePolicy ||
        request.noSave ||
        pack.update.track is! ReleaseTrack) {
      return null;
    }
    if (request.bump == null && !request.includePrerelease) return null;
    return PackPolicyChange(
      bump: request.bump,
      includePrerelease: request.includePrerelease,
      save: true,
    );
  }

  Future<List<String>> _targets(
    PackLifecycleRequest request,
    PackDefinition pack,
    PackConfiguration configuration,
    _PackCandidate candidate,
    InstallationRecord? record,
  ) async {
    if (candidate.type == PackResourceType.agent) {
      final target = _harness(candidate.profile!).name;
      if (request.target != null && request.target != target) {
        throw MambaException(
          'Agent target ${request.target} does not match native profile $target.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      return [target];
    }
    final targets = request.target != null
        ? [request.target!]
        : pack.install.targets.isNotEmpty
        ? pack.install.targets
        : configuration.cli.install.targets;
    if (targets.isEmpty && record != null) return record.validatedProfiles;
    if (targets.isEmpty && request.interactive && !request.yes) {
      final target = await _promptChoice('Skill target [claude/codex]:', const [
        'claude',
        'codex',
      ]);
      if (target == null) {
        throw MambaException(
          'Skill target selection was cancelled; no resource was published.',
          exitCode: PackProcessStatus.cancelled.code,
        );
      }
      return [target];
    }
    if (targets.isEmpty ||
        targets.any(
          (target) => !const {'claude', 'codex', 'shared'}.contains(target),
        )) {
      throw MambaException(
        'Skill installation requires an explicit claude or codex --target/configuration choice.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    return List<String>.unmodifiable(targets.toSet());
  }

  Future<SkillInstallMethod?> _method(
    PackLifecycleRequest request,
    PackDefinition pack,
    PackConfiguration configuration,
    _PackCandidate candidate,
    InstallationRecord? record,
  ) async {
    if (candidate.type == PackResourceType.agent) return null;
    final requested =
        request.operation != PackOperation.install || request.method == null
        ? null
        : SkillInstallMethod.values.firstWhere(
            (method) => method.name == _methodName(request.method!),
          );
    final method =
        requested ??
        pack.install.skillMethod ??
        configuration.cli.install.skillMethod;
    if (method == null && record != null) {
      return switch (record.kind) {
        ArtifactKind.skillCanonical => SkillInstallMethod.canonical,
        ArtifactKind.skillLink => SkillInstallMethod.sourceLink,
        _ => SkillInstallMethod.copy,
      };
    }
    if (method == null && request.interactive && !request.yes) {
      final answer = await _promptChoice(
        'Skill method [canonical/copy/source-link]:',
        const ['canonical', 'copy', 'source-link'],
      );
      if (answer == null) {
        throw MambaException(
          'Skill method selection was cancelled; no resource was published.',
          exitCode: PackProcessStatus.cancelled.code,
        );
      }
      if (answer == 'source-link' && pack.source is! LocalPackSource) {
        throw MambaException(
          'source-link requires a durable local pack source.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      return SkillInstallMethod.values.firstWhere(
        (value) => _methodName(answer) == value.name,
      );
    }
    if (method == null) {
      throw MambaException(
        'Skill installation requires an explicit canonical, copy, or source-link method.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (method == SkillInstallMethod.sourceLink &&
        pack.source is! LocalPackSource) {
      throw MambaException(
        'source-link requires a durable local pack source.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    return method;
  }

  Map<String, Set<String>> _folderApprovals(List<String> values) {
    final result = <String, Set<String>>{};
    for (final value in values) {
      final separator = value.indexOf(':');
      if (separator <= 0 || separator == value.length - 1) {
        throw MambaException(
          '--allow-folder requires <skill-name>:<root-folder>: $value',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      final name = value.substring(0, separator);
      final folder = value.substring(separator + 1);
      if (p.basename(folder) != folder || folder == '.' || folder == '..') {
        throw MambaException(
          '--allow-folder must name one root folder: $value',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      result.putIfAbsent(name, () => <String>{}).add(folder);
    }
    return result;
  }

  List<PackWarning> _modeWarnings(
    PackLifecycleRequest request,
    PackDefinition pack,
  ) {
    final warnings = <PackWarning>[
      if (request.operation == PackOperation.install && request.savePolicy)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--save-policy applies to updates and was ignored.',
        ),
      if (request.operation == PackOperation.update &&
          pack.update.track is! ReleaseTrack &&
          request.savePolicy)
        const PackWarning(
          id: 'inapplicable-option',
          message:
              '--save-policy applies only to release tracks and was ignored.',
        ),
      if (request.operation != PackOperation.install && request.method != null)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--method applies to install and was ignored.',
        ),
      if (request.operation != PackOperation.update && request.skipNew)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--skip-new applies to update and was ignored.',
        ),
      if (request.operation != PackOperation.update &&
          request.approveRemoval.isNotEmpty)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--approve-removal applies to update and was ignored.',
        ),
      if (request.operation != PackOperation.sourceChange && request.to != null)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--to applies to source change and was ignored.',
        ),
      if (request.operation != PackOperation.rollback &&
          request.snapshot != null)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--snapshot applies to rollback and was ignored.',
        ),
      if (request.operation != PackOperation.cleanup && request.localEdits)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--local-edits applies to cleanup and was ignored.',
        ),
      if (request.operation != PackOperation.update &&
          request.keepLocal.isNotEmpty)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--keep-local applies to update and was ignored.',
        ),
      if (request.operation != PackOperation.update &&
          request.replaceLocal.isNotEmpty)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--replace-local applies to update and was ignored.',
        ),
      if (request.operation != PackOperation.install &&
          request.operation != PackOperation.update &&
          request.allowFolder.isNotEmpty)
        const PackWarning(
          id: 'inapplicable-option',
          message:
              '--allow-folder applies to install and update and was ignored.',
        ),
    ];
    if (pack.update.track is ReleaseTrack) return warnings;
    return [
      ...warnings,
      if (request.bump != null)
        const PackWarning(
          id: 'inapplicable-option',
          message:
              '--bump is inapplicable to this source track and was ignored.',
        ),
      if (request.release != null)
        const PackWarning(
          id: 'inapplicable-option',
          message:
              '--release is inapplicable to this source track and was ignored.',
        ),
      if (request.includePrerelease)
        const PackWarning(
          id: 'inapplicable-option',
          message: '--include-prerelease is inapplicable and was ignored.',
        ),
    ];
  }

  void _savePolicy(
    PackConfiguration configuration,
    PackDefinition pack,
    PackLifecycleRequest request,
  ) {
    if (pack.update.track is! ReleaseTrack) return;
    if (request.bump == null && !request.includePrerelease) return;
    final file = File(configuration.configPath);
    final source = file.readAsStringSync();
    final lines = source.split('\n');
    final escaped = pack.key.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final headers = {'[packs."$escaped".update]', "[packs.'$escaped'.update]"};
    final start = lines.indexWhere((line) => headers.contains(line.trim()));
    if (start < 0) {
      throw MambaException(
        'Cannot safely save policy without a table-form update section for '
        '${pack.key}; edit ${configuration.configPath} manually.',
        exitCode: PackProcessStatus.failure.code,
      );
    }
    var end = lines.length;
    for (var index = start + 1; index < lines.length; index++) {
      if (lines[index].trim().startsWith('[')) {
        end = index;
        break;
      }
    }
    final section = lines.sublist(start + 1, end);
    void setValue(String key, String value) {
      final pattern = RegExp('^(\\s*)${RegExp.escape(key)}\\s*=');
      final index = section.indexWhere((line) => pattern.hasMatch(line));
      if (index >= 0) {
        final indentation = pattern.firstMatch(section[index])!.group(1)!;
        section[index] = '$indentation$key = $value';
      } else {
        section.add('$key = $value');
      }
    }

    if (request.bump != null) setValue('bump', '"${request.bump}"');
    if (request.includePrerelease) setValue('include_prerelease', 'true');
    final updated = [
      ...lines.sublist(0, start + 1),
      ...section,
      ...lines.sublist(end),
    ];
    final temporary = File('${file.path}.policy.tmp');
    try {
      temporary.writeAsStringSync(updated.join('\n'), flush: true);
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  Map<String, Object?> _contextJson(
    PackLifecycleRequest request,
    LifecycleContext context,
    PackConfiguration configuration,
  ) => {
    'scope': context.scope.name,
    'projectRoot': context.scope == LifecycleScope.project
        ? context.projectRoot
        : null,
    'target': request.target,
    'configPath': configuration.configPath,
  };

  Map<String, Object?> _sourceJson(
    PackDefinition pack,
    AcquisitionProvenance provenance,
  ) => {
    'pack': pack.key,
    ...provenance.toJson(),
    'track': _trackJson(pack.update.track),
  };

  Map<String, Object?> _trackJson(PackTrack track) => switch (track) {
    BranchTrack branch => {'kind': 'branch', 'name': branch.name},
    TagTrack tag => {'kind': 'tag', 'name': tag.name},
    CommitTrack commit => {'kind': 'commit', 'commit': commit.commit},
    ReleaseTrack release => {
      'kind': 'release',
      'artifact': release.artifact.name,
      if (release.attachment != null) 'attachment': release.attachment,
    },
    LocalTrack() => {'kind': 'local'},
    DownloadTrack() => {'kind': 'download'},
  };

  String? _recordSnapshots(
    LifecycleContext context,
    String packKey,
    _PackCandidate candidate,
  ) {
    final records = _packRecords(context, packKey, candidate.type)
        .where(
          (record) =>
              record.name == candidate.name && record.lifecycle == 'live',
        )
        .toList();
    String? firstRef;
    for (final record in records) {
      final ref = _recordSnapshot(context, record).ref;
      firstRef ??= ref;
    }
    return firstRef;
  }

  String? _currentSnapshotRef(
    LifecycleContext context,
    InstallationRecord record,
  ) {
    final current = PackState(stateDirectory: context.stateRoot())
        .snapshots(installationId: record.installationId)
        .where((snapshot) => snapshot.noncurrentAt == null)
        .toList();
    return current.isEmpty ? null : current.single.ref;
  }

  RecordedSnapshot _recordEditedSnapshot(
    LifecycleContext context,
    InstallationRecord record,
  ) {
    return _withSnapshotArtifact(record, (artifactPath) {
      return PackState(stateDirectory: context.stateRoot()).recordLocalEdit(
        installationId: record.installationId,
        artifactPath: artifactPath,
        baseline: _lifecycleState.observeBaseline(record).toJson(),
        editedEvidence: {
          'status': 'localEdit',
          'previousOrigin': record.origin,
        },
      );
    });
  }

  RecordedSnapshot _recordSnapshot(
    LifecycleContext context,
    InstallationRecord record,
  ) {
    return _withSnapshotArtifact(record, (artifactPath) {
      return PackState(stateDirectory: context.stateRoot()).recordSnapshot(
        installationId: record.installationId,
        artifactPath: artifactPath,
        baseline: record.baseline.toJson(),
        sourceEvidence: {
          'source': record.origin,
          'installation': record.toJson(),
        },
      );
    });
  }

  T _withSnapshotArtifact<T>(
    InstallationRecord record,
    T Function(String path) body,
  ) {
    if (record.kind == ArtifactKind.skillCopy ||
        record.kind == ArtifactKind.skillCanonical) {
      return body(record.location);
    }
    final temporary = Directory.systemTemp.createTempSync(
      'agent-resource-snapshot-',
    );
    try {
      if (record.kind == ArtifactKind.agentFile) {
        File(p.join(temporary.path, p.basename(record.location)))
            .writeAsBytesSync(
              File(record.location).readAsBytesSync(),
              flush: true,
            );
      } else {
        File(
          p.join(temporary.path, 'link.json'),
        ).writeAsStringSync(jsonEncode(record.baseline.toJson()), flush: true);
      }
      return body(temporary.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    }
  }

  bool _isSourceLink(
    LifecycleContext context,
    String packKey,
    _PackCandidate candidate,
  ) => _packRecords(context, packKey, candidate.type).any(
    (record) =>
        record.name == candidate.name && record.kind == ArtifactKind.skillLink,
  );

  void _persistPackOperation({
    required LifecycleContext context,
    required PackPlan plan,
    required List<PackResourceResult> results,
    required String outcome,
    required String packKey,
    required PackResourceType type,
    AcquisitionProvenance? provenance,
    List<_PackCandidate> candidates = const <_PackCandidate>[],
    bool noSave = false,
  }) {
    final state = PackState(stateDirectory: context.stateRoot());
    final recorded = DateTime.now().toUtc().toIso8601String();
    state.recordOperation({
      'operationId': plan.planId,
      'operation': plan.operation,
      'outcome': outcome,
      'scope': context.scope.name,
      'packKey': packKey,
      'context': plan.context,
      'source': plan.source,
      'resources': [for (final result in results) result.toJson()],
      'warnings': [for (final warning in plan.warnings) warning.toJson()],
      'recordedAt': recorded,
    });
    if (!noSave) {
      for (final result in results) {
        state.recordSelections([
          {
            'packKey': packKey,
            'resourceType': type.name,
            'resourceName': result.name,
            'scope': context.scope.name,
            'selected': !const {
              'removed',
              'observed',
              'notAttempted',
              'failed',
            }.contains(result.disposition.wireName),
            'excluded': false,
            'membership': switch (result.disposition.wireName) {
              'removed' => 'removed',
              'observed' => 'known',
              _ => 'selected',
            },
            'reason': result.disposition.wireName,
            'updatedAt': recorded,
          },
        ]);
      }
    }
    final live = _packRecords(
      context,
      packKey,
      type,
    ).where((record) => record.lifecycle == 'live');
    for (final candidate in candidates) {
      if (candidate.extraFolders.isEmpty) continue;
      for (final record in live.where(
        (record) => record.name == candidate.name,
      )) {
        for (final folder in candidate.extraFolders) {
          state.recordApprovals([
            {
              'packKey': packKey,
              'resourceType': type.name,
              'resourceName': candidate.name,
              'scope': context.scope.name,
              'destination': record.nativeDestination,
              'folder': folder,
              'sourceRequested':
                  provenance?.requestedLocator ??
                  plan.source['requestedLocator'] ??
                  packKey,
              'sourceResolved':
                  provenance?.resolvedLocator ??
                  plan.source['resolvedLocator'] ??
                  packKey,
              'approvedAt': recorded,
            },
          ]);
        }
      }
    }
  }

  ArtifactBaseline _candidateBaseline(_PackCandidate candidate) =>
      _lifecycleState.baselineFor(
        candidate.path,
        candidate.type == PackResourceType.agent
            ? ArtifactKind.agentFile
            : ArtifactKind.skillCopy,
      );

  PackResourceResult _result(
    PackLifecycleRequest request,
    String name,
    String disposition, {
    String? previousSnapshot,
    String? snapshot,
    bool linkOnly = false,
    List<PackChangedPath> changedPaths = const <PackChangedPath>[],
  }) => PackResourceResult(
    type: request.resourceType.name,
    name: name,
    disposition: PackDisposition.parse(disposition),
    previousSnapshot: previousSnapshot,
    snapshot: snapshot,
    linkOnly: linkOnly,
    changedPaths: changedPaths,
  );

  AgentHarness _harness(NativeAgentProfile profile) => switch (profile) {
    NativeAgentProfile.claude => AgentHarness.claude,
    NativeAgentProfile.codex => AgentHarness.codex,
    NativeAgentProfile.piCommon => AgentHarness.pi,
  };

  String _methodName(String value) =>
      value == 'source-link' ? 'sourceLink' : value;

  String get _nativeDirectoryLinkKind =>
      (operatingSystem ?? Platform.operatingSystem) == 'windows'
      ? 'windows-directory-symlink'
      : 'posix-directory-symlink';

  void _validateModeConflicts(
    PackLifecycleRequest request,
    PackDefinition pack,
  ) {
    if (pack.update.track is! ReleaseTrack) return;
    if (request.release != null && request.bump != null) {
      throw MambaException(
        '--release and --bump cannot be combined for a release track.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.noSave &&
        request.savePolicy &&
        (request.bump != null || request.includePrerelease)) {
      throw MambaException(
        '--no-save and --save-policy conflict when the policy change is applicable.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  void _validateRequest(PackLifecycleRequest request) {
    if (request.operation == PackOperation.validate) {
      _validateReadOnlyRequest(request);
    } else if (request.resourceTypes.isNotEmpty &&
        (request.resourceTypes.length != 1 ||
            request.resourceTypes.single != request.resourceType)) {
      throw MambaException(
        'Multi-type pack operations are not yet supported.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    void unique(Iterable<String> values, String option) {
      final seen = <String>{};
      if (values.any((value) => value.trim().isEmpty || !seen.add(value))) {
        throw MambaException(
          '$option requires unique, nonblank native names.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }

    unique(request.only, '--only');
    unique(request.keepLocal, '--keep-local');
    unique(request.replaceLocal, '--replace-local');
    unique(request.approveRemoval, '--approve-removal');
    if (request.only.isNotEmpty && request.skipNew) {
      throw MambaException(
        '--only and --skip-new contradict selection semantics.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.keepLocal
        .toSet()
        .intersection(request.replaceLocal.toSet())
        .isNotEmpty) {
      throw MambaException(
        '--keep-local and --replace-local cannot name the same resource.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.resourceType == PackResourceType.agent &&
        request.method != null) {
      throw MambaException(
        '--method is Skill-only; Agents retain native-copy behavior.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.resourceType == PackResourceType.agent &&
        request.allowFolder.isNotEmpty) {
      throw MambaException(
        '--allow-folder is Skill-only.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.operation == PackOperation.remove && request.only.isEmpty) {
      throw MambaException(
        'remove requires at least one --only native name.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.operation == PackOperation.sourceAssociate &&
        request.only.isEmpty) {
      throw MambaException(
        'source associate requires at least one --only native name.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.operation == PackOperation.sourceChange &&
        (request.to == null || request.to!.trim().isEmpty)) {
      throw MambaException(
        'source change requires --to <configured-pack-key>.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.operation == PackOperation.rollback &&
        (request.only.length != 1 || request.snapshot == null)) {
      throw MambaException(
        'rollback requires exactly one --only name and --snapshot ref.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (request.operation != PackOperation.configValidate &&
        request.pack?.trim().isEmpty != false) {
      throw MambaException(
        'A configured pack key is required.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  void _validateReadOnlyRequest(PackLifecycleRequest request) {
    if (request.resourceTypes.toSet().length != request.resourceTypes.length) {
      throw MambaException(
        '--type requires unique resource kinds.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final rejected = <String>[
      if (request.target != null) '--target',
      if (request.method != null) '--method',
      if (request.bump != null) '--bump',
      if (request.savePolicy) '--save-policy',
      if (request.noSave) '--no-save',
      if (request.skipNew) '--skip-new',
      if (request.includeNew) '--include-new',
      if (request.keepLocal.isNotEmpty) '--keep-local',
      if (request.replaceLocal.isNotEmpty) '--replace-local',
      if (request.approveRemoval.isNotEmpty) '--approve-removal',
      if (request.allowFolder.isNotEmpty) '--allow-folder',
      if (request.to != null) '--to',
      if (request.snapshot != null) '--snapshot',
      if (request.localEdits) '--local-edits',
      if (request.yes) '--yes',
    ];
    if (rejected.isNotEmpty) {
      throw MambaException(
        'pack validate is read-only and does not accept mutation-only '
        'option(s): ${rejected.join(', ')}.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  List<PackResourceType> _requestResourceTypes(PackLifecycleRequest request) =>
      request.resourceTypes.isEmpty
      ? [request.resourceType]
      : request.resourceTypes;
}

final class _PackValidationCandidate {
  const _PackValidationCandidate({
    required this.type,
    required this.relativePath,
    required this.path,
    required this.profile,
  });

  final PackResourceType type;
  final String relativePath;
  final String path;
  final NativeAgentProfile? profile;
}

final class _InspectedPackResource {
  const _InspectedPackResource({
    required this.candidate,
    required this.name,
    required this.failures,
    required this.warnings,
  });

  final _PackValidationCandidate candidate;
  final String? name;
  final List<String> failures;
  final List<String> warnings;

  String get label =>
      '${candidate.type.name} '
      '${ValidationDiagnostics.escape(candidate.relativePath)}';
}

final class _AcquiredSource {
  const _AcquiredSource(this.workspace, this.release);

  final AcquisitionWorkspace workspace;
  final _ReleaseEvidence? release;
}

final class _ReleaseEvidence {
  const _ReleaseEvidence({
    required this.repositoryHost,
    required this.repositoryName,
    required this.repositoryId,
    required this.id,
    required this.literalTag,
    required this.draft,
    required this.prerelease,
    this.commit,
    this.attachmentId,
    this.attachmentName,
    this.attachmentDigest,
  });

  factory _ReleaseEvidence.fromResolution(GithubReleaseResolution resolution) {
    final release = resolution.release;
    final acquisition = resolution.acquisition;
    return _ReleaseEvidence(
      repositoryHost: release.repository.host,
      repositoryName: release.repository.repository,
      repositoryId: release.repository.id,
      id: release.id,
      literalTag: release.literalTag,
      draft: release.isDraft,
      prerelease: release.isPrerelease,
      commit: release.commit,
      attachmentId: switch (acquisition) {
        GithubAttachmentAcquisition attachment => attachment.id,
        _ => null,
      },
      attachmentName: switch (acquisition) {
        GithubAttachmentAcquisition attachment => attachment.name,
        _ => null,
      },
      attachmentDigest: switch (acquisition) {
        GithubAttachmentAcquisition attachment => attachment.digest,
        _ => null,
      },
    );
  }

  final String repositoryHost;
  final String repositoryName;
  final int repositoryId;
  final int id;
  final String literalTag;
  final bool draft;
  final bool prerelease;
  final String? commit;
  final int? attachmentId;
  final String? attachmentName;
  final String? attachmentDigest;

  Map<String, Object?> toEvidenceJson() => {
    'provider': {'host': repositoryHost, 'repositoryId': repositoryId},
    'release': {
      'id': id,
      'literalTag': literalTag,
      'draft': draft,
      'prerelease': prerelease,
      'commit': commit,
    },
    if (attachmentId != null)
      'attachment': {
        'id': attachmentId,
        'releaseId': id,
        'name': attachmentName,
        'digest': attachmentDigest,
      },
  };
}

final class _PackCandidate {
  const _PackCandidate({
    required this.type,
    required this.name,
    required this.path,
    required this.profile,
    required this.digest,
    required this.extraFolders,
    required this.origin,
    this.historicalInstallation,
  });

  final PackResourceType type;
  final String name;
  final String path;
  final NativeAgentProfile? profile;
  final String digest;
  final Set<String> extraFolders;
  final Map<String, Object?> origin;
  final InstallationRecord? historicalInstallation;
}
