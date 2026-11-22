import 'dart:convert';
import 'dart:io';

import '../conversion/route_journal_evidence.dart';
import '../conversion/route_recovery_paths.dart';
import '../conversion/route_recovery_plan.dart';
import '../skill_files.dart';
import 'lifecycle_state_service.dart';
import 'native_link_service.dart';
import 'route_recovery_observation_service.dart';

/// Recovers one journaled cross-route transaction.
///
/// The planner's decision is authoritative: `complete` is provable only when
/// the ledger holds exactly the new records, `rollback` only against the old
/// ledger, and anything ambiguous keeps its evidence and refuses. Terminal
/// journals are a no-op except verified cleanup: quarantined old artifacts
/// after completion and staged new artifacts after rollback are deleted only
/// when they still match their recorded baseline, and are otherwise retained.
interface class RouteRecoveryService {
  RouteRecoveryService({required this.state});
  final LifecycleStateService state;

  Future<Map<String, Object?>> recover(
    LifecycleContext context,
    String transactionId, {
    required RouteRecoveryAction action,
  }) => state.runCoordinated(
    context: context,
    location: context.stateRoot(),
    body: () async {
      if (!RegExp(r'^trx_[a-f0-9]{32}$').hasMatch(transactionId)) {
        throw const FormatException('Invalid route transaction identity');
      }
      final fs = state.io.fs;
      final path = fs.path.join(
        context.stateRoot(),
        'transactions',
        '$transactionId.json',
      );

      RouteJournalEvidence read() {
        _checkPath(path);
        if (state.io.type(path, followLinks: false) !=
                FileSystemEntityType.file ||
            const NativeLinkService().isWindowsReparsePoint(path)) {
          throw const FormatException('Unsafe route journal');
        }
        final bytes = state.io.read(path, 4 * 1024 * 1024);
        final journal = RouteJournalEvidence.decode(
          utf8.decode(bytes),
          fs.path,
        );
        final doc = journal.toJson();
        if (doc['transactionId'] != transactionId ||
            doc['scope'] != context.scope.name) {
          throw const FormatException('Route journal authority mismatch');
        }
        return journal;
      }

      void persist(Map<String, Object?> doc) {
        _checkPath(path);
        persistRouteJournal(
          io: state.io,
          paths: fs.path,
          journalPath: path,
          doc: doc,
        );
      }

      final observer = RouteRecoveryObservationService(state: state);
      while (true) {
        final journal = read();
        final doc = journal.toJson();
        final phase = RouteJournalPhase.parse(doc['phase']);
        if (phase == RouteJournalPhase.completed) {
          if (action != RouteRecoveryAction.complete) {
            throw StateError(
              'Route recovery action ${action.wireName} is not provable',
            );
          }
          return <String, Object?>{
            'outcome': 'completed',
            'retained': _cleanup(doc, transactionId, quarantined: true),
          };
        }
        if (phase == RouteJournalPhase.rolledBack) {
          if (action != RouteRecoveryAction.rollback) {
            throw StateError(
              'Route recovery action ${action.wireName} is not provable',
            );
          }
          return <String, Object?>{
            'outcome': 'rolledBack',
            'retained': _cleanup(doc, transactionId, quarantined: false),
          };
        }
        final observation = observer.inspect(journal, context);
        final plan = observation.plan;
        if (plan.decision == RecoveryDecision.complete) {
          if (action == RouteRecoveryAction.rollback &&
              phase != RouteJournalPhase.committed) {
            throw StateError(
              'Route evidence proves a committed ledger; rollback is refused.',
            );
          }
          doc['phase'] = RouteJournalPhase.committed.wireName;
          persist(doc);
          doc['phase'] = RouteJournalPhase.completed.wireName;
          persist(doc);
          return <String, Object?>{
            'outcome': 'completed',
            'retained': _cleanup(doc, transactionId, quarantined: true),
          };
        }
        if (plan.decision == RecoveryDecision.rolledBack) {
          return <String, Object?>{
            'outcome': 'rolledBack',
            'retained': _cleanup(doc, transactionId, quarantined: false),
          };
        }
        if (plan.decision != RecoveryDecision.rollback ||
            action != RouteRecoveryAction.rollback) {
          throw StateError('Route rollback evidence is unsafe or ambiguous');
        }
        final actions = doc['actions'] as List;
        final records = [
          for (final item in [
            ...doc['oldRecords'] as List,
            ...doc['newRecords'] as List,
          ])
            InstallationRecord.fromJson(item),
        ];
        state.checkPendingConversions(
          context,
          locations: [for (final action in actions) action['path'] as String],
          installationIds: {
            for (final record in records) record.installationId,
          },
          packKeys: {
            for (final record in records) ?record.installationRoute!.packKey,
          },
          excludedRouteEvidencePaths: {path},
        );
        final steps = RouteJournalStep.ofActions(actions);
        final completed = doc['completedActions'] as List;
        final applied = plan.appliedSteps!;
        if (!doc.containsKey('rolledBackActions')) {
          if (applied > completed.length) {
            completed.add(steps[completed.length].encode());
          }
          doc['rolledBackActions'] = <String>[];
          doc['phase'] = RouteJournalPhase.rollingBack.wireName;
          persist(doc);
          continue;
        }
        final reversed = doc['rolledBackActions'] as List;
        final remaining = completed.length - reversed.length;
        if (applied < remaining) {
          reversed.add(completed[remaining - 1]);
          persist(doc);
          continue;
        }
        if (remaining == 0) {
          doc['phase'] = RouteJournalPhase.rolledBack.wireName;
          persist(doc);
          continue;
        }
        final step = RouteJournalStep.parse(completed[remaining - 1] as String);
        final stepAction = actions[step.index];
        final live = stepAction['path'] as String;
        final isPublish = step.kind == RouteJournalStepKind.publish;
        final sideRecords =
            doc[isPublish ? 'newRecords' : 'oldRecords'] as List;
        final owner = routeOwningArtifact(
          sideRecords.map(InstallationRecord.fromJson),
          live,
          fs.path,
        );
        if (owner == null) {
          throw const FormatException('Missing route authority');
        }
        final locations = RouteRecoveryPaths(fs.path)
            .forLocation(owner.nativeRoot, live, transactionId);
        final source = isPublish ? live : locations.quarantine;
        final destination = isPublish ? locations.staged : live;
        _checkPath(source);
        _checkPath(destination);
        state.io.rename(source, destination);
      }
    },
  );

