import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../../components/acquisition_progress.dart';
import '../agent_inspection.dart';
import '../configuration/effective_configuration.dart';
import '../harness/harness_catalog.dart';
import '../installation/installation_batch.dart';
import '../installation/installation_interaction.dart';
import '../installation/installation_plan.dart';
import '../installation/installation_request.dart';
import '../installation/resource_catalog.dart';
import 'acquisition_service.dart';
import 'agent_lifecycle_service.dart';
import 'lifecycle_state_service.dart';
import 'skill_installation_service.dart';

/// Native Agent file-copy installation workflow. Profiles are declarations,
/// not inferred formats or conversion requests.
interface class AgentInstallationService {
  AgentInstallationService({
    AcquisitionService? acquisition,
    AgentLifecycleService? lifecycle,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    InstallationInteraction? interaction,
    InstallationBatch? batch,
    InstallationProgress? progress,
  }) : _fileSystem = fileSystem,
       _acquisition = acquisition ?? AcquisitionService(fileSystem: fileSystem),
       _lifecycle = lifecycle ?? AgentLifecycleService(fileSystem: fileSystem),
       _interaction = interaction ?? InteractInstallationInteraction(),
       _batch = batch ?? InstallationBatch(),
       _progress = progress ?? _agentProgress;

  fslib.FileSystem get fileSystem => _fileSystem;

  final fslib.FileSystem _fileSystem;
  final AcquisitionService _acquisition;
  final AgentLifecycleService _lifecycle;
  final InstallationInteraction _interaction;
  final InstallationBatch _batch;
  final InstallationProgress _progress;

  LifecycleStateService get state => _lifecycle.state;
  bool get hasInteractiveTerminal => _interaction.isInteractive;

