import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('agent clone', () {
    test(
      'plans and applies a definition-only clone with source provenance',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('agent-clone-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = File(p.join(sandbox.path, 'source.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
model: claude-sonnet
tools: [Read, Grep]
---
Review correctness.
''');
          final sourceBytes = source.readAsBytesSync();
          final request = File(p.join(sandbox.path, 'clone.json'))
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'schemaVersion': 1,
                'operation': 'clone',
                'source': <String, Object?>{
                  'kind': 'native-file',
                  'path': source.path,
                  'harness': 'claude',
                },
                'target': <String, Object?>{
                  'harness': 'claude',
                  'output': '.claude/agents/reviewer-copy.md',
                },
                'context': <String, Object?>{'workingDirectory': './'},
              }),
            );
          final output = p.join(
            project.path,
            '.claude',
            'agents',
            'reviewer-copy.md',
          );
          final result = await createExecutor().fake().execute([
            'agent',
            'clone',
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
          expect(report['command'], 'agent clone');
          expect(data['ready'], isTrue);
          expect(data['writes'], isFalse);
          expect(
            data['source'],
            isA<Map<String, Object?>>().having(
              (value) => value['profile'],
              'source profile',
              'claude-agent-native-v1',
            ),
          );
          expect(data['instructionByteLength'], 20);
          expect(result.output, isNot(contains('Review correctness.')));
          expect(source.readAsBytesSync(), sourceBytes);
          expect(File(output).existsSync(), isFalse);
          expect(
            Directory(p.join(project.path, '.agent-resource')).existsSync(),
            isFalse,
          );

          final applied = await createExecutor().fake().execute([
            'agent',
            'clone',
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
          expect(appliedReport['command'], 'agent clone');
          expect(appliedReport['outcome'], 'installed');
          expect(source.readAsBytesSync(), sourceBytes);
          expect(File(output).readAsStringSync(), '''---
description: "Reviews changes."
model: "claude-sonnet"
name: "reviewer"
tools: ["Read","Grep"]
---
Review correctness.
''');
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
