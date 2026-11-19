import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/agent_conversion_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent convert command covers every ordered direction', () {
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

    String nativeSource(String harness) => switch (harness) {
      'claude' =>
        '''---
name: reviewer
description: Reviews changes.
model: claude-sonnet
effort: high
tools: [Read, Grep]
---
Review correctness.
''',
      'codex' =>
        '''name = "reviewer"
description = "Reviews changes."
model = "openai/gpt-5"
model_reasoning_effort = "high"
developer_instructions = "Review correctness.\\n"
''',
      'pi' =>
        '''---
name: reviewer
description: Reviews changes.
model: kimi-coding/k3
thinking: high
tools: read, grep
---
Review correctness.
''',
      'antigravity' =>
        '''---
name: reviewer
description: Reviews changes.
tools: [read, grep]
mainAgent: true
---
Review correctness.
''',
      _ => throw StateError('Unsupported harness: $harness'),
    };

    String outputFor(String harness) => switch (harness) {
      'claude' => '.claude/agents/reviewer.md',
      'codex' => '.codex/agents/reviewer.toml',
      'pi' => '.pi/agents/reviewer.md',
      'antigravity' => '.agents/agents/reviewer.md',
      _ => throw StateError('Unsupported harness: $harness'),
    };

    Map<String, Object?> definitionFor(String harness) => switch (harness) {
      'claude' => <String, Object?>{
        'model': 'claude-sonnet',
        'effort': 'high',
        'tools': <Object?>['Read'],
      },
      'codex' => <String, Object?>{
        'model': 'openai/gpt-5',
        'model_reasoning_effort': 'high',
      },
      'pi' => <String, Object?>{
        'model': 'kimi-coding/k3',
        'thinking': 'high',
        'tools': 'read, grep',
      },
      'antigravity' => <String, Object?>{
        'tools': <Object?>['read'],
        'mainAgent': true,
      },
      _ => throw StateError('Unsupported harness: $harness'),
    };

    Set<String> decisionsFor(String source, String target) => <String>{
      if (target != 'antigravity') ...<String>['map:model', 'map:effort'],
      if (target == 'antigravity') ...<String>[
        if (source != 'antigravity') 'omit:model',
        if (source != 'antigravity') 'omit:effort',
        'map:tools',
        'map:mainAgent',
      ],
      if (target == 'pi' || target == 'claude') 'map:tools',
      if (source != 'codex' && target == 'codex') 'omit:tools',
      if (source == 'antigravity' && target != 'antigravity') 'omit:mainAgent',
    };

    const directions = <({String source, String target})>[
      (source: 'claude', target: 'codex'),
      (source: 'claude', target: 'pi'),
      (source: 'codex', target: 'claude'),
      (source: 'codex', target: 'pi'),
      (source: 'pi', target: 'claude'),
      (source: 'pi', target: 'codex'),
      (source: 'claude', target: 'antigravity'),
      (source: 'codex', target: 'antigravity'),
      (source: 'pi', target: 'antigravity'),
      (source: 'antigravity', target: 'claude'),
      (source: 'antigravity', target: 'codex'),
      (source: 'antigravity', target: 'pi'),
    ];

    for (final direction in directions) {
      test('${direction.source} to ${direction.target}', () async {
        final source = fs.file(
          fs.path.join(
            root.path,
            'source${direction.source == 'codex' ? '.toml' : '.md'}',
          ),
        )..writeAsStringSync(nativeSource(direction.source));
        final sourceBytes = source.readAsBytesSync();
        final request = fs.file(fs.path.join(root.path, 'convert.json'))
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'convert',
              'source': <String, Object?>{
                'kind': 'native-file',
                'path': source.path,
                'harness': direction.source,
              },
              'target': <String, Object?>{
                'harness': direction.target,
                'output': outputFor(direction.target),
              },
              'context': <String, Object?>{'workingDirectory': './'},
              'definition': definitionFor(direction.target),
              'decisions': decisionsFor(
                direction.source,
                direction.target,
              ).toList()..sort(),
            }),
          );
        final output = fs.file(
          fs.path.join(project.path, outputFor(direction.target)),
        );
        final planned = dataOf(
          await executor.execute([
            'agent',
            'convert',
            request.path,
            ...context(),
          ]),
        );
        expect(
          planned['ready'],
          isTrue,
          reason: planned['diagnostics']?.toString(),
        );
        expect(output.existsSync(), isFalse);
        final applied = dataOf(
          await executor.execute([
            'agent',
            'convert',
            request.path,
            '--apply',
            '--plan-id',
            planned['planId']! as String,
            '--yes',
            ...context(),
          ]),
        );
        expect(output.existsSync(), isTrue);
        expect(output.readAsStringSync(), contains('Review correctness.'));
        expect(source.readAsBytesSync(), sourceBytes);
      });
    }
  });
}
