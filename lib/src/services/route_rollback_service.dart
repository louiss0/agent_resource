import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../conversion/route_journal_evidence.dart';
import '../conversion/route_recovery_paths.dart';
import '../conversion/route_recovery_plan.dart';
import '../skill_files.dart';
import 'lifecycle_state_service.dart';
import 'native_link_service.dart';
import 'route_recovery_observation_service.dart';

/// Internal local recovery only; this does not enable route migration.
interface class RouteRollbackService {
  RouteRollbackService({required this.state});
  final LifecycleStateService state;

  Future<void> rollback(
    LifecycleContext context,
    String transactionId,
  ) => state.runCoordinated(
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
      void checkPath(String path) {
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

      RouteJournalEvidence read() {
        checkPath(path);
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
        final encoded = jsonEncode(doc);
        RouteJournalEvidence.decode(encoded, fs.path);
        checkPath(path);
        final temp = '$path.${Random.secure().nextInt(1 << 32)}.tmp';
        if (state.io.type(temp, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const FileSystemException('Temporary journal already exists');
        }
        state.io.write(temp, utf8.encode(encoded));
        state.io.rename(temp, path);
      }

      final observer = RouteRecoveryObservationService(state: state);
      while (true) {
        final journal = read();
        final doc = journal.toJson();
        final observation = observer.inspect(journal, context);
        final plan = observation.plan;
        if (plan.decision == RecoveryDecision.rolledBack) return;
        if (plan.decision != RecoveryDecision.rollback) {
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
        final steps = <String>[
          for (var i = 0; i < actions.length; i++) ...[
            if (actions[i]['oldKind'] != null) '$i-remove',
            if (actions[i]['newKind'] != null) '$i-publish',
          ],
        ];
        final completed = doc['completedActions'] as List;
        final applied = plan.appliedSteps!;
        if (!doc.containsKey('rolledBackActions')) {
          if (applied > completed.length) {
            completed.add(steps[completed.length]);
          }
          doc['rolledBackActions'] = <String>[];
          doc['phase'] = 'rollingBack';
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
          doc['phase'] = 'rolledBack';
          persist(doc);
          continue;
        }
        final parts = (completed[remaining - 1] as String).split('-');
        final action = actions[int.parse(parts[0])];
        final live = action['path'] as String;
        final isPublish = parts[1] == 'publish';
        final sideRecords =
            doc[isPublish ? 'newRecords' : 'oldRecords'] as List;
        InstallationRecord? owner;
        String? root;
        for (final item in sideRecords) {
          final record = InstallationRecord.fromJson(item);
          if (fs.path.equals(record.location, live)) {
            owner = record;
            root = record.nativeRoot;
          }
          for (final exposure in record.exposures) {
            if (fs.path.equals(exposure.path, live)) {
              owner = record;
              root = fs.path.dirname(exposure.path);
            }
          }
        }
        if (owner == null || root == null) {
          throw const FormatException('Missing route authority');
        }
        final locations = RouteRecoveryPaths(fs.path)
            .forLocation(root, live, transactionId);
        final source = isPublish ? live : locations.quarantine;
        final destination = isPublish ? locations.staged : live;
        checkPath(source);
        checkPath(destination);
        state.io.rename(source, destination);
      }
    },
  );
}
