import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../conversion/route_journal_evidence.dart';
import '../conversion/route_recovery_paths.dart';
import '../conversion/route_recovery_plan.dart';
import '../skill_files.dart';
import 'lifecycle_state_service.dart';
import 'native_link_service.dart';
import 'skill_lifecycle_service.dart';

typedef RouteRecoveryObservation = ({
  LedgerObservation ledger,
  List<RouteArtifactObservations> artifacts,
  RouteRecoveryPlan plan,
});

typedef _Side = ({
  String path,
  String root,
  ArtifactKind kind,
  ArtifactBaseline baseline,
});

/// Read-only evidence for the route planner. No observation grants mutation authority.
interface class RouteRecoveryObservationService {
  RouteRecoveryObservationService({required this.state});

  final LifecycleStateService state;

  RouteRecoveryObservation inspect(
    RouteJournalEvidence journal,
    LifecycleContext context,
  ) {
    final doc = journal.toJson();
    final actions = doc['actions'] as List;
    var ledger = LedgerObservation.unknown;
    var artifacts = <RouteArtifactObservations>[
      for (final _ in actions)
        (
          live: ArtifactObservation.unknown,
          staged: ArtifactObservation.unknown,
          quarantine: ArtifactObservation.unknown,
        ),
    ];
    try {
      if (context.scope.name != doc['scope']) {
        throw const FormatException('Scope mismatch');
      }
      final old = [
        for (final item in doc['oldRecords'] as List)
          InstallationRecord.fromJson(item),
      ];
      final next = [
        for (final item in doc['newRecords'] as List)
          InstallationRecord.fromJson(item),
      ];
      final resource = SkillLifecycleService(state: state);
      for (final record in [...old, ...next]) {
        resource.validateAuthority(record, context);
      }
      final sides = <String, List<_Side?>>{};
      String key(String path) => state.io.fs.path.style == p.Style.windows
          ? state.io.fs.path.normalize(path).toLowerCase()
          : state.io.fs.path.normalize(path);
      void collect(List<InstallationRecord> records, int index) {
        for (final record in records) {
          void add(String path, _Side side) {
            if (side.kind == ArtifactKind.skillLink) {
              final entries = side.baseline.entries;
              if (entries.length != 1 ||
                  entries.single.type != 'link' ||
                  entries.single.originalParent == null ||
                  !state.io.fs.path.equals(
                    entries.single.originalParent!,
                    state.io.fs.path.dirname(path),
                  )) {
                throw const FormatException('Invalid link baseline authority');
              }
            }
            final pair = sides.putIfAbsent(key(path), () => [null, null]);
            if (pair[index] != null) {
              throw const FormatException('Duplicate route path');
            }
            pair[index] = side;
          }

          add(record.location, (
            path: record.location,
            root: record.nativeRoot,
            kind: record.kind,
            baseline: record.baseline,
          ));
          for (final exposure in record.exposures) {
            add(exposure.path, (
              path: exposure.path,
              root: state.io.fs.path.dirname(exposure.path),
              kind: ArtifactKind.skillLink,
              baseline: exposure.baseline,
            ));
          }
        }
      }

      collect(old, 0);
      collect(next, 1);
      final paths = RouteRecoveryPaths(state.io.fs.path);
      final transaction = doc['transactionId'] as String;
      artifacts = [
        for (final action in actions)
          () {
            final path = action['path'] as String;
            final pair = sides[key(path)];
            if (pair == null) throw const FormatException('Unknown route path');
            final previous = pair[0];
            final proposed = pair[1];
            return (
              live: _observe((previous ?? proposed)!.path, previous, proposed),
              staged: proposed == null
                  ? ArtifactObservation.absent
                  : _observe(
                      paths
                          .forLocation(
                            proposed.root,
                            proposed.path,
                            transaction,
                          )
                          .staged,
                      previous,
                      proposed,
                    ),
              quarantine: previous == null
                  ? ArtifactObservation.absent
                  : _observe(
                      paths
                          .forLocation(
                            previous.root,
                            previous.path,
                            transaction,
                          )
                          .quarantine,
                      previous,
                      proposed,
                    ),
            );
          }(),
      ];
      final ledgerPath = state.io.fs.path.join(
        context.stateRoot(),
        'installations.json',
      );
      _checkParents(ledgerPath);
      final ledgerType = skillEntityType(
        ledgerPath,
        followLinks: false,
        fs: state.io.fs,
      );
      if (ledgerType != FileSystemEntityType.file &&
              ledgerType != FileSystemEntityType.notFound ||
          const NativeLinkService().isWindowsReparsePoint(ledgerPath)) {
        throw const FormatException('Unsafe ledger');
      }
      final ids = {
        ...old.map((e) => e.installationId),
        ...next.map((e) => e.installationId),
      };
      final participatingPaths = sides.keys;
      bool overlaps(String a, String b) =>
          state.io.fs.path.equals(a, b) ||
          state.io.fs.path.isWithin(a, b) ||
          state.io.fs.path.isWithin(b, a);
      final current = state
          .records(context)
          .where(
            (record) =>
                ids.contains(record.installationId) ||
                record.lifecycle == 'live' &&
                    [
                      record.location,
                      ...record.exposures.map((e) => e.path),
                    ].any(
                      (path) => participatingPaths.any(
                        (other) => overlaps(path, other),
                      ),
                    ),
          )
          .toList();
      bool matches(List<InstallationRecord> expected) {
        final a = current.map((r) => jsonEncode(_sorted(r.toJson()))).toList()
          ..sort();
        final b = expected.map((r) => jsonEncode(_sorted(r.toJson()))).toList()
          ..sort();
        return jsonEncode(a) == jsonEncode(b);
      }

      final isOld = matches(old);
      final isNew = matches(next);
      ledger = isOld && isNew
          ? LedgerObservation.ambiguous
          : isOld
          ? LedgerObservation.old
          : isNew
          ? LedgerObservation.newRecords
          : LedgerObservation.unknown;
    } on Object {
      // Failed authority, metadata, or filesystem inspection cannot prove recovery.
    }
    return (
      ledger: ledger,
      artifacts: List.unmodifiable(artifacts),
      plan: RouteRecoveryPlan.inspect(
        journal,
        ledger: ledger,
        artifacts: artifacts,
      ),
    );
  }

