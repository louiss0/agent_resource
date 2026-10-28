import 'dart:async';
import 'dart:io';

import 'package:agent_resource/src/installation/installation_batch.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/installation/installation_request.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/installation_test_support.dart';

final class _FakeState implements LifecycleStateService {
  _FakeState(this.handler);

  final Future<ResourceUnitPublicationResult> Function(InstallationUnitPlan)
  handler;

  @override
  Future<ResourceUnitPublicationResult> installResourceUnit({
    required LifecycleResource resource,
    required LifecycleContext context,
    required InstallationUnitPlan unit,
  }) => handler(unit);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeResource implements LifecycleResource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

InstallationUnitPlan _unit(String id, {String? path}) => InstallationUnitPlan(
  resourceType: InstallationResourceType.skill,
  resourceId: id,
  nativeName: id,
  profile: null,
  method: InstallationMethod.copy,
  status: InstallationUnitStatus.planned,
  installationIds: const [],
  entries: [
    InstallationEntryPlan(
      path: path ?? '/$id',
      kind: InstallationEntryKind.copy,
      action: InstallationEntryAction.createCopy,
      artifactKind: OwnedArtifactKind.skillCopy,
    ),
  ],
  sourcePath: '/$id-source',
  sourceDigest: '$id-digest',
  origin: const {'status': 'evidenced'},
);

InstallationPlan _plan(List<InstallationUnitPlan> units) =>
    InstallationPlan.create(
      command: 'skill install',
      source: const AcquisitionProvenance(
        kind: AcquisitionLocatorKind.local,
        requestedLocator: 'source',
        resolvedLocator: 'source',
        subpath: null,
        temporary: false,
        directFile: false,
        durableLocalDirectory: true,
      ),
      scope: 'project',
      units: units,
    );

LifecycleContext _context(Directory project, Directory home) =>
    LifecycleContext.resolve(
      LifecycleOptions(
        processWorkingDirectory: project.path,
        scope: LifecycleScope.project,
        cwd: project.path,
        projectRoot: project.path,
        home: home.path,
      ),
    );

void main() {
  group('InstallationBatch', () {
    test(
      'restored failures skip dependents and continue independent units',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'batch-continue-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final attempted = <String>[];
          final state = _FakeState((unit) async {
            attempted.add(unit.resourceId);
            if (unit.resourceId == 'one') {
              throw MambaException('restored failure', exitCode: 5);
            }
            return const ResourceUnitPublicationResult(
              status: InstallationUnitStatus.installed,
              installationIds: ['ins_three'],
              transactionId: 'trx_three',
            );
          });
          await expectLater(
            () => InstallationBatch().execute(
              plan: _plan([
                _unit('one', path: '/shared'),
                _unit('two', path: '/shared'),
                _unit('three', path: '/independent'),
              ]),
              context: _context(project, home),
              state: state,
              resourceFor: (_) => _FakeResource(),
              interaction: ScriptedInstallationInteraction(),
              interactive: false,
              approved: true,
            ),
            throwsA(
              isA<MambaException>()
                  .having((error) => error.exitCode, 'status', 5)
                  .having(
                    (error) => error.message,
                    'message',
                    contains('not-started'),
                  )
                  .having(
                    (error) => error.message,
                    'message',
                    contains('installed'),
                  ),
            ),
          );
          expect(attempted, ['one', 'three']);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'recovery uncertainty stops every remaining unit with status six',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('batch-stop-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final attempted = <String>[];
          final state = _FakeState((unit) async {
            attempted.add(unit.resourceId);
            throw MambaException('recovery required', exitCode: 6);
          });
          await expectLater(
            () => InstallationBatch().execute(
              plan: _plan([_unit('one'), _unit('two')]),
              context: _context(project, home),
              state: state,
              resourceFor: (_) => _FakeResource(),
              interaction: ScriptedInstallationInteraction(),
              interactive: false,
              approved: true,
            ),
            throwsA(
              isA<MambaException>()
                  .having((error) => error.exitCode, 'status', 6)
                  .having(
                    (error) => error.message,
                    'message',
                    contains('not-started'),
                  ),
            ),
          );
          expect(attempted, ['one']);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'post-write interruption retains success and prevents new units',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'batch-interrupt-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final interruption = StreamController<void>();
          final attempted = <String>[];
          final state = _FakeState((unit) async {
            attempted.add(unit.resourceId);
            interruption.add(null);
            return const ResourceUnitPublicationResult(
              status: InstallationUnitStatus.installed,
              installationIds: ['ins_one'],
              transactionId: 'trx_one',
            );
          });
          final execution = InstallationBatch(interruption: interruption.stream)
              .execute(
                plan: _plan([_unit('one'), _unit('two')]),
                context: _context(project, home),
                state: state,
                resourceFor: (_) => _FakeResource(),
                interaction: ScriptedInstallationInteraction(),
                interactive: false,
                approved: true,
              );
          await expectLater(
            () => execution,
            throwsA(
              isA<MambaException>().having(
                (error) => error.exitCode,
                'status',
                7,
              ),
            ),
          );
          expect(attempted, ['one']);
          await interruption.close();
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test('pre-write decline cancels without invoking publication', () async {
      final sandbox = await Directory.systemTemp.createTemp('batch-cancel-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final context = LifecycleContext.resolve(
          LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          ),
        );
        final unit = InstallationUnitPlan(
          resourceType: InstallationResourceType.skill,
          resourceId: 'review',
          nativeName: 'review',
          profile: null,
          method: InstallationMethod.copy,
          status: InstallationUnitStatus.planned,
          installationIds: const [],
          entries: const [],
          sourcePath: 'unused',
          sourceDigest: 'unused',
          origin: const {'status': 'evidenced'},
        );
        final plan = InstallationPlan.create(
          command: 'skill install',
          source: const AcquisitionProvenance(
            kind: AcquisitionLocatorKind.local,
            requestedLocator: 'source',
            resolvedLocator: 'source',
            subpath: null,
            temporary: false,
            directFile: false,
            durableLocalDirectory: true,
          ),
          scope: 'project',
          units: [unit],
        );
        final interaction = ScriptedInstallationInteraction()
          ..approvals.add(false);
        final result = await InstallationBatch().execute(
          plan: plan,
          context: context,
          state: LifecycleStateService(),
          resourceFor: (unit) => throw StateError('Publication must not start'),
          interaction: interaction,
          interactive: true,
          approved: false,
        );
        expect(result, isA<InstallationCancelledResult>());
        expect(project.listSync(recursive: true), isEmpty);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
  });
}
