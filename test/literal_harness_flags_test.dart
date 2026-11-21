import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/agent_conversion_service.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('literal --harness CLI contract', () {
    late FileSystem fs;
    late Directory root;
    late Directory project;
    late Directory home;
    late Directory gemini;
    late MambaExecutor<MambaExecutionResult> executor;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      root = fs.directory('/sandbox')..createSync();
      project = fs.directory(fs.path.join(root.path, 'project'))..createSync();
      home = fs.directory(fs.path.join(root.path, 'home'))..createSync();
      gemini = fs.directory(fs.path.join(root.path, 'gemini'))..createSync();
      fs.directory(fs.path.join(root.path, 'state')).createSync();
      executor = createExecutor(
        fileSystem: fs,
        agentConversion: AgentConversionService(fileSystem: fs),
        guided: GuidedAuthoringService(fileSystem: fs, terminal: () => false),
      ).fake();
    });

    List<String> context() => <String>[
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

    Map<String, Object?> dataOf(MambaExecutionResult result) {
      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      return (jsonDecode((result as MambaSuccessResult).output!)
              as Map<String, Object?>)['data']!
          as Map<String, Object?>;
    }

    test('authoring, conversion and pack help expose --harness', () async {
      for (final path in <List<String>>[
        ['agent', 'create'],
        ['agent', 'edit'],
        ['agent', 'clone'],
        ['agent', 'compose'],
        ['agent', 'convert'],
        ['pack', 'install'],
        ['pack', 'discover'],
      ]) {
        final result = await executor.execute([...path, '--help']);
        expect(
          result,
          isA<MambaSuccessResult>(),
          reason:
              '${path.join(' ')}: ${result is MambaFailureResult ? result.message : ''}',
        );
        expect(
          (result as MambaSuccessResult).output,
          contains('--harness'),
          reason: path.join(' '),
        );
      }
    });

    test('agent create accepts --harness antigravity', () async {
      final data = dataOf(
        await executor.execute([
          'agent',
          'create',
          '--harness',
          'antigravity',
          '--name',
          'reviewer',
          '--description',
          'Reviews.',
          '--body-text',
          'Review carefully.',
          ...context(),
        ]),
      );
      expect(data['profile'], 'antigravity');
      expect(data['ready'], isTrue);
    });

    test('agent clone --harness overrides the request target', () async {
      final source = fs.file(fs.path.join(root.path, 'source.md'))
        ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
tools: [read]
---
Review carefully.''');
      final request = fs.file(fs.path.join(root.path, 'clone.json'))
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 1,
            'operation': 'clone',
            'source': <String, Object?>{
              'kind': 'native-file',
              'path': source.path,
              'harness': 'antigravity',
            },
            'target': <String, Object?>{
              'harness': 'claude',
              'output': '.agents/agents/copy.md',
            },
            'context': <String, Object?>{'workingDirectory': './'},
          }),
        );
      final data = dataOf(
        await executor.execute([
          'agent',
          'clone',
          request.path,
          '--harness',
          'antigravity',
          ...context(),
        ]),
      );
      expect(data['ready'], isTrue);
      expect(data['profile'], 'antigravity-agent-native-v1');
    });

    test('agent convert accepts --harness for the target', () async {
      final source = fs.file(fs.path.join(root.path, 'source.md'))
        ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
model: claude-sonnet
tools: [Read]
effort: high
---
Review carefully.''');
      final request = fs.file(fs.path.join(root.path, 'convert.json'))
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
              'harness': 'claude',
              'output': '.agents/agents/converted.md',
            },
            'context': <String, Object?>{'workingDirectory': './'},
            'decisions': <Object?>['map:tools', 'omit:model', 'omit:effort'],
          }),
        );
      final data = dataOf(
        await executor.execute([
          'agent',
          'convert',
          request.path,
          '--harness',
          'antigravity',
          ...context(),
        ]),
      );
      expect(data['targetProfile'], 'antigravity-agent-native-v1');
    });
  });
}
