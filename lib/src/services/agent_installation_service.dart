import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../../components/acquisition_progress.dart';
import '../agent_inspection.dart';
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
    this._acquisition = const AcquisitionService(),
    AgentLifecycleService? lifecycle,
    InstallationInteraction? interaction,
    InstallationBatch? batch,
    InstallationProgress? progress,
  }) : _lifecycle = lifecycle ?? AgentLifecycleService(),
       _interaction = interaction ?? ClixInstallationInteraction(),
       _batch = batch ?? InstallationBatch(),
       _progress = progress ?? _agentProgress;

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
    final source = await _source(request, interactive);
    if (source == null) {
      return const InstallationCancelledResult('agent install');
    }
    final context = LifecycleContext.resolve(request.options);
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
      );
      if (candidates == null) {
        return const InstallationCancelledResult('agent install');
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
          exitCode: worstStatus == 1 ? 4 : worstStatus,
        );
      }
      final plan = InstallationPlan.create(
        command: 'agent install',
        source: candidates.provenance,
        scope: context.scope.name,
        units: units,
        diagnostics: [
          if (candidates.provenance.directFile)
            const <String, Object?>{
              'code': 'single-file-boundary',
              'message': 'Only the selected native definition was acquired; siblings were not read.',
            },
        ],
      );
      if (request.options.dryRun) {
        return InstallationCompletedResult(plan, InstallationOutcome.planned);
      }
      return await _batch.execute(
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
    final root = p.normalize(_lifecycle.installRoot(context, harness));
    final location = p.join(root, p.basename(candidate.path));
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
              record.lifecycle == 'live' && p.equals(record.location, location),
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
    } else if (FileSystemEntity.typeSync(location, followLinks: false) !=
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
};

InstallationTarget _target(NativeAgentProfile profile) => switch (profile) {
  NativeAgentProfile.claude => InstallationTarget.claude,
  NativeAgentProfile.codex => InstallationTarget.codex,
  NativeAgentProfile.piCommon => InstallationTarget.pi,
};

Future<T> _agentProgress<T>(String label, Future<T> Function() work) =>
    AcquisitionProgressComponent(label: label).render(work);
