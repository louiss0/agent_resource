import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/parent_config_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ParentConfigService', () {
    test(
      'request validation rejects duplicate and unknown envelope fields',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'parent-request-',
        );
        try {
          File write(String name, String text) =>
              File(p.join(sandbox.path, name))..writeAsStringSync(text);
          for (final request in [
            write(
              'duplicate.json',
              '{"schemaVersion":1,"schemaVersion":1,"operation":"inspect",'
                  '"source":{"harness":"claude","scope":"project",'
                  '"layer":"project","file":".claude/settings.json"}}',
            ),
            write(
              'unknown.json',
              '{"schemaVersion":1,"operation":"inspect","unexpected":true,'
                  '"source":{"harness":"claude","scope":"project",'
                  '"layer":"project","file":".claude/settings.json"}}',
            ),
          ]) {
            expect(
              () => parseParentRequest(request.path, sandbox.path),
              throwsA(isA<MambaException>()),
            );
          }
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'Claude array membership edits preserve unrelated bytes and order',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('parent-json-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final claude = Directory(p.join(sandbox.path, 'claude'))
            ..createSync();
          final settings =
              File(p.join(project.path, '.claude', 'settings.json'))
                ..createSync(recursive: true)
                ..writeAsStringSync(
                  '{\r\n  "model": "sonnet",\r\n'
                  '  "permissions": {\r\n    "allow": [\r\n'
                  '      "Read(README.md)"\r\n    ]\r\n  },\r\n'
                  '  "unknown": {"keep": "exact value"}\r\n}\r\n',
                );
          final original = settings.readAsBytesSync();
          LifecycleOptions options({bool approved = false}) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            claudeConfigDir: claude.path,
            approved: approved,
          );
          final service = ParentConfigService();
          const changes = [
            ParentChange(
              unit: 'permissions.allow',
              action: ParentAction.add,
              value: 'Bash(git status *)',
            ),
          ];
          ParentRequest request(ParentOperation operation, {String? planId}) =>
              ParentRequest(
                operation: operation,
                harness: ParentHarness.claude,
                scope: LifecycleScope.project,
                layer: ParentLayer.project,
                file: p.join('.claude', 'settings.json'),
                changes: changes,
                planId: planId,
                clientsStopped: operation == ParentOperation.apply,
              );
          final plan = await service.plan(
            request: request(ParentOperation.plan),
            options: options(),
          );
          expect(settings.readAsBytesSync(), original);
          await service.apply(
            request: request(
              ParentOperation.apply,
              planId: plan.data['planId']! as String,
            ),
            options: options(approved: true),
          );
          final text = settings.readAsStringSync();
          expect(text, contains('\r\n'));
          expect(text, contains('"unknown": {"keep": "exact value"}'));
          expect(
            text.indexOf('"model"'),
            lessThan(text.indexOf('"permissions"')),
          );
          final decoded = jsonDecode(text) as Map<String, Object?>;
          expect((decoded['permissions']! as Map<String, Object?>)['allow'], [
            'Read(README.md)',
            'Bash(git status *)',
          ]);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'stale Claude plans refuse after an unrelated document edit',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('parent-stale-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final claude = Directory(p.join(sandbox.path, 'claude'))
            ..createSync();
          final settings =
              File(p.join(project.path, '.claude', 'settings.json'))
                ..createSync(recursive: true)
                ..writeAsStringSync('{"model":"sonnet"}\n');
          LifecycleOptions options({bool approved = false}) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            claudeConfigDir: claude.path,
            approved: approved,
          );
          final service = ParentConfigService();
          ParentRequest request(ParentOperation operation, {String? planId}) =>
              ParentRequest(
                operation: operation,
                harness: ParentHarness.claude,
                scope: LifecycleScope.project,
                layer: ParentLayer.project,
                file: p.join('.claude', 'settings.json'),
                changes: const [
                  ParentChange(
                    unit: 'model',
                    action: ParentAction.set,
                    value: 'opus',
                  ),
                ],
                planId: planId,
                clientsStopped: operation == ParentOperation.apply,
              );
          final plan = await service.plan(
            request: request(ParentOperation.plan),
            options: options(),
          );
          final planId = plan.data['planId']! as String;
          settings.writeAsStringSync('{"model":"sonnet","unrelated":true}\n');
          final before = settings.readAsStringSync();
          try {
            await service.apply(
              request: request(ParentOperation.apply, planId: planId),
              options: options(approved: true),
            );
            fail('A stale plan was applied.');
          } on MambaException catch (error) {
            expect(error.exitCode, 4);
            expect(error.message, contains('plan ID'));
          }
          expect(settings.readAsStringSync(), before);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'Codex TOML edits preserve comments and refuse project providers',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('parent-codex-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
          final config = File(p.join(project.path, '.codex', 'config.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              '# keep this comment\n'
              'model = "gpt-5"\n'
              'unknown = "unchanged"\n\n'
              '[mcp_servers.github]\n'
              'command = "github-mcp" # inline comment\n'
              'args = ["serve"]\n',
            );
          LifecycleOptions options({bool approved = false}) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            codexHome: codex.path,
            approved: approved,
          );
          final service = ParentConfigService();
          ParentRequest request(
            List<ParentChange> changes,
            ParentOperation operation, {
            String? planId,
          }) => ParentRequest(
            operation: operation,
            harness: ParentHarness.codex,
            scope: LifecycleScope.project,
            layer: ParentLayer.project,
            file: p.join('.codex', 'config.toml'),
            changes: changes,
            planId: planId,
            clientsStopped: operation == ParentOperation.apply,
          );
          final plan = await service.plan(
            request: request(const [
              ParentChange(
                unit: 'mcp_servers.github.command',
                action: ParentAction.set,
                value: 'github-mcp-v2',
              ),
              ParentChange(
                unit: 'agents.reviewer.description',
                action: ParentAction.set,
                value: 'Reviews changes.',
              ),
            ], ParentOperation.plan),
            options: options(),
          );
          final applied = await service.apply(
            request: request(
              const [
                ParentChange(
                  unit: 'mcp_servers.github.command',
                  action: ParentAction.set,
                  value: 'github-mcp-v2',
                ),
                ParentChange(
                  unit: 'agents.reviewer.description',
                  action: ParentAction.set,
                  value: 'Reviews changes.',
                ),
              ],
              ParentOperation.apply,
              planId: plan.data['planId']! as String,
            ),
            options: options(approved: true),
          );
          expect(applied.outcome, 'applied');
          final text = config.readAsStringSync();
          expect(text, contains('# keep this comment'));
          expect(text, contains('unknown = "unchanged"'));
          expect(text, contains('command = "github-mcp-v2" # inline comment'));
          expect(text, contains('[agents.reviewer]'));
          expect(text, contains('description = "Reviews changes."'));
          expect(text, contains('args = ["serve"]'));
          try {
            await service.plan(
              request: request(const [
                ParentChange(
                  unit: 'model_provider',
                  action: ParentAction.set,
                  value: 'custom',
                ),
              ], ParentOperation.plan),
              options: options(),
            );
            fail('Project provider change was planned.');
          } on MambaException catch (error) {
            expect(error.exitCode, 4);
            expect(error.message, contains('user source'));
          }
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test('disjoint applies merge selected-unit ownership', () async {
      final sandbox = await Directory.systemTemp.createTemp('parent-merge-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final claude = Directory(p.join(sandbox.path, 'claude'))..createSync();
        File(p.join(project.path, '.claude', 'settings.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{"model":"sonnet","effortLevel":"low"}\n');
        LifecycleOptions options({bool approved = false}) => LifecycleOptions(
          processWorkingDirectory: project.path,
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          claudeConfigDir: claude.path,
          approved: approved,
        );
        final service = ParentConfigService();
        Future<void> apply(String unit, String value) async {
          ParentRequest request(ParentOperation operation, {String? planId}) =>
              ParentRequest(
                operation: operation,
                harness: ParentHarness.claude,
                scope: LifecycleScope.project,
                layer: ParentLayer.project,
                file: p.join('.claude', 'settings.json'),
                changes: [
                  ParentChange(
                    unit: unit,
                    action: ParentAction.set,
                    value: value,
                  ),
                ],
                planId: planId,
                clientsStopped: operation == ParentOperation.apply,
              );
          final plan = await service.plan(
            request: request(ParentOperation.plan),
            options: options(),
          );
          await service.apply(
            request: request(
              ParentOperation.apply,
              planId: plan.data['planId']! as String,
            ),
            options: options(approved: true),
          );
        }

        await apply('model', 'opus');
        await apply('effortLevel', 'high');
        final record = service.records(options()).single;
        final units = (record['units']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map((unit) => unit['unit'])
            .toSet();
        expect(units, {'model', 'effortLevel'});
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'parent backup restore preserves unrelated later edits and cleanup',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'parent-restore-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final claude = Directory(p.join(sandbox.path, 'claude'))
            ..createSync();
          final settings =
              File(p.join(project.path, '.claude', 'settings.json'))
                ..createSync(recursive: true)
                ..writeAsStringSync('{"model":"sonnet","keep":"one"}\n');
          LifecycleOptions options({bool approved = false}) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            claudeConfigDir: claude.path,
            approved: approved,
          );
          final service = ParentConfigService();
          ParentRequest request(ParentOperation operation, {String? planId}) =>
              ParentRequest(
                operation: operation,
                harness: ParentHarness.claude,
                scope: LifecycleScope.project,
                layer: ParentLayer.project,
                file: p.join('.claude', 'settings.json'),
                changes: const [
                  ParentChange(
                    unit: 'model',
                    action: ParentAction.set,
                    value: 'opus',
                  ),
                ],
                planId: planId,
                clientsStopped: operation == ParentOperation.apply,
              );
          final plan = await service.plan(
            request: request(ParentOperation.plan),
            options: options(),
          );
          final applied = await service.apply(
            request: request(
              ParentOperation.apply,
              planId: plan.data['planId']! as String,
            ),
            options: options(approved: true),
          );
          final backupId = applied.data['backupId']! as String;
          settings.writeAsStringSync(
            '{"model":"opus","keep":"two","later":true}\n',
          );
          final backupPlan = service.restorePlanId(options(), backupId);
          final restored = await service.restore(
            options: options(approved: true),
            backupId: backupId,
            planId: backupPlan,
            clientsStopped: true,
          );
          expect(restored.outcome, 'restored');
          final text = settings.readAsStringSync();
          final decoded = jsonDecode(text) as Map<String, Object?>;
          expect(decoded['model'], 'sonnet');
          expect(decoded['keep'], 'two');
          expect(decoded['later'], true);
          final cleaned = await service.cleanup(
            options: options(approved: true),
            backupId: backupId,
          );
          expect(cleaned.outcome, 'cleaned');
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
