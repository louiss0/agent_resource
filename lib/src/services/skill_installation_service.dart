import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../../components/acquisition_progress.dart';
import '../installation/installation_batch.dart';
import '../installation/installation_interaction.dart';
import '../installation/installation_plan.dart';
import '../installation/installation_request.dart';
import '../installation/resource_catalog.dart';
import 'acquisition_service.dart';
import 'lifecycle_state_service.dart';
import 'skill_lifecycle_service.dart';

typedef InstallationProgress = Future<T> Function<T>(
  String label,
  Future<T> Function() work,
);

/// Resource-specific Skill planning and publication workflow.
interface class SkillInstallationService {
  SkillInstallationService({
    this._acquisition = const AcquisitionService(),
    SkillLifecycleService? lifecycle,
    InstallationInteraction? interaction,
    InstallationBatch? batch,
    InstallationProgress? progress,
  }) : _lifecycle = lifecycle ?? SkillLifecycleService(),
       _interaction = interaction ?? InteractInstallationInteraction(),
       _batch = batch ?? InstallationBatch(),
       _progress = progress ?? _defaultProgress;

  final AcquisitionService _acquisition;
  final SkillLifecycleService _lifecycle;
  final InstallationInteraction _interaction;
  final InstallationBatch _batch;
  final InstallationProgress _progress;

  LifecycleStateService get state => _lifecycle.state;
  bool get hasInteractiveTerminal => _interaction.isInteractive;