  void _checkParents(String path) {
    final fs = state.io.fs;
    final parent = fs.path.dirname(path);
    final root = fs.path.rootPrefix(parent);
    for (final component in skillPathComponents(parent, base: root, fs: fs)) {
      final type = skillEntityType(component, followLinks: false, fs: fs);
      if ((type != FileSystemEntityType.directory &&
              type != FileSystemEntityType.notFound) ||
          const NativeLinkService().isWindowsReparsePoint(component)) {
        throw const FormatException('Unsafe route observation parent');
      }
    }
  }

  ArtifactObservation _observe(String path, _Side? old, _Side? next) {
    try {
      _checkParents(path);
      final type = skillEntityType(path, followLinks: false, fs: state.io.fs);
      if (type == FileSystemEntityType.notFound) {
        return ArtifactObservation.absent;
      }
      if (type != FileSystemEntityType.link &&
          const NativeLinkService().isWindowsReparsePoint(path)) {
        return ArtifactObservation.unknown;
      }
      bool matches(_Side? side) {
        if (side == null) return false;
        if (side.kind == ArtifactKind.skillLink
            ? type != FileSystemEntityType.link
            : type != FileSystemEntityType.directory) {
          return false;
        }
        final actual = state.baselineFor(path, side.kind);
        if (side.kind == ArtifactKind.skillLink) {
          final a = actual.entries.single;
          final b = side.baseline.entries.single;
          return a.type == 'link' &&
              b.type == 'link' &&
              a.target == b.target &&
              a.nativeKind == b.nativeKind;
        }
        return actual.digest == side.baseline.digest;
      }

      final a = matches(old);
      final b = matches(next);
      return a && b
          ? ArtifactObservation.ambiguous
          : a
          ? ArtifactObservation.old
          : b
          ? ArtifactObservation.newArtifact
          : ArtifactObservation.unknown;
    } on Object {
      return ArtifactObservation.unknown;
    }
  }
}

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return [for (final item in value) _sorted(item)];
  return value;
}
