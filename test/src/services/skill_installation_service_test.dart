import 'dart:io';

import 'package:agent_resource/src/installation/installation_interaction.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/installation/installation_request.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_installation_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SkillInstallationService', () {
    test(
      'plans a durable local source link without management writes',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'skill-workflow-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = Directory(p.join(sandbox.path, 'source'))
            ..createSync();
          File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
          );
          final result =
              await SkillInstallationService(
                interaction: InteractInstallationInteraction(
                  terminal: () => false,
                ),
              ).run(
                InstallationWorkflowRequest(
                  source: source.path,
                  options: LifecycleOptions(
                    processWorkingDirectory: project.path,
                    scope: LifecycleScope.project,
                    cwd: project.path,
                    projectRoot: project.path,
                    home: home.path,
                    dryRun: true,
                  ),
                  sourceKind: AcquisitionSourceKind.resource,
                  resourceIds: const [],
                  allResources: false,
                  targets: const [InstallationTarget.claude],
                  method: InstallationMethod.sourceLink,
                  profile: null,
                  ref: null,
                  subpath: null,
                  scopeExplicit: true,
                ),
                interactive: false,
              );
          expect(result, isA<InstallationCompletedResult>());
          final completed = result as InstallationCompletedResult;
          expect(completed.outcome, InstallationOutcome.planned);
          expect(
            completed.plan.units.single.method,
            InstallationMethod.sourceLink,
          );
          expect(
            completed.plan.units.single.entries.single.linkTarget,
            source.path,
          );
          expect(project.listSync(recursive: true), isEmpty);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
