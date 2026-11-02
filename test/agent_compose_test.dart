import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/agent_authoring_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent compose', () {
    late FileSystem fs;
    late MambaExecutor<MambaExecutionResult> executor;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      executor = createExecutor(
        agentAuthoring: AgentAuthoringService(fileSystem: fs),
      ).fake();
    });
    test(
      'plans ordered native instructions without writing artifacts',
      () async {
        final sandbox = (fs.directory('/sandbox')..createSync());
        try {
          final project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          final home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync();
          final request = fs.file(fs.path.join(sandbox.path, 'compose.json'))
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
          final output = fs.path.join(
            project.path,
            '.claude',
            'agents',
            'reviewer.md',
          );

          final first = await executor.execute([
            'agent',
            'compose',
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
          final second = await executor.execute([
            'agent',
            'compose',
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
          expect(fs.file(output).existsSync(), isFalse);
          expect(
            fs
                .directory(fs.path.join(project.path, '.agent-resource'))
                .existsSync(),
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
        final sandbox = (fs.directory('/sandbox')..createSync());
        try {
          final project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          final home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync();
          final request = fs.file(fs.path.join(sandbox.path, 'compose.json'))
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
            '${project.path}${fs.path.separator}',
            '--project-root',
            '${project.path}${fs.path.separator}',
            '--home',
            '${home.path}${fs.path.separator}',
            '--state-dir',
            '${fs.path.join(sandbox.path, 'state')}${fs.path.separator}',
            '--format',
            'json',
          ];
          final planned = await executor.execute([
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
          final applied = await executor.execute([
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
          final output = fs.file(
            fs.path.join(project.path, '.codex', 'agents', 'reviewer.toml'),
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
        final sandbox = (fs.directory('/sandbox')..createSync());
        try {
          final project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          final home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync();
          final request = fs.file(fs.path.join(sandbox.path, 'compose.json'))
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
          final result = await executor.execute([
            'agent',
            'compose',
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

          expect(result, isA<MambaSuccessResult>());
          final report = jsonDecode(
            (result as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          final data = report['data']! as Map<String, Object?>;
          expect(data['ready'], isFalse);
          expect(report['diagnostics'].toString(), contains('TOOLS_CATALOG'));
          expect(
            fs
                .file(fs.path.join(project.path, '.pi', 'agents', 'worker.md'))
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
