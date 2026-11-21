import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../authoring/native_field_matrix.dart';
import '../harness/harness_catalog.dart';
import '../installation/skill_root_markdown_migration.dart';
import '../installation/installation_plan.dart';
import '../installation/installation_route.dart';
import '../installation/resource_catalog.dart';
import '../skill_files.dart';
import '../skill_validation.dart';
import 'acquisition_service.dart';
import 'conversion_coordinator_service.dart';
import 'native_link_service.dart';
import 'lifecycle_state_service.dart';
import 'prompt_read_service.dart';

enum SkillHarness implements HarnessWireNamed {
  claude,
  codex,
  antigravity;

  @override
  String get wireName => name;
}

enum SkillDestination { claude, codex, shared, antigravity }

enum SkillMode { copy, link }

final class SkillInstallInput {
  const new({
    required this.options,
    required this.source,
    required this.destination,
    this.harnesses = const <SkillHarness>[],
    this.mode = SkillMode.copy,
  });

  final LifecycleOptions options;
  final String source;
  final SkillDestination destination;
  final List<SkillHarness> harnesses;
  final SkillMode mode;
}

/// Copied-Skill installation and adoption. Later lifecycle operations share
/// the same state service and native adapter.
interface class SkillLifecycleService implements LifecycleResource {
  SkillLifecycleService({
    LifecycleStateService? state,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : state = state ?? LifecycleStateService(io: LifecycleIO(fs: fileSystem)),
       _prompts = PromptReadService(
         fileSystem: state?.io.fs ?? fileSystem,
         state: state,
       );

  final LifecycleStateService state;

  /// Shares the body-free native inspector; operational read failures abort.
  final PromptReadService _prompts;

  static const skillKinds = <ArtifactKind>{
    ArtifactKind.skillCopy,
    ArtifactKind.skillLink,
    ArtifactKind.skillCanonical,
  };

  @override
  ArtifactKind get kind => ArtifactKind.skillCopy;

  Future<LifecycleResult> list(
    LifecycleOptions options, {
    SkillDestination? destination,
    bool verify = false,
  }) async {
    final occurrences = <Map<String, Object?>>[];
    var rootsScanned = 0;
    var rootsAbsent = 0;
    var entries = 0;
    for (final scope in switch (options.scope) {
      LifecycleScope.project => const [LifecycleScope.project],
      LifecycleScope.user => const [LifecycleScope.user],
      LifecycleScope.all => const [LifecycleScope.project, LifecycleScope.user],
    }) {
      final scopedContext = LifecycleContext.resolve(
        options.copyWith(scope: scope),
        fileSystem: state.io.fs,
      );
      final records = <InstallationRecord>[];
      final seenRoots = <String>{};
      String? ownershipFailure;
      try {
        records.addAll(state.records(scopedContext));
      } on Exception catch (error) {
        ownershipFailure = error.toString();
      }
      for (final selected in SkillDestination.values) {
        for (final root in _inventoryRoots(scopedContext, selected)) {
          if (!seenRoots.add(state.io.fs.path.normalize(root))) continue;
          final type = skillEntityType(
            root,
            followLinks: false,
            fs: state.io.fs,
          );
          if (type == FileSystemEntityType.notFound) {
            rootsAbsent++;
            continue;
          }
          if (type == FileSystemEntityType.link) {
            rootsAbsent++;
            continue;
          }
          if (type != FileSystemEntityType.directory) {
            throw MambaException(
              'Required Skill inventory root is not a directory: $root',
              exitCode: 3,
            );
          }
          final candidates = _inventoryCandidates(root, () {
            entries++;
            if (entries > maxSkillEntries) {
              throw MambaException(
                'Skill inventory exceeds the 10,000-entry budget.',
                exitCode: 3,
              );
            }
          });
          rootsScanned++;
          for (final candidate in candidates) {
            final path = candidate.path;
            final record = _recordAt(records, path, scope);
            final canonical = record?.kind == ArtifactKind.skillCanonical
                ? record
                : _canonicalRecordForPath(records, path);
            final exposure = canonical == null
                ? null
                : _exposureAt(canonical, path);
            // A tracked exposure is represented by its canonical occurrence.
            if (exposure != null &&
                candidate.type == FileSystemEntityType.link &&
                _isCanonicalExposure(canonical!, exposure, scopedContext)) {
              continue;
            }
            final link = candidate.type == FileSystemEntityType.link
                ? _linkObservation(path, root)
                : null;
            occurrences.add(<String, Object?>{
              'occurrenceId': _occurrenceId(scope, selected, path),
              'path': path,
              'root': root,
              'destination': selected.name,
              'installationScope': scope.name,
              'hasSkillFile': candidate.hasSkillFile,
              'eligibility': link?['eligibility'] ?? candidate.eligibility,
              'nativeLinkKind': link?['nativeLinkKind'],
              'target': link?['target'],
              'targetResolved': link?['targetResolved'],
              'targetValidation': link == null
                  ? 'notApplicable'
                  : 'notRequested',
              'installationId':
                  record?.installationId ?? canonical?.installationId,
              if (canonical != null)
                'artifactKind': ArtifactKind.skillCanonical.wireName,
              if (canonical != null &&
                  state.io.fs.path.equals(canonical.location, path)) ...{
                'exposures': [
                  for (final item in canonical.exposures)
                    <String, Object?>{
                      'path': item.path,
                      'target': item.target,
                      'nativeKind': item.nativeKind,
                      'baselineDigest': item.baseline.digest,
                      'modification': !verify
                          ? 'notVerified'
                          : state.verifyExposure(item)
                          ? 'unchanged'
                          : 'changed',
                    },
                ],
                'directConsumers': [
                  for (final consumer in canonical.knownConsumers)
                    if (canonical.exposures.every(
                      (item) => item.target != consumer,
                    ))
                      consumer,
                ],
                'runtimeActivation': 'notClaimed',
              },
              if (exposure != null) ...{
                'canonicalLocation': canonical!.location,
                'exposureBaselineDigest': exposure.baseline.digest,
                'exposureModification': !verify
                    ? 'notVerified'
                    : state.verifyExposure(exposure)
                    ? 'unchanged'
                    : 'changed',
                'runtimeActivation': 'notClaimed',
              },
              'management': ownershipFailure != null
                  ? 'ownershipUnverified'
                  : record == null
                  ? 'unmanaged'
                  : 'managed',
              ...await _promptObservation(
                path,
                canRead: link == null && candidate.hasSkillFile,
                unavailable: link != null ? 'linkNotRead' : 'markerAbsent',
              ),
              'modification': !verify
                  ? 'notVerified'
                  : record == null
                  ? 'notVerified'
                  : state.verify(record).name,
            });
          }
        }
      }
      for (final record in records.where(
        (record) => skillKinds.contains(record.kind),
      )) {
        final alreadyVisible = occurrences.any(
          (occurrence) =>
              occurrence['path'] is String &&
              state.io.fs.path.equals(
                occurrence['path']! as String,
                record.location,
              ),
        );
        if (alreadyVisible) continue;
        final missing =
            skillEntityType(
              record.location,
              followLinks: false,
              fs: state.io.fs,
            ) ==
            FileSystemEntityType.notFound;
        if (record.lifecycle == 'live' && !missing) continue;
        occurrences.add(<String, Object?>{
          'occurrenceId': _occurrenceId(
            scope,
            record.kind == ArtifactKind.skillCanonical
                ? SkillDestination.shared
                : SkillDestination.values.byName(record.nativeDestination),
            record.location,
          ),
          'path': record.location,
          'root': record.nativeRoot,
          'destination': record.nativeDestination,
          'installationScope': scope.name,
          'hasSkillFile': false,
          'eligibility': 'tracked-missing',
          'promptViews': const <Object?>[],
          'promptInspection': 'sourceUnavailable',
          'installationId': record.installationId,
          if (record.kind == ArtifactKind.skillCanonical) ...{
            'artifactKind': record.kind.wireName,
            'exposures': [
              for (final item in record.exposures)
                <String, Object?>{
                  'path': item.path,
                  'target': item.target,
                  'nativeKind': item.nativeKind,
                  'baselineDigest': item.baseline.digest,
                  'modification': !verify
                      ? 'notVerified'
                      : state.verifyExposure(item)
                      ? 'unchanged'
                      : 'changed',
                },
            ],
            'directConsumers': [
              for (final consumer in record.knownConsumers)
                if (record.exposures.every((item) => item.target != consumer))
                  consumer,
            ],
            'runtimeActivation': 'notClaimed',
          },
          'management': 'managed',
          'modification': !verify
              ? 'notVerified'
              : missing
              ? 'missing'
              : state.verify(record).name,
        });
      }
      if (ownershipFailure != null) {
        occurrences.add(<String, Object?>{
          'occurrenceId': sha256
              .convert(utf8.encode('skill-state\n${scopedContext.stateRoot()}'))
              .toString(),
          'path': state.io.fs.path.join(
            scopedContext.stateRoot(),
            'installations.json',
          ),
          'root': scopedContext.stateRoot(),
          'destination': null,
          'installationScope': scope.name,
          'hasSkillFile': false,
          'eligibility': 'management-document',
          'promptViews': const <Object?>[],
          'promptInspection': 'notResource',
          'installationId': null,
          'management': 'ownershipUnverified',
          'modification': 'unableToVerify',
        });
      }
    }
    final filtered =
        occurrences
            .where(
              (occurrence) =>
                  destination == null ||
                  occurrence['destination'] == destination.name ||
                  (occurrence['exposures'] is List &&
                      (occurrence['exposures'] as List).any(
                        (item) => item['target'] == destination.name,
                      )) ||
                  (occurrence['directConsumers'] is List &&
                      (occurrence['directConsumers'] as List).contains(
                        destination.name,
                      )),
            )
            .toList()
          ..sort(
            (left, right) => '${left['path']}'.compareTo('${right['path']}'),
          );
    return LifecycleResult(
      command: 'skill list',
      outcome: 'inventoried',
      data: <String, Object?>{
        'scope': options.scope.name,
        'verification': verify ? 'requested' : 'notVerified',
        'occurrences': filtered,
        'coverage': <String, Object?>{
          'status': 'complete',
          'rootsScanned': rootsScanned,
          'rootsAbsent': rootsAbsent,
          'entries': entries,
          'limits': const <String, int>{'entries': maxSkillEntries},
        },
      },
    );
  }

  /// Checks the source-level admission rules shared by Skill installations.
  /// Destination, ownership and publication checks are performed separately.
  Future<Map<String, Object?>> installationAdmission(String path) async {
    StagedSkill? staged;
    try {
      staged = await SkillRootMarkdownMigration(fileSystem: state.io.fs)
          .stage(path);
      state.validateSkillTree(staged.path);
      final name = readDeclaredSkillName(staged.path, fs: state.io.fs);
      final report = validateSkill(
        staged.path,
        expectedDirectoryName: name,
        fs: state.io.fs,
      );
      return <String, Object?>{
        'eligible': report.valid,
        'scope': 'source-only',
        'methods': <String, bool>{
          'copy': report.valid,
          'canonical': report.valid,
          'source-link': report.valid && !staged.migrated,
        },
        'diagnostics': [
          for (final diagnostic in report.diagnostics) diagnostic.toJson(),
          if (staged.migrated)
            <String, Object?>{
              'code': 'SOURCE_LINK_REQUIRES_MIGRATION',
              'message': 'source-link cannot migrate loose root files; move them into references/ or assets/, or use copy or canonical.',
            },
        ],
      };
    } on MambaException catch (error) {
      return <String, Object?>{
        'eligible': false,
        'scope': 'source-only',
        'methods': <String, bool>{
          'copy': false,
          'canonical': false,
          'source-link': false,
        },
        'diagnostics': [
          <String, Object?>{'message': error.message},
        ],
      };
    } finally {
      await staged?.close();
    }
  }

  /// The body-free native Skill view of one source for Antigravity.
  ///
  /// Antigravity has no Prompt facet, but it does consume ordinary Skills.
  /// The view applies the Antigravity Skill field matrix instead of inventing
  /// a manual-only Prompt classification.
  Future<Map<String, Object?>> antigravityView(String path) async {
    final diagnostics = <Map<String, Object?>>[];
    final report = validateSkill(path, fs: state.io.fs);
    for (final diagnostic in report.diagnostics) {
      if (diagnostic.severity != DiagnosticSeverity.error) continue;
      diagnostics.add(<String, Object?>{
        'code': diagnostic.code,
        'message': diagnostic.message,
        'path': path,
      });
    }
    try {
      _validateAntigravityFields(path);
    } on MambaException catch (error) {
      diagnostics.add(<String, Object?>{
        'code': 'UNSUPPORTED_FIELD',
        'message': error.message,
        'path': path,
      });
    }
    return <String, Object?>{
      'path': state.io.fs.path.normalize(
        state.io.fs.directory(path).absolute.path,
      ),
      'form': 'skill',
      'selectedConsumer': 'antigravity',
      'globalCompatibility': 'notApplicable',
      'placement': 'unknown',
      'views': <Object?>[
        <String, Object?>{
          'consumer': 'antigravity',
          'classification': 'nonPrompt',
          'valid': diagnostics.isEmpty,
          'installationSupported': diagnostics.isEmpty,
          'diagnostics': diagnostics,
        },
      ],
    };
  }

  Future<Map<String, Object?>> _promptObservation(
    String path, {
    required bool canRead,
    required String unavailable,
  }) async {
    if (!canRead) {
      return {
        'promptViews': const <Object?>[],
        'promptInspection': unavailable,
      };
    }
    final native = await _prompts.inspect(path);
    return {
      'promptViews': [for (final view in native.views.values) view.toJson()],
      'promptInspection': 'inspected',
      'globalCompatibility': native.globalCompatibility.name,
    };
  }

  List<_SkillCandidate> _inventoryCandidates(
    String root,
    void Function() chargeEntry,
  ) {
    final result = <_SkillCandidate>[];
    void visit(String directory, int depth) {
      if (depth > maxSkillDepth) {
        throw MambaException(
          'Skill inventory exceeds the depth-32 budget.',
          exitCode: 3,
        );
      }
      final children = listSkillDirectory(directory, fs: state.io.fs)
        ..sort((left, right) => left.path.compareTo(right.path));
      for (final child in children) {
        chargeEntry();
        final type = skillEntityType(
          child.path,
          followLinks: false,
          fs: state.io.fs,
        );
        final path = state.io.fs.path.normalize(child.absolute.path);
        if (type == FileSystemEntityType.link) {
          if (depth == 0) {
            result.add(
              _SkillCandidate(
                path: path,
                type: type,
                hasSkillFile: false,
                eligibility: 'unsupported-link',
              ),
            );
          }
          continue;
        }
        if (type != FileSystemEntityType.directory) continue;
        final hasMarker =
            skillEntityType(
              state.io.fs.path.join(path, 'SKILL.md'),
              followLinks: false,
              fs: state.io.fs,
            ) ==
            FileSystemEntityType.file;
        if (depth == 0 || hasMarker) {
          result.add(
            _SkillCandidate(
              path: path,
              type: type,
              hasSkillFile: hasMarker,
              eligibility: depth == 0
                  ? 'direct-child-copy'
                  : 'nested-ineligible',
            ),
          );
        }
        visit(path, depth + 1);
      }
    }

    visit(root, 0);
    return result;
  }

  InstallationRecord? _recordAt(
    List<InstallationRecord> records,
    String path,
    LifecycleScope scope,
  ) {
    final matches = records.where(
      (record) =>
          skillKinds.contains(record.kind) &&
          record.scope == scope &&
          record.lifecycle == 'live' &&
          state.io.fs.path.equals(record.location, path),
    );
    if (matches.length > 1) {
      throw MambaException(
        'Overlapping Skill management authority.',
        exitCode: 4,
      );
    }
    return matches.isEmpty ? null : matches.single;
  }

  InstallationRecord? _canonicalRecordForPath(
    List<InstallationRecord> records,
    String path,
  ) {
    for (final record in records) {
      if (record.kind == ArtifactKind.skillCanonical &&
          record.lifecycle == 'live' &&
          record.exposures.any(
            (exposure) => state.io.fs.path.equals(exposure.path, path),
          )) {
        return record;
      }
    }
    return null;
  }

  bool _isCanonicalExposure(
    InstallationRecord record,
    ExposureRecord exposure,
    LifecycleContext context,
  ) {
    try {
      validateAuthority(record, context);
      final entry = exposure.baseline.entries.single;
      if (entry.target == null ||
          entry.originalParent == null ||
          !state.io.fs.path.equals(
            entry.originalParent!,
            state.io.fs.path.dirname(exposure.path),
          ) ||
          entry.nativeKind != exposure.nativeKind) {
        return false;
      }
      final target = state.io.fs.path.normalize(
        state.io.fs.path.isAbsolute(entry.target!)
            ? entry.target!
            : state.io.fs.path.join(
                state.io.fs.path.dirname(exposure.path),
                entry.target!,
              ),
      );
      return state.io.fs.path.equals(target, record.location) &&
          state.verifyExposure(exposure);
    } on Exception {
      return false;
    }
  }

  ExposureRecord? _exposureAt(InstallationRecord record, String path) {
    for (final exposure in record.exposures) {
      if (state.io.fs.path.equals(exposure.path, path)) return exposure;
    }
    return null;
  }

  String _occurrenceId(
    LifecycleScope scope,
    SkillDestination destination,
    String path,
  ) => sha256
      .convert(
        utf8.encode(
          'skill-occurrence-v1\n${scope.name}\n${destination.name}\n$path',
        ),
      )
      .toString();

  List<String> _inventoryRoots(
    LifecycleContext context,
    SkillDestination destination,
  ) {
    if (context.scope == LifecycleScope.user) {
      if (destination == SkillDestination.antigravity) {
        return _skillSpec(HarnessId.antigravity).discoveryRoots(context);
      }
      return [_root(context, destination)];
    }
    final roots = <String>[];
    var current = context.cwd;
    while (true) {
      roots.add(
        state.io.fs.path.normalize(switch (destination) {
          SkillDestination.claude => state.io.fs.path.join(
            current,
            '.claude',
            'skills',
          ),
          SkillDestination.codex => state.io.fs.path.join(
            current,
            '.codex',
            'skills',
          ),
          SkillDestination.shared || SkillDestination.antigravity =>
            state.io.fs.path.join(current, '.agents', 'skills'),
        }),
      );
      if (state.io.fs.path.equals(current, context.projectRoot)) break;
      current = state.io.fs.path.dirname(current);
      if (roots.length >= 64) {
        throw MambaException(
          'Skill inventory exceeds 64 ancestors.',
          exitCode: 3,
        );
      }
    }
    return roots;
  }

  LifecycleResource installationResource({
    required List<String> targets,
    required ArtifactKind kind,
    Set<String> allowedExtraFolders = const <String>{},
  }) => _ProfiledSkillResource(this, targets, kind, allowedExtraFolders);

  Future<LifecycleResult> install(SkillInstallInput input) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: state.io.fs,
    );
    _requireMutationScope(context);
    final source = context.resolvePath(input.source);
    final declaredName = readDeclaredSkillName(source, fs: state.io.fs);
    final root = _root(context, input.destination);
    final location = state.io.fs.path.normalize(
      state.io.fs.path.join(root, declaredName),
    );
    return state.install(
      resource: _ProfiledSkillResource(
        this,
        _selectedProfiles(input.destination, input.harnesses),
        input.mode == SkillMode.link
            ? ArtifactKind.skillLink
            : ArtifactKind.skillCopy,
      ),
      context: context,
      source: source,
      location: location,
      nativeRoot: root,
      nativeDestination: input.destination.name,
      installationRoute: InstallationRoute(
        source: AcquisitionProvenance(
          kind: AcquisitionLocatorKind.local,
          requestedLocator: input.source,
          resolvedLocator: source,
          subpath: null,
          temporary: false,
          directFile: false,
          durableLocalDirectory:
              state.io.type(source, followLinks: false) ==
              FileSystemEntityType.directory,
        ),
        sourceKind: AcquisitionSourceKind.resource,
        sourceRelativePath: '.',
        scope: context.scope,
        targets: <InstallationRouteTarget>{
          InstallationRouteTarget.values.byName(input.destination.name),
          for (final harness in input.harnesses)
            InstallationRouteTarget.values.byName(harness.name),
        }.toList()..sort((a, b) => a.name.compareTo(b.name)),
        method: input.mode == SkillMode.copy
            ? InstallationMethod.copy
            : InstallationMethod.sourceLink,
        derivedArtifacts: const [],
      ),
    );
  }