  Future<InstallationWorkflowResult> run(
    InstallationWorkflowRequest request, {
    required bool interactive,
  }) async {
    if (request.method != null) {
      throw MambaException(
        'Agents are native-file-copy only; --method is not applicable.',
      );
    }
    if (!interactive) {
      if (!request.scopeExplicit) {
        throw MambaException(
          'Unattended Agent installation requires explicit --scope; the '
          'interactive project-scope default is not assumed.',
        );
      }
      if (request.source == null) {
        throw MambaException('Unattended installation requires a source.');
      }
      if (request.targets.isEmpty) {
        throw MambaException(
          'Unattended Agent installation requires explicit --target values '
          'consistent with selected native profiles.',
        );
      }
      if (!request.options.dryRun && !request.options.approved) {
        throw MambaException(
          'Unattended installation requires --yes for the current final plan; '
          'use --dry-run for a preview without approval.',
          exitCode: 4,
        );
      }
    }
    request = await resolveInstallationScope(
      request,
      _interaction,
      _fileSystem,
      interactive: interactive,
    );
    final source = await _source(request, interactive);
    if (source == null) {
      return const InstallationCancelledResult('agent install');
    }
    final context = LifecycleContext.resolve(
      request.options,
      fileSystem: _fileSystem,
    );
    final targetExplicit = request.targets.isNotEmpty;
    final effective = interactive
        ? await effectiveInstallationConfiguration(
            request,
            context,
            _fileSystem,
          )
        : null;
    final targetSetting = effective?.settings.singleWhere(
      (setting) => setting.key == EligiblePreference.installTargets.wireName,
    );
    final configuredTargets =
        ((targetSetting?.value as List<Object?>?)?.cast<String>() ??
                const <String>[])
            .where(
              (target) => InstallationTarget.values.any(
                (value) => value.name == target,
              ),
            )
            .toList();
    if (request.targets.isEmpty && configuredTargets.isNotEmpty) {
      request = request.withTargets([
        for (final target in configuredTargets)
          InstallationTarget.values.byName(target),
      ]);
    }
    final workspace = interactive
        ? await _progress(
            'Acquiring Agent source',
            () => _acquisition.acquire(
              AcquisitionRequest(
                locator: source,
                cwd: context.cwd,
                resourceType: CatalogResourceType.agent,
                sourceKind: request.sourceKind,
                ref: request.ref,
                subpath: request.subpath,
              ),
            ),
          )
        : await _acquisition.acquire(
            AcquisitionRequest(
              locator: source,
              cwd: context.cwd,
              resourceType: CatalogResourceType.agent,
              sourceKind: request.sourceKind,
              ref: request.ref,
              subpath: request.subpath,
            ),
          );
    try {
      final candidates = await resolveInstallationCandidates(
        workspace: workspace,
        request: request,
        interaction: _interaction,
        resourceType: CatalogResourceType.agent,
        interactive: interactive,
        fileSystem: _fileSystem,
      );
      if (candidates == null) {
        return const InstallationCancelledResult('agent install');
      }
      if (targetExplicit &&
          candidates.sourceKind == AcquisitionSourceKind.resource &&
          (request.targets.length != 1 ||
              request.targets.single !=
                  _target(candidates.candidates.single.profile!))) {
        throw MambaException(
          'A direct agent file requires one --target consistent with --profile.',
        );
      }
      if (!targetExplicit &&
          configuredTargets.isNotEmpty &&
          candidates.sourceKind == AcquisitionSourceKind.resource &&
          !request.targets.contains(
            _target(candidates.candidates.single.profile!),
          )) {
        throw MambaException('No Agent resources match the preferred targets.');
      }
      final units = <InstallationUnitPlan>[];
      final errors = <String>[];
      var worstStatus = 1;
      for (final candidate in candidates.candidates) {
        try {
          units.add(await _planUnit(candidate, candidates.provenance, context));
        } on MambaException catch (error) {
          worstStatus = error.exitCode > worstStatus
              ? error.exitCode
              : worstStatus;
          errors.add('${candidate.id ?? candidate.path}: ${error.message}');
        }
      }
      _checkBatch(units, errors);
      if (errors.isNotEmpty) {
        throw MambaException(
          'Agent installation preflight failed; no installation writes occurred:\n- ${errors.join('\n- ')}',
          exitCode: worstStatus,
        );
      }
      final targetNames = units
          .expand((unit) => unit.entries)
          .map((entry) => entry.target)
          .whereType<String>()
          .toSet();
      final targets = InstallationTarget.values
          .where((target) => targetNames.contains(target.name))
          .toList();
      final plan = InstallationPlan.create(
        command: 'agent install',
        source: candidates.provenance,
        scope: context.scope.name,
        units: units,
        resolution: {
          'scope': {
            'value': context.scope.name,
            'origin': request.scopeExplicit
                ? 'explicit-argument'
                : context.scope == LifecycleScope.user
                ? 'interactive-selection'
                : 'built-in-default',
          },
          'targets': {
            'value': [for (final target in targets) target.name],
            'origin': targetExplicit
                ? 'explicit-argument'
                : configuredTargets.isNotEmpty &&
                      targets.every(
                        (target) => configuredTargets.contains(target.name),
                      )
                ? targetSetting!.origin.wireName
                : 'native-profile',
          },
          'method': {'value': 'copy', 'origin': 'native-profile'},
        },
        diagnostics: [
          if (candidates.provenance.directFile)
            const <String, Object?>{
              'code': 'single-file-boundary',
              'message': 'Only the selected native definition was acquired; siblings were not read.',
            },
        ],
      );
      final explicitCommand = interactive
          ? installationExplicitCommand(
              request: request,
              plan: plan,
              candidates: candidates,
              source: source,
              context: context,
              targets: targets,
              resourceType: CatalogResourceType.agent,
            )
          : null;
      if (request.options.dryRun) {
        return InstallationCompletedResult(
          plan,
          InstallationOutcome.planned,
          explicitCommand: explicitCommand,
        );
      }
      final result = await _batch.execute(
        plan: plan,
        context: context,
        state: state,
        resourceFor: (unit) => _lifecycle.installationResource(
          _harness(
            NativeAgentProfile.values.singleWhere(
              (profile) => profile.wireName == unit.profile,
            ),
          ),
        ),
        interaction: _interaction,
        interactive: interactive,
        approved: request.options.approved,
      );
      if (result is InstallationCompletedResult) {
        if (interactive &&
            result.outcome == InstallationOutcome.installed &&
            targets.isNotEmpty) {
          await offerInstallationPreferenceSave(
            request: request,
            context: context,
            fileSystem: _fileSystem,
            interaction: _interaction,
            preferences: [
              'cli.install.targets=${targets.map((target) => target.name).join(',')}',
            ],
          );
        }
        return InstallationCompletedResult(
          result.plan,
          result.outcome,
          explicitCommand: explicitCommand,
        );
      }
      return result;
    } finally {
      await workspace.close();
    }
  }

  Future<String?> _source(
    InstallationWorkflowRequest request,
    bool interactive,
  ) async {
    if (request.source != null) return request.source;
    if (!interactive) {
      throw MambaException('Unattended installation requires a source.');
    }
    final answer = await _interaction.requestSource();
    if (answer.status != InteractionAnswerStatus.value) return null;
    return answer.value;
  }

