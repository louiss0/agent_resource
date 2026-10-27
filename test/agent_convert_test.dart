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
            isA<MambaSuccessResult>(),
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
  });
}
