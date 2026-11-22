import 'package:path/path.dart' as p;

import '../services/acquisition_service.dart';
import '../services/lifecycle_state_service.dart';
import 'installation_plan.dart';

/// A consuming harness or the legacy shared storage destination.
enum InstallationRouteTarget { claude, codex, pi, antigravity, shared }

/// Recorded source and publication choices, not permission to replay them.
final class InstallationRoute {
  InstallationRoute({
    required this.source,
    required this.sourceKind,
    required this.sourceRelativePath,
    required this.scope,
    required List<InstallationRouteTarget> targets,
    required this.method,
    required List<ManagedDerivedArtifact> derivedArtifacts,
    this.entryId,
    this.packKey,
    List<String> promptTargets = const <String>[],
  }) : targets = List.unmodifiable(targets),
       promptTargets = List.unmodifiable(
         promptTargets.toSet().toList()..sort(),
       ),
       derivedArtifacts = List.unmodifiable(derivedArtifacts) {
    _relative(sourceRelativePath, allowRoot: true);
    if (scope == LifecycleScope.all ||
        targets.isEmpty ||
        targets.toSet().length != targets.length) {
      throw const FormatException(
        'Invalid installation route scope or targets.',
      );
    }
    if ((entryId != null && entryId!.isEmpty) ||
        (packKey != null && packKey!.isEmpty)) {
      throw const FormatException('Invalid route selector.');
    }
    if (method == InstallationMethod.sourceLink &&
        derivedArtifacts.isNotEmpty) {
      throw const FormatException(
        'A source link cannot own migrated source content.',
      );
    }
  }

  factory InstallationRoute.fromJson(Object? value) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['targets'] is! List ||
        value['derivedArtifacts'] is! List) {
      throw const FormatException('Invalid installation route.');
    }
    T named<T>(Iterable<T> values, String Function(T) name, Object? raw) =>
        values.firstWhere(
          (item) => name(item) == raw,
          orElse: () =>
              throw const FormatException('Invalid installation route value.'),
        );
    final relative = value['sourceRelativePath'];
    final entry = value['entryId'];
    final pack = value['packKey'];
    if (relative is! String ||
        (entry != null && entry is! String) ||
        (pack != null && pack is! String)) {
      throw const FormatException('Invalid route source.');
    }
    return InstallationRoute(
      source: AcquisitionProvenance.fromJson(value['source']),
      sourceKind: named(
        AcquisitionSourceKind.values,
        (v) => v.name,
        value['sourceKind'],
      ),
      sourceRelativePath: relative,
      entryId: entry as String?,
      packKey: pack as String?,
      scope: named(LifecycleScope.values, (v) => v.name, value['scope']),
      promptTargets: value['promptTargets'] == null
          ? const <String>[]
          : value['promptTargets'] is List
          ? [
              for (final item in value['promptTargets'] as List)
                item is String
                    ? item
                    : (throw const FormatException(
                        'Invalid installation route.',
                      )),
            ]
          : (throw const FormatException('Invalid installation route.')),
      targets: [
        for (final item in value['targets'] as List)
          named(InstallationRouteTarget.values, (v) => v.name, item),
      ],
      method: named(
        InstallationMethod.values,
        (v) => v.wireName,
        value['method'],
      ),
      derivedArtifacts: [
        for (final item in value['derivedArtifacts'] as List)
          ManagedDerivedArtifact.fromJson(item),
      ],
    );
  }

  final AcquisitionProvenance source;
  final AcquisitionSourceKind sourceKind;
  final String sourceRelativePath;
  final String? entryId;
  final String? packKey;
  final LifecycleScope scope;
  final List<InstallationRouteTarget> targets;
  final InstallationMethod method;
  final List<ManagedDerivedArtifact> derivedArtifacts;

  /// The prompt-capable harnesses publishing a derived Prompt template
  /// alongside the Skill; empty means none.
  final List<String> promptTargets;

  InstallationRoute withTargets(List<InstallationRouteTarget> targets) =>
      InstallationRoute(
        source: source,
        sourceKind: sourceKind,
        sourceRelativePath: sourceRelativePath,
        entryId: entryId,
        packKey: packKey,
        scope: scope,
        targets: targets,
        method: method,
        derivedArtifacts: derivedArtifacts,
        promptTargets: promptTargets,
      );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'source': {
      ...source.toJson(),
      'durableLocalDirectory': source.durableLocalDirectory,
    },
    'sourceKind': sourceKind.name,
    'sourceRelativePath': sourceRelativePath,
    if (entryId != null) 'entryId': entryId,
    if (packKey != null) 'packKey': packKey,
    'scope': scope.name,
    'targets': [for (final target in targets) target.name],
    'method': method.wireName,
    'derivedArtifacts': [
      for (final artifact in derivedArtifacts) artifact.toJson(),
    ],
    if (promptTargets.isNotEmpty) 'promptTargets': promptTargets,
  };
}

enum DerivedArtifactOperation { moveRootFile, rewriteMarker }

/// A managed output created from source content by a named transformation.
final class ManagedDerivedArtifact {
  ManagedDerivedArtifact({
    required this.operation,
    required this.sourcePath,
    required this.outputPath,
  }) {
    _relative(sourcePath);
    _relative(outputPath);
    switch (operation) {
      case DerivedArtifactOperation.moveRootFile:
        if (sourcePath.contains('/') ||
            !const [
              'references',
              'assets',
            ].contains(p.posix.dirname(outputPath)) ||
            p.posix.basename(outputPath) != sourcePath) {
          throw const FormatException('Invalid root file migration evidence.');
        }
      case DerivedArtifactOperation.rewriteMarker:
        if (sourcePath != 'SKILL.md' || outputPath != 'SKILL.md') {
          throw const FormatException('Invalid marker rewrite evidence.');
        }
    }
  }

  factory ManagedDerivedArtifact.fromJson(Object? value) {
    if (value is! Map ||
        value['sourcePath'] is! String ||
        value['outputPath'] is! String) {
      throw const FormatException('Invalid derived artifact.');
    }
    final operation = DerivedArtifactOperation.values.where(
      (item) => item.name == value['operation'],
    );
    if (operation.length != 1) {
      throw const FormatException('Invalid derived artifact operation.');
    }
    return ManagedDerivedArtifact(
      operation: operation.single,
      sourcePath: value['sourcePath'] as String,
      outputPath: value['outputPath'] as String,
    );
  }
  final DerivedArtifactOperation operation;
  final String sourcePath;
  final String outputPath;
  Map<String, Object?> toJson() => {
    'operation': operation.name,
    'sourcePath': sourcePath,
    'outputPath': outputPath,
  };
}

void _relative(String value, {bool allowRoot = false}) {
  if (value.isEmpty ||
      value.contains('\\') ||
      value.contains(':') ||
      value.runes.any((rune) => rune < 32 || rune == 127) ||
      p.posix.isAbsolute(value) ||
      p.posix.normalize(value) != value ||
      value == '..' ||
      value.startsWith('../') ||
      (!allowRoot && value == '.')) {
    throw const FormatException('Invalid source-relative route path.');
  }
}
