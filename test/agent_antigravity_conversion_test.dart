import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/agent_conversion_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent convert with Antigravity', () {
    late FileSystem fs;
    late MambaExecutor<MambaExecutionResult> executor;
    late Directory project;
    late Directory home;
    late Directory gemini;
    late List<String> context;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      final root = fs.directory('/sandbox')..createSync();
      project = fs.directory(fs.path.join(root.path, 'project'))..createSync();
      home = fs.directory(fs.path.join(root.path, 'home'))..createSync();
      gemini = fs.directory(fs.path.join(root.path, 'gemini'))..createSync();
      fs.directory(fs.path.join(root.path, 'state')).createSync();
      executor = createExecutor(
        agentConversion: AgentConversionService(fileSystem: fs),
      ).fake();
      context = <String>[
        '--cwd',
        '${project.path}${fs.path.separator}',
        '--project-root',
        '${project.path}${fs.path.separator}',
        '--home',
        '${home.path}${fs.path.separator}',
        '--gemini-dir',
        '${gemini.path}${fs.path.separator}',
        '--state-dir',
        '${fs.path.join(root.path, 'state')}${fs.path.separator}',
        '--format',
        'json',
      ];
    });

    Map<String, Object?> dataOf(MambaExecutionResult result) {
      expect(
        result,
        isA<MambaSuccessResult>()
            .having((value) => value.exitCode, 'exit code', 0)
            .having((value) => value.output, 'output', isNotNull),
        reason: result is MambaFailureResult ? result.message : null,
      );
      final report = jsonDecode(
        (result as MambaSuccessResult).output!,
      ) as Map<String, Object?>;
      return report['data']! as Map<String, Object?>;
    }

    Future<void> applyRequest(File request, Map<String, Object?> plan) async {
      final applied = await executor.execute(<String>[
        'agent',
        'convert',
        request.path,
        '--apply',
        '--plan-id',
        plan['planId']! as String,
        '--yes',
        ...context,
      ]);
      final report = jsonDecode(
        (applied as MambaSuccessResult).output!,
      ) as Map<String, Object?>;
      expect(report['outcome'], 'converted');
    }

    test('plans and publishes a Claude to Antigravity conversion', () async {
      final source = fs.file('/sandbox/source.md')
        ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
model: claude-sonnet
tools: [Read]
effort: high
---
Review carefully.''');
      final sourceBytes = source.readAsBytesSync();
      final request = fs.file('/sandbox/convert.json')
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
              'harness': 'antigravity',
              'output': '.agents/agents/reviewer.md',
            },
            'context': <String, Object?>{'workingDirectory': './'},
            'definition': <String, Object?>{
              'tools': <Object?>['read'],
            },
            'decisions': <Object?>['map:tools', 'omit:model', 'omit:effort'],
          }),
        );
      final planned = await executor.execute([
        'agent',
        'convert',
        request.path,
        ...context,
      ]);
      final plan = dataOf(planned);
      expect(plan['ready'], isTrue);
      expect(plan['sourceProfile'], 'claude-agent-native-v1');
      expect(plan['targetProfile'], 'antigravity-agent-native-v1');
      expect(plan['sourcePreserved'], isTrue);
      final fields = plan['fields']! as List<Object?>;
      expect(
        fields.cast<Map<String, Object?>>().any(
          (field) =>
              field['sourcePath'] == 'model' && field['outcome'] == 'omitted',
        ),
        isTrue,
      );
      final output = fs.file(
        fs.path.join(project.path, '.agents', 'agents', 'reviewer.md'),
      );
      expect(output.existsSync(), isFalse);
      await applyRequest(request, plan);
      expect(output.existsSync(), isTrue);
      expect(output.readAsStringSync(), contains('tools: ["read"]'));
      expect(output.readAsStringSync(), isNot(contains('model:')));
      expect(source.readAsBytesSync(), sourceBytes);
    });

    test('plans and publishes an Antigravity to Claude conversion', () async {
      final source = fs.file('/sandbox/source.md')
        ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
tools: [read]
mainAgent: true
---
Review carefully.''');
      final sourceBytes = source.readAsBytesSync();
      final request = fs.file('/sandbox/convert.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 1,
            'operation': 'convert',
            'source': <String, Object?>{
              'kind': 'native-file',
              'path': source.path,
              'harness': 'antigravity',
            },
            'target': <String, Object?>{
              'harness': 'claude',
              'output': '.claude/agents/reviewer.md',
            },
            'context': <String, Object?>{'workingDirectory': './'},
            'definition': <String, Object?>{
              'model': 'claude-sonnet',
              'effort': 'high',
              'tools': <Object?>['Read'],
            },
            'decisions': <Object?>[
              'map:model',
              'map:effort',
              'map:tools',
              'omit:mainAgent',
            ],
          }),
        );
      final planned = await executor.execute([
        'agent',
        'convert',
        request.path,
        ...context,
      ]);
      final plan = dataOf(planned);
      expect(plan['ready'], isTrue);
      expect(plan['sourceProfile'], 'antigravity-agent-native-v1');
      final output = fs.file(
        fs.path.join(project.path, '.claude', 'agents', 'reviewer.md'),
      );
      expect(output.existsSync(), isFalse);
      await applyRequest(request, plan);
      expect(output.readAsStringSync(), contains('model: "claude-sonnet"'));
      expect(source.readAsBytesSync(), sourceBytes);
    });
  });
}
