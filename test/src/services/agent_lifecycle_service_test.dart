import 'dart:io';

import 'package:agent_resource/src/agent_inspection.dart';
import 'package:agent_resource/src/services/agent_lifecycle_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AgentLifecycleService', () {
    test(
      'Claude install preserves file bytes and recursive output placement',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('agent-install-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = File(p.join(sandbox.path, 'source.md'))
            ..writeAsStringSync(
              '---\nname: reviewer\ndescription: Reviews.\n---\nExact body.\n',
            );
          final output = p.join(
            project.path,
            '.claude',
            'agents',
            'team',
            'review.md',
          );
          final service = AgentLifecycleService();
          final result = await service.install(
            AgentInstallInput(
              options: LifecycleOptions(
                processWorkingDirectory: project.path,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
              ),
              source: source.path,
              harness: AgentHarness.claude,
              output: output,
            ),
          );

          expect(result.outcome, 'installed');
          expect(File(output).readAsBytesSync(), source.readAsBytesSync());
          final records = service.state.records(
            LifecycleContext.resolve(
              LifecycleOptions(
                processWorkingDirectory: project.path,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
              ),
            ),
          );
          expect(records, hasLength(1));
          expect(records.single.nativeProfile, 'claude');
          expect(records.single.nativeForm, 'claude-agent-file');
          expect(records.single.location, output);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'Pi shared adoption requires an immediate regular Markdown file',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('agent-adopt-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final file = File(
            p.join(project.path, '.agents', 'agents', 'worker.md'),
          )..createSync(recursive: true);
          file.writeAsStringSync(
            '---\nname: worker\ndescription: Works.\nmodel: kimi-coding/k3\n'
            'tools: read, grep, find, ls\n---\nWork.\n',
          );
          final service = AgentLifecycleService();
          final result = await service.adopt(
            AgentInstallInput(
              options: LifecycleOptions(
                processWorkingDirectory: project.path,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
              ),
              source: file.path,
              harness: AgentHarness.pi,
              destination: AgentDestination.shared,
            ),
          );
          expect(result.outcome, 'adopted');
          expect(result.data['location'], file.path);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
    test('documented builtin names refuse Agent installation', () async {
      final sandbox = await Directory.systemTemp.createTemp('agent-builtin-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final source = File(p.join(sandbox.path, 'worker.toml'))
          ..writeAsStringSync(
            'name = "worker"\ndescription = "Works."\n'
            'developer_instructions = "Work."\n',
          );
        try {
          await AgentLifecycleService().install(
            AgentInstallInput(
              options: LifecycleOptions(
                processWorkingDirectory: project.path,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                dryRun: true,
              ),
              source: source.path,
              harness: AgentHarness.codex,
            ),
          );
          fail('A builtin collision unexpectedly passed.');
        } on MambaException catch (error) {
          expect(error.exitCode, 4);
          expect(error.message, contains('builtin'));
        }
        expect(Directory(p.join(project.path, '.codex')).existsSync(), isFalse);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
  });
}
