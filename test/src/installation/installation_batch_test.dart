import 'dart:io';

import 'package:agent_resource/src/installation/installation_batch.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/installation/installation_request.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/installation_test_support.dart';

void main() {
  group('InstallationBatch', () {
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
