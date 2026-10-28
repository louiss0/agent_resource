import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../skill_files.dart';
import '../skill_validation.dart';
import 'native_link_service.dart';
import 'lifecycle_state_service.dart';

enum SkillHarness { claude, codex }

enum SkillDestination { claude, codex, shared }

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
  SkillLifecycleService({LifecycleStateService? state})
    : state = state ?? LifecycleStateService();

  final LifecycleStateService state;

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
      );
      final records = <InstallationRecord>[];
      String? ownershipFailure;
      try {
        records.addAll(state.records(scopedContext));
      } on Exception catch (error) {
        ownershipFailure = error.toString();
      }
      for (final selected in SkillDestination.values) {
        for (final root in _inventoryRoots(scopedContext, selected)) {
          final type = skillEntityType(root, followLinks: false);
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
              'installationId': record?.installationId,
              'management': ownershipFailure != null
                  ? 'ownershipUnverified'
                  : record == null
                  ? 'unmanaged'
                  : 'managed',
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
              p.equals(occurrence['path']! as String, record.location),
        );
        if (alreadyVisible) continue;
        final missing =
            skillEntityType(record.location, followLinks: false) ==
            FileSystemEntityType.notFound;
        if (record.lifecycle == 'live' && !missing) continue;
        occurrences.add(<String, Object?>{
          'occurrenceId': _occurrenceId(
            scope,
            SkillDestination.values.byName(record.nativeDestination),
            record.location,
          ),
          'path': record.location,
          'root': record.nativeRoot,
          'destination': record.nativeDestination,
          'installationScope': scope.name,
          'hasSkillFile': false,
          'eligibility': 'tracked-missing',
          'installationId': record.installationId,
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
          'path': p.join(scopedContext.stateRoot(), 'installations.json'),
          'root': scopedContext.stateRoot(),
          'destination': null,
          'installationScope': scope.name,
          'hasSkillFile': false,
          'eligibility': 'management-document',
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
                  occurrence['destination'] == destination.name,
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
      final children = listSkillDirectory(directory)
        ..sort((left, right) => left.path.compareTo(right.path));
      for (final child in children) {
        chargeEntry();
        final type = skillEntityType(child.path, followLinks: false);
        final path = p.normalize(child.absolute.path);
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
            skillEntityType(p.join(path, 'SKILL.md'), followLinks: false) ==
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
          p.equals(record.location, path),
    );
    if (matches.length > 1) {
      throw MambaException(
        'Overlapping Skill management authority.',
        exitCode: 4,
      );
    }
    return matches.isEmpty ? null : matches.single;
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
      return [_root(context, destination)];
    }
    final roots = <String>[];
    var current = context.cwd;
    while (true) {
      roots.add(
        p.normalize(switch (destination) {
          SkillDestination.claude => p.join(current, '.claude', 'skills'),
          SkillDestination.codex => p.join(current, '.codex', 'skills'),
          SkillDestination.shared => p.join(current, '.agents', 'skills'),
        }),
      );
      if (p.equals(current, context.projectRoot)) break;
      current = p.dirname(current);
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
  }) => _ProfiledSkillResource(this, targets, kind);

  Future<LifecycleResult> install(SkillInstallInput input) async {
    final context = LifecycleContext.resolve(input.options);
    _requireMutationScope(context);
    final source = context.resolvePath(input.source);
    final declaredName = readDeclaredSkillName(source);
    final root = _root(context, input.destination);
    final location = p.normalize(p.join(root, declaredName));
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
    );
  }

  Future<LifecycleResult> adopt(SkillInstallInput input) async {
    final context = LifecycleContext.resolve(input.options);
    _requireMutationScope(context);
    final location = context.resolvePath(input.source);
    final root = _root(context, input.destination);
    if (!p.equals(p.dirname(location), root)) {
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

  Future<LifecycleResult> replace(
    LifecycleReplaceInput input, {
    SkillMode? mode,
  }) async {
    final context = LifecycleContext.resolve(input.options);
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
    return state.replace(
      resource: _ProfiledSkillResource(
        this,
        record.validatedProfiles,
        replacementKind,
      ),
      context: context,
      installationId: input.installationId,
      source: context.resolvePath(input.source),
    );
  }

  Future<LifecycleResult> remove(LifecycleIdInput input) async {
    final context = LifecycleContext.resolve(input.options);
    _requireMutationScope(context);
    final record = state.recordById(context, input.id);
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
    final context = LifecycleContext.resolve(input.options);
    _requireMutationScope(context);
    final backupKind = state.artifactKindForBackup(
      context,
      input.id,
      skillKinds,
    );
    final record = state.installationForBackup(context, input.id, backupKind);
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
  }) {
    final context = LifecycleContext.resolve(options);
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
        LifecycleContext.resolve(options),
        kind,
        otherKind: ArtifactKind.skillLink,
      );

  Future<LifecycleResult> cleanup(LifecycleIdInput input) {
    final context = LifecycleContext.resolve(input.options);
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
          final name = readDeclaredSkillName(path).toLowerCase();
          if (name == 'synced' || name == 'anthropic-skills') {
            throw MambaException(
              'The Claude Skill profile reserves the name "$name".',
              exitCode: 2,
            );
          }
        case 'codex':
          _validateCodexSidecar(path);
        default:
          throw MambaException(
            'Unsupported Skill compatibility profile: $profile',
            exitCode: 2,
          );
      }
    }
  }

  void _validateCodexSidecar(String path) {
    final sidecar = p.join(path, 'agents', 'openai.yaml');
    final type = skillEntityType(sidecar, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'Codex agents/openai.yaml must be a regular non-link file.',
        exitCode: 2,
      );
    }
    final bytes = readBoundedSkillMarker(sidecar, maxBytes: 1048576);
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
      return p.normalize(
        p.isAbsolute(target) ? target : p.join(p.dirname(path), target),
      );
    }
    if (type == FileSystemEntityType.file &&
        p.basename(path) == 'artifact-link.json') {
      final entry = state.readLinkBaseline(path).entries.single;
      return p.normalize(
        p.isAbsolute(entry.target!)
            ? entry.target!
            : p.join(entry.originalParent!, entry.target!),
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
        !p.equals(record.nativeRoot, root) ||
        !p.equals(p.dirname(record.location), root) ||
        p.basename(record.location) != record.name) {
      throw MambaException(
        'Stored Skill location does not match current native authority.',
        exitCode: 4,
      );
    }
  }

  @override
  Future<LifecycleCandidate> inspect(
    String path,
    LifecycleContext context, {
    String? expectedName,
  }) async {
    final type = state.io.type(path, followLinks: false);
    var nativeForm = 'skill-copy';
    if (type == FileSystemEntityType.link ||
        (type == FileSystemEntityType.file &&
            p.basename(path) == 'artifact-link.json')) {
      nativeForm = 'skill-link';
    }
    final inspectedPath = resolveContentTarget(path);
    state.validateSkillTree(inspectedPath);
    final declaredName = readDeclaredSkillName(inspectedPath);
    if (expectedName != null && declaredName != expectedName) {
      throw MambaException(
        'The declared Skill name changed during the operation.',
        exitCode: 4,
      );
    }
    final report = validateSkill(
      inspectedPath,
      expectedDirectoryName: declaredName,
    );
    if (!report.valid) {
      throw MambaException(
        'Skill validation failed: ${report.diagnostics.where((diagnostic) => diagnostic.severity == DiagnosticSeverity.error).map((diagnostic) => diagnostic.code).join(', ')}',
        exitCode: 2,
      );
    }
    final profiles = _profiles(context, _destinationForPath(context, path));
    return LifecycleCandidate(
      name: declaredName,
      nativeForm: nativeForm,
      validatedProfiles: profiles,
      knownConsumers: const ['claude', 'codex'],
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
      'claude' => const [SkillDestination.claude, SkillDestination.shared],
      'codex' => const [SkillDestination.codex, SkillDestination.shared],
      'shared' || 'canonical' => const [
        SkillDestination.claude,
        SkillDestination.codex,
        SkillDestination.shared,
      ],
      _ => throw MambaException('Unsupported Skill destination.', exitCode: 4),
    };
    var entries = 0;
    final seen = <String>{};
    for (final destination in destinations) {
      for (final root in _visibleRoots(context, destination)) {
        final key = '${destination.name}\n${p.normalize(root)}';
        if (!seen.add(key)) continue;
        final type = skillEntityType(root, followLinks: false);
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
            children = listSkillDirectory(directory);
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
            if ((excludePath != null && p.equals(child.path, excludePath)) ||
                allowedPaths.any((path) => p.equals(child.path, path))) {
              continue;
            }
            final childType = skillEntityType(child.path, followLinks: false);
            if (childType != FileSystemEntityType.directory &&
                childType != FileSystemEntityType.link) {
              continue;
            }
            if (p.basename(child.path) == name) {
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
    return const <String>[];
  }

  SkillDestination? _destinationForPath(LifecycleContext context, String path) {
    for (final destination in SkillDestination.values) {
      final root = _root(context, destination);
      if (p.equals(path, root) || p.isWithin(root, path)) return destination;
    }
    return null;
  }

  String _root(LifecycleContext context, SkillDestination destination) =>
      switch (destination) {
        SkillDestination.claude => p.normalize(context.claudeSkillsRoot()),
        SkillDestination.codex => p.normalize(context.codexSkillsRoot()),
        SkillDestination.shared => p.normalize(context.sharedSkillsRoot()),
      };

  List<String> _visibleRoots(
    LifecycleContext context,
    SkillDestination destination,
  ) {
    String at(String boundary) => switch (destination) {
      SkillDestination.claude => p.join(boundary, '.claude', 'skills'),
      SkillDestination.codex => p.join(boundary, '.codex', 'skills'),
      SkillDestination.shared => p.join(boundary, '.agents', 'skills'),
    };
    final roots = <String>[];
    var current = context.cwd;
    while (true) {
      roots.add(p.normalize(at(current)));
      if (p.equals(current, context.projectRoot)) break;
      final parent = p.dirname(current);
      if (p.equals(parent, current)) {
        throw MambaException('Project ancestry is incomplete.', exitCode: 3);
      }
      current = parent;
      if (roots.length > 64) {
        throw MambaException('Skill ancestry exceeds 64 roots.', exitCode: 3);
      }
    }
    final home = context.requireHome();
    roots.add(switch (destination) {
      SkillDestination.claude => p.normalize(
        p.join(context.claudeConfigRoot(), 'skills'),
      ),
      SkillDestination.codex => p.normalize(
        p.join(context.codexRoot(), 'skills'),
      ),
      SkillDestination.shared => p.normalize(p.join(home, '.agents', 'skills')),
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
  ]);

  final SkillLifecycleService delegate;
  final List<String> profiles;
  final ArtifactKind _kind;

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
  }) async {
    final candidate = await delegate.inspect(
      path,
      context,
      expectedName: expectedName,
    );
    if (p.basename(path) != 'artifact-link.json') {
      delegate.validateProfiles(delegate.resolveContentTarget(path), profiles);
    }
    return LifecycleCandidate(
      name: candidate.name,
      nativeForm: _kind.wireName,
      validatedProfiles: profiles,
      knownConsumers: candidate.knownConsumers,
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
