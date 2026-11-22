import 'dart:convert';

import 'package:agent_resource/src/conversion/route_journal_evidence.dart';
import 'package:agent_resource/src/conversion/route_recovery_plan.dart';
import 'package:path/path.dart' as p;
import 'package:agent_resource/src/installation/installation_plan.dart';

import 'installation_path_diff_test.dart' as path_fixture;

import 'package:test/test.dart';

import 'route_journal_evidence_test.dart' as fixture;

void main() {
  test('infers an unmarked quarantine rename and plans rollback', () {
    final journal = RouteJournalEvidence.decode(
      jsonEncode(fixture.evidence()),
      p.posix,
    );
    final plan = RouteRecoveryPlan.inspect(
      journal,
      ledger: LedgerObservation.old,
      artifacts: [
        (
          live: ArtifactObservation.absent,
          staged: ArtifactObservation.absent,
          quarantine: ArtifactObservation.old,
        ),
        (
          live: ArtifactObservation.absent,
          staged: ArtifactObservation.newArtifact,
          quarantine: ArtifactObservation.absent,
        ),
      ],
    );
    expect(plan.decision, RecoveryDecision.rollback);
    expect(plan.appliedSteps, 1);
  });

  test('resumes after a reverse rename before its marker and verifies terminal evidence', () {
    final doc = fixture.evidence();
    doc['completedActions'] = ['0-remove', '1-publish'];
    doc['phase'] = 'rollingBack';
    doc['rolledBackActions'] = <String>[];
    final afterReverse = <RouteArtifactObservations>[
      (
        live: ArtifactObservation.absent,
        staged: ArtifactObservation.absent,
        quarantine: ArtifactObservation.old,
      ),
      (
        live: ArtifactObservation.absent,
        staged: ArtifactObservation.newArtifact,
        quarantine: ArtifactObservation.absent,
      ),
    ];
    RouteRecoveryPlan inspect(
      LedgerObservation ledger,
      List<RouteArtifactObservations> artifacts,
    ) => RouteRecoveryPlan.inspect(
      RouteJournalEvidence.decode(jsonEncode(doc), p.posix),
      ledger: ledger,
      artifacts: artifacts,
    );
    expect(inspect(LedgerObservation.old, afterReverse).appliedSteps, 1);
    expect(
      inspect(LedgerObservation.newRecords, afterReverse).decision,
      RecoveryDecision.refuse,
    );
    final initial = <RouteArtifactObservations>[
      (
        live: ArtifactObservation.old,
        staged: ArtifactObservation.absent,
        quarantine: ArtifactObservation.absent,
      ),
      afterReverse.last,
    ];
    expect(
      inspect(LedgerObservation.old, initial).decision,
      RecoveryDecision.refuse,
    );
    doc['rolledBackActions'] = ['1-publish'];
    expect(inspect(LedgerObservation.old, initial).appliedSteps, 0);
    doc['phase'] = 'rolledBack';
    doc['rolledBackActions'] = ['1-publish', '0-remove'];
    expect(
      inspect(LedgerObservation.old, initial).decision,
      RecoveryDecision.rolledBack,
    );
    expect(
      inspect(LedgerObservation.old, afterReverse).decision,
      RecoveryDecision.refuse,
    );
  });

  test('distinguishes old and new baselines at a replaced path', () {
    final doc = fixture.evidence();
    final next = (doc['newRecords'] as List).first as Map;
    next['location'] = '/old/skill';
    next['nativeRoot'] = '/old';
    next['artifactKind'] = 'skill-link';
    next['installationRoute'] = path_fixture
        .route(InstallationMethod.sourceLink)
        .toJson();
    doc['actions'] = [
      {'path': '/old/skill', 'oldKind': 'skillCopy', 'newKind': 'skillLink'},
    ];
    final journal = RouteJournalEvidence.decode(jsonEncode(doc), p.posix);
    final removal = RouteRecoveryPlan.inspect(
      journal,
      ledger: LedgerObservation.old,
      artifacts: [
        (
          live: ArtifactObservation.absent,
          staged: ArtifactObservation.newArtifact,
          quarantine: ArtifactObservation.old,
        ),
      ],
    );
    expect(removal.decision, RecoveryDecision.rollback);
    expect(removal.appliedSteps, 1);
    final ambiguous = RouteRecoveryPlan.inspect(
      journal,
      ledger: LedgerObservation.old,
      artifacts: [
        (
          live: ArtifactObservation.ambiguous,
          staged: ArtifactObservation.newArtifact,
          quarantine: ArtifactObservation.absent,
        ),
      ],
    );
    expect(ambiguous.decision, RecoveryDecision.refuse);
  });

  test('requires verified artifacts and an unambiguous ledger', () {
    final journal = RouteJournalEvidence.decode(
      jsonEncode(fixture.evidence()),
      p.posix,
    );
    final initial = <RouteArtifactObservations>[
      (
        live: ArtifactObservation.old,
        staged: ArtifactObservation.absent,
        quarantine: ArtifactObservation.absent,
      ),
      (
        live: ArtifactObservation.absent,
        staged: ArtifactObservation.newArtifact,
        quarantine: ArtifactObservation.absent,
      ),
    ];
    RecoveryDecision decide(
      LedgerObservation ledger,
      List<RouteArtifactObservations> observations,
    ) => RouteRecoveryPlan.inspect(
      journal,
      ledger: ledger,
      artifacts: observations,
    ).decision;
    expect(decide(LedgerObservation.old, initial), RecoveryDecision.rollback);
    expect(decide(LedgerObservation.unknown, initial), RecoveryDecision.refuse);
    expect(
      decide(LedgerObservation.ambiguous, initial),
      RecoveryDecision.refuse,
    );
    expect(
      decide(LedgerObservation.newRecords, initial),
      RecoveryDecision.refuse,
    );
    expect(
      decide(LedgerObservation.old, [initial.first]),
      RecoveryDecision.refuse,
    );
    for (final foreign in [
      ArtifactObservation.unknown,
      ArtifactObservation.ambiguous,
      ArtifactObservation.newArtifact,
    ]) {
      expect(
        decide(LedgerObservation.old, [
          (
            live: foreign,
            staged: ArtifactObservation.absent,
            quarantine: ArtifactObservation.absent,
          ),
          initial.last,
        ]),
        RecoveryDecision.refuse,
      );
    }
  });

  test('infers unmarked publication but refuses skipped markers', () {
    final doc = fixture.evidence();
    doc['phase'] = 'applying';
    doc['completedActions'] = ['0-remove'];
    final journal = RouteJournalEvidence.decode(jsonEncode(doc), p.posix);
    final published = <RouteArtifactObservations>[
      (
        live: ArtifactObservation.absent,
        staged: ArtifactObservation.absent,
        quarantine: ArtifactObservation.old,
      ),
      (
        live: ArtifactObservation.newArtifact,
        staged: ArtifactObservation.absent,
        quarantine: ArtifactObservation.absent,
      ),
    ];
    final result = RouteRecoveryPlan.inspect(
      journal,
      ledger: LedgerObservation.old,
      artifacts: published,
    );
    expect(result.decision, RecoveryDecision.rollback);
    expect(result.appliedSteps, 2);
    expect(
      RouteRecoveryPlan.inspect(
        journal,
        ledger: LedgerObservation.newRecords,
        artifacts: published,
      ).decision,
      RecoveryDecision.refuse,
    );
    final unmarked = RouteJournalEvidence.decode(
      jsonEncode(fixture.evidence()),
      p.posix,
    );
    expect(
      RouteRecoveryPlan.inspect(
        unmarked,
        ledger: LedgerObservation.old,
        artifacts: published,
      ).decision,
      RecoveryDecision.refuse,
    );
  });

  test(
    'completes only with fully marked publication and verified new ledger',
    () {
      final doc = fixture.evidence();
      doc['phase'] = 'published';
      doc['completedActions'] = ['0-remove', '1-publish'];
      final published = <RouteArtifactObservations>[
        (
          live: ArtifactObservation.absent,
          staged: ArtifactObservation.absent,
          quarantine: ArtifactObservation.old,
        ),
        (
          live: ArtifactObservation.newArtifact,
          staged: ArtifactObservation.absent,
          quarantine: ArtifactObservation.absent,
        ),
      ];
      var journal = RouteJournalEvidence.decode(jsonEncode(doc), p.posix);
      expect(
        RouteRecoveryPlan.inspect(
          journal,
          ledger: LedgerObservation.newRecords,
          artifacts: published,
        ).decision,
        RecoveryDecision.complete,
      );
      expect(
        RouteRecoveryPlan.inspect(
          journal,
          ledger: LedgerObservation.old,
          artifacts: published,
        ).decision,
        RecoveryDecision.rollback,
      );
      doc['phase'] = 'committed';
      journal = RouteJournalEvidence.decode(jsonEncode(doc), p.posix);
      expect(
        RouteRecoveryPlan.inspect(
          journal,
          ledger: LedgerObservation.old,
          artifacts: published,
        ).decision,
        RecoveryDecision.refuse,
      );
      expect(
        RouteRecoveryPlan.inspect(
          journal,
          ledger: LedgerObservation.newRecords,
          artifacts: [
            (
              live: ArtifactObservation.absent,
              staged: ArtifactObservation.absent,
              quarantine: ArtifactObservation.unknown,
            ),
            published.last,
          ],
        ).decision,
        RecoveryDecision.refuse,
      );
    },
  );
}