  Future<InstallationUnitPlan> _planUnit(
    InstallationCandidate candidate,
    AcquisitionProvenance provenance,
    LifecycleContext context,
  ) async {
    final profile = candidate.profile!;
    final harness = _harness(profile);
    final resource = _lifecycle.installationResource(harness);
    final inspected = await resource.inspect(candidate.path, context);
    final digest = state.contentDigest(candidate.path, ArtifactKind.agentFile);
    final root = _fileSystem.path.normalize(
      _lifecycle.installRoot(context, harness),
    );
    final location = _fileSystem.path.join(
      root,
      _agentSpec(
        harness,
      ).installationFileName(candidate.path, inspected.name, _fileSystem.path),
    );
    final target = _target(profile);
    final origin = <String, Object?>{
      'status': 'evidenced',
      'schemaVersion': 1,
      'source': provenance.toJson(),
      if (candidate.id != null) 'entryId': candidate.id,
      'contentDigest': digest,
      'profile': profile.wireName,
    };
    final entry = InstallationEntryPlan(
      path: location,
      kind: InstallationEntryKind.copy,
      action: InstallationEntryAction.createCopy,
      target: target.name,
      nativeRoot: root,
      nativeDestination: 'native',
      artifactKind: OwnedArtifactKind.agentFile,
    );
    final records = state.records(context);
    final managed = records
        .where(
          (record) =>
              record.lifecycle == 'live' &&
              _fileSystem.path.equals(record.location, location),
        )
        .toList();
    final ids = <String>[];
    var plannedEntry = entry;
    if (managed.isNotEmpty) {
      final record = managed.single;
      if (record.kind != ArtifactKind.agentFile ||
          record.nativeProfile != profile.wireName ||
          record.baseline.digest != digest ||
          jsonEncode(record.origin) != jsonEncode(origin)) {
        throw MambaException(
          'The managed Agent destination has a different origin, profile, or '
          'source revision; use explicit lifecycle replacement: $location',
          exitCode: 4,
        );
      }
      if (state.verify(record) != ModificationStatus.unchanged) {
        throw MambaException(
          'The managed Agent file is changed, missing, or unverifiable: $location',
          exitCode: 4,
        );
      }
      plannedEntry = entry.copyWith(
        action: InstallationEntryAction.unchanged,
        observedDigest: record.baseline.digest,
      );
      ids.add(record.installationId);
    } else if (_fileSystem.typeSync(location, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw MambaException(
        'The Agent destination is occupied by an unmanaged or conflicting entry: $location',
        exitCode: 4,
      );
    }
    await resource.checkUnique(
      context,
      inspected.name,
      nativeDestination: 'native',
      allowedPaths: {location},
    );
    return InstallationUnitPlan(
      resourceType: InstallationResourceType.agent,
      resourceId: candidate.id ?? inspected.name,
      nativeName: inspected.name,
      profile: profile.wireName,
      method: InstallationMethod.copy,
      status: plannedEntry.action == InstallationEntryAction.unchanged
          ? InstallationUnitStatus.unchanged
          : InstallationUnitStatus.planned,
      installationIds: ids,
      entries: [plannedEntry],
      sourcePath: candidate.path,
      sourceDigest: digest,
      origin: origin,
    );
  }

  void _checkBatch(List<InstallationUnitPlan> units, List<String> errors) {
    final paths = <String, String>{};
    final nativeTargets = <String, String>{};
    for (final unit in units) {
      for (final entry in unit.entries) {
        final previous = paths[entry.path];
        if (previous != null && previous != unit.resourceId) {
          errors.add('${unit.resourceId} shares ${entry.path} with $previous.');
        }
        paths[entry.path] = unit.resourceId;
        final key = '${unit.nativeName}\n${unit.profile}';
        final conflict = nativeTargets[key];
        if (conflict != null && conflict != unit.resourceId) {
          errors.add(
            '${unit.resourceId} and $conflict have the same native Agent name '
            '${unit.nativeName} for ${unit.profile}.',
          );
        }
        nativeTargets[key] = unit.resourceId;
      }
    }
  }
}

AgentHarness _harness(NativeAgentProfile profile) => switch (profile) {
  NativeAgentProfile.claude => AgentHarness.claude,
  NativeAgentProfile.codex => AgentHarness.codex,
  NativeAgentProfile.piCommon => AgentHarness.pi,
  NativeAgentProfile.antigravity => AgentHarness.antigravity,
};

InstallationTarget _target(NativeAgentProfile profile) => switch (profile) {
  NativeAgentProfile.claude => InstallationTarget.claude,
  NativeAgentProfile.codex => InstallationTarget.codex,
  NativeAgentProfile.piCommon => InstallationTarget.pi,
  NativeAgentProfile.antigravity => InstallationTarget.antigravity,
};

AgentHarnessSpec _agentSpec(AgentHarness harness) =>
    HarnessCatalog.instance.requireFacet(
      HarnessId.of(harness),
      HarnessFacet.agent,
    ) as AgentHarnessSpec;

Future<T> _agentProgress<T>(String label, Future<T> Function() work) =>
    AcquisitionProgressComponent(label: label).render(work);
