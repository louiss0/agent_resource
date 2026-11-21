import 'package:agent_resource/src/conversion/installation_path_diff.dart';
import 'package:agent_resource/src/conversion/path_action_diff.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/installation/installation_route.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
  InstallationMethod method, {
  LifecycleScope scope = LifecycleScope.project,
  AcquisitionProvenance provenance = source,
  List<InstallationRouteTarget> targets = const [
    InstallationRouteTarget.claude,
  ],
}) => InstallationRoute(
  source: provenance,
  sourceKind: AcquisitionSourceKind.resource,
  sourceRelativePath: '.',
  scope: scope,
  targets: targets,
  method: method,
  derivedArtifacts: [],
);
InstallationRecord oldRecord({
  InstallationRoute? routing,
  String path = '/old/skill',
  String id = 'ins_1',
  List<String> consumers = const ['claude'],
}) => InstallationRecord(
  installationId: id,
  kind: ArtifactKind.skillCopy,
  scope: LifecycleScope.project,
  nativeDestination: 'claude',
  nativeForm: 'skill-copy',
  location: path,
  nativeRoot: '/old',
  name: 'skill',
  nativeProfile: null,
  validatedProfiles: consumers,
  knownConsumers: consumers,
  baseline: const ArtifactBaseline([]),
  lifecycle: 'live',
  origin: {'source': source.toJson()},
  backupIds: [],
  transactionId: null,
  installationRoute: routing ?? route(InstallationMethod.copy),
);
InstallationUnitPlan desired({
  InstallationRoute? routing,
  String path = '/new/skill',
}) => InstallationUnitPlan(
  resourceType: InstallationResourceType.skill,
  resourceId: 'skill',
  nativeName: 'skill',
  profile: null,
  method: InstallationMethod.sourceLink,
  status: InstallationUnitStatus.planned,
  installationIds: [],
  entries: [
    InstallationEntryPlan(
      path: path,
      kind: InstallationEntryKind.link,
      action: InstallationEntryAction.createLink,
      target: 'claude',
      nativeRoot: '/new',
      nativeDestination: 'claude',
      artifactKind: OwnedArtifactKind.skillLink,
    ),
  ],
  sourcePath: '/source',
  sourceDigest: 'digest',
  origin: {'source': source.toJson()},
  installationRoute: routing ?? route(InstallationMethod.sourceLink),
);
void main() {
  test('adapts a reviewed copy to a cross-root source link', () {
    expect(
      InstallationPathDiff(p.Context(style: p.Style.posix)).prepare(
        oldRecords: [oldRecord()],
        desired: desired(),
        scope: LifecycleScope.project,
        occupiedPaths: [],
      ),
      [
        (path: '/old/skill', oldKind: OldArtifactKind.skillCopy, newKind: null),
        (path: '/new/skill', oldKind: null, newKind: NewArtifactKind.skillLink),
      ],
    );
  });
  test('rejects wrong scope and source provenance', () {
    final diff = InstallationPathDiff(p.Context(style: p.Style.posix));
    expect(
      () => diff.prepare(
        oldRecords: [oldRecord()],
        desired: desired(),
        scope: LifecycleScope.user,
        occupiedPaths: [],
      ),
      throwsArgumentError,
    );
    const other = AcquisitionProvenance(
      kind: AcquisitionLocatorKind.local,
      requestedLocator: '/other',
      resolvedLocator: '/other',
      subpath: null,
      temporary: false,
      directFile: false,
      durableLocalDirectory: true,
    );
    expect(
      () => diff.prepare(
        oldRecords: [oldRecord()],
        desired: desired(
          routing: route(InstallationMethod.sourceLink, provenance: other),
        ),
        scope: LifecycleScope.project,
        occupiedPaths: [],
      ),
      throwsArgumentError,
    );
  });
  test(
    'rejects incomplete groups, overlapping paths and invalid desired kind',
    () {
      final diff = InstallationPathDiff(p.Context(style: p.Style.posix));
      final multi = route(
        InstallationMethod.copy,
        targets: [
          InstallationRouteTarget.claude,
          InstallationRouteTarget.codex,
        ],
      );
      expect(
        () => diff.prepare(
          oldRecords: [oldRecord(routing: multi)],
          desired: desired(),
          scope: LifecycleScope.project,
          occupiedPaths: [],
        ),
        throwsArgumentError,
      );
      expect(
        () => diff.prepare(
          oldRecords: [oldRecord()],
          desired: desired(path: '/old/skill/child'),
          scope: LifecycleScope.project,
          occupiedPaths: [],
        ),
        throwsArgumentError,
      );
      final plan = desired();
      final bad = InstallationUnitPlan(
        resourceType: plan.resourceType,
        resourceId: plan.resourceId,
        nativeName: plan.nativeName,
        profile: plan.profile,
        method: plan.method,
        status: plan.status,
        installationIds: [],
        entries: [
          const InstallationEntryPlan(
            path: '/new/skill',
            kind: InstallationEntryKind.link,
            action: InstallationEntryAction.createLink,
            target: 'claude',
            artifactKind: OwnedArtifactKind.skillCopy,
          ),
        ],
        sourcePath: plan.sourcePath,
        sourceDigest: plan.sourceDigest,
        origin: plan.origin,
        installationRoute: plan.installationRoute,
      );
      expect(
        () => diff.prepare(
          oldRecords: [oldRecord()],
          desired: bad,
          scope: LifecycleScope.project,
          occupiedPaths: [],
        ),
        throwsArgumentError,
      );
    },
  );
  test('rejects a canonical plan with no canonical content', () {
    final plan = desired();
    final bad = InstallationUnitPlan(
      resourceType: plan.resourceType,
      resourceId: plan.resourceId,
      nativeName: plan.nativeName,
      profile: plan.profile,
      method: InstallationMethod.canonical,
      status: plan.status,
      installationIds: [],
      entries: plan.entries,
      sourcePath: plan.sourcePath,
      sourceDigest: plan.sourceDigest,
      origin: plan.origin,
      installationRoute: route(InstallationMethod.canonical),
    );
    expect(
      () => InstallationPathDiff(p.Context(style: p.Style.posix)).prepare(
        oldRecords: [oldRecord()],
        desired: bad,
        scope: LifecycleScope.project,
        occupiedPaths: [],
      ),
      throwsArgumentError,
    );
  });
  test('retains every record in a reviewed multi-target group', () {
    final multi = route(
      InstallationMethod.copy,
      targets: [InstallationRouteTarget.claude, InstallationRouteTarget.codex],
    );
    final actions = InstallationPathDiff(p.Context(style: p.Style.posix))
        .prepare(
          oldRecords: [
            oldRecord(routing: multi),
            oldRecord(
              routing: multi,
              path: '/old/second',
              id: 'ins_2',
              consumers: ['codex'],
            ),
          ],
          desired: desired(),
          scope: LifecycleScope.project,
          occupiedPaths: [],
        );
    expect(actions.map((action) => action.path), [
      '/old/skill',
      '/old/second',
      '/new/skill',
    ]);
    expect(
      () => InstallationPathDiff(p.Context(style: p.Style.posix)).prepare(
        oldRecords: [
          oldRecord(routing: multi),
          oldRecord(path: '/old/second', id: 'ins_2', consumers: ['codex']),
        ],
        desired: desired(),
        scope: LifecycleScope.project,
        occupiedPaths: [],
      ),
      throwsArgumentError,
    );
  });
  test('includes canonical owned content and exposure link', () {
    final record = oldRecord().copyWith(
      kind: ArtifactKind.skillCanonical,
      installationRoute: route(InstallationMethod.canonical),
      exposures: [
        const ExposureRecord(
          path: '/exposure/skill',
          target: 'claude',
          nativeKind: 'symlink',
          baseline: ArtifactBaseline([]),
        ),
      ],
    );
    final actions = InstallationPathDiff(p.Context(style: p.Style.posix))
        .prepare(
          oldRecords: [record],
          desired: desired(),
          scope: LifecycleScope.project,
          occupiedPaths: [],
        );
    expect(actions, [
      (
        path: '/old/skill',
        oldKind: OldArtifactKind.skillCanonical,
        newKind: null,
      ),
      (
        path: '/exposure/skill',
        oldKind: OldArtifactKind.skillLink,
        newKind: null,
      ),
      (path: '/new/skill', oldKind: null, newKind: NewArtifactKind.skillLink),
    ]);
  });
}
