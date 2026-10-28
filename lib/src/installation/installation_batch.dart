import 'dart:async';
import 'dart:io';

import 'package:mamba/mamba.dart';

import '../services/lifecycle_state_service.dart';
import 'installation_interaction.dart';
import 'installation_plan.dart';
import 'installation_request.dart';

/// Sequential scheduler for reviewed resource units. Native planning remains
/// in resource workflows; this class owns approval, continuation and aggregate
/// outcome truthfulness.
final class InstallationBatch {
  InstallationBatch({this.interruption});

  final Stream<void>? interruption;

  Future<InstallationWorkflowResult> execute({
    required InstallationPlan plan,
    required LifecycleContext context,
    required LifecycleStateService state,
    required LifecycleResource Function(InstallationUnitPlan unit) resourceFor,
    required InstallationInteraction interaction,
    required bool interactive,
    required bool approved,
  }) async {
    if (interactive) {
      interaction.presentPlan(plan.renderText(InstallationOutcome.planned));
    }
    if (!approved) {
      final answer = await interaction.approve(
        plan.renderText(InstallationOutcome.planned),
      );
      if (answer.status != InteractionAnswerStatus.value ||
          answer.value != true) {
        return InstallationCancelledResult(plan.command);
      }
    }

    var interrupted = false;
    final subscription = (interruption ?? ProcessSignal.sigint.watch()).listen(
      (_) => interrupted = true,
    );
    final units = plan.units.toList();
    final diagnostics = <String>[];
    var anyFailure = false;
    var recoveredFailure = false;
    var retainedSuccess = false;
    var recoveryRequired = false;
    var stopped = false;
    final blockedBy = <InstallationUnitPlan>[];
    final failureStatuses = <int>[];
    try {
      for (var index = 0; index < units.length; index++) {
        if (interrupted &&
            !retainedSuccess &&
            !recoveredFailure &&
            !recoveryRequired) {
          return InstallationCancelledResult(plan.command);
        }
        if (stopped || interrupted) {
          units[index] = units[index].copyWith(
            status: InstallationUnitStatus.notStarted,
          );
          diagnostics.add('${units[index].resourceId}: not started.');
          continue;
        }
        final unit = units[index];
        if (blockedBy.any((failed) => !_independent(failed, unit))) {
          units[index] = unit.copyWith(
            status: InstallationUnitStatus.notStarted,
          );
          diagnostics.add(
            '${unit.resourceId}: not started because a shared-path unit required restoration.',
          );
          continue;
        }
        try {
          final result = await state.installResourceUnit(
            resource: resourceFor(unit),
            context: context,
            unit: unit,
          );
          units[index] = unit.copyWith(
            status: result.status,
            installationIds: result.installationIds,
          );
          retainedSuccess =
              retainedSuccess ||
              result.status == InstallationUnitStatus.installed;
          if (interrupted) {
            diagnostics.add(
              '${unit.resourceId}: committed ${result.transactionId}; '
              'post-write interruption requested; remaining units will not start.',
            );
          }
        } on MambaException catch (error) {
          anyFailure = true;
          failureStatuses.add(error.exitCode);
          if (error.exitCode == 6) {
            recoveryRequired = true;
            stopped = true;
            units[index] = unit.copyWith(
              status: InstallationUnitStatus.recoveryRequired,
            );
          } else if (error.exitCode == 5) {
            recoveredFailure = true;
            blockedBy.add(unit);
            units[index] = unit.copyWith(
              status: InstallationUnitStatus.failedRestored,
            );
          } else {
            units[index] = unit.copyWith(
              status: InstallationUnitStatus.notStarted,
            );
          }
          diagnostics.add('${unit.resourceId}: ${error.message}');
        }
      }
      if (interrupted && !anyFailure) {
        anyFailure = true;
        diagnostics.add(
          'Installation interrupted after writes; retained changes are reported above.',
        );
      }
      if (anyFailure) {
        final failedPlan = InstallationPlan.create(
          command: plan.command,
          source: plan.source,
          scope: plan.scope,
          units: units,
          diagnostics: plan.diagnostics,
        );
        final status = recoveryRequired
            ? 6
            : interrupted
            ? 7
            : (retainedSuccess || recoveredFailure)
            ? 5
            : failureStatuses.fold<int>(
                1,
                (left, right) => left > right ? left : right,
              );
        throw MambaException(
          '${plan.command} did not complete.\n'
          '${failedPlan.renderText(InstallationOutcome.planned)}\n'
          '${diagnostics.join('\n')}\n'
          '${recoveryRequired ? 'Inspect the cited transaction evidence and use the matching resource recover command before retrying.' : 'Completed units were retained; safely restored units were not installed. Recompute a fresh plan before retrying.'}',
          exitCode: status,
        );
      }
      final completed = InstallationPlan.create(
        command: plan.command,
        source: plan.source,
        scope: plan.scope,
        units: units,
        diagnostics: plan.diagnostics,
      );
      final unchanged = units.every(
        (unit) => unit.status == InstallationUnitStatus.unchanged,
      );
      return InstallationCompletedResult(
        completed,
        unchanged
            ? InstallationOutcome.unchanged
            : InstallationOutcome.installed,
      );
    } finally {
      await subscription.cancel();
    }
  }
}

bool _independent(InstallationUnitPlan failed, InstallationUnitPlan other) {
  final failedPaths = failed.entries.map((entry) => entry.path).toSet();
  return other.entries.every((entry) => !failedPaths.contains(entry.path));
}
