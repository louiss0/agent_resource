import 'dart:convert';

import 'package:path/path.dart' as p;

import '../installation/installation_plan.dart';
import '../installation/installation_route.dart';
import '../services/lifecycle_state_service.dart';
import 'path_action_diff.dart';

/// Lexical preparation only: this neither verifies filesystem authority nor
/// reserves paths or authorizes a subsequent publication.
final class InstallationPathDiff(final p.Context paths) {
  List<PathAction> prepare({
    required List<InstallationRecord> oldRecords,
    required InstallationUnitPlan desired,
    required LifecycleScope scope,
    required Iterable<String> occupiedPaths,
  }) {
    if (oldRecords.isEmpty ||
        scope == LifecycleScope.all ||
        desired.resourceType != InstallationResourceType.skill) {
      throw ArgumentError('A scoped, nonempty skill group is required.');
    }
    final nextRoute = desired.installationRoute;
    final oldRoute = oldRecords.first.installationRoute;
    if (nextRoute == null ||
        oldRoute == null ||
        oldRoute.scope != scope ||
        nextRoute.scope != scope ||
        nextRoute.method != desired.method ||
        !_sameSource(oldRoute, nextRoute) ||
        !_same(desired.origin['source'], nextRoute.source.toJson())) {
      throw ArgumentError('Route, scope or source does not match.');
    }
    final oldPaths = <OldArtifactPath>[];
    final ids = <String>{};
    final consumers = <String>{};
    for (final record in oldRecords) {
      final route = record.installationRoute;
      if (route == null ||
          !_same(route.toJson(), oldRoute.toJson()) ||
          record.scope != scope ||
          record.lifecycle != 'live' ||
          record.name != desired.nativeName ||
          !ids.add(record.installationId) ||
          !_same(record.origin['source'], oldRoute.source.toJson()) ||
          record.kind != _recordKind(oldRoute.method)) {
        throw ArgumentError('Mixed or invalid old installation group.');
      }
      if (record.kind != ArtifactKind.skillCanonical &&
          (record.exposures.isNotEmpty || record.knownConsumers.length != 1)) {
        throw ArgumentError('Unexpected exposures.');
      }
      for (final consumer in record.knownConsumers) {
        if (!consumers.add(consumer)) {
          throw ArgumentError('Duplicate consumer.');
        }
      }
      oldPaths.add((
        path: record.location,
        kind: OldArtifactKind.values.byName(record.kind.name),
      ));
      final exposureTargets = <String>{};
      for (final exposure in record.exposures) {
        if (!record.knownConsumers.contains(exposure.target) ||
            !exposureTargets.add(exposure.target)) {
          throw ArgumentError('Unknown or duplicate exposure.');
        }
        oldPaths.add((path: exposure.path, kind: OldArtifactKind.skillLink));
      }
    }
    if (oldRoute.method == InstallationMethod.canonical &&
            oldRecords.length != 1 ||
        consumers.length != oldRoute.targets.length ||
        !consumers.containsAll(oldRoute.targets.map((target) => target.name))) {
      throw ArgumentError('Incomplete old installation group.');
    }
    final newPaths = <NewArtifactPath>[];
    final newConsumers = <String>{};
    final placements = <String>{};
    for (final entry in desired.entries) {
      if (entry.target != null) newConsumers.add(entry.target!);
      if (entry.kind != InstallationEntryKind.content &&
          (entry.target == null || !placements.add(entry.target!))) {
        throw ArgumentError('Missing or duplicate desired target.');
      }
      if (entry.kind == InstallationEntryKind.consumer) {
        if (desired.method != InstallationMethod.canonical) {
          throw ArgumentError('Unexpected consumer entry.');
        }
        continue;
      }
      final kind = entry.artifactKind;
      final expected = switch ((desired.method, entry.kind)) {
        (InstallationMethod.copy, InstallationEntryKind.copy) =>
          OwnedArtifactKind.skillCopy,
        (InstallationMethod.sourceLink, InstallationEntryKind.link) =>
          OwnedArtifactKind.skillLink,
        (InstallationMethod.canonical, InstallationEntryKind.content) =>
          OwnedArtifactKind.skillCanonical,
        (InstallationMethod.canonical, InstallationEntryKind.link) =>
          OwnedArtifactKind.skillLink,
        _ => null,
      };
      if (kind == null || kind != expected) {
        throw ArgumentError('Invalid desired artifact kind.');
      }
      newPaths.add((
        path: entry.path,
        kind: NewArtifactKind.values.byName(kind.name),
      ));
    }
    if (newPaths.isEmpty ||
        (desired.method != InstallationMethod.canonical &&
            placements.length != nextRoute.targets.length) ||
        (desired.method == InstallationMethod.canonical &&
            newPaths
                    .where(
                      (entry) => entry.kind == NewArtifactKind.skillCanonical,
                    )
                    .length !=
                1) ||
        newConsumers.length != nextRoute.targets.length ||
        !newConsumers.containsAll(
          nextRoute.targets.map((target) => target.name),
        )) {
      throw ArgumentError('Incomplete desired installation group.');
    }
    final actions = PathActionDiff(paths).compare(
      oldPaths: oldPaths,
      newPaths: newPaths,
      occupiedPaths: occupiedPaths,
    );
    for (var i = 0; i < actions.length; i++) {
      for (var j = i + 1; j < actions.length; j++) {
        if (paths.isWithin(actions[i].path, actions[j].path) ||
            paths.isWithin(actions[j].path, actions[i].path)) {
          throw ArgumentError('Overlapping installation paths.');
        }
      }
    }
    return actions;
  }

  bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
  bool _sameSource(InstallationRoute a, InstallationRoute b) =>
      _same(a.source.toJson(), b.source.toJson()) &&
      a.source.durableLocalDirectory == b.source.durableLocalDirectory &&
      a.sourceKind == b.sourceKind &&
      a.sourceRelativePath == b.sourceRelativePath &&
      a.entryId == b.entryId &&
      a.packKey == b.packKey;
  ArtifactKind _recordKind(InstallationMethod method) => switch (method) {
    InstallationMethod.copy => ArtifactKind.skillCopy,
    InstallationMethod.sourceLink => ArtifactKind.skillLink,
    InstallationMethod.canonical => ArtifactKind.skillCanonical,
  };
}
