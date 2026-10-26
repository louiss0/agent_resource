import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/services/bound_role_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('BoundRoleService', () {
    test(
      'create plans by default and publishes definition plus registration',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('bound-create-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
          final config = File(p.join(project.path, '.codex', 'config.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# keep\n');
          final source = File(p.join(sandbox.path, 'reviewer.toml'))
            ..writeAsStringSync(
              'name = "reviewer"\ndescription = "Reviews changes."\n'
              'developer_instructions = "Review."\n',
            );
          final service = BoundRoleService();
          LifecycleOptions options({
            bool approved = false,
            bool dryRun = false,
          }) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            codexHome: codex.path,
            approved: approved,
            dryRun: dryRun,
          );
          final request = BoundRoleRequest(
            operation: BoundOperation.create,
            configFile: p.join(project.path, '.codex', 'config.toml'),
            roleKey: 'reviewer',
            ownership: BoundOwnership.both,
            source: source.path,
            output: p.join(project.path, '.codex', 'agents', 'reviewer.toml'),
            clientsStopped: true,
          );
          final planned = await service.run(request, options(dryRun: true));
          expect(planned.outcome, 'planned');
          expect(
            File(p.join(project.path, '.codex', 'agents', 'reviewer.toml'))
                .existsSync(),
            isFalse,
          );
          expect(config.readAsStringSync(), '# keep\n');
          final planId = planned.data['planId']! as String;
          final applied = await service.run(
            BoundRoleRequest(
              operation: BoundOperation.create,
              configFile: request.configFile,
              roleKey: request.roleKey,
              ownership: request.ownership,
              source: request.source,
              output: request.output,
              planId: planId,
              clientsStopped: true,
            ),
            options(approved: true),
          );
          expect(applied.outcome, 'created');
          final installed = File(
            p.join(project.path, '.codex', 'agents', 'reviewer.toml'),
          );
          expect(installed.existsSync(), isTrue);
          final text = config.readAsStringSync();
          expect(text, contains('# keep'));
          expect(text, contains('[agents.reviewer]'));
          expect(text, contains('config_file ='));
          expect(text, contains('reviewer.toml'));
          expect(text, contains('description = "Reviews changes."'));
          expect(applied.data['registrationCommitted'], isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test('request parsing rejects operation/source ambiguity', () async {
      final sandbox = await Directory.systemTemp.createTemp('bound-request-');
      try {
        final request = File(p.join(sandbox.path, 'request.json'))
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'create',
              'source': <String, Object?>{
                'kind': 'codex-role',
                'configFile': '.codex/config.toml',
                'roleKey': 'reviewer',
              },
              'ownership': 'both',
              'definition': <String, Object?>{'source': 'reviewer.toml'},
              'unexpected': true,
            }),
          );
        expect(
          () => parseBoundRoleRequest(request.path, sandbox.path),
          throwsA(isA<MambaException>()),
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
  });
}
