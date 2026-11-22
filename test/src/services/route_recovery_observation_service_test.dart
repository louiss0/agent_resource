import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/conversion/route_journal_evidence.dart';
import 'package:agent_resource/src/conversion/route_recovery_paths.dart';
import 'package:agent_resource/src/conversion/route_recovery_plan.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/route_recovery_observation_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../conversion/route_journal_evidence_test.dart' as fixture;

void main() {
  test('observes prepared artifacts and old ledger without writing', () {
    final root = Directory.systemTemp.createTempSync('route-observe-');
    addTearDown(() => root.deleteSync(recursive: true));
    final nativeRoot = p.join(root.path.toLowerCase(), '.claude', 'skills');
    final live = p.join(nativeRoot, 'skill');
    Directory(live).createSync(recursive: true);
    File(p.join(live, 'SKILL.md')).writeAsStringSync('old');
    final state = LifecycleStateService();
    final baseline = state.baselineFor(live, ArtifactKind.skillCopy);
    final doc = fixture.evidence();
    for (final record in [
      ...doc['oldRecords'] as List,
      ...doc['newRecords'] as List,
    ]) {
      record['location'] = live;
      record['nativeRoot'] = nativeRoot;
      record['baseline'] = baseline.toJson();
    }
    doc['actions'] = [
      {'path': live, 'oldKind': 'skillCopy', 'newKind': 'skillCopy'},
    ];
    final journal = RouteJournalEvidence.decode(jsonEncode(doc), p.context);
    final stage = RouteRecoveryPaths(p.context)
        .forLocation(nativeRoot, live, doc['transactionId'] as String)
        .staged;
    Directory(stage).createSync(recursive: true);
    File(p.join(stage, 'SKILL.md')).writeAsStringSync('old');
    final stateDir = p.join(root.path, '.agent-resource');
    Directory(stateDir).createSync();
    final ledger = File(p.join(stateDir, 'installations.json'));
    ledger.writeAsStringSync(
      jsonEncode({'schemaVersion': 1, 'installations': doc['oldRecords']}),
    );
    final before = ledger.readAsStringSync();
    final context = LifecycleContext.resolve(
      LifecycleOptions(
        processWorkingDirectory: root.path,
        projectRoot: root.path,
        stateDir: stateDir,
      ),
    );
    final result = RouteRecoveryObservationService(state: state)
        .inspect(journal, context);
    expect(result.ledger, LedgerObservation.old);
    expect(result.artifacts.single.live, ArtifactObservation.ambiguous);
    expect(result.plan.decision, RecoveryDecision.refuse);
    expect(ledger.readAsStringSync(), before);
    final sameDoc = jsonDecode(jsonEncode(doc)) as Map<String, dynamic>;
    sameDoc['newRecords'] = jsonDecode(jsonEncode(sameDoc['oldRecords']));
    final ambiguousLedger = RouteRecoveryObservationService(state: state)
        .inspect(
          RouteJournalEvidence.decode(jsonEncode(sameDoc), p.context),
          context,
        );
    expect(ambiguousLedger.ledger, LedgerObservation.ambiguous);
    expect(ambiguousLedger.plan.decision, RecoveryDecision.refuse);

    File(p.join(stage, 'SKILL.md')).writeAsStringSync('new');
    final updated = state.baselineFor(stage, ArtifactKind.skillCopy);
    (doc['newRecords'] as List).first['baseline'] = updated.toJson();
    final changed = RouteJournalEvidence.decode(jsonEncode(doc), p.context);
    final service = RouteRecoveryObservationService(state: state);
    final prepared = service.inspect(changed, context);
    expect(prepared.ledger, LedgerObservation.old);
    expect(prepared.artifacts.single.live, ArtifactObservation.old);
    expect(prepared.artifacts.single.staged, ArtifactObservation.newArtifact);
    expect(prepared.plan.decision, RecoveryDecision.rollback);
    ledger.writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'installations': [
          ...doc['oldRecords'] as List,
          ...doc['newRecords'] as List,
        ],
      }),
    );
    expect(service.inspect(changed, context).ledger, LedgerObservation.unknown);
    ledger.writeAsStringSync(before);

    final quarantine = RouteRecoveryPaths(p.context)
        .forLocation(nativeRoot, live, doc['transactionId'] as String)
        .quarantine;
    Directory(p.dirname(quarantine)).createSync(recursive: true);
    Directory(live).renameSync(quarantine);
    final removed = service.inspect(changed, context);
    expect(removed.artifacts.single.quarantine, ArtifactObservation.old);
    expect(removed.plan.decision, RecoveryDecision.rollback);
    Directory(stage).renameSync(live);
    doc['phase'] = 'published';
    doc['completedActions'] = ['0-remove', '0-publish'];
    final published = RouteJournalEvidence.decode(jsonEncode(doc), p.context);
    ledger.writeAsStringSync(
      jsonEncode({'schemaVersion': 1, 'installations': doc['newRecords']}),
    );
    expect(
      service.inspect(published, context).plan.decision,
      RecoveryDecision.complete,
    );
    Directory(live).renameSync(stage);
    Directory(quarantine).renameSync(live);
    ledger.writeAsStringSync(before);
    doc['phase'] = 'prepared';
    doc['completedActions'] = <String>[];

    Directory(stage).deleteSync(recursive: true);
    File(stage).writeAsStringSync('foreign kind');
    final foreignKind = service.inspect(changed, context);
    expect(foreignKind.artifacts.single.staged, ArtifactObservation.unknown);
    expect(foreignKind.plan.decision, RecoveryDecision.refuse);

    final alien = p.join(root.path.toLowerCase(), 'foreign', 'skill');
    for (final record in [
      ...doc['oldRecords'] as List,
      ...doc['newRecords'] as List,
    ]) {
      record['location'] = alien;
      record['nativeRoot'] = p.dirname(alien);
    }
    doc['actions'] = [
      {'path': alien, 'oldKind': 'skillCopy', 'newKind': 'skillCopy'},
    ];
    final foreign = service.inspect(
      RouteJournalEvidence.decode(jsonEncode(doc), p.context),
      context,
    );
    expect(foreign.ledger, LedgerObservation.unknown);
    expect(foreign.plan.decision, RecoveryDecision.refuse);
    expect(ledger.readAsStringSync(), before);
  });
}
