import 'route_journal_evidence.dart';

/// Result of independently comparing an entry against both typed baselines.
/// Ambiguous includes matching both baselines; unknown includes foreign entries,
/// failed inspection, and any state that cannot be independently verified.
enum ArtifactObservation { absent, old, newArtifact, ambiguous, unknown }

/// Exact comparison of the complete participating ledger state, not a write result.
enum LedgerObservation { old, newRecords, ambiguous, unknown }

enum RecoveryDecision { rollback, rolledBack, complete, refuse }

typedef RouteArtifactObservations = ({
  ArtifactObservation live,
  ArtifactObservation staged,
  ArtifactObservation quarantine,
});

/// A read-only inference, never authority to perform recovery. Observations must
/// be freshly and independently verified by a caller with filesystem authority,
/// including link targets, artifact kinds and baselines. The journal alone does
/// not establish that authority or specify trusted staging/quarantine paths.
final class RouteRecoveryPlan {
  const RouteRecoveryPlan._(this.decision, this.appliedSteps);

  final RecoveryDecision decision;

  /// Number of forward renames still in effect, or null when inconclusive.
  final int? appliedSteps;

  static RouteRecoveryPlan inspect(
    RouteJournalEvidence journal, {
    required LedgerObservation ledger,
    required List<RouteArtifactObservations> artifacts,
  }) {
    const refuse = RouteRecoveryPlan._(RecoveryDecision.refuse, null);
    final doc = journal.toJson();
    final actions = doc['actions'] as List;
    final markers = (doc['completedActions'] as List).length;
    if (artifacts.length != actions.length ||
        ledger == LedgerObservation.ambiguous ||
        ledger == LedgerObservation.unknown) {
      return refuse;
    }

    final reverse = doc['rolledBackActions'] as List?;
    if (reverse != null && ledger != LedgerObservation.old) return refuse;

    // Simulate only the recorded prefix and the single possible rename that
    // can occur before its marker is durable. No later mutation is inferred.
    final state = <RouteArtifactObservations>[
      for (final action in actions)
        (
          live: action['oldKind'] == null
              ? ArtifactObservation.absent
              : ArtifactObservation.old,
          staged: action['newKind'] == null
              ? ArtifactObservation.absent
              : ArtifactObservation.newArtifact,
          quarantine: ArtifactObservation.absent,
        ),
    ];
    final candidates = <int>[];
    var step = 0;
    void match() {
      final remaining = reverse == null ? null : markers - reverse.length;
      final eligible = remaining == null
          ? step == markers || step == markers + 1
          : step == remaining ||
                (remaining > 0 &&
                    doc['phase'] != 'rolledBack' &&
                    step == remaining - 1);
      if (eligible &&
          List.generate(
            state.length,
            (i) => state[i] == artifacts[i],
          ).every((v) => v)) {
        candidates.add(step);
      }
    }

    match();
    for (var i = 0; i < actions.length; i++) {
      final action = actions[i];
      if (action['oldKind'] != null) {
        state[i] = (
          live: ArtifactObservation.absent,
          staged: state[i].staged,
          quarantine: ArtifactObservation.old,
        );
        step++;
        match();
      }
      if (action['newKind'] != null) {
        state[i] = (
          live: ArtifactObservation.newArtifact,
          staged: ArtifactObservation.absent,
          quarantine: state[i].quarantine,
        );
        step++;
        match();
      }
    }
    if (reverse != null) {
      // Rollback starts only after every applied forward rename is marked.
      // Candidates include at most one unmarked reverse rename.
      if (candidates.length != 1) return refuse;
      return RouteRecoveryPlan._(
        doc['phase'] == 'rolledBack'
            ? RecoveryDecision.rolledBack
            : RecoveryDecision.rollback,
        candidates.single,
      );
    }
    if (candidates.length != 1) {
      // A committed-new ledger plus fully published live artifacts is complete
      // even when quarantine evidence changed: rollback is impossible anyway,
      // and cleanup separately retains anything that fails verification.
      final terminalPhase = [
        'published',
        'committed',
        'completed',
        'recoveryRequired',
      ].contains(doc['phase']);
      if (ledger == LedgerObservation.newRecords &&
          terminalPhase &&
          markers == step &&
          List.generate(actions.length, (i) {
            final action = actions[i];
            final observed = artifacts[i];
            final expectedLive = action['newKind'] == null
                ? ArtifactObservation.absent
                : ArtifactObservation.newArtifact;
            return observed.live == expectedLive &&
                observed.staged == ArtifactObservation.absent;
          }).every((v) => v)) {
        return const RouteRecoveryPlan._(RecoveryDecision.complete, null);
      }
      return refuse;
    }
    final applied = candidates.single;
    final phase = doc['phase'];
    if (ledger == LedgerObservation.old) {
      if (phase == 'committed' || phase == 'completed') return refuse;
      return RouteRecoveryPlan._(RecoveryDecision.rollback, applied);
    }
    if (applied != step ||
        markers != step ||
        ![
          'published',
          'committed',
          'completed',
          'recoveryRequired',
        ].contains(phase)) {
      return refuse;
    }
    return RouteRecoveryPlan._(RecoveryDecision.complete, applied);
  }
}
