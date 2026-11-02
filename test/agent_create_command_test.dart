import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/agent_authoring_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent create', () {
    late FileSystem fs;
    late MambaExecutor<MambaExecutionResult> executor;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      executor = createExecutor(
        agentAuthoring: AgentAuthoringService(fileSystem: fs),
      ).fake();
    });
    test(
      'plans and applies a canonical positional native creation request',
      () async {
        final sandbox = (fs.directory('/sandbox')..createSync());
        try {
          final project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          final home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync();
          final request = fs.file(fs.path.join(sandbox.path, 'create.json'))
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'schemaVersion': 1,
                'operation': 'create',
                'target': <String, Object?>{
                  'harness': 'pi',
                  'destination': 'shared',
                  'output': '.agents/agents/worker.md',
                },
                'context': <String, Object?>{'workingDirectory': './'},
                'definition': <String, Object?>{
                  'name': 'worker',
                  'description': 'Works on tasks.',
                  'model': 'kimi-coding/k3',
                  'tools': 'read, grep',
                  'thinking': 'medium',
                },
                'instructions': <Object?>['Complete the selected task.'],
              }),
            );
          final result = await executor.execute([
            'agent',
            'create',
            request.path,
            '--cwd',
            '${project.path}${fs.path.separator}',
            '--project-root',
            '${project.path}${fs.path.separator}',
            '--home',
            '${home.path}${fs.path.separator}',
            '--format',
            'json',
          ]);

          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final report = jsonDecode(
            (result as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          final data = report['data']! as Map<String, Object?>;
          expect(report['command'], 'agent create');
          expect(data['ready'], isTrue);
          expect(data['profile'], 'pi-agent-common-v1');
          expect(
            data['target'],
            isA<Map<String, Object?>>().having(
              (value) => value['destination'],
              'destination',
              'shared',
            ),
          );
          expect(result.output, isNot(contains('Complete the selected task.')));
          final output = fs.file(
            fs.path.join(project.path, '.agents', 'agents', 'worker.md'),
          );
          expect(output.existsSync(), isFalse);

          final applied = await executor.execute([
            'agent',
            'create',
            request.path,
            '--apply',
            '--plan-id',
            data['planId']! as String,
            '--yes',
            '--cwd',
            '${project.path}${fs.path.separator}',
            '--project-root',
            '${project.path}${fs.path.separator}',
            '--home',
            '${home.path}${fs.path.separator}',
            '--state-dir',
            '${fs.path.join(sandbox.path, 'state')}${fs.path.separator}',
            '--format',
            'json',
          ]);
          expect(
            applied,
            isA<MambaSuccessResult>().having(
              (value) => value.exitCode,
              'exit code',
              0,
            ),
            reason: applied is MambaFailureResult ? applied.message : null,
          );
          final appliedReport = jsonDecode(
            (applied as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          expect(appliedReport['command'], 'agent create');
          expect(appliedReport['outcome'], 'installed');
          expect(output.readAsStringSync(), '''---
description: "Works on tasks."
model: "kimi-coding/k3"
name: "worker"
thinking: "medium"
tools: "read, grep"
---
Complete the selected task.''');
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test('rejects rich flags on the bound-role compatibility path', () async {
      final sandbox = (fs.directory('/sandbox')..createSync());
      try {
        final request = fs.file(fs.path.join(sandbox.path, 'bound.json'))
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'create',
              'source': <String, Object?>{
                'kind': 'codex-role',
                'configFile': '.codex/config.toml',
                'roleKey': 'reviewer',
              },
            }),
          );
        final result = await executor.execute([
          'agent',
          'create',
          '--request',
          request.path,
          '--apply',
        ]);

        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', 1)
              .having((value) => value.output, 'output', isNull),
        );
        expect(
          (result as MambaFailureResult).message,
          contains('compatibility path'),
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
  });
}
