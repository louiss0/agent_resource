import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('agent convert', () {
    test(
      'plans Claude to Codex with typed field outcomes and no source writes',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('agent-convert-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = File(p.join(sandbox.path, 'reviewer.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
model: claude-sonnet
tools: [Read, Grep]
effort: high
---
Review correctness.
''');
          final sourceBytes = source.readAsBytesSync();
          final request = File(p.join(sandbox.path, 'convert.json'))
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'schemaVersion': 1,
                'operation': 'convert',
                'source': <String, Object?>{
                  'kind': 'native-file',
                  'path': source.path,
                  'harness': 'claude',
                },
                'target': <String, Object?>{
                  'harness': 'codex',
                  'output': '.codex/agents/reviewer.toml',
                },
                'context': <String, Object?>{'workingDirectory': './'},
                'definition': <String, Object?>{
                  'model': 'openai/gpt-5',
                  'model_reasoning_effort': 'high',
                },
                'decisions': <Object?>['omit:tools', 'map:model', 'map:effort'],
              }),
            );
          final output = p.join(
            project.path,
            '.codex',
            'agents',
            'reviewer.toml',
          );
          final result = await createExecutor().fake().execute([
            'agent',
            'convert',
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
            isA<MambaSuccessResult>().having(
              (value) => value.exitCode,
              'exit code',
              0,
            ),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final report = jsonDecode(
            (result as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          expect(report['command'], 'agent convert');
          expect(report['outcome'], 'planned');
          final data = report['data']! as Map<String, Object?>;
          expect(data['ready'], isTrue);
          expect(data['sourceProfile'], 'claude-agent-native-v1');
          expect(data['targetProfile'], 'codex-agent-native-v1');
          expect(data['sourcePreserved'], isTrue);
          final fields = data['fields']! as List<Object?>;
          expect(fields, hasLength(greaterThanOrEqualTo(5)));
          final outcomes = fields
              .map((field) => (field! as Map<String, Object?>)['outcome'])
              .toSet();
          expect(
            outcomes,
            containsAll(<Object?>['represented', 'altered', 'omitted']),
          );
          expect(result.output, isNot(contains('Review correctness.')));
          expect(source.readAsBytesSync(), sourceBytes);
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
    test('applies a reviewed Claude to common-Pi conversion', () async {
      final sandbox = await Directory.systemTemp.createTemp('agent-convert-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final source = File(p.join(sandbox.path, 'reviewer.md'))
          ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
model: claude-sonnet
tools: [Read]
effort: high
---
Review carefully.
''');
        final sourceBytes = source.readAsBytesSync();
        final request = File(p.join(sandbox.path, 'convert.json'))
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'convert',
              'source': <String, Object?>{
                'kind': 'native-file',
                'path': source.path,
                'harness': 'claude',
              },
              'target': <String, Object?>{
                'harness': 'pi',
                'output': '.pi/agents/reviewer.md',
              },
              'context': <String, Object?>{'workingDirectory': './'},
              'definition': <String, Object?>{
                'model': 'kimi-coding/k3',
                'thinking': 'high',
                'tools': 'read',
              },
              'decisions': <Object?>['map:model', 'map:effort', 'map:tools'],
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
          'convert',
          request.path,
          ...context,
        ]);
        expect(
          planned,
          isA<MambaSuccessResult>().having(
            (value) => value.exitCode,
            'exit code',
            0,
          ),
          reason: planned is MambaFailureResult ? planned.message : null,
        );
        final plan = jsonDecode(
          (planned as MambaSuccessResult).output!,
        ) as Map<String, Object?>;
        final planData = plan['data']! as Map<String, Object?>;
        expect(planData['ready'], isTrue);
        final output = File(
          p.join(project.path, '.pi', 'agents', 'reviewer.md'),
        );
        expect(output.existsSync(), isFalse);

        final applied = await createExecutor().fake().execute([
          'agent',
          'convert',
          request.path,
          '--apply',
          '--plan-id',
          planData['planId']! as String,
          '--yes',
          ...context,
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
        expect(appliedReport['command'], 'agent convert');
        expect(appliedReport['outcome'], 'converted');
        final content = output.readAsStringSync();
        expect(content, contains('name: "reviewer"'));
        expect(content, contains('model: "kimi-coding/k3"'));
        expect(content, contains('tools: "read"'));
        expect(content, endsWith('Review carefully.\n'));
        expect(source.readAsBytesSync(), sourceBytes);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test('refuses to apply a conversion with unresolved decisions', () async {
      final sandbox = await Directory.systemTemp.createTemp('agent-convert-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final source = File(p.join(sandbox.path, 'reviewer.md'))
          ..writeAsStringSync('''---
name: reviewer
description: Reviews.
model: claude-sonnet
tools: [Read]
---
Review.
''');
        final request = File(p.join(sandbox.path, 'convert.json'))
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'convert',
              'source': <String, Object?>{
                'kind': 'native-file',
                'path': source.path,
                'harness': 'claude',
              },
              'target': <String, Object?>{
                'harness': 'codex',
                'output': '.codex/agents/reviewer.toml',
              },
              'context': <String, Object?>{'workingDirectory': './'},
              'definition': <String, Object?>{'model': 'openai/gpt-5'},
              'decisions': <Object?>['omit:tools'],
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
          'convert',
          request.path,
          ...context,
        ]);
        expect(
          planned,
          isA<MambaSuccessResult>().having(
            (value) => value.exitCode,
            'exit code',
            0,
          ),
          reason: planned is MambaFailureResult ? planned.message : null,
        );
        final plan = jsonDecode(
          (planned as MambaSuccessResult).output!,
        ) as Map<String, Object?>;
        final planData = plan['data']! as Map<String, Object?>;
        expect(planData['ready'], isFalse);
        expect(planData['writes'], isFalse);

        final applied = await createExecutor().fake().execute([
          'agent',
          'convert',
          request.path,
          '--apply',
          '--plan-id',
          planData['planId']! as String,
          '--yes',
          ...context,
        ]);
        expect(
          applied,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', 4)
              .having(
                (value) => value.message,
                'message',
                'Conversion has unresolved fields or incomplete native readiness.',
              )
              .having((value) => value.output, 'output', isNull)
              .having(
                (value) => value.error.phase,
                'phase',
                MambaExecutionPhase.run,
              )
              .having((value) => value.error.commandPath, 'command path', [
                'agent_resource',
                'agent',
                'convert',
              ]),
        );
        expect(
          File(p.join(project.path, '.codex', 'agents', 'reviewer.toml'))
              .existsSync(),
          isFalse,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
  });
}
