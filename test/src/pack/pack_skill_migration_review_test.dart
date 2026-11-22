import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/installation/installation_route.dart';
import 'package:agent_resource/src/pack/pack_skill_migration_review.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  const review = PackSkillMigrationReview();
  const source = AcquisitionProvenance(
    kind: AcquisitionLocatorKind.local,
    requestedLocator: '/source',
    resolvedLocator: '/source',
    subpath: null,
    temporary: false,
    directFile: false,
    durableLocalDirectory: true,
  );
  InstallationRoute route(
    InstallationMethod method,
    InstallationRouteTarget target, {
    String path = 'skills/a',
  }) => InstallationRoute(
    source: source,
    sourceKind: AcquisitionSourceKind.collection,
    sourceRelativePath: path,
    scope: LifecycleScope.project,
    targets: [target],
    method: method,
    derivedArtifacts: [],
    packKey: 'pack',
  );
  InstallationRecord record(String name, {String id = 'one'}) =>
      InstallationRecord(
        installationId: id,
        kind: ArtifactKind.skillCopy,
        scope: LifecycleScope.project,
        nativeDestination: 'codex',
        nativeForm: 'skill',
        location: '/old/$name',
        nativeRoot: '/old',
        name: name,
        nativeProfile: null,
        validatedProfiles: const ['codex'],
        knownConsumers: const [],
        baseline: const ArtifactBaseline([]),
        lifecycle: 'live',
        origin: const {'packKey': 'pack'},
        backupIds: const [],
        transactionId: null,
        installationRoute: route(
          InstallationMethod.copy,
          InstallationRouteTarget.codex,
        ),
      );
  InstallationUnitPlan desired(
    InstallationMethod method,
    InstallationRouteTarget target, {
    String path = 'skills/a',
    String digest = 'digest',
  }) => InstallationUnitPlan(
    resourceType: InstallationResourceType.skill,
    resourceId: 'a',
    nativeName: 'a',
    profile: null,
    method: method,
    status: InstallationUnitStatus.planned,
    installationIds: const [],
    entries: [
      InstallationEntryPlan(
        path: '/new/a',
        kind: InstallationEntryKind.copy,
        action: InstallationEntryAction.createCopy,
        observedDigest: digest,
      ),
    ],
    sourcePath: '/source/skills/a',
    sourceDigest: digest,
    origin: const {'packKey': 'pack'},
    installationRoute: route(method, target, path: path),
  );
  group('Pack Skill migration review', () {
    for (final method in InstallationMethod.values) {
      test('previews selected Skill with ${method.wireName}', () {
        final plan = review.preview(
          packKey: 'pack',
          name: 'a',
          records: [record('a'), record('other')],
          desired: desired(method, InstallationRouteTarget.claude),
        );
        expect(plan.resources.single.name, 'a');
        expect(plan.resources.single.method, method.wireName);
        expect(plan.resources.single.targets, ['claude']);
        expect((plan.context['previousInstallations'] as List), hasLength(1));
        expect(plan.resources.single.changedPaths.map((p) => p.path), [
          '/old/a',
          '/new/a',
        ]);
        expect(
          () => review.requireReviewed(plan, plan.planId),
          returnsNormally,
        );
      });
    }
    test('refuses unknown selection and changed source identity', () {
      expect(
        () => review.preview(
          packKey: 'pack',
          name: 'a',
          records: [record('other')],
          desired: desired(
            InstallationMethod.copy,
            InstallationRouteTarget.claude,
          ),
        ),
        throwsA(isA<MambaException>()),
      );
      expect(
        () => review.preview(
          packKey: 'pack',
          name: 'a',
          records: [record('a')],
          desired: desired(
            InstallationMethod.copy,
            InstallationRouteTarget.claude,
            path: 'elsewhere',
          ),
        ),
        throwsA(isA<MambaException>()),
      );
    });
    test('rejects missing or stale review', () {
      final old = review.preview(
        packKey: 'pack',
        name: 'a',
        records: [record('a')],
        desired: desired(
          InstallationMethod.copy,
          InstallationRouteTarget.claude,
        ),
      );
      final changed = review.preview(
        packKey: 'pack',
        name: 'a',
        records: [record('a')],
        desired: desired(
          InstallationMethod.copy,
          InstallationRouteTarget.claude,
          digest: 'changed',
        ),
      );
      expect(old.planId, isNot(changed.planId));
      expect(
        () => review.requireReviewed(changed, old.planId),
        throwsA(isA<MambaException>()),
      );
      expect(
        () => review.requireReviewed(old, null),
        throwsA(isA<MambaException>()),
      );
    });
  });
}