  /// Deletes the transaction's retained artifacts on the [quarantined] side
  /// (old artifacts after a completion, staged new artifacts after a
  /// rollback) only while they still match their recorded baseline. Anything
  /// changed, foreign, or unverifiable is retained and reported.
  List<String> _cleanup(
    Map<String, Object?> doc,
    String transactionId, {
    required bool quarantined,
  }) {
    final fs = state.io.fs;
    final kept = <String>[];
    final recordsKey = quarantined ? 'oldRecords' : 'newRecords';
    final kindKey = quarantined ? 'oldKind' : 'newKind';
    final roots = <String>{};
    for (final action in doc['actions'] as List) {
      if (action[kindKey] == null) continue;
      final live = action['path'] as String;
      final owner = routeOwningArtifact(
        (doc[recordsKey] as List).map(InstallationRecord.fromJson),
        live,
        fs.path,
      );
      if (owner == null) {
        throw const FormatException('Missing route authority');
      }
      roots.add(owner.nativeRoot);
      final baseline = owner.baseline;
      final kind = owner.kind;
      final artifact = quarantined
          ? RouteRecoveryPaths(fs.path)
                .forLocation(owner.nativeRoot, live, transactionId)
                .quarantine
          : RouteRecoveryPaths(fs.path)
                .forLocation(owner.nativeRoot, live, transactionId)
                .staged;
      try {
        _checkPath(artifact);
        if (state.io.type(artifact, followLinks: false) ==
            FileSystemEntityType.notFound) {
          continue;
        }
        final actual = state.baselineFor(artifact, kind);
        final matches = kind == ArtifactKind.skillLink
            ? () {
                final left = actual.entries.single;
                final right = baseline.entries.single;
                return left.type == 'link' &&
                    right.type == 'link' &&
                    left.target == right.target &&
                    left.nativeKind == right.nativeKind;
              }()
            : actual.digest == baseline.digest;
        if (!matches) {
          kept.add(artifact);
          continue;
        }
        state.io.delete(artifact);
      } on Object {
        kept.add(artifact);
      }
    }
    void removeEmpty(String parent, String name) {
      final directory = fs.path.join(parent, '.agent-resource', name);
      final transaction = fs.path.join(directory, transactionId);
      try {
        state.io.deleteEmptyDirectory(transaction);
      } on Object {
        // Retained artifacts keep the transaction directory.
      }
      try {
        state.io.deleteEmptyDirectory(directory);
      } on Object {
        // Other transactions still own this directory.
      }
    }

    for (final root in roots) {
      final parent = fs.path.dirname(root);
      removeEmpty(parent, quarantined ? 'quarantine' : 'staging');
    }
    return kept;
  }

  void _checkPath(String path) {
    final fs = state.io.fs;
    final parent = fs.path.dirname(path);
    for (final component in skillPathComponents(
      parent,
      base: fs.path.rootPrefix(parent),
      fs: fs,
    )) {
      final type = state.io.type(component, followLinks: false);
      if (type != FileSystemEntityType.directory ||
          const NativeLinkService().isWindowsReparsePoint(component)) {
        throw const FormatException('Unsafe recovery parent');
      }
    }
  }
}
