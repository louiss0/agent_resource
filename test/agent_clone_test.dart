import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/agent_authoring_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent clone', () {
    late FileSystem fs;
    late MambaExecutor<MambaExecutionResult> executor;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      executor = createExecutor(
        agentAuthoring: AgentAuthoringService(fileSystem: fs),
      ).fake();
    });
    test(
      'plans and applies a definition-only clone with source provenance',
      () async {
        final sandbox = (fs.directory('/sandbox')..createSync());
        try {
          final project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          final home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync();
          final source = fs.file(fs.path.join(sandbox.path, 'source.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
model: claude-sonnet
tools: [Read, Grep]
---
Review correctness.
''');
          final sourceBytes = source.readAsBytesSync();
          final request = fs.file(fs.path.join(sandbox.path, 'clone.json'))
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
          final output = fs.path.join(
            project.path,
            '.claude',
            'agents',
            'reviewer-copy.md',
          );
          final result = await executor.execute([
            'agent',
            'clone',
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
          expect(fs.file(output).existsSync(), isFalse);
          expect(
            fs
                .directory(fs.path.join(project.path, '.agent-resource'))
                .existsSync(),
            isFalse,
          );

          final applied = await executor.execute([
            'agent',
            'clone',
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
          expect(appliedReport['command'], 'agent clone');
          expect(appliedReport['outcome'], 'installed');
          expect(source.readAsBytesSync(), sourceBytes);
          expect(fs.file(output).readAsStringSync(), '''---
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
