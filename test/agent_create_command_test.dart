import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('agent create', () {
    test(
      'plans and applies a canonical positional native creation request',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('agent-create-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final request = File(p.join(sandbox.path, 'create.json'))
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
          final result = await createExecutor().fake().execute([
            'agent',
            'create',
            request.path,
            '--cwd',
            '${project.path}${p.separator}',
            '--project-root',
            '${project.path}${p.separator}',
            '--home',
            '${home.path}${p.separator}',
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
          final output = File(
            p.join(project.path, '.agents', 'agents', 'worker.md'),
          );
          expect(output.existsSync(), isFalse);

          final applied = await createExecutor().fake().execute([
            'agent',
            'create',
            request.path,
            '--apply',
            '--plan-id',
            data['planId']! as String,
            '--yes',
            '--cwd',
            '${project.path}${p.separator}',
            '--project-root',
            '${project.path}${p.separator}',
            '--home',
            '${home.path}${p.separator}',
            '--state-dir',
            '${p.join(sandbox.path, 'state')}${p.separator}',
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
      final sandbox = await Directory.systemTemp.createTemp('agent-create-');
      try {
        final request = File(p.join(sandbox.path, 'bound.json'))
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
        final result = await createExecutor().fake().execute([
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
