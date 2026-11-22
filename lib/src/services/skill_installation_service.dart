import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../../components/acquisition_progress.dart';
import '../installation/installation_batch.dart';
import '../installation/installation_interaction.dart';
import '../installation/installation_plan.dart';
import '../installation/installation_request.dart';
import '../installation/installation_route.dart';
import '../authoring/native_field_matrix.dart';
import '../conversion/derived_prompt.dart';
import '../installation/resource_catalog.dart';
import '../installation/skill_root_markdown_migration.dart';
import '../harness/harness_catalog.dart';
import '../configuration/effective_configuration.dart';
import 'acquisition_service.dart';
import 'lifecycle_state_service.dart';
import 'prompt_inspection_service.dart';
import 'skill_lifecycle_service.dart';

typedef InstallationProgress = Future<T> Function<T>(
  String label,
  Future<T> Function() work,
);

/// Resource-specific Skill planning and publication workflow.
interface class SkillInstallationService {
  SkillInstallationService({
    AcquisitionService? acquisition,
    SkillLifecycleService? lifecycle,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    InstallationInteraction? interaction,
    InstallationBatch? batch,
    InstallationProgress? progress,
    PromptInspectionService? prompts,
  }) : _fileSystem = fileSystem,
       _acquisition = acquisition ?? AcquisitionService(fileSystem: fileSystem),
       _lifecycle = lifecycle ?? SkillLifecycleService(fileSystem: fileSystem),
       _interaction = interaction ?? InteractInstallationInteraction(),
       _batch = batch ?? InstallationBatch(),
       _progress = progress ?? _defaultProgress,
       _prompts = prompts ?? PromptInspectionService(fs: fileSystem);

