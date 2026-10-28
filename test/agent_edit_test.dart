import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('agent edit', () {
    test('plans an edit only for an unchanged recorded installation', () async {
      final sandbox = await Directory.systemTemp.createTemp('agent-edit-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final source = File(p.join(sandbox.path, 'source.md'))
          ..writeAsStringSync('''---
name: reviewer
description: Original description.
---
Original instructions.
''');
        final context = <String>[
          '--cwd',
          '${project.path}${p.separator}',
          '--project-root',
          '${project.path}${p.separator}',
          '--home',
          '${home.path}${p.separator}',
          '--format',
          'json',
        ];
        final installed = await createExecutor().fake().execute([
          'agent',
          'install',
          source.path,
          '--source-kind',
          'resource',
          '--profile',
          'claude',
          '--target',
          'claude',
          '--scope',
          'project',
          '--yes',
          ...context,
        ]);
        expect(
          installed,
          isA<MambaSuccessResult>(),
          reason: installed is MambaFailureResult ? installed.message : null,
        );
        final installation = jsonDecode(
          (installed as MambaSuccessResult).output!,
        ) as Map<String, Object?>;
        final installationData = installation['data']! as Map<String, Object?>;
        final unit =
            (installationData['units']! as List<Object?>).single!
                as Map<String, Object?>;
        final installationId =
            (unit['installationIds']! as List<Object?>).single! as String;
        final entry =
            (unit['entries']! as List<Object?>).single! as Map<String, Object?>;
        final location = entry['path']! as String;
        final request = File(p.join(sandbox.path, 'edit.json'))
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'edit',
              'source': <String, Object?>{
                'kind': 'managed-agent',
                'installationId': installationId,
              },
              'target': <String, Object?>{
                'harness': 'claude',
                'installationId': installationId,
                'output': location,
              },
              'context': <String, Object?>{'workingDirectory': './'},
              'definition': <String, Object?>{
                'description': 'Edited description.',
              },
              'instructions': <Object?>['Edited instructions.'],
            }),
          );
        final before = File(location).readAsBytesSync();
        final result = await createExecutor().fake().execute([
          'agent',
          'edit',
          request.path,
          ...context,
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
        expect(data['ready'], isTrue);
        expect(data['writes'], isFalse);
        expect(
          data['target'],
          isA<Map<String, Object?>>().having(
            (value) => value['installationId'],
            'installation ID',
            installationId,
          ),
        );
        expect(result.output, isNot(contains('Edited instructions.')));
        expect(File(location).readAsBytesSync(), before);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
  });
}