  Future<LifecycleResult> adopt(SkillInstallInput input) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: state.io.fs,
    );
    _requireMutationScope(context);
    final location = context.resolvePath(input.source);
    final root = _root(context, input.destination);
    if (!state.io.fs.path.equals(state.io.fs.path.dirname(location), root)) {
      throw MambaException(
        'Skill adoption requires an existing direct child of $root; '
        'nested candidates remain discoverable but are ineligible.',
        exitCode: 4,
      );
    }
    final entryKind =
        state.io.type(location, followLinks: false) == FileSystemEntityType.link
        ? ArtifactKind.skillLink
        : ArtifactKind.skillCopy;
    return state.adopt(
      resource: _ProfiledSkillResource(
        this,
        _selectedProfiles(input.destination, input.harnesses),
        entryKind,
      ),
      context: context,
      location: location,
      nativeRoot: root,
      nativeDestination: input.destination.name,
    );
  }

  /// Update a direct installation from its recorded acquisition and route.
  Future<LifecycleResult> update(LifecycleIdInput input) => _replay(input);

  /// Review and change the method of a direct copied or linked Skill.
  Future<LifecycleResult> migrate(
    LifecycleIdInput input, {
    required InstallationMethod method,
    List<InstallationTarget>? targets,
    String? reviewedPlan,
  }) => _replay(
    input,
    migrationMethod: method,
    migrationTargets: targets,
    reviewedPlan: reviewedPlan,
  );

  Future<LifecycleResult> _replay(
    LifecycleIdInput input, {
    InstallationMethod? migrationMethod,
    List<InstallationTarget>? migrationTargets,
    String? reviewedPlan,
  }) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: state.io.fs,
    );
    _requireMutationScope(context);
    final record = state.recordById(context, input.id);
    final route = record.installationRoute;
    if (!skillKinds.contains(record.kind) ||
        route == null ||
        route.packKey != null ||
        route.scope != context.scope) {
      throw MambaException(
        'A direct Skill update requires a recorded direct installation route in this scope.',
        exitCode: 4,
      );
    }
    final expectedKind = switch (route.method) {
      InstallationMethod.copy => ArtifactKind.skillCopy,
      InstallationMethod.canonical => ArtifactKind.skillCanonical,
      InstallationMethod.sourceLink => ArtifactKind.skillLink,
    };
    if (record.kind != expectedKind) {
      throw MambaException(
        'The recorded Skill method does not match its installation.',
        exitCode: 4,
      );
    }
    final requestedTargets =
        migrationTargets == null || migrationTargets.isEmpty
        ? route.targets
        : ([
            for (final target in migrationTargets)
              InstallationRouteTarget.values.byName(target.name),
          ]..sort((a, b) => a.name.compareTo(b.name)));
    if (requestedTargets.toSet().length != requestedTargets.length) {
      throw MambaException(
        'Duplicate migration targets are not allowed.',
        exitCode: 4,
      );
    }
    for (final target in migrationTargets ?? const <InstallationTarget>[]) {
      HarnessCatalog.instance.requireSkillInstallation(HarnessId.of(target));
    }
    final targetsChanged =
        jsonEncode(requestedTargets.map((target) => target.name).toList()) !=
        jsonEncode(route.targets.map((target) => target.name).toList());
    final canonicalTargets =
        migrationMethod == InstallationMethod.canonical &&
        route.method == InstallationMethod.canonical &&
        targetsChanged;
    if (migrationMethod != null &&
        !canonicalTargets &&
        (targetsChanged ||
            migrationMethod == InstallationMethod.canonical ||
            route.method == InstallationMethod.canonical ||
            migrationMethod == route.method)) {
      throw MambaException(
        'This migration supports canonical target changes or copy/source-link method changes at the existing target; the requested transition is not supported.',
        exitCode: 4,
      );
    }
    final method = migrationMethod ?? route.method;
    final desiredKind = switch (method) {
      InstallationMethod.copy => ArtifactKind.skillCopy,
      InstallationMethod.canonical => ArtifactKind.skillCanonical,
      InstallationMethod.sourceLink => ArtifactKind.skillLink,
    };
    final source = route.source;
    final workspace = await AcquisitionService(fileSystem: state.io.fs).acquire(
      AcquisitionRequest(
        locator: source.kind == AcquisitionLocatorKind.local
            ? source.resolvedLocator
            : source.requestedLocator,
        cwd: context.cwd,
        resourceType: CatalogResourceType.skill,
        sourceKind: route.sourceKind,
        ref: source.requestedRef,
        subpath: source.kind == AcquisitionLocatorKind.local
            ? null
            : source.subpath,
      ),
    );
    try {
      final fs = state.io.fs;
      var path = workspace.selectedRoot;
      if (route.sourceRelativePath != '.') {
        for (final part in route.sourceRelativePath.split('/')) {
          path = fs.path.join(path, part);
          if (skillEntityType(path, followLinks: false, fs: fs) ==
              FileSystemEntityType.link) {
            throw MambaException(
              'The recorded source path now contains a link.',
              exitCode: 4,
            );
          }
        }
      }
      for (final omitted in workspace.omittedLinkPaths) {
        if (route.sourceRelativePath == '.' ||
            omitted == route.sourceRelativePath ||
            omitted.startsWith('${route.sourceRelativePath}/')) {
          throw MambaException(
            'The recorded Skill source contains an unsafe link.',
            exitCode: 4,
          );
        }
      }
      final staged = await SkillRootMarkdownMigration(fileSystem: fs)
          .stage(path);
      try {
        if (method == InstallationMethod.sourceLink &&
            (!workspace.provenance.durableLocalDirectory || staged.migrated)) {
          throw MambaException(
            'source-link cannot migrate loose root files.',
            exitCode: 4,
          );
        }
        final acquired = workspace.provenance;
        final replayedSource = AcquisitionProvenance(
          kind: acquired.kind,
          requestedLocator: source.requestedLocator,
          resolvedLocator: acquired.resolvedLocator,
          subpath: source.subpath,
          temporary: acquired.temporary,
          directFile: acquired.directFile,
          durableLocalDirectory: acquired.durableLocalDirectory,
          requestedRef: source.requestedRef,
          resolvedCommit: acquired.resolvedCommit,
          downloadDigest: acquired.downloadDigest,
          configDigest: source.configDigest,
        );
        final newRoute = InstallationRoute(
          source: replayedSource,
          sourceKind: route.sourceKind,
          sourceRelativePath: route.sourceRelativePath,
          entryId: route.entryId,
          scope: route.scope,
          targets: requestedTargets,
          method: method,
          derivedArtifacts: [
            for (final item in [...staged.movedMarkdown, ...staged.movedImages])
              ManagedDerivedArtifact(
                operation: DerivedArtifactOperation.moveRootFile,
                sourcePath: item.split('/').last,
                outputPath: item,
              ),
            if (staged.rewritten)
              ManagedDerivedArtifact(
                operation: DerivedArtifactOperation.rewriteMarker,
                sourcePath: 'SKILL.md',
                outputPath: 'SKILL.md',
              ),
          ],
        );
        final resource = installationResource(
          targets: [for (final target in requestedTargets) target.name],
          kind: desiredKind,
        );
        final digest = state.contentDigest(staged.path, ArtifactKind.skillCopy);
        final origin = <String, Object?>{
          ...record.origin,
          'source': replayedSource.toJson(),
          'contentDigest': digest,
        };
        final planId = migrationMethod == null
            ? null
            : sha256
                  .convert(
                    utf8.encode(
                      jsonEncode({
                        'record': record.toJson(),
                        'destinationRoots': [
                          for (final target in requestedTargets)
                            canonicalExposureRoot(context, target.name),
                        ],
                        'from': route.toJson(),
                        'to': newRoute.toJson(),
                        'sourceDigest': digest,
                      }),
                    ),
                  )
                  .toString();
        if (migrationMethod != null &&
            !context.dryRun &&
            reviewedPlan != planId) {
          throw MambaException(
            'Review a current migration preview and supply its plan ID with --reviewed-plan.',
            exitCode: 4,
          );
        }
        if (expectedKind == ArtifactKind.skillLink && migrationMethod == null) {
          if (!workspace.provenance.durableLocalDirectory ||
              state.verify(record) != ModificationStatus.unchanged) {
            throw MambaException(
              'The recorded source link is no longer unchanged or durable.',
              exitCode: 4,
            );
          }
          final target = fs.link(record.location).targetSync();
          final resolvedTarget = fs.path.normalize(
            fs.path.isAbsolute(target)
                ? target
                : fs.path.join(fs.path.dirname(record.location), target),
          );
          if (!fs.path.equals(resolvedTarget, fs.path.normalize(path))) {
            throw MambaException(
              'The recorded source link no longer points to its source.',
              exitCode: 4,
            );
          }
          await resource.inspect(path, context, expectedName: record.name);
          await state.updateOrigin(
            context: context,
            installationId: input.id,
            expectedOrigin: record.origin,
            origin: origin,
            installationRoute: newRoute,
          );
          return LifecycleResult(
            command: 'skill update',
            outcome: context.dryRun ? 'planned' : 'updated',
            data: {
              'installationId': input.id,
              'location': record.location,
              'route': newRoute.toJson(),
            },
          );
        }
        final exposures = canonicalTargets
            ? [
                for (final target in requestedTargets)
                  if (canonicalExposureRoot(context, target.name)
                      case final String root)
                    state.plannedCanonicalExposure(
                      path: fs.path.join(root, record.name),
                      target: target.name,
                      canonicalPath: record.location,
                    ),
              ]
            : null;
        if (canonicalTargets) {
          for (final old in route.targets) {
            if (!requestedTargets.contains(old) &&
                (old == InstallationRouteTarget.codex ||
                    old == InstallationRouteTarget.antigravity &&
                        context.scope == LifecycleScope.project)) {
              throw MambaException(
                'Shared canonical content remains discoverable to ${old.name}; this target cannot be revoked by metadata.',
                exitCode: 4,
              );
            }
          }
        }
        final result = expectedKind == ArtifactKind.skillCanonical
            ? await state.replaceCanonical(
                resource: resource,
                context: context,
                installationId: input.id,
                source: staged.path,
                origin: origin,
                installationRoute: newRoute,
                exposures: exposures,
                validatedProfiles: canonicalTargets
                    ? [for (final target in requestedTargets) target.name]
                    : null,
                knownConsumers: canonicalTargets
                    ? [for (final target in requestedTargets) target.name]
                    : null,
              )
            : await state.replace(
                resource: resource,
                context: context,
                installationId: input.id,
                source: desiredKind == ArtifactKind.skillLink
                    ? path
                    : staged.path,
                origin: origin,
                installationRoute: newRoute,
              );
        return LifecycleResult(
          command: migrationMethod == null ? 'skill update' : 'skill migrate',
          outcome: context.dryRun
              ? 'planned'
              : migrationMethod == null
              ? 'updated'
              : 'migrated',
          data: {
            ...result.data,
            if (migrationMethod != null) ...{
              'fromMethod': route.method.wireName,
              'toMethod': method.wireName,
              'fromTargets': [for (final target in route.targets) target.name],
              'toTargets': [for (final target in requestedTargets) target.name],
              'planId': planId,
            },
            'route': newRoute.toJson(),
          },
        );
      } finally {
        await staged.close();
      }
    } finally {
      await workspace.close();
    }
  }

  Future<LifecycleResult> replace(
    LifecycleReplaceInput input, {
    SkillMode? mode,
  }) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: state.io.fs,
    );
    _requireMutationScope(context);
    final record = state.recordById(context, input.installationId);
    if (!skillKinds.contains(record.kind)) {
      throw MambaException(
        'The selected installation is not a managed Skill.',
        exitCode: 4,
      );
    }
    final replacementKind = switch (mode) {
      null => record.kind,
      SkillMode.copy => ArtifactKind.skillCopy,
      SkillMode.link => ArtifactKind.skillLink,
    };
    final source = context.resolvePath(input.source);
    if (record.kind == ArtifactKind.skillCanonical) {
      if (mode != null) {
        throw MambaException(
          'Canonical replacement preserves its canonical method; --mode is not applicable.',
          exitCode: 4,
        );
      }
      return state.replaceCanonical(
        resource: _ProfiledSkillResource(
          this,
          record.validatedProfiles,
          ArtifactKind.skillCanonical,
        ),
        context: context,
        installationId: input.installationId,
        source: source,
        origin: <String, Object?>{
          'status': 'evidenced',
          'schemaVersion': 1,
          'source': <String, Object?>{
            'kind': 'local',
            'requestedLocator': input.source,
            'resolvedLocator': source,
            'temporary': false,
          },
          'contentDigest': state.contentDigest(
            source,
            ArtifactKind.skillCanonical,
          ),
        },
      );
    }
    return state.replace(
      resource: _ProfiledSkillResource(
        this,
        record.validatedProfiles,
        replacementKind,
      ),
      context: context,
      installationId: input.installationId,
      source: source,
    );
  }

  Future<LifecycleResult> remove(
    LifecycleIdInput input, {
    SkillHarness? target,
  }) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: state.io.fs,
    );
    _requireMutationScope(context);
    final record = state.recordById(context, input.id);
    if (record.kind == ArtifactKind.skillCanonical) {
      return state.removeCanonical(
        resource: _ProfiledSkillResource(
          this,
          record.validatedProfiles,
          ArtifactKind.skillCanonical,
        ),
        context: context,
        installationId: input.id,
        target: target?.name,
      );
    }
    if (target != null) {
      throw MambaException(
        '--target applies only to canonical exposure detachment; legacy '
        'copy/link artifacts require whole-installation removal.',
        exitCode: 4,
      );
    }
    return state.remove(
      resource: _ProfiledSkillResource(
        this,
        record.validatedProfiles,
        record.kind,
      ),
      context: context,
      installationId: input.id,
    );
  }

  Future<LifecycleResult> restore(LifecycleIdInput input) async {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: state.io.fs,
    );
    _requireMutationScope(context);
    final backupKind = state.artifactKindForBackup(
      context,
      input.id,
      skillKinds,
    );
    final record = state.installationForBackup(context, input.id, backupKind);
    if (record.kind == ArtifactKind.skillCanonical) {
      return state.restoreCanonical(
        resource: _ProfiledSkillResource(
          this,
          record.validatedProfiles,
          ArtifactKind.skillCanonical,
        ),
        context: context,
        backupId: input.id,
      );
    }
    return state.restore(
      resource: _ProfiledSkillResource(
        this,
        record.validatedProfiles,
        backupKind,
      ),
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
        editKinds: const {ArtifactKind.skillCopy},
      );
    }
    final context = LifecycleContext.resolve(options, fileSystem: state.io.fs);
    final resource = transactionId == null
        ? this
        : _ProfiledSkillResource(
            this,
            const <String>[],
            state.artifactKindForTransaction(
              context,
              transactionId,
              skillKinds,
            ),
          );
    return state.recover(
      resource: resource,
      context: context,
      transactionId: transactionId,
      action: action,
      kinds: skillKinds,
    );
  }

  Future<LifecycleResult> backupList(LifecycleOptions options) =>
      state.backupList(
        LifecycleContext.resolve(options, fileSystem: state.io.fs),
        kind,
        additionalKinds: const {
          ArtifactKind.skillLink,
          ArtifactKind.skillCanonical,
        },
      );

  Future<LifecycleResult> cleanup(LifecycleIdInput input) {
    final context = LifecycleContext.resolve(
      input.options,
      fileSystem: state.io.fs,
    );
    final backupKind = state.artifactKindForBackup(
      context,
      input.id,
      skillKinds,
    );
    return state.cleanup(
      resource: _ProfiledSkillResource(this, const <String>[], backupKind),
      context: context,
      backupId: input.id,
    );
  }

  void validateProfiles(String path, List<String> profiles) {
    for (final profile in profiles) {
      switch (profile) {
        case 'claude':
          final name = readDeclaredSkillName(
            path,
            fs: state.io.fs,
          ).toLowerCase();
          if (name == 'synced' || name == 'anthropic-skills') {
            throw MambaException(
              'The Claude Skill profile reserves the name "$name".',
              exitCode: 2,
            );
          }
        case 'codex':
          _validateCodexSidecar(path);
        case 'antigravity':
          _validateAntigravityFields(path);
        default:
          throw MambaException(
            'Unsupported Skill compatibility profile: $profile',
            exitCode: 2,
          );
      }
    }
  }

  void _validateAntigravityFields(String path) {
    final spec = _skillSpec(HarnessId.antigravity);
    final marker = state.io.fs.path.join(path, 'SKILL.md');
    final bytes = readBoundedSkillMarker(
      marker,
      maxBytes: 1048576,
      fs: state.io.fs,
    );
    if (bytes.length > 1048576) {
      throw MambaException('SKILL.md exceeds 1 MiB.', exitCode: 2);
    }
    final content = utf8.decode(bytes, allowMalformed: false);
    final lines = content.split('\n');
    if (lines.isEmpty || lines.first.trimRight() != '---') {
      throw MambaException(
        'Antigravity SKILL.md must start with frontmatter.',
        exitCode: 2,
      );
    }
    final closing = lines.indexWhere((line) => line.trimRight() == '---', 1);
    if (closing < 0) {
      throw MambaException(
        'Antigravity SKILL.md frontmatter is unterminated.',
        exitCode: 2,
      );
    }
    final Object? document;
    try {
      document = loadYaml(lines.sublist(1, closing).join('\n'));
    } on Exception catch (error) {
      throw MambaException(
        'SKILL.md frontmatter is invalid: $error',
        exitCode: 2,
      );
    }
    if (document is! Map) {
      throw MambaException(
        'Antigravity SKILL.md must contain a YAML mapping.',
        exitCode: 2,
      );
    }
    final supported = spec
        .nativeSkillFields(AuthoringProfile.antigravity)
        .supportedNames
        .toSet();
    final unsupported =
        document.keys
            .where((key) => key is String && !supported.contains(key))
            .toList()
          ..sort();
    if (unsupported.isNotEmpty) {
      throw MambaException(
        'The antigravity Skill profile supports only ${supported.join(', ')}; '
        'unsupported field(s): ${unsupported.join(', ')}.',
        exitCode: 2,
      );
    }
  }

  void _validateCodexSidecar(String path) {
    final sidecar = state.io.fs.path.join(path, 'agents', 'openai.yaml');
    final type = skillEntityType(sidecar, followLinks: false, fs: state.io.fs);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'Codex agents/openai.yaml must be a regular non-link file.',
        exitCode: 2,
      );
    }
    final bytes = readBoundedSkillMarker(
      sidecar,
      maxBytes: 1048576,
      fs: state.io.fs,
    );
    if (bytes.length > 1048576) {
      throw MambaException(
        'Codex agents/openai.yaml exceeds 1 MiB.',
        exitCode: 2,
      );
    }
    final Object? document;
    try {
      document = loadYaml(utf8.decode(bytes, allowMalformed: false));
    } on Exception catch (error) {
      throw MambaException(
        'Codex agents/openai.yaml is invalid: $error',
        exitCode: 2,
      );
    }
    if (document is! Map) {
      throw MambaException(
        'Codex agents/openai.yaml must contain a YAML mapping.',
        exitCode: 2,
      );
    }
    for (final section in const ['interface', 'policy', 'dependencies']) {
      final value = document[section];
      if (value != null && value is! Map) {
        throw MambaException(
          'Codex $section must be a mapping when present.',
          exitCode: 2,
        );
      }
    }
    final policy = document['policy'];
    if (policy is Map &&
        policy['allow_implicit_invocation'] != null &&
        policy['allow_implicit_invocation'] is! bool) {
      throw MambaException(
        'Codex policy.allow_implicit_invocation must be a boolean.',
        exitCode: 2,
      );
    }
  }

  String resolveContentTarget(String path) {
    final type = state.io.type(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      final target = state.io.readLink(path);
      return state.io.fs.path.normalize(
        state.io.fs.path.isAbsolute(target)
            ? target
            : state.io.fs.path.join(state.io.fs.path.dirname(path), target),
      );
    }
    if (type == FileSystemEntityType.file &&
        state.io.fs.path.basename(path) == 'artifact-link.json') {
      final entry = state.readLinkBaseline(path).entries.single;
      return state.io.fs.path.normalize(
        state.io.fs.path.isAbsolute(entry.target!)
            ? entry.target!
            : state.io.fs.path.join(entry.originalParent!, entry.target!),
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw MambaException(
        'The Skill candidate is not an ordinary directory or supported link: $path',
        exitCode: 2,
      );
    }
    return path;
  }

  /// The native root that requires a link to shared canonical content.
  String? canonicalExposureRoot(LifecycleContext context, String target) =>
      switch (target) {
        'claude' => _root(context, SkillDestination.claude),
        'antigravity' when context.scope == LifecycleScope.user => _root(
          context,
          SkillDestination.antigravity,
        ),
        _ => null,
      };

  @override
  void validateAuthority(InstallationRecord record, LifecycleContext context) {
    final canonical = record.kind == ArtifactKind.skillCanonical;
    final destination = canonical
        ? SkillDestination.shared
        : SkillDestination.values.firstWhere(
            (value) => value.name == record.nativeDestination,
            orElse: () => throw MambaException(
              'Unsupported stored Skill destination.',
              exitCode: 4,
            ),
          );
    final root = _root(context, destination);
    if (!skillKinds.contains(record.kind) ||
        record.scope != context.scope ||
        record.nativeForm != record.kind.wireName ||
        (canonical && record.nativeDestination != 'canonical') ||
        !state.io.fs.path.equals(record.nativeRoot, root) ||
        !state.io.fs.path.equals(
          state.io.fs.path.dirname(record.location),
          root,
        ) ||
        state.io.fs.path.basename(record.location) != record.name) {
      throw MambaException(
        'Stored Skill location does not match current native authority.',
        exitCode: 4,
      );
    }
    if (canonical) {
      final paths = <String>[];
      for (final exposure in record.exposures) {
        final exposureRoot = canonicalExposureRoot(context, exposure.target);
        if (exposureRoot == null ||
            !state.io.fs.path.equals(
              exposure.path,
              state.io.fs.path.join(exposureRoot, record.name),
            ) ||
            paths.any((path) => state.io.fs.path.equals(path, exposure.path)) ||
            exposure.baseline.entries.length != 1 ||
            exposure.baseline.entries.single.type != 'link') {
          throw MambaException(
            'Stored canonical exposure does not match current native authority.',
            exitCode: 4,
          );
        }
        final entry = exposure.baseline.entries.single;
        final parent = state.io.fs.path.dirname(exposure.path);
        if (entry.target == null ||
            entry.originalParent == null ||
            !state.io.fs.path.equals(entry.originalParent!, parent) ||
            entry.nativeKind != exposure.nativeKind ||
            !state.io.fs.path.equals(
              state.io.fs.path.normalize(
                state.io.fs.path.isAbsolute(entry.target!)
                    ? entry.target!
                    : state.io.fs.path.join(parent, entry.target!),
              ),
              record.location,
            )) {
          throw MambaException(
            'Stored canonical exposure does not match current native authority.',
            exitCode: 4,
          );
        }
        paths.add(exposure.path);
      }
    }
  }

  @override
  Future<LifecycleCandidate> inspect(
    String path,
    LifecycleContext context, {
    String? expectedName,
    bool restoringBaseline = false,
    Set<String> allowedExtraFolders = const <String>{},
  }) async {
    final type = state.io.type(path, followLinks: false);
    var nativeForm = 'skill-copy';
    String? nativeLinkKind;
    String? linkTarget;
    if (type == FileSystemEntityType.link) {
      nativeForm = 'skill-link';
      nativeLinkKind = state.io.linkKind(path);
      linkTarget = state.io.readLink(path);
    } else if (type == FileSystemEntityType.file &&
        state.io.fs.path.basename(path) == 'artifact-link.json') {
      nativeForm = 'skill-link';
      final entry = state.readLinkBaseline(path).entries.single;
      nativeLinkKind = entry.nativeKind;
      linkTarget = entry.target;
    }
    final inspectedPath = resolveContentTarget(path);
    state.validateSkillTree(
      inspectedPath,
      restoringBaseline: restoringBaseline,
      allowedExtraFolders: allowedExtraFolders,
    );
    final declaredName = readDeclaredSkillName(inspectedPath, fs: state.io.fs);
    if (expectedName != null && declaredName != expectedName) {
      throw MambaException(
        'The declared Skill name changed during the operation.',
        exitCode: 4,
      );
    }
    final report = validateSkill(
      inspectedPath,
      expectedDirectoryName: declaredName,
      fs: state.io.fs,
    );
    if (!report.valid) {
      throw MambaException(
        'Skill validation failed: ${report.diagnostics.where((diagnostic) => diagnostic.severity == DiagnosticSeverity.error).map((diagnostic) => diagnostic.code).join(', ')}',
        exitCode: 2,
      );
    }
    final destination = _destinationForPath(context, path);
    final profiles = _profiles(context, destination);
    final knownConsumers = switch (destination) {
      SkillDestination.antigravity =>
        context.scope == LifecycleScope.project
            ? const <String>['codex', 'antigravity']
            : const <String>['antigravity'],
      _ => const <String>['claude', 'codex'],
    };
    return LifecycleCandidate(
      name: declaredName,
      nativeForm: nativeForm,
      validatedProfiles: profiles,
      knownConsumers: knownConsumers,
      nativeLinkKind: nativeLinkKind,
      linkTarget: linkTarget,
      targetResolved: nativeForm == 'skill-link' ? inspectedPath : null,
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
    final destinations = switch (nativeDestination) {
      'claude' => const [
        SkillDestination.claude,
        SkillDestination.shared,
        SkillDestination.antigravity,
      ],
      'codex' => const [
        SkillDestination.codex,
        SkillDestination.shared,
        SkillDestination.antigravity,
      ],
      'antigravity' => const [
        SkillDestination.antigravity,
        SkillDestination.shared,
      ],
      'shared' || 'canonical' => const [
        SkillDestination.claude,
        SkillDestination.codex,
        SkillDestination.shared,
        SkillDestination.antigravity,
      ],
      _ => throw MambaException('Unsupported Skill destination.', exitCode: 4),
    };
    state.checkPendingConversions(
      context,
      uniqueness: (
        kind: kind,
        name: name,
        nativeProfile: null,
        roots: [
          for (final destination in destinations)
            ..._visibleRoots(context, destination),
        ],
      ),
    );
    var entries = 0;
    final seen = <String>{};
    for (final destination in destinations) {
      for (final root in _visibleRoots(context, destination)) {
        final key = '${destination.name}\n${state.io.fs.path.normalize(root)}';
        if (!seen.add(key)) continue;
        final type = skillEntityType(root, followLinks: false, fs: state.io.fs);
        if (type == FileSystemEntityType.notFound) continue;
        if (type != FileSystemEntityType.directory) {
          throw MambaException(
            'Required Skill uniqueness root is not a directory: $root',
            exitCode: 3,
          );
        }
        void visit(String directory, int depth) {
          if (depth > maxSkillDepth) {
            throw MambaException(
              'Skill uniqueness inventory exceeds the depth-32 budget.',
              exitCode: 3,
            );
          }
          final List<FileSystemEntity> children;
          try {
            children = listSkillDirectory(directory, fs: state.io.fs);
          } on MambaException catch (error) {
            throw MambaException(error.message, exitCode: 3);
          }
          for (final child in children) {
            entries++;
            if (entries > maxSkillEntries) {
              throw MambaException(
                'Skill uniqueness inventory exceeds the 10,000-entry budget.',
                exitCode: 3,
              );
            }
            if ((excludePath != null &&
                    state.io.fs.path.equals(child.path, excludePath)) ||
                allowedPaths.any(
                  (path) => state.io.fs.path.equals(child.path, path),
                )) {
              continue;
            }
            final childType = skillEntityType(
              child.path,
              followLinks: false,
              fs: state.io.fs,
            );
            if (childType != FileSystemEntityType.directory &&
                childType != FileSystemEntityType.link) {
              continue;
            }
            if (state.io.fs.path.basename(child.path) == name) {
              throw MambaException(
                'Skill name "$name" conflicts with ${child.path} for the selected consumer profile.',
                exitCode: 4,
              );
            }
            if (childType == FileSystemEntityType.directory) {
              visit(child.path, depth + 1);
            }
          }
        }

        visit(root, 0);
      }
    }
  }

  List<String> _profiles(
    LifecycleContext context,
    SkillDestination? destination,
  ) {
    // The adapter is stateless; inspection validates the baseline for every
    // requested profile. Destination-specific mandatory profiles are attached
    // by install/adopt through the same deterministic destination inference.
    if (destination == SkillDestination.claude) return const ['claude'];
    if (destination == SkillDestination.codex) return const ['codex'];
    if (destination == SkillDestination.antigravity) {
      return const ['antigravity'];
    }
    return const <String>[];
  }

  SkillDestination? _destinationForPath(LifecycleContext context, String path) {
    for (final destination in SkillDestination.values) {
      final root = _root(context, destination);
      if (state.io.fs.path.equals(path, root) ||
          state.io.fs.path.isWithin(root, path)) {
        return destination;
      }
    }
    return null;
  }

  SkillHarnessSpec _skillSpec(HarnessId id) =>
      HarnessCatalog.instance.requireFacet(id, HarnessFacet.skill)
          as SkillHarnessSpec;

  String _root(LifecycleContext context, SkillDestination destination) {
    final id = switch (destination) {
      SkillDestination.claude => HarnessId.claude,
      SkillDestination.codex => HarnessId.codex,
      SkillDestination.shared ||
      SkillDestination.antigravity => HarnessId.antigravity,
    };
    final userScope = context.scope == LifecycleScope.user;
    final root = destination == SkillDestination.shared
        ? context.sharedSkillsRoot()
        : _skillSpec(id).root(context, userScope: userScope);
    return state.io.fs.path.normalize(root);
  }

  List<String> _visibleRoots(
    LifecycleContext context,
    SkillDestination destination,
  ) {
    String at(String boundary) => switch (destination) {
      SkillDestination.claude => state.io.fs.path.join(
        boundary,
        '.claude',
        'skills',
      ),
      SkillDestination.codex => state.io.fs.path.join(
        boundary,
        '.codex',
        'skills',
      ),
      SkillDestination.shared || SkillDestination.antigravity =>
        state.io.fs.path.join(boundary, '.agents', 'skills'),
    };
    final roots = <String>[];
    var current = context.cwd;
    while (true) {
      roots.add(state.io.fs.path.normalize(at(current)));
      if (state.io.fs.path.equals(current, context.projectRoot)) break;
      final parent = state.io.fs.path.dirname(current);
      if (state.io.fs.path.equals(parent, current)) {
        throw MambaException('Project ancestry is incomplete.', exitCode: 3);
      }
      current = parent;
      if (roots.length > 64) {
        throw MambaException('Skill ancestry exceeds 64 roots.', exitCode: 3);
      }
    }
    final home = context.requireHome();
    roots.add(switch (destination) {
      SkillDestination.claude => state.io.fs.path.normalize(
        state.io.fs.path.join(context.claudeConfigRoot(), 'skills'),
      ),
      SkillDestination.codex => state.io.fs.path.normalize(
        state.io.fs.path.join(context.codexRoot(), 'skills'),
      ),
      SkillDestination.shared => state.io.fs.path.normalize(
        state.io.fs.path.join(home, '.agents', 'skills'),
      ),
      SkillDestination.antigravity => state.io.fs.path.normalize(
        state.io.fs.path.join(context.geminiConfigRoot(), 'skills'),
      ),
    });
    return roots;
  }

  List<String> _selectedProfiles(
    SkillDestination destination,
    List<SkillHarness> requested,
  ) {
    if (requested.toSet().length != requested.length) {
      throw MambaException(
        'A Skill harness profile may be selected only once.',
      );
    }
    return <String>{
      if (destination == SkillDestination.claude) 'claude',
      if (destination == SkillDestination.codex) 'codex',
      for (final harness in requested) harness.name,
    }.toList()..sort();
  }

  void _requireMutationScope(LifecycleContext context) {
    if (context.scope == LifecycleScope.all) {
      throw MambaException(
        'A Skill mutation requires --scope project or --scope user.',
      );
    }
  }
}

Map<String, Object?> _linkObservation(String path, String root) {
  try {
    final service = const NativeLinkService();
    final kind = service.inspectKind(path);
    final target = service.readTarget(path);
    return <String, Object?>{
      'nativeLinkKind': kind,
      'target': target,
      'targetResolved': p.normalize(
        p.isAbsolute(target) ? target : p.join(p.dirname(path), target),
      ),
      'eligibility': p.equals(p.dirname(path), root)
          ? 'direct-child-link'
          : 'nested-ineligible-link',
    };
  } on MambaException {
    return <String, Object?>{
      'nativeLinkKind': 'unsupported-reparse',
      'target': null,
      'targetResolved': null,
      'eligibility': 'unsupported-reparse',
    };
  }
}

final class _SkillCandidate {
  const _SkillCandidate({
    required this.path,
    required this.type,
    required this.hasSkillFile,
    required this.eligibility,
  });

  final String path;
  final FileSystemEntityType type;
  final bool hasSkillFile;
  final String eligibility;
}

final class _ProfiledSkillResource implements LifecycleResource {
  const _ProfiledSkillResource(
    this.delegate,
    this.profiles, [
    this._kind = ArtifactKind.skillCopy,
    this.allowedExtraFolders = const <String>{},
  ]);

  final SkillLifecycleService delegate;
  final List<String> profiles;
  final ArtifactKind _kind;
  final Set<String> allowedExtraFolders;

  @override
  ArtifactKind get kind => _kind;

  @override
  void validateAuthority(InstallationRecord record, LifecycleContext context) =>
      delegate.validateAuthority(record, context);

  @override
  Future<LifecycleCandidate> inspect(
    String path,
    LifecycleContext context, {
    String? expectedName,
    bool restoringBaseline = false,
  }) async {
    final candidate = await delegate.inspect(
      path,
      context,
      expectedName: expectedName,
      restoringBaseline: restoringBaseline,
      allowedExtraFolders: allowedExtraFolders,
    );
    delegate.validateProfiles(delegate.resolveContentTarget(path), profiles);
    final knownConsumers = <String>{
      ...candidate.knownConsumers,
      ...profiles,
    }.toList()..sort();
    return LifecycleCandidate(
      name: candidate.name,
      nativeForm: _kind.wireName,
      validatedProfiles: profiles,
      knownConsumers: knownConsumers,
      nativeLinkKind:
          candidate.nativeLinkKind ??
          (_kind == ArtifactKind.skillLink
              ? Platform.isWindows
                    ? 'windows-directory-symlink'
                    : 'posix-directory-symlink'
              : null),
      linkTarget:
          candidate.linkTarget ??
          (_kind == ArtifactKind.skillLink
              ? delegate.resolveContentTarget(path)
              : null),
      targetResolved:
          candidate.targetResolved ??
          (_kind == ArtifactKind.skillLink
              ? delegate.resolveContentTarget(path)
              : null),
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
  }) => delegate.checkUnique(
    context,
    name,
    nativeDestination: nativeDestination,
    excludeInstallationId: excludeInstallationId,
    excludePath: excludePath,
    allowedPaths: allowedPaths,
  );
}
