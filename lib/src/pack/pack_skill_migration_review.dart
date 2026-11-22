import 'package:mamba/mamba.dart';

import '../installation/installation_plan.dart';
import '../services/lifecycle_state_service.dart';
import 'pack_models.dart';

/// Builds review evidence only. Publication must independently recheck it
/// inside the lifecycle transaction; this plan is not a reservation.
final class const PackSkillMigrationReview() {
  /// [records] must be the complete set of Pack records in the scope, not a
  /// prefiltered subset. Destination observations must come from the shared
  /// lifecycle planner, which must revalidate them before any publication.
  PackPlan preview({
    required String packKey,
    required String name,
    required List<InstallationRecord> records,
    required InstallationUnitPlan desired,
  }) {
    final selected =
        records
            .where(
              (record) =>
                  record.lifecycle == 'live' &&
                  record.name == name &&
                  record.origin['packKey'] == packKey,
            )
            .toList()
          ..sort((a, b) => a.installationId.compareTo(b.installationId));
    final route = desired.installationRoute;
    if (selected.isEmpty ||
        desired.resourceType != InstallationResourceType.skill ||
        desired.nativeName != name ||
        desired.origin['packKey'] != packKey ||
        route == null ||
        route.packKey != packKey ||
        route.method != desired.method ||
        desired.entries.isEmpty) {
      throw MambaException(
        'Migration requires an explicitly selected managed Pack Skill and a complete destination.',
      );
    }
    for (final record in selected) {
      final old = record.installationRoute;
      if (old == null ||
          old.packKey != packKey ||
          old.scope != route.scope ||
          record.scope != old.scope ||
          old.method !=
              switch (record.kind) {
                ArtifactKind.skillCanonical => InstallationMethod.canonical,
                ArtifactKind.skillCopy => InstallationMethod.copy,
                ArtifactKind.skillLink => InstallationMethod.sourceLink,
                _ => null,
              } ||
          old.sourceKind != route.sourceKind ||
          old.sourceRelativePath != route.sourceRelativePath ||
          old.entryId != route.entryId ||
          old.source.requestedLocator != route.source.requestedLocator ||
          old.source.requestedRef != route.source.requestedRef ||
          old.source.subpath != route.source.subpath) {
        throw MambaException(
          'Migration cannot change or infer the recorded Pack Skill source.',
        );
      }
    }
    return PackPlan.create(
      operation: 'skills.migrate',
      context: {
        'pack': packKey,
        'scope': route.scope.name,
        'previousInstallations': [
          for (final record in selected) record.toJson(),
        ],
        'desiredInstallation': desired.identityJson(),
      },
      source: route.source.toJson(),
      resources: [
        PackResourcePlan(
          type: 'skill',
          name: name,
          action: 'migrate',
          method: route.method.wireName,
          methodOrigin: 'explicit-argument',
          targets: [for (final target in route.targets) target.name],
          targetOrigin: 'explicit-argument',
          changedPaths: [
            for (final record in selected) ...[
              PackChangedPath(path: record.location, change: 'removed'),
              for (final exposure in record.exposures)
                PackChangedPath(path: exposure.path, change: 'removed'),
            ],
            for (final entry in desired.entries)
              PackChangedPath(path: entry.path, change: 'added'),
          ],
        ),
      ],
    );
  }

  /// Checks a separately supplied preview ID; it does not authorize effects.
  void requireReviewed(PackPlan current, String? reviewedPlan) {
    if (reviewedPlan == null || reviewedPlan != current.planId) {
      throw MambaException(
        'Review the current Pack Skill migration preview and supply its plan ID.',
      );
    }
  }
}