  final fslib.FileSystem _fileSystem;
  final AcquisitionService _acquisition;
  final SkillLifecycleService _lifecycle;
  final InstallationInteraction _interaction;
  final InstallationBatch _batch;
  final InstallationProgress _progress;
  final PromptInspectionService _prompts;

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
          'interactive project-scope default is not assumed.',
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
    for (final target in request.targets) {
      HarnessCatalog.instance.requireSkillInstallation(HarnessId.of(target));
    }
    request = await resolveInstallationScope(
      request,
      _interaction,
      _fileSystem,
      interactive: interactive,
    );
    final source = await _source(request, interactive);
    if (source == null) {
      return const InstallationCancelledResult('skill install');
    }
    final context = LifecycleContext.resolve(
      request.options,
      fileSystem: _fileSystem,
    );
    final effective = interactive
        ? await effectiveInstallationConfiguration(
            request,
            context,
            _fileSystem,
          )
        : null;
    final targetSetting = effective?.settings.firstWhere(
      (setting) => setting.key == EligiblePreference.installTargets.wireName,
    );
    final methodSetting = effective?.settings.firstWhere(
      (setting) =>
          setting.key == EligiblePreference.installSkillMethod.wireName,
    );
    final configuredMethod = methodSetting?.value as String?;
    final method =
        request.method ??
        (configuredMethod == null
            ? InstallationMethod.canonical
            : InstallationMethod.values.singleWhere(
                (value) => value.wireName == configuredMethod,
              ));
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
        fileSystem: _fileSystem,
      );
      if (candidates == null) {
        return const InstallationCancelledResult('skill install');
      }
      if (candidates.candidates.isEmpty) {
        final plan = InstallationPlan.create(
          command: 'skill install',
          source: candidates.provenance,
          scope: context.scope.name,
          units: const [],
          diagnostics: [
            {
              'code': 'all-groups-declined',
              'message': candidates.selectionWarning!,
            },
          ],
        );
        return InstallationCompletedResult(plan, InstallationOutcome.unchanged);
      }
      if (method == InstallationMethod.sourceLink &&
          !candidates.provenance.durableLocalDirectory) {
        throw MambaException(
          '--method source-link requires an explicitly selected durable local '
          'Skill directory; temporary or single-file sources are ineligible.',
          exitCode: 4,
        );
      }
      final configuredTargets =
          ((targetSetting?.value as List<Object?>?)?.cast<String>() ??
                  const <String>[])
              .where(
                (target) => HarnessCatalog.instance.skillInstallationTargets
                    .any((id) => id.wireName == target),
              )
              .toList();
      final detectedTargets =
          interactive && request.targets.isEmpty && configuredTargets.isEmpty
          ? detectSkillInstallationTargets(context, _fileSystem)
          : <InstallationTarget>{};
      final targets = request.targets.isEmpty && configuredTargets.isNotEmpty
          ? [
              for (final target in configuredTargets)
                InstallationTarget.values.byName(target),
            ]
          : await _targets(request, detectedTargets, interactive);
      if (targets == null) {
        return const InstallationCancelledResult('skill install');
      }
      if (targets.isEmpty) {
        throw MambaException('No compatible consuming harness was selected.');
      }
      for (final target in targets) {
        HarnessCatalog.instance.requireSkillInstallation(HarnessId.of(target));
      }
      final units = <InstallationUnitPlan>[];
      final stagedSkills = <StagedSkill>[];
      final stagedPairs =
          <({InstallationCandidate candidate, StagedSkill staged})>[];
      final migrationDiagnostics = <Map<String, Object?>>[];
      final errors = <String>[];
      var worstStatus = 1;
      try {
        for (final candidate in candidates.candidates) {
          try {
            final staged = await SkillRootMarkdownMigration(
              fileSystem: _fileSystem,
            ).stage(candidate.path);
            stagedSkills.add(staged);
            if (staged.migrated) {
              if (method == InstallationMethod.sourceLink) {
                throw MambaException(
                  'source-link cannot migrate loose root files without changing the '
                  'user-owned target; move them into references/ or assets/ first.',
                  exitCode: 4,
                );
              }
              final skill =
                  candidate.id ?? _fileSystem.path.basename(candidate.path);
              if (staged.movedMarkdown.isNotEmpty) {
                migrationDiagnostics.add({
                  'code': 'root-markdown-migrated',
                  'skill': skill,
                  'message':
                      'Moved root Markdown documents into references/ in staged content (${staged.movedMarkdown.length}): ${staged.movedMarkdown.join(', ')}; SKILL.md references ${staged.rewritten ? 'were' : 'were not'} rewritten. Make a PR or consult the pack maker about adopting standard support directories.',
                });
              }
              if (staged.movedImages.isNotEmpty) {
                migrationDiagnostics.add({
                  'code': 'root-images-migrated',
                  'skill': skill,
                  'message':
                      'Moved root images into assets/ in staged content (${staged.movedImages.length}): ${staged.movedImages.join(', ')}; SKILL.md references ${staged.rewritten ? 'were' : 'were not'} rewritten. Make a PR or consult the pack maker about adopting standard support directories.',
                });
              }
            }
            stagedPairs.add((candidate: candidate, staged: staged));
          } on MambaException catch (error) {
            worstStatus = error.exitCode > worstStatus
                ? error.exitCode
                : worstStatus;
            errors.add('${candidate.id ?? candidate.path}: ${error.message}');
          }
        }
        final promptCapable = <String>[
          for (final target in targets)
            if (isPromptCapableTarget(target.name)) target.name,
        ];
        if (request.derivedPrompts && promptCapable.isEmpty) {
          throw MambaException(
            '--derived-prompts requires a prompt-capable target; none of the '
            'selected targets publishes a native Prompt template.',
            exitCode: 4,
          );
        }
        final assessments =
            <
              ({InstallationCandidate candidate, StagedSkill staged}),
              DerivedPromptAssessment
            >{};
        if (promptCapable.isNotEmpty) {
          for (final pair in stagedPairs) {
            final inspection = await _prompts.inspect(
              pair.staged.path,
              form: PromptForm.skill,
            );
            assessments[pair] = assessDerivedPrompt(
              skillDirectory: pair.staged.path,
              inspection: inspection,
              consumers: [
                for (final target in promptCapable)
                  PromptConsumer.values.byName(target),
              ],
              matrix: NativeFieldMatrix.forKind(
                AuthoringKind.prompt,
                AuthoringProfile.values.byName(promptCapable.first),
              ),
            );
          }
        }
        var derive = request.derivedPrompts;
        if (!derive &&
            interactive &&
            context.scope == LifecycleScope.project &&
            promptCapable.isNotEmpty) {
          final eligible = <String>[];
          final ineligible = <String>[];
          for (final MapEntry(key: pair, value: assessment)
              in assessments.entries) {
            final name =
                pair.candidate.id ??
                _fileSystem.path.basename(pair.candidate.path);
            if (assessment.eligible) {
              eligible.add(name);
            } else if (assessment.manualOnly) {
              ineligible.add('$name (${assessment.reasons.join('; ')})');
            }
          }
          for (final entry in ineligible) {
            stdout.writeln('Ineligible for a derived Prompt: $entry');
          }
          if (eligible.isNotEmpty) {
            derive = await _interaction.offerDerivedPrompts(eligible);
          }
        }
        for (final pair in stagedPairs) {
          final assessment = assessments[pair];
          if (derive &&
              assessment != null &&
              assessment.manualOnly &&
              !assessment.eligible) {
            errors.add(
              '${pair.candidate.id ?? pair.candidate.path}: a selected '
              'manual-only Skill is ineligible for a derived Prompt: '
              '${assessment.reasons.join('; ')}',
            );
            continue;
          }
          units.add(
            await _planUnit(
              pair.candidate,
              pair.staged,
              candidates.provenance,
              candidates.sourceKind,
              workspace.selectedRoot,
              context,
              method,
              targets,
              derived: derive && assessment != null && assessment.eligible
                  ? assessment
                  : null,
              promptTargets: promptCapable,
            ),
          );
          for (final field
              in derive
                  ? (assessment?.unsupportedFields ?? const <String>[])
                  : const <String>[]) {
            migrationDiagnostics.add({
              'code': 'derived-prompt-field-dropped',
              'message':
                  'The derived Prompt could not translate the "$field" '
                  'metadata; it is reported rather than silently discarded.',
            });
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
              'origin': request.targets.isNotEmpty
                  ? 'explicit-argument'
                  : configuredTargets.isNotEmpty
                  ? targetSetting!.origin.wireName
                  : detectedTargets.length == 1 &&
                        targets.length == 1 &&
                        detectedTargets.contains(targets.single)
                  ? 'detection'
                  : 'interactive-selection',
            },
            'method': {
              'value': method.wireName,
              'origin': request.method != null
                  ? 'explicit-argument'
                  : methodSetting?.origin.wireName ?? 'built-in-default',
            },
          },
          diagnostics: [
            ...migrationDiagnostics,
            if (candidates.provenance.directFile)
              const <String, Object?>{
                'code': 'single-file-boundary',
                'message': 'Only the selected SKILL.md was acquired; siblings were not read.',
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
                resourceType: CatalogResourceType.skill,
                method: method,
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
          resourceFor: (unit) => _resource(unit),
          interaction: _interaction,
          interactive: interactive,
          approved: request.options.approved,
        );
        if (result is InstallationCompletedResult) {
          if (interactive && result.outcome == InstallationOutcome.installed) {
            await offerInstallationPreferenceSave(
              request: request,
              context: context,
              fileSystem: _fileSystem,
              interaction: _interaction,
              preferences: [
                'cli.install.targets=${targets.map((target) => target.name).join(',')}',
                'cli.install.skill_method=${method.wireName}',
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
        for (final staged in stagedSkills) {
          await staged.close();
        }
      }
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
    Set<InstallationTarget> detected,
    bool interactive,
  ) async {
    if (request.targets.isNotEmpty) {
      return List<InstallationTarget>.unmodifiable(request.targets.toSet());
    }
    if (!interactive) {
      throw MambaException('Unattended Skill installation requires --target.');
    }
    while (true) {
      final answer = await _interaction.selectTargets([
        for (final id in HarnessCatalog.instance.skillInstallationTargets)
          InstallationTarget.values.byName(id.wireName),
      ], detected);
      if (answer.status == InteractionAnswerStatus.cancelled) return null;
      if (answer.status == InteractionAnswerStatus.value) return answer.value;
    }
  }

  Future<InstallationUnitPlan> _planUnit(
    InstallationCandidate candidate,
    StagedSkill staged,
    AcquisitionProvenance provenance,
    AcquisitionSourceKind sourceKind,
    String selectedRoot,
    LifecycleContext context,
    InstallationMethod method,
    List<InstallationTarget> targets, {
    DerivedPromptAssessment? derived,
    List<String> promptTargets = const <String>[],
  }) async {
    final stagedPath = staged.path;
    final relative = provenance.directFile
        ? '.'
        : _fileSystem.path
              .relative(candidate.path, from: selectedRoot)
              .split(_fileSystem.path.separator)
              .join('/');
    final route = InstallationRoute(
      source: provenance,
      sourceKind: sourceKind,
      sourceRelativePath: relative,
      entryId: candidate.id,
      scope: context.scope,
      targets: ([
        for (final target in targets)
          InstallationRouteTarget.values.byName(target.name),
      ]..sort((a, b) => a.name.compareTo(b.name))),
      method: method,
      derivedPrompts: derived?.content != null && promptTargets.isNotEmpty,
      derivedArtifacts: [
        for (final path in [...staged.movedMarkdown, ...staged.movedImages])
          ManagedDerivedArtifact(
            operation: DerivedArtifactOperation.moveRootFile,
            sourcePath: path.split('/').last,
            outputPath: path,
          ),
        if (staged.rewritten)
          ManagedDerivedArtifact(
            operation: DerivedArtifactOperation.rewriteMarker,
            sourcePath: 'SKILL.md',
            outputPath: 'SKILL.md',
          ),
      ],
    );
    final resource = _lifecycle.installationResource(
      targets: [for (final target in targets) target.name],
      kind: switch (method) {
        InstallationMethod.canonical => ArtifactKind.skillCanonical,
        InstallationMethod.copy => ArtifactKind.skillCopy,
        InstallationMethod.sourceLink => ArtifactKind.skillLink,
      },
    );
    final inspected = await resource.inspect(stagedPath, context);
    final digest = state.contentDigest(stagedPath, ArtifactKind.skillCopy);
    final origin = <String, Object?>{
      'status': 'evidenced',
      'schemaVersion': 1,
      'source': provenance.toJson(),
      if (candidate.id != null) 'entryId': candidate.id,
      if (method != InstallationMethod.sourceLink) 'contentDigest': digest,
    };
    final entries = <InstallationEntryPlan>[];
    final canonicalRoot = _fileSystem.path.normalize(
      context.sharedSkillsRoot(),
    );
    final canonicalPath = _fileSystem.path.join(canonicalRoot, inspected.name);
    if (method == InstallationMethod.canonical) {
      entries.add(
        InstallationEntryPlan(
          path: canonicalPath,
          kind: InstallationEntryKind.content,
          action: InstallationEntryAction.createContent,
          target: targets
              .where(
                (target) => _fileSystem.path.equals(
                  _harnessRoot(context, target),
                  canonicalRoot,
                ),
              )
              .firstOrNull
              ?.name,
          nativeRoot: canonicalRoot,
          nativeDestination: 'canonical',
          artifactKind: OwnedArtifactKind.skillCanonical,
        ),
      );
      for (final target in [
        for (final id in HarnessCatalog.instance.skillInstallationTargets)
          InstallationTarget.values.byName(id.wireName),
      ]) {
        if (!targets.contains(target)) continue;
        final root = _lifecycle.canonicalExposureRoot(context, target.name);
        entries.add(
          root == null
              ? InstallationEntryPlan(
                  path: canonicalPath,
                  kind: InstallationEntryKind.consumer,
                  action: InstallationEntryAction.recordConsumer,
                  target: target.name,
                )
              : InstallationEntryPlan(
                  path: _fileSystem.path.join(root, inspected.name),
                  kind: InstallationEntryKind.link,
                  action: InstallationEntryAction.createLink,
                  target: target.name,
                  linkTarget: canonicalPath,
                  nativeLinkKind: _nativeDirectoryLinkKind,
                  nativeRoot: root,
                  nativeDestination: target.name,
                  artifactKind: OwnedArtifactKind.skillLink,
                ),
        );
      }
    } else {
      for (final target in targets) {
        final root = _fileSystem.path.normalize(_harnessRoot(context, target));
        final location = _fileSystem.path.join(root, inspected.name);
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
            nativeLinkKind: method == InstallationMethod.sourceLink
                ? _nativeDirectoryLinkKind
                : null,
            nativeRoot: root,
            nativeDestination: context.scope == LifecycleScope.user
                ? HarnessCatalog.instance
                      .requireSkillInstallation(HarnessId.of(target))
                      .userInstallationDestination!
                : HarnessCatalog.instance
                      .requireSkillInstallation(HarnessId.of(target))
                      .projectInstallationDestination!,
            artifactKind: method == InstallationMethod.copy
                ? OwnedArtifactKind.skillCopy
                : OwnedArtifactKind.skillLink,
          ),
        );
      }
    }
    if (derived?.content != null && promptTargets.isNotEmpty) {
      final promptRoot = derivedPromptRoot(context, promptTargets.first);
      entries.add(
        InstallationEntryPlan(
          path: _fileSystem.path.join(promptRoot, '${inspected.name}.md'),
          kind: InstallationEntryKind.template,
          action: InstallationEntryAction.createContent,
          target: promptTargets.first,
          nativeRoot: promptRoot,
          nativeDestination: promptTargets.first,
          artifactKind: OwnedArtifactKind.promptTemplate,
          content: derived!.content,
        ),
      );
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
      sourcePath: method == InstallationMethod.sourceLink
          ? candidate.path
          : stagedPath,
      sourceDigest: digest,
      origin: origin,
      installationRoute: route,
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
                _fileSystem.path.equals(record.location, content.path);
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
            .where(
              (exposure) => _fileSystem.path.equals(exposure.path, entry.path),
            )
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
      final occupant = _fileSystem.typeSync(entry.path, followLinks: false);
      final managed = records.where((record) {
        return record.lifecycle == 'live' &&
            _fileSystem.path.equals(record.location, entry.path);
      }).toList();
      if (managed.isNotEmpty) {
        final record = managed.single;
        final expectedKind = switch (entry.artifactKind!) {
          OwnedArtifactKind.skillCopy => ArtifactKind.skillCopy,
          OwnedArtifactKind.skillLink => ArtifactKind.skillLink,
          OwnedArtifactKind.skillCanonical => ArtifactKind.skillCanonical,
          OwnedArtifactKind.agentFile => ArtifactKind.agentFile,
          OwnedArtifactKind.promptTemplate => ArtifactKind.promptTemplate,
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

  String _harnessRoot(LifecycleContext context, InstallationTarget target) {
    final spec = HarnessCatalog.instance.requireSkillInstallation(
      HarnessId.of(target),
    );
    return switch (spec.installationRoot!) {
      SkillInstallationRoot.shared => context.sharedSkillsRoot(),
      SkillInstallationRoot.harness => spec.root(
        context,
        userScope: context.scope == LifecycleScope.user,
      ),
    };
  }
}

String get _nativeDirectoryLinkKind => Platform.isWindows
    ? 'windows-directory-symlink'
    : 'posix-directory-symlink';

Future<T> _defaultProgress<T>(String label, Future<T> Function() work) =>
    AcquisitionProgressComponent(label: label).render(work);
