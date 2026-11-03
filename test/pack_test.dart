import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

import 'pack_action_test.dart' show RecordingPackService;

void main() {
  group('agent_resource', () {
    group('pack', () {
      test('help lists canonical actions without effects', () async {
        final service = RecordingPackService();
        final result = await createExecutor(packLifecycle: service)
            .fake()
            .execute(['pack', '--help']);
        expect(
          result,
          isA<MambaSuccessResult>().having(
            (v) => v.output,
            'output',
            allOf(
              contains('install'),
              contains('validate'),
              contains('source'),
            ),
          ),
        );
        expect(service.requests, isEmpty);
      });
      final declarationCases = [
        (
          name: 'remove requires --only',
          arguments: ['pack', 'remove', 'owner/repo'],
          token: '--only',
        ),
        (
          name: 'rollback requires --snapshot',
          arguments: ['pack', 'rollback', 'owner/repo', '--only', 'reviewer'],
          token: '--snapshot',
        ),
        (
          name: 'source associate requires --only',
          arguments: ['pack', 'source', 'associate', 'owner/repo'],
          token: '--only',
        ),
        (
          name: 'source change requires --to',
          arguments: ['pack', 'source', 'change', 'owner/repo'],
          token: '--to',
        ),
        (
          name: 'validate does not register --yes',
          arguments: ['pack', 'validate', 'owner/repo', '--yes'],
          token: '--yes',
        ),
        (
          name: 'validate does not register mutation options',
          arguments: ['pack', 'validate', 'owner/repo', '--target', 'codex'],
          token: '--target',
        ),
        (
          name: 'method uses typed choices',
          arguments: ['pack', 'install', 'owner/repo', '--method', 'symlink'],
          token: '--method',
        ),
        (
          name: 'bump uses typed choices',
          arguments: ['pack', 'update', 'owner/repo', '--bump', 'majorish'],
          token: '--bump',
        ),
      ];
      for (final testCase in declarationCases) {
        test(testCase.name, () async {
          final service = RecordingPackService();
          final result = await createExecutor(packLifecycle: service)
              .fake()
              .execute(testCase.arguments);

          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', isNonZero)
                .having(
                  (value) => value.message,
                  'message',
                  contains(testCase.token),
                )
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.error.phase,
                  'phase',
                  MambaExecutionPhase.parse,
                ),
          );
          expect(service.requests, isEmpty);
        });
      }
      for (final operation in [
        'install',
        'update',
        'remove',
        'rollback',
        'cleanup',
        'validate',
      ]) {
        group(operation, () {
          test(
            'passes both types by default and preserves item filter',
            () async {
              final service = RecordingPackService();
              await createExecutor(packLifecycle: service).fake().execute([
                'pack',
                operation,
                'owner/repo',
                '--only',
                'reviewer',
                if (operation == 'rollback') ...['--snapshot', 'snapshot-ref'],
                if (operation != 'validate') '--yes',
              ]);
              expect(service.requests.single.resourceTypes, [
                PackResourceType.skill,
                PackResourceType.agent,
              ]);
              expect(service.requests.single.only, ['reviewer']);
              expect(service.requests.single.includeNew, isFalse);
            },
          );
        });
      }
      group('update', () {
        test('accepts explicit type and include-new', () async {
          final service = RecordingPackService();
          await createExecutor(packLifecycle: service).fake().execute([
            'pack',
            'update',
            'owner/repo',
            '--type',
            'agent',
            '--include-new',
          ]);
          expect(service.requests.single.resourceTypes, [
            PackResourceType.agent,
          ]);
          expect(service.requests.single.includeNew, isTrue);
        });
        test('rejects conflicting selections before effects', () async {
          final service = RecordingPackService();
          final result = await createExecutor(packLifecycle: service)
              .fake()
              .execute([
                'pack',
                'update',
                'owner/repo',
                '--include-new',
                '--skip-new',
              ]);
          expect(
            result,
            isA<MambaFailureResult>().having(
              (v) => v.message,
              'message',
              contains('--include-new'),
            ),
          );
          expect(service.requests, isEmpty);
        });
        test('rejects invalid type before effects', () async {
          final service = RecordingPackService();
          final result = await createExecutor(packLifecycle: service)
              .fake()
              .execute(['pack', 'update', 'owner/repo', '--type', 'other']);
          expect(result, isA<MambaFailureResult>());
          expect(service.requests, isEmpty);
        });
      });
      group('source', () {
        for (final operation in ['associate', 'change']) {
          group(operation, () {
            test('passes selected kinds', () async {
              final service = RecordingPackService();
              await createExecutor(packLifecycle: service).fake().execute([
                'pack',
                'source',
                operation,
                'owner/repo',
                if (operation == 'associate') ...['--only', 'reviewer'],
                if (operation == 'change') ...['--to', 'owner/other'],
                '--type',
                'skill',
                '--type',
                'agent',
              ]);
              expect(service.requests.single.resourceTypes, [
                PackResourceType.skill,
                PackResourceType.agent,
              ]);
            });
          });
        }
      });
      group('lifecycle', () {
        late fslib.FileSystem fs;
        late fslib.Directory sandbox;
        late fslib.Directory project;
        late fslib.Directory home;
        late fslib.File skillFile;
        late fslib.File agentFile;

        setUp(() {
          fs = const local.LocalFileSystem();
          sandbox = fs.systemTempDirectory.createTempSync('pack-command-test-');
          project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync(recursive: true);
          home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync(recursive: true);
          fs.file(fs.path.join(sandbox.path, 'source', 'agent-resources.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/reviewer"
[[catalog.agents]]
path = "agents/writer.md"
profile = "claude"
''');
          skillFile =
              fs.file(
                  fs.path.join(
                    sandbox.path,
                    'source',
                    'skills',
                    'reviewer',
                    'SKILL.md',
                  ),
                )
                ..createSync(recursive: true)
                ..writeAsStringSync('''
---
name: reviewer
description: Reviews code.
---
# Reviewer
''');
          agentFile =
              fs.file(
                  fs.path.join(sandbox.path, 'source', 'agents', 'writer.md'),
                )
                ..createSync(recursive: true)
                ..writeAsStringSync('''
---
name: writer
description: Writes code.
---
Write changes.
''');
          fs
              .file(fs.path.join(project.path, 'agent-resources.toml'))
              .writeAsStringSync('''
schema_version = 1
[cli.install]
targets = ["codex"]
skill_method = "copy"
[packs."local/demo".source]
kind = "local"
path = "../source"
[packs."local/demo".update]
track = { kind = "local" }
''');
        });

        tearDown(() {
          if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
        });

        bool projectFileExists(String relative) => fs
            .file(fs.path.joinAll([project.path, ...relative.split('/')]))
            .existsSync();

        bool projectDirectoryExists(String relative) => fs
            .directory(fs.path.joinAll([project.path, ...relative.split('/')]))
            .existsSync();

        List<String> invocation(String operation) => [
          'pack',
          operation,
          'local/demo',
          '--scope',
          'project',
          '--cwd',
          '${project.path}${fs.path.separator}',
          '--project-root',
          '${project.path}${fs.path.separator}',
          '--home',
          '${home.path}${fs.path.separator}',
          '--format',
          'json',
          '--yes',
        ];

        Future<Map<String, Object?>> runSuccessfully(
          List<String> arguments,
        ) async {
          final result = await createExecutor(
            packLifecycle: PackLifecycleService(fileSystem: fs),
          ).fake().execute(arguments);
          expect(
            result,
            isA<MambaSuccessResult>().having(
              (value) => value.exitCode,
              'exit code',
              0,
            ),
            reason: result is MambaFailureResult
                ? '${result.message}\n$arguments'
                : null,
          );
          return jsonDecode((result as MambaSuccessResult).output!)
              as Map<String, Object?>;
        }

        test('installs both resource types through the real service', () async {
          final envelope = await runSuccessfully(invocation('install'));

          expect(envelope['operation'], 'pack.install');
          expect(envelope['outcome'], 'completed');
          final resources = envelope['resources']! as List<Object?>;
          expect(
            resources.map((value) => (value! as Map<String, Object?>)['type']),
            containsAll(['skill', 'agent']),
          );
          expect(projectFileExists('.agents/skills/reviewer/SKILL.md'), isTrue);
          expect(projectFileExists('.claude/agents/writer.md'), isTrue);
        });

        test('installs only Agents when explicitly selected', () async {
          final envelope = await runSuccessfully([
            ...invocation('install'),
            '--type',
            'agent',
          ]);

          final resources = envelope['resources']! as List<Object?>;
          expect(resources, hasLength(1));
          expect((resources.single! as Map<String, Object?>)['type'], 'agent');
          expect(skillFile.existsSync(), isTrue);
          expect(projectDirectoryExists('.agents/skills'), isFalse);
          expect(projectFileExists('.claude/agents/writer.md'), isTrue);
        });

        test('routes a native name to its source type', () async {
          final envelope = await runSuccessfully([
            ...invocation('install'),
            '--only',
            'writer',
          ]);

          final resources = envelope['resources']! as List<Object?>;
          expect(resources, hasLength(1));
          expect((resources.single! as Map<String, Object?>)['name'], 'writer');
          expect(projectDirectoryExists('.agents/skills'), isFalse);
          expect(projectFileExists('.claude/agents/writer.md'), isTrue);
        });

        test('removes selected names from both types', () async {
          await runSuccessfully(invocation('install'));

          final envelope = await runSuccessfully([
            ...invocation('remove'),
            '--only',
            'reviewer',
            '--only',
            'writer',
          ]);

          expect(envelope['operation'], 'pack.remove');
          expect(envelope['resources'], hasLength(2));
          expect(
            projectFileExists('.agents/skills/reviewer/SKILL.md'),
            isFalse,
          );
          expect(projectFileExists('.claude/agents/writer.md'), isFalse);
        });

        test('rejects an ambiguous name before removing either type', () async {
          agentFile.writeAsStringSync('''
---
name: reviewer
description: Reviews code.
---
Review changes.
''');
          await runSuccessfully(invocation('install'));

          final result = await createExecutor(
            packLifecycle: PackLifecycleService(fileSystem: fs),
          ).fake().execute([...invocation('remove'), '--only', 'reviewer']);

          expect(
            result,
            isA<MambaFailureResult>().having(
              (value) => value.message,
              'message',
              contains('Ambiguous native name(s) across selected types'),
            ),
          );
          expect(projectFileExists('.agents/skills/reviewer/SKILL.md'), isTrue);
          expect(projectFileExists('.claude/agents/writer.md'), isTrue);
        });
      });
    });
    for (final entry in {
      'skills': PackResourceType.skill,
      'agents': PackResourceType.agent,
    }.entries) {
      group(entry.key, () {
        test('pins type and sends deprecation separately from JSON', () async {
          final service = RecordingPackService();
          final warnings = <String>[];
          final result =
              await createExecutor(
                packLifecycle: service,
                deprecationWarning: warnings.add,
              ).fake().execute([
                entry.key,
                'install',
                'owner/repo',
                '--format',
                'json',
              ]);
          expect(service.requests.single.resourceTypes, [entry.value]);
          expect(warnings.single, contains('deprecated'));
          expect(
            result,
            isA<MambaSuccessResult>().having(
              (v) => v.output,
              'output',
              isNot(contains('deprecated')),
            ),
          );
        });
      });
    }
  });
}
