import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('agent edit', () {
    test('plans and applies an edit through a retained-backup replacement', () async {
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
          // Lifecycle coordination also covers the user state root. Keep this
          // test's lock and evidence isolated from concurrently running tests.
          '--state-dir',
          '${p.join(sandbox.path, 'state')}${p.separator}',
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

        final applied = await createExecutor().fake().execute([
          'agent',
          'edit',
          request.path,
          '--apply',
          '--plan-id',
          data['planId']! as String,
          '--yes',
          ...context,
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
        expect(appliedReport['command'], 'agent edit');
        expect(appliedReport['outcome'], 'replaced');
        final appliedData = appliedReport['data']! as Map<String, Object?>;
        final backupId = appliedData['backupId'];
        expect(backupId, isA<String>());
        expect(File(location).readAsStringSync(), '''---
description: "Edited description."
name: "reviewer"
---
Original instructions.

Edited instructions.''');

        final backups = await createExecutor().fake().execute([
          'agent',
          'backup',
          'list',
          ...context,
        ]);
        expect(
          backups,
          isA<MambaSuccessResult>().having(
            (value) => value.exitCode,
            'exit code',
            0,
          ),
        );
        final backupReport = jsonDecode(
          (backups as MambaSuccessResult).output!,
        ) as Map<String, Object?>;
        final backupData = backupReport['data']! as Map<String, Object?>;
        expect(
          (backupData['backups']! as List<Object?>).any(
            (entry) => (entry! as Map<String, Object?>)['backupId'] == backupId,
          ),
          isTrue,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
  });
}
