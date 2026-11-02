import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/agent_graph_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent inspect graph', () {
    late FileSystem fs;
    late MambaExecutor<MambaExecutionResult> executor;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      executor = createExecutor(agentGraph: AgentGraphService(fileSystem: fs))
          .fake();
    });
    test(
      'adds bounded graph and source-qualified capability evidence',
      () async {
        final sandbox = (fs.directory('/sandbox')..createSync());
        try {
          final source = fs.file(fs.path.join(sandbox.path, 'reviewer.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews.
tools: [Read]
---
Private instructions.
''');
          final result = await executor.execute([
            'agent',
            'inspect',
            source.path,
            '--harness',
            'claude',
            '--cwd',
            '${sandbox.path}${fs.path.separator}',
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
          final graph = data['graph']! as Map<String, Object?>;
          expect(graph['complete'], isTrue);
          expect(graph['ready'], isTrue);
          expect(graph['runtimeVerification'], 'notPerformed');
          expect(graph['nodes'], isA<List<Object?>>());
          expect(graph['edges'], isA<List<Object?>>());
          expect(graph['exposureNotes'], isNotEmpty);
          expect(result.output, isNot(contains('Private instructions.')));
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test('a missing required preload makes the inspection unready', () async {
      final sandbox = (fs.directory('/sandbox')..createSync());
      try {
        final source = fs.file(fs.path.join(sandbox.path, 'reviewer.md'))
          ..writeAsStringSync('''---
name: reviewer
description: Reviews.
skills: [missing-skill]
---
Review.
''');
        final result = await executor.execute([
          'agent',
          'inspect',
          source.path,
          '--harness',
          'claude',
          '--cwd',
          '${sandbox.path}${fs.path.separator}',
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
        final data = report['data']! as Map<String, Object?>;
        final graph = data['graph']! as Map<String, Object?>;
        expect(graph['ready'], isFalse);
        expect(data['ready'], isFalse);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
  });
}
