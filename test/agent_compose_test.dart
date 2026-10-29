import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('agent compose', () {
    test(
      'plans ordered native instructions without writing artifacts',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('agent-compose-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final request = File(p.join(sandbox.path, 'compose.json'))
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'schemaVersion': 1,
                'operation': 'compose',
                'target': <String, Object?>{
                  'harness': 'claude',
                  'output': '.claude/agents/reviewer.md',
                },
                'context': <String, Object?>{'workingDirectory': './'},
                'definition': <String, Object?>{
                  'name': 'reviewer',
                  'description': 'Reviews changes.',
                },
                'instructions': <Object?>[
                  'First review correctness.',
                  'Then review tests.',
                ],
              }),
            );
          final output = p.join(
            project.path,
            '.claude',
            'agents',
            'reviewer.md',
          );

          final first = await createExecutor().fake().execute([
            'agent',
            'compose',
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
          final second = await createExecutor().fake().execute([
            'agent',
            'compose',
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
            first,
            isA<MambaSuccessResult>(),
            reason: first is MambaFailureResult ? first.message : null,
          );
          expect(
            second,
            isA<MambaSuccessResult>(),
            reason: second is MambaFailureResult ? second.message : null,
          );
          final report = jsonDecode(
            (first as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          expect(report['command'], 'agent compose');
          expect(report['outcome'], 'planned');
          final data = report['data']! as Map<String, Object?>;
          final secondReport = jsonDecode(
            (second as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          final secondData = secondReport['data']! as Map<String, Object?>;
          expect(data['ready'], isTrue);
          expect(data['writes'], isFalse);
          expect(data['planId'], secondData['planId']);
          expect(data['instructionParts'], [25, 18]);
          expect(first.output, isNot(contains('First review correctness.')));
          expect(File(output).existsSync(), isFalse);
          expect(
            Directory(p.join(project.path, '.agent-resource')).existsSync(),
            isFalse,
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'applies only the reviewed plan through native lifecycle validation',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('agent-compose-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final request = File(p.join(sandbox.path, 'compose.json'))
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'schemaVersion': 1,
                'operation': 'compose',
                'target': <String, Object?>{
                  'harness': 'codex',
                  'output': '.codex/agents/reviewer.toml',
                },
                'context': <String, Object?>{'workingDirectory': './'},
                'definition': <String, Object?>{
                  'name': 'reviewer',
                  'description': 'Reviews changes.',
                  'model': 'openai/gpt-5',
                },
                'instructions': <Object?>[
                  'Review correctness.',
                  'Review tests.',
                ],
              }),
            );
          final context = <String>[
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
          ];
          final planned = await createExecutor().fake().execute([
            'agent',
            'compose',
            request.path,
            ...context,
          ]);
          expect(planned, isA<MambaSuccessResult>());
          final plan = jsonDecode(
            (planned as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          final planId =
              (plan['data']! as Map<String, Object?>)['planId']! as String;
          final applied = await createExecutor().fake().execute([
            'agent',
            'compose',
            request.path,
            '--apply',
            '--plan-id',
            planId,
            '--yes',
            ...context,
          ]);

          expect(
            applied,
            isA<MambaSuccessResult>(),
            reason: applied is MambaFailureResult ? applied.message : null,
          );
          final output = File(
            p.join(project.path, '.codex', 'agents', 'reviewer.toml'),
          );
          expect(output.readAsStringSync(), '''
description = "Reviews changes."
developer_instructions = "Review correctness.\\nReview tests."
model = "openai/gpt-5"
name = "reviewer"
''');
          expect(
            (jsonDecode((applied as MambaSuccessResult).output!)
                as Map<String, Object?>)['outcome'],
            'installed',
          );
          expect(request.readAsStringSync(), contains('Review correctness.'));
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'reports native candidate errors before apply without writing',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('agent-compose-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final request = File(p.join(sandbox.path, 'compose.json'))
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'schemaVersion': 1,
                'operation': 'compose',
                'target': <String, Object?>{
                  'harness': 'pi',
                  'output': '.pi/agents/worker.md',
                },
                'context': <String, Object?>{'workingDirectory': './'},
                'definition': <String, Object?>{
                  'name': 'worker',
                  'description': 'Works.',
                  'model': 'kimi-coding/k3',
                  'tools': 'read, shell',
                },
                'instructions': <Object?>['Work.'],
              }),
            );
          final result = await createExecutor().fake().execute([
            'agent',
            'compose',
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

          expect(result, isA<MambaSuccessResult>());
          final report = jsonDecode(
            (result as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          final data = report['data']! as Map<String, Object?>;
          expect(data['ready'], isFalse);
          expect(report['diagnostics'].toString(), contains('TOOLS_CATALOG'));
          expect(
            File(p.join(project.path, '.pi', 'agents', 'worker.md'))
                .existsSync(),
            isFalse,
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
