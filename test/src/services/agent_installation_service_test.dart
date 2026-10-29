import 'dart:io';

import 'package:agent_resource/src/installation/installation_interaction.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/installation/installation_request.dart';
import 'package:agent_resource/src/installation/resource_catalog.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/agent_installation_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AgentInstallationService', () {
    test(
      'plans an explicitly profiled native file copy without writes',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-workflow-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final claude = Directory(p.join(sandbox.path, 'claude'))
            ..createSync();
          final source = File(p.join(sandbox.path, 'reviewer.md'))
            ..writeAsStringSync(
              '---\nname: reviewer\ndescription: Reviews.\n---\nBody.\n',
            );
          final result =
              await AgentInstallationService(
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
                    claudeConfigDir: claude.path,
                    dryRun: true,
                  ),
                  sourceKind: AcquisitionSourceKind.resource,
                  resourceIds: const [],
                  allResources: false,
                  targets: const [InstallationTarget.claude],
                  method: null,
                  profile: NativeAgentProfile.claude,
                  ref: null,
                  subpath: null,
                  scopeExplicit: true,
                ),
                interactive: false,
              );
          expect(result, isA<InstallationCompletedResult>());
          final completed = result as InstallationCompletedResult;
          expect(completed.outcome, InstallationOutcome.planned);
          expect(completed.plan.units.single.profile, 'claude');
          expect(completed.plan.units.single.method, InstallationMethod.copy);
          expect(project.listSync(recursive: true), isEmpty);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