  Future<InstallationWorkflowResult> run(
    InstallationWorkflowRequest request, {
    required bool interactive,
  }) async {
    if (!interactive) {
      if (!request.scopeExplicit) {
        throw MambaException(
          'Unattended Skill installation requires explicit --scope; the '
          'interactive user-scope default is not assumed.',
        );
      }
      if (request.method == null) {
        throw MambaException(
          'Unattended Skill installation requires explicit --method; the '
          'interactive canonical default is not assumed.',
        );
      }
      if (request.source == null) {
        throw MambaException('Unattended installation requires a source.');
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
      return const InstallationCancelledResult('skill install');
    }
    final context = LifecycleContext.resolve(request.options);
    final method = request.method ?? InstallationMethod.canonical;
    final acquisition = AcquisitionRequest(
      locator: source,
      cwd: context.cwd,
      resourceType: CatalogResourceType.skill,
      sourceKind: request.sourceKind,
      ref: request.ref,
      subpath: request.subpath,
    );
    final workspace = interactive
        ? await _progress(
            'Acquiring Skill source',
            () => _acquisition.acquire(acquisition),
          )
        : await _acquisition.acquire(acquisition);
    try {
      final candidates = await resolveInstallationCandidates(
        workspace: workspace,
        request: request,
        interaction: _interaction,
        resourceType: CatalogResourceType.skill,
        interactive: interactive,
      );
      if (candidates == null) {
        return const InstallationCancelledResult('skill install');
      }
      if (method == InstallationMethod.sourceLink &&
          !candidates.provenance.durableLocalDirectory) {
        throw MambaException(
          '--method source-link requires an explicitly selected durable local '
          'Skill directory; temporary or single-file sources are ineligible.',
          exitCode: 4,
        );
      }
      final targets = await _targets(request, context, interactive);
      if (targets == null) {
        return const InstallationCancelledResult('skill install');
      }
      if (targets.isEmpty) {
        throw MambaException('No compatible consuming harness was selected.');
      }
      final units = <InstallationUnitPlan>[];
      final errors = <String>[];
      var worstStatus = 1;
      for (final candidate in candidates.candidates) {
        try {
          units.add(
            await _planUnit(
              candidate,
              candidates.provenance,
              context,
              method,
              targets,
            ),
          );
        } on MambaException catch (error) {
          worstStatus = error.exitCode > worstStatus
              ? error.exitCode
              : worstStatus;
          errors.add('${candidate.id ?? candidate.path}: ${error.message}');
        }
      }
      _checkBatchIndependence(units, errors);
      if (errors.isNotEmpty) {
        throw MambaException(
          'Skill installation preflight failed; no installation writes occurred:\n- ${errors.join('\n- ')}',
          exitCode: worstStatus,
        );
      }
      final plan = InstallationPlan.create(
        command: 'skill install',
        source: candidates.provenance,
        scope: context.scope.name,
        units: units,
        diagnostics: [
          if (candidates.provenance.directFile)
            const <String, Object?>{
              'code': 'single-file-boundary',
              'message': 'Only the selected SKILL.md was acquired; siblings were not read.',
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
        resourceFor: (unit) => _resource(unit),
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

  Future<List<InstallationTarget>?> _targets(
    InstallationWorkflowRequest request,
    LifecycleContext context,
    bool interactive,
  ) async {
    if (request.targets.isNotEmpty) {
      return List<InstallationTarget>.unmodifiable(request.targets.toSet());
    }
    if (!interactive) {
      throw MambaException('Unattended Skill installation requires --target.');
    }
    final detected = <InstallationTarget>{
      if (_directoryHint(context.claudeSkillsRoot())) InstallationTarget.claude,
      if (_directoryHint(context.codexSkillsRoot()) ||
          _directoryHint(context.sharedSkillsRoot()))
        InstallationTarget.codex,
    };
    while (true) {
      final answer = await _interaction.selectTargets(const [
        InstallationTarget.claude,
        InstallationTarget.codex,
      ], detected);
      if (answer.status == InteractionAnswerStatus.cancelled) return null;
      if (answer.status == InteractionAnswerStatus.value) return answer.value;
    }
  }

  Future<InstallationUnitPlan> _planUnit(
    InstallationCandidate candidate,
    AcquisitionProvenance provenance,
    LifecycleContext context,
    InstallationMethod method,
    List<InstallationTarget> targets,
  ) async {
    final resource = _lifecycle.installationResource(
      targets: [for (final target in targets) target.name],
      kind: switch (method) {
        InstallationMethod.canonical => ArtifactKind.skillCanonical,
        InstallationMethod.copy => ArtifactKind.skillCopy,
        InstallationMethod.sourceLink => ArtifactKind.skillLink,
      },
    );
    final inspected = await resource.inspect(candidate.path, context);
    final digest = state.contentDigest(candidate.path, ArtifactKind.skillCopy);
    final origin = <String, Object?>{
      'status': 'evidenced',
      'schemaVersion': 1,
      'source': provenance.toJson(),
      if (candidate.id != null) 'entryId': candidate.id,
      if (method != InstallationMethod.sourceLink) 'contentDigest': digest,
    };
    final entries = <InstallationEntryPlan>[];
    final canonicalRoot = p.normalize(context.sharedSkillsRoot());
    final canonicalPath = p.join(canonicalRoot, inspected.name);
    if (method == InstallationMethod.canonical) {
      entries.add(
        InstallationEntryPlan(
          path: canonicalPath,
          kind: InstallationEntryKind.content,
          action: InstallationEntryAction.createContent,
          target: targets.contains(InstallationTarget.codex) ? 'codex' : null,
          nativeRoot: canonicalRoot,
          nativeDestination: 'canonical',
          artifactKind: OwnedArtifactKind.skillCanonical,
        ),
      );
      if (targets.contains(InstallationTarget.claude)) {
        final root = p.normalize(context.claudeSkillsRoot());
        entries.add(
          InstallationEntryPlan(
            path: p.join(root, inspected.name),
            kind: InstallationEntryKind.link,
            action: InstallationEntryAction.createLink,
            target: 'claude',
            linkTarget: canonicalPath,
            nativeRoot: root,
            nativeDestination: 'claude',
            artifactKind: OwnedArtifactKind.skillLink,
          ),
        );
      }
      if (targets.contains(InstallationTarget.codex)) {
        entries.add(
          InstallationEntryPlan(
            path: canonicalPath,
            kind: InstallationEntryKind.consumer,
            action: InstallationEntryAction.recordConsumer,
            target: 'codex',
          ),
        );
      }
    } else {
      for (final target in targets) {
        final root = p.normalize(
          target == InstallationTarget.claude
              ? context.claudeSkillsRoot()
              : context.sharedSkillsRoot(),
        );
        final location = p.join(root, inspected.name);
        entries.add(
          InstallationEntryPlan(
            path: location,
            kind: method == InstallationMethod.copy
                ? InstallationEntryKind.copy
                : InstallationEntryKind.link,
            action: method == InstallationMethod.copy
                ? InstallationEntryAction.createCopy
                : InstallationEntryAction.createLink,
            target: target.name,
            linkTarget: method == InstallationMethod.sourceLink
                ? candidate.path
                : null,
            nativeRoot: root,
            nativeDestination: target == InstallationTarget.claude
                ? 'claude'
                : 'shared',
            artifactKind: method == InstallationMethod.copy
                ? OwnedArtifactKind.skillCopy
                : OwnedArtifactKind.skillLink,
          ),
        );
      }
    }
    final ids = _observeExisting(context, entries, method, origin, digest);
    await resource.checkUnique(
      context,
      inspected.name,
      nativeDestination: 'canonical',
      allowedPaths: {for (final entry in entries) entry.path},
    );
    return InstallationUnitPlan(
      resourceType: InstallationResourceType.skill,
      resourceId: candidate.id ?? inspected.name,
      nativeName: inspected.name,
      profile: null,
      method: method,
      status:
          entries.every(
            (entry) => entry.action == InstallationEntryAction.unchanged,
          )
          ? InstallationUnitStatus.unchanged
          : InstallationUnitStatus.planned,
      installationIds: ids,
      entries: entries,
      sourcePath: candidate.path,
      sourceDigest: digest,
      origin: origin,
    );
  }

  List<String> _observeExisting(
    LifecycleContext context,
    List<InstallationEntryPlan> entries,
    InstallationMethod method,
    Map<String, Object?> origin,
    String digest,
  ) {
    final records = state.records(context);
    final canonical = method == InstallationMethod.canonical
        ? records.where((record) {
            final content = entries.firstWhere(
              (entry) => entry.kind == InstallationEntryKind.content,
            );
            return record.kind == ArtifactKind.skillCanonical &&
                record.lifecycle == 'live' &&
                p.equals(record.location, content.path);
          }).toList()
        : const <InstallationRecord>[];
    final canonicalRecord = canonical.isEmpty ? null : canonical.single;
    final ids = <String>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (entry.kind == InstallationEntryKind.consumer) {
        if (canonicalRecord != null &&
            canonicalRecord.knownConsumers.contains(entry.target)) {
          entries[index] = entry.copyWith(
            action: InstallationEntryAction.unchanged,
          );
        } else if (canonicalRecord != null) {
          _requireCanonicalIdentity(canonicalRecord, origin, digest);
        }
        continue;
      }
      if (entry.kind == InstallationEntryKind.content &&
          canonicalRecord != null) {
        _requireCanonicalIdentity(canonicalRecord, origin, digest);
        _requireUnchanged(canonicalRecord);
        entries[index] = entry.copyWith(
          action: InstallationEntryAction.unchanged,
          observedDigest: canonicalRecord.baseline.digest,
        );
        ids.add(canonicalRecord.installationId);
        continue;
      }
      if (entry.kind == InstallationEntryKind.link &&
          method == InstallationMethod.canonical &&
          canonicalRecord != null) {
        final exposures = canonicalRecord.exposures
            .where((exposure) => p.equals(exposure.path, entry.path))
            .toList();
        if (exposures.isNotEmpty) {
          final exposure = exposures.single;
          if (exposure.target != entry.target ||
              !state.verifyExposure(exposure)) {
            throw MambaException(
              'The canonical exposure changed or could not be verified: ${entry.path}',
              exitCode: 4,
            );
          }
          entries[index] = entry.copyWith(
            action: InstallationEntryAction.unchanged,
            observedDigest: exposure.baseline.digest,
          );
          continue;
        }
      }
      final occupant = FileSystemEntity.typeSync(
        entry.path,
        followLinks: false,
      );
      final managed = records.where((record) {
        return record.lifecycle == 'live' &&
            p.equals(record.location, entry.path);
      }).toList();
      if (managed.isNotEmpty) {
        final record = managed.single;
        final expectedKind = switch (entry.artifactKind!) {
          OwnedArtifactKind.skillCopy => ArtifactKind.skillCopy,
          OwnedArtifactKind.skillLink => ArtifactKind.skillLink,
          OwnedArtifactKind.skillCanonical => ArtifactKind.skillCanonical,
          OwnedArtifactKind.agentFile => ArtifactKind.agentFile,
        };
        if (record.kind != expectedKind ||
            jsonEncode(record.origin) != jsonEncode(origin) ||
            (expectedKind != ArtifactKind.skillLink &&
                record.baseline.digest != digest)) {
          throw MambaException(
            'The managed destination has a different origin, method, or source '
            'revision; use explicit lifecycle replacement: ${entry.path}',
            exitCode: 4,
          );
        }
        _requireUnchanged(record);
        entries[index] = entry.copyWith(
          action: InstallationEntryAction.unchanged,
          observedDigest: record.baseline.digest,
        );
        ids.add(record.installationId);
      } else if (occupant != FileSystemEntityType.notFound) {
        throw MambaException(
          'The destination is occupied by an unmanaged or conflicting entry: '
          '${entry.path}',
          exitCode: 4,
        );
      }
    }
    return List<String>.unmodifiable(ids.toSet());
  }

  void _requireCanonicalIdentity(
    InstallationRecord record,
    Map<String, Object?> origin,
    String digest,
  ) {
    if (jsonEncode(record.origin) != jsonEncode(origin) ||
        record.baseline.digest != digest) {
      throw MambaException(
        'The canonical installation has a different origin or source revision; '
        'use explicit lifecycle replacement: ${record.location}',
        exitCode: 4,
      );
    }
  }

  void _requireUnchanged(InstallationRecord record) {
    if (state.verify(record) != ModificationStatus.unchanged) {
      throw MambaException(
        'The managed installation is changed, missing, or unverifiable: '
        '${record.location}',
        exitCode: 4,
      );
    }
  }

  LifecycleResource _resource(InstallationUnitPlan unit) {
    final targets = <String>{
      for (final entry in unit.entries) ?entry.target,
    }.toList()..sort();
    return _lifecycle.installationResource(
      targets: targets,
      kind: switch (unit.method) {
        InstallationMethod.canonical => ArtifactKind.skillCanonical,
        InstallationMethod.copy => ArtifactKind.skillCopy,
        InstallationMethod.sourceLink => ArtifactKind.skillLink,
      },
    );
  }

  void _checkBatchIndependence(
    List<InstallationUnitPlan> units,
    List<String> errors,
  ) {
    final paths = <String, String>{};
    final nativeTargets = <String, String>{};
    for (final unit in units) {
      for (final entry in unit.entries) {
        final previous = paths[entry.path];
        if (previous != null && previous != unit.resourceId) {
          errors.add(
            '${unit.resourceId} shares destination ${entry.path} with $previous.',
          );
        }
        paths[entry.path] = unit.resourceId;
        if (entry.target != null) {
          final key = '${unit.nativeName}\n${entry.target}';
          final conflict = nativeTargets[key];
          if (conflict != null && conflict != unit.resourceId) {
            errors.add(
              '${unit.resourceId} and $conflict have the same native name '
              '${unit.nativeName} for ${entry.target}.',
            );
          }
          nativeTargets[key] = unit.resourceId;
        }
      }
    }
  }
}

bool _directoryHint(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.directory;

Future<T> _defaultProgress<T>(String label, Future<T> Function() work) =>
    AcquisitionProgressComponent(label: label).render(work);
