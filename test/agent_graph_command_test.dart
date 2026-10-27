import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('agent inspect graph', () {
    test(
      'adds bounded graph and source-qualified capability evidence',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-graph-command-',
        );
        try {
          final source = File(p.join(sandbox.path, 'reviewer.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews.
tools: [Read]
---
Private instructions.
''');
          final result = await createExecutor().fake().execute([
            'agent',
            'inspect',
            source.path,
            '--harness',
            'claude',
            '--cwd',
            '${sandbox.path}${p.separator}',
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
  });
}
