import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/conversion/route_recovery_paths.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/route_recovery_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../conversion/route_journal_evidence_test.dart' as fixture;

void main() {
  for (final scenario in ['normal', 'interrupted', 'foreign', 'ambiguous']) {
    test('rollback evidence: $scenario', () async {
      final root = Directory.systemTemp.createTempSync('route-rollback-');
      addTearDown(() => root.deleteSync(recursive: true));
      final nativeRoot = p.join(root.path.toLowerCase(), '.claude', 'skills');
      final live = p.join(nativeRoot, 'skill');
      Directory(live).createSync(recursive: true);
      File(p.join(live, 'SKILL.md')).writeAsStringSync('old');
      final io = InterruptIO();
      final state = LifecycleStateService(io: io);
      final old = state.baselineFor(live, ArtifactKind.skillCopy);
      final doc = fixture.evidence();
      final paths = RouteRecoveryPaths(p.context)
          .forLocation(nativeRoot, live, doc['transactionId'] as String);
      Directory(p.dirname(paths.quarantine)).createSync(recursive: true);
      Directory(p.dirname(paths.staged)).createSync(recursive: true);
      Directory(live).renameSync(paths.quarantine);
      Directory(live).createSync(recursive: true);
      File(p.join(live, 'SKILL.md')).writeAsStringSync('new');
      final next = state.baselineFor(live, ArtifactKind.skillCopy);
      for (final record in [
        ...doc['oldRecords'] as List,
        ...doc['newRecords'] as List,
      ]) {
        record['location'] = live;
        record['nativeRoot'] = nativeRoot;
      }
      (doc['oldRecords'] as List).first['baseline'] = old.toJson();
      (doc['newRecords'] as List).first['baseline'] = next.toJson();
      doc['actions'] = [
        {'path': live, 'oldKind': 'skillCopy', 'newKind': 'skillCopy'},
      ];
      doc['phase'] = 'published';
      doc['completedActions'] = ['0-remove', '0-publish'];
      final stateDir = p.join(root.path, '.agent-resource');
      final transactions = Directory(p.join(stateDir, 'transactions'))
        ..createSync(recursive: true);
      File(p.join(stateDir, 'installations.json')).writeAsStringSync(
        jsonEncode({'schemaVersion': 1, 'installations': doc['oldRecords']}),
      );
      final journal = File(
        p.join(transactions.path, '${doc['transactionId']}.json'),
      )..writeAsStringSync(jsonEncode(doc));
      final context = LifecycleContext.resolve(
        LifecycleOptions(
          processWorkingDirectory: root.path,
          projectRoot: root.path,
          stateDir: stateDir,
        ),
      );
      final service = RouteRecoveryService(state: state);
      final id = doc['transactionId'] as String;
      if (scenario == 'foreign') {
        File(p.join(live, 'SKILL.md')).writeAsStringSync('foreign');
      }
      if (scenario == 'ambiguous') {
        (doc['newRecords'] as List).first['baseline'] = old.toJson();
        File(p.join(live, 'SKILL.md')).writeAsStringSync('old');
        journal.writeAsStringSync(jsonEncode(doc));
      }
      if (scenario == 'foreign' || scenario == 'ambiguous') {
        final before = journal.readAsStringSync();
        await expectLater(
          service.recover(context, id, action: 'rollback'),
          throwsStateError,
        );
        expect(journal.readAsStringSync(), before);
        expect(Directory(paths.quarantine).existsSync(), isTrue);
        return;
      }
      if (scenario == 'interrupted') {
        io.interruptAfterRename = live;
        await expectLater(
          service.recover(context, id, action: 'rollback'),
          throwsStateError,
        );
        final interrupted = jsonDecode(journal.readAsStringSync());
        expect(interrupted['rolledBackActions'], isEmpty);
        expect(Directory(paths.staged).existsSync(), isTrue);
      }
      await service.recover(context, id, action: 'rollback');
      expect(File(p.join(live, 'SKILL.md')).readAsStringSync(), 'old');
      expect(
        FileSystemEntity.typeSync(paths.staged, followLinks: false),
        FileSystemEntityType.notFound,
      );
      final persisted = jsonDecode(journal.readAsStringSync());
      expect(persisted['phase'], 'rolledBack');
      expect(persisted['rolledBackActions'], ['0-publish', '0-remove']);
      final terminal = journal.readAsStringSync();
      await RouteRecoveryService(state: LifecycleStateService())
          .recover(context, id, action: 'rollback');
      expect(journal.readAsStringSync(), terminal);
    });
  }

  test('rolls back a multi-action route across two native roots', () async {
    final root = Directory.systemTemp.createTempSync('route-rollback-multi-');
    addTearDown(() => root.deleteSync(recursive: true));
    final claudeRoot = p.join(root.path.toLowerCase(), '.claude', 'skills');
    final codexRoot = p.join(root.path.toLowerCase(), '.codex', 'skills');
    final liveOld = p.join(claudeRoot, 'skill');
    final liveNew = p.join(codexRoot, 'skill');
    Directory(liveOld).createSync(recursive: true);
    File(p.join(liveOld, 'SKILL.md')).writeAsStringSync('old');
    final io = LifecycleIO();
    final state = LifecycleStateService(io: io);
    final old = state.baselineFor(liveOld, ArtifactKind.skillCopy);
    final doc = fixture.evidence();
    final id = doc['transactionId'] as String;
    final paths = RouteRecoveryPaths(p.context);
    final oldPaths = paths.forLocation(claudeRoot, liveOld, id);
    final newPaths = paths.forLocation(codexRoot, liveNew, id);
    Directory(p.dirname(oldPaths.quarantine)).createSync(recursive: true);
    Directory(p.dirname(newPaths.staged)).createSync(recursive: true);
    Directory(liveOld).renameSync(oldPaths.quarantine);
    Directory(liveNew).createSync(recursive: true);
    File(p.join(liveNew, 'SKILL.md')).writeAsStringSync('new');
    final next = state.baselineFor(liveNew, ArtifactKind.skillCopy);
    final oldRecord = (doc['oldRecords'] as List).single as Map;
    oldRecord['location'] = liveOld;
    oldRecord['nativeRoot'] = claudeRoot;
    oldRecord['baseline'] = old.toJson();
    final newRecord = (doc['newRecords'] as List).single as Map;
    newRecord['location'] = liveNew;
    newRecord['nativeRoot'] = codexRoot;
    newRecord['baseline'] = next.toJson();
    newRecord['nativeDestination'] = 'codex';
    newRecord['validatedProfiles'] = ['codex'];
    newRecord['knownConsumers'] = ['codex'];
    (newRecord['installationRoute'] as Map)['targets'] = ['codex'];
    doc['actions'] = [
      {'path': liveOld, 'oldKind': 'skillCopy', 'newKind': null},
      {'path': liveNew, 'oldKind': null, 'newKind': 'skillCopy'},
    ];
    doc['phase'] = 'published';
    doc['completedActions'] = ['0-remove', '1-publish'];
    final stateDir = p.join(root.path, '.agent-resource');
    final transactions = Directory(p.join(stateDir, 'transactions'))
      ..createSync(recursive: true);
    File(p.join(stateDir, 'installations.json')).writeAsStringSync(
      jsonEncode({'schemaVersion': 1, 'installations': doc['oldRecords']}),
    );
    final journal = File(p.join(transactions.path, '$id.json'))
      ..writeAsStringSync(jsonEncode(doc));
    final context = LifecycleContext.resolve(
      LifecycleOptions(
        processWorkingDirectory: root.path,
        projectRoot: root.path,
        stateDir: stateDir,
      ),
    );
    await RouteRecoveryService(state: state)
        .recover(context, id, action: 'rollback');
    expect(File(p.join(liveOld, 'SKILL.md')).readAsStringSync(), 'old');
    expect(
      FileSystemEntity.typeSync(newPaths.staged, followLinks: false),
      FileSystemEntityType.notFound,
    );
    expect(Directory(liveNew).existsSync(), isFalse);
    final persisted = jsonDecode(journal.readAsStringSync());
    expect(persisted['phase'], 'rolledBack');
    expect(persisted['rolledBackActions'], ['1-publish', '0-remove']);
    final terminal = journal.readAsStringSync();
    await RouteRecoveryService(state: LifecycleStateService())
        .recover(context, id, action: 'rollback');
    expect(journal.readAsStringSync(), terminal);
  });

  group('forward completion', () {
    Future<
      ({
        File journal,
        String quarantine,
        String live,
        String id,
        LifecycleContext context,
        LifecycleStateService state,
      })
    >
    committedJournal({bool tampered = false}) async {
      final root = Directory.systemTemp.createTempSync('route-recover-');
      addTearDown(() => root.deleteSync(recursive: true));
      final nativeRoot = p.join(root.path.toLowerCase(), '.claude', 'skills');
      final live = p.join(nativeRoot, 'skill');
      Directory(live).createSync(recursive: true);
      File(p.join(live, 'SKILL.md')).writeAsStringSync('old');
      final state = LifecycleStateService();
      final old = state.baselineFor(live, ArtifactKind.skillCopy);
      final doc = fixture.evidence();
      final id = doc['transactionId'] as String;
      final paths = RouteRecoveryPaths(p.context)
          .forLocation(nativeRoot, live, id);
      Directory(p.dirname(paths.quarantine)).createSync(recursive: true);
      Directory(live).renameSync(paths.quarantine);
      Directory(live).createSync(recursive: true);
      File(p.join(live, 'SKILL.md')).writeAsStringSync('new');
      if (tampered) {
        File(p.join(paths.quarantine, 'SKILL.md'))
            .writeAsStringSync('tampered');
      }
      final next = state.baselineFor(live, ArtifactKind.skillCopy);
      for (final record in [
        ...doc['oldRecords'] as List,
        ...doc['newRecords'] as List,
      ]) {
        record['location'] = live;
        record['nativeRoot'] = nativeRoot;
      }
      (doc['oldRecords'] as List).first['baseline'] = old.toJson();
      (doc['newRecords'] as List).first['baseline'] = next.toJson();
      doc['actions'] = [
        {'path': live, 'oldKind': 'skillCopy', 'newKind': 'skillCopy'},
      ];
      doc['phase'] = tampered ? 'completed' : 'published';
      doc['completedActions'] = ['0-remove', '0-publish'];
      final stateDir = p.join(root.path, '.agent-resource');
      final transactions = Directory(p.join(stateDir, 'transactions'))
        ..createSync(recursive: true);
      File(p.join(stateDir, 'installations.json')).writeAsStringSync(
        jsonEncode({'schemaVersion': 1, 'installations': doc['newRecords']}),
      );
      final journal = File(p.join(transactions.path, '$id.json'))
        ..writeAsStringSync(jsonEncode(doc));
      final context = LifecycleContext.resolve(
        LifecycleOptions(
          processWorkingDirectory: root.path,
          projectRoot: root.path,
          stateDir: stateDir,
        ),
      );
      return (
        journal: journal,
        quarantine: paths.quarantine,
        live: live,
        id: id,
        context: context,
        state: state,
      );
    }

    test(
      'completes a committed-ledger journal and clears quarantine',
      () async {
        final env = await committedJournal();
        final result = await RouteRecoveryService(state: env.state)
            .recover(env.context, env.id, action: 'complete');
        expect(result['outcome'], 'completed');
        expect(result['retained'], isEmpty);
        expect(Directory(env.quarantine).existsSync(), isFalse);
        final persisted = jsonDecode(env.journal.readAsStringSync());
        expect(persisted['phase'], 'completed');
        env.state.checkPendingConversions(env.context, locations: [env.live]);
      },
    );

    test('keeps and reports a tampered quarantine', () async {
      final env = await committedJournal(tampered: true);
      final result = await RouteRecoveryService(state: env.state)
          .recover(env.context, env.id, action: 'complete');
      expect(result['outcome'], 'completed');
      expect(result['retained'], [env.quarantine]);
      expect(
        File(p.join(env.quarantine, 'SKILL.md')).readAsStringSync(),
        'tampered',
      );
      expect(jsonDecode(env.journal.readAsStringSync())['phase'], 'completed');
    });

    test(
      'is listed and recovered through the shared recovery surface',
      () async {
        final env = await committedJournal();
        const resource = _CopySkillResource();
        final inventory = await env.state.recover(
          resource: resource,
          context: env.context,
        );
        final transactions =
            inventory.data['transactions'] as List<Map<String, Object?>>;
        expect(
          transactions
              .singleWhere((item) => item['transactionId'] == env.id)
              .containsKey('transactionId'),
          isTrue,
        );
        final inspected = await env.state.recover(
          resource: resource,
          context: env.context,
          transactionId: env.id,
        );
        expect(
          inspected.data['availableActions'],
          containsAll(<String>['rollback', 'complete']),
        );
        final approved = LifecycleContext.resolve(
          env.context.options.copyWith(approved: true),
        );
        final result = await env.state.recover(
          resource: resource,
          context: approved,
          transactionId: env.id,
          action: 'complete',
        );
        expect(result.data['stateEstablished'], 'completed');
        expect(
          jsonDecode(env.journal.readAsStringSync())['phase'],
          'completed',
        );
        final after = await env.state.recover(
          resource: resource,
          context: env.context,
        );
        expect(
          (after.data['transactions'] as List).any(
            (item) => item['transactionId'] == env.id,
          ),
          isFalse,
        );
      },
    );
  });
}

final class _CopySkillResource implements LifecycleResource {
  const _CopySkillResource();

  @override
  ArtifactKind get kind => ArtifactKind.skillCopy;

  @override
  Future<LifecycleCandidate> inspect(
    String path,
    LifecycleContext context, {
    String? expectedName,
    bool restoringBaseline = false,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> checkUnique(
    LifecycleContext context,
    String name, {
    required String nativeDestination,
    String? excludeInstallationId,
    String? excludePath,
    Set<String> allowedPaths = const <String>{},
  }) async {}

  @override
  void validateAuthority(InstallationRecord record, LifecycleContext context) {}
}

class InterruptIO extends LifecycleIO {
  String? interruptAfterRename;
  bool renamed = false;
  @override
  void before(String operation, String path) {
    if (operation == 'rename' && path == interruptAfterRename) renamed = true;
    if (operation == 'write' && renamed) {
      renamed = false;
      interruptAfterRename = null;
      throw StateError('injected interruption');
    }
  }
}
