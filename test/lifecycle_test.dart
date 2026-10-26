import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

MambaSuccessResult _success(MambaExecutionResult result) {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', isNotNull),
    reason: result is MambaFailureResult ? result.message : null,
  );
  return result as MambaSuccessResult;
}

MambaFailureResult _failure(
  MambaExecutionResult result,
  int status,
  String message, {
  required MambaExecutionPhase phase,
  required List<String> commandPath,
}) {
  expect(
    result,
    isA<MambaFailureResult>()
        .having((value) => value.exitCode, 'exit code', status)
        .having((value) => value.message, 'message', contains(message))
        .having((value) => value.output, 'output', isNull)
        .having((value) => value.error.phase, 'phase', phase)
        .having(
          (value) => value.error.commandPath,
          'command path',
          commandPath,
        ),
  );
  return result as MambaFailureResult;
}

void main() {
  group('agent_resource', () {
    group('skill', () {
      test('help lists lifecycle commands and no discover alias', () async {
        final output = _success(
          await createExecutor().fake().execute(['skill', '--help']),
        ).output!;
        for (final command in [
          'list',
          'install',
          'adopt',
          'replace',
          'remove',
          'backup',
          'recover',
          'inspect',
          'validate',
        ]) {
          expect(output, contains(command));
        }
        expect(output, isNot(contains('discover')));
        expect(output, isNot(contains('lifecycle')));
      });

      group('install', () {
        test('dry-run is planned and creates no artifacts', () async {
          final sandbox = await Directory.systemTemp.createTemp(
            'lifecycle-cli-',
          );
          try {
            final project = Directory(p.join(sandbox.path, 'project'))
              ..createSync();
            final home = Directory(p.join(sandbox.path, 'home'))..createSync();
            final source = Directory(p.join(sandbox.path, 'source'))
              ..createSync();
            File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
            );
            final separator = Platform.pathSeparator;
            final result = _success(
              await createExecutor().fake().execute([
                'skill',
                'install',
                '${source.path}$separator',
                '--destination',
                'claude',
                '--scope',
                'project',
                '--cwd',
                '${project.path}$separator',
                '--project-root',
                '${project.path}$separator',
                '--home',
                '${home.path}$separator',
                '--dry-run',
                '--format',
                'json',
              ]),
            );
            final envelope = jsonDecode(result.output!) as Map<String, Object?>;
            expect(envelope['command'], 'skill install');
            expect(envelope['outcome'], 'planned');
            expect(
              Directory(p.join(project.path, '.agent-resource')).existsSync(),
              isFalse,
            );
            expect(
              Directory(p.join(project.path, '.claude')).existsSync(),
              isFalse,
            );
          } finally {
            await sandbox.delete(recursive: true);
          }
        });

        test(
          'link mode is explicit and reported in a read-only plan',
          () async {
            final sandbox = await Directory.systemTemp.createTemp(
              'lifecycle-mode-',
            );
            try {
              final project = Directory(p.join(sandbox.path, 'project'))
                ..createSync();
              final home = Directory(p.join(sandbox.path, 'home'))
                ..createSync();
              final source = Directory(p.join(sandbox.path, 'source'))
                ..createSync();
              File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
                '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
              );
              final separator = Platform.pathSeparator;
              final result = _success(
                await createExecutor().fake().execute([
                  'skill',
                  'install',
                  '${source.path}$separator',
                  '--destination',
                  'claude',
                  '--mode',
                  'link',
                  '--scope',
                  'project',
                  '--cwd',
                  '${project.path}$separator',
                  '--project-root',
                  '${project.path}$separator',
                  '--home',
                  '${home.path}$separator',
                  '--dry-run',
                  '--format',
                  'json',
                ]),
              );
              final envelope =
                  jsonDecode(result.output!) as Map<String, Object?>;
              expect(envelope['outcome'], 'planned');
              final data = envelope['data']! as Map<String, Object?>;
              expect(data['nativeForm'], 'skill-link');
              expect(
                Directory(p.join(project.path, '.claude')).existsSync(),
                isFalse,
              );
            } finally {
              await sandbox.delete(recursive: true);
            }
          },
        );

        test('adoption and restore reject a mode selector', () async {
          for (final arguments in [
            [
              'skill',
              'adopt',
              'source${Platform.pathSeparator}',
              '--destination',
              'claude',
              '--mode',
              'link',
            ],
            [
              'skill',
              'backup',
              'restore',
              'bak_00000000000000000000000000000000',
              '--mode',
              'link',
            ],
          ]) {
            final result = await createExecutor().fake().execute(arguments);
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'exit code', 1)
                  .having((value) => value.output, 'output', isNull),
            );
          }
        });

        test(
          'typed paths and JSON/interactive conflicts reject before effects',
          () async {
            final result = await createExecutor().fake().execute([
              'skill',
              'install',
              'missing-separator',
              '--destination',
              'claude',
            ]);
            _failure(
              result,
              1,
              'Invalid path',
              phase: MambaExecutionPhase.parse,
              commandPath: const ['agent_resource', 'skill', 'install'],
            );

            final conflict = await createExecutor().fake().execute([
              'skill',
              'install',
              '..${Platform.pathSeparator}',
              '--destination',
              'claude',
              '--interactive',
              '--format',
              'json',
            ]);
            _failure(
              conflict,
              1,
              'conflict',
              phase: MambaExecutionPhase.run,
              commandPath: const ['agent_resource', 'skill', 'install'],
            );
          },
        );
      });

      group('recover', () {
        test(
          'action without an ID rejects before filesystem effects',
          () async {
            final result = await createExecutor().fake().execute([
              'skill',
              'recover',
              '--action',
              'rollback',
              '--yes',
            ]);
            _failure(
              result,
              1,
              'requires a transaction ID',
              phase: MambaExecutionPhase.run,
              commandPath: const ['agent_resource', 'skill', 'recover'],
            );
          },
        );
      });
    });

    group('agent', () {
      test('help lists regular-file lifecycle commands only', () async {
        final output = _success(
          await createExecutor().fake().execute(['agent', '--help']),
        ).output!;
        for (final command in [
          'list',
          'install',
          'adopt',
          'replace',
          'remove',
          'backup',
          'recover',
          'inspect',
          'validate',
          'config',
          'create',
        ]) {
          expect(output, contains(command));
        }
        for (final unsupported in ['register', 'compose', 'convert', 'clone']) {
          expect(output, isNot(contains(unsupported)));
        }
      });

      group('create', () {
        test('plans a reviewed bound-role creation without effects', () async {
          final sandbox = await Directory.systemTemp.createTemp('create-cli-');
          try {
            final project = Directory(p.join(sandbox.path, 'project'))
              ..createSync();
            final home = Directory(p.join(sandbox.path, 'home'))..createSync();
            final codex = Directory(p.join(sandbox.path, 'codex'))
              ..createSync();
            Directory(p.join(project.path, '.codex')).createSync();
            File(p.join(project.path, '.codex', 'config.toml'))
                .writeAsStringSync('# keep\n');
            final source = File(p.join(sandbox.path, 'reviewer.toml'))
              ..writeAsStringSync(
                'name = "reviewer"\ndescription = "Reviews."\n'
                'developer_instructions = "Review."\n',
              );
            final request = File(p.join(sandbox.path, 'bound.json'))
              ..writeAsStringSync(
                jsonEncode(<String, Object?>{
                  'schemaVersion': 1,
                  'operation': 'create',
                  'source': <String, Object?>{
                    'kind': 'codex-role',
                    'configFile': p.join(project.path, '.codex', 'config.toml'),
                    'roleKey': 'reviewer',
                  },
                  'ownership': 'both',
                  'definition': <String, Object?>{'source': source.path},
                }),
              );
            final separator = Platform.pathSeparator;
            final result = _success(
              await createExecutor().fake().execute([
                'agent',
                'create',
                '--request',
                request.path,
                '--scope',
                'project',
                '--cwd',
                '${project.path}$separator',
                '--project-root',
                '${project.path}$separator',
                '--home',
                '${home.path}$separator',
                '--codex-home',
                '${codex.path}$separator',
                '--dry-run',
                '--format',
                'json',
              ]),
            );
            final envelope = jsonDecode(result.output!) as Map<String, Object?>;
            expect(envelope['outcome'], 'planned');
            expect(
              (envelope['data']! as Map<String, Object?>)['planId'],
              isA<String>(),
            );
            expect(
              File(p.join(project.path, '.codex', 'agents', 'reviewer.toml'))
                  .existsSync(),
              isFalse,
            );
            expect(
              File(p.join(project.path, '.codex', 'config.toml'))
                  .readAsStringSync(),
              '# keep\n',
            );
          } finally {
            await sandbox.delete(recursive: true);
          }
        });
      });

      group('config', () {
        test(
          'plan is read-only and apply requires quiescence acknowledgement',
          () async {
            final sandbox = await Directory.systemTemp.createTemp(
              'config-cli-',
            );
            try {
              final project = Directory(p.join(sandbox.path, 'project'))
                ..createSync();
              final home = Directory(p.join(sandbox.path, 'home'))
                ..createSync();
              final request = File(p.join(sandbox.path, 'plan.json'))
                ..writeAsStringSync(
                  jsonEncode(<String, Object?>{
                    'schemaVersion': 1,
                    'operation': 'plan',
                    'source': <String, Object?>{
                      'harness': 'claude',
                      'scope': 'project',
                      'layer': 'project',
                      'file': '.claude/settings.json',
                    },
                    'changes': [
                      <String, Object?>{
                        'unit': 'model',
                        'action': 'set',
                        'value': 'opus',
                      },
                    ],
                  }),
                );
              final separator = Platform.pathSeparator;
              final common = [
                '--scope',
                'project',
                '--cwd',
                '${project.path}$separator',
                '--project-root',
                '${project.path}$separator',
                '--home',
                '${home.path}$separator',
              ];
              final planned = _success(
                await createExecutor().fake().execute([
                  'agent',
                  'config',
                  'plan',
                  '--request',
                  request.path,
                  ...common,
                  '--format',
                  'json',
                ]),
              );
              final envelope =
                  jsonDecode(planned.output!) as Map<String, Object?>;
              expect(envelope['outcome'], 'planned');
              final planId =
                  (envelope['data']! as Map<String, Object?>)['planId']!
                      as String;
              expect(
                File(p.join(project.path, '.claude', 'settings.json'))
                    .existsSync(),
                isFalse,
              );
              final applyRequest = File(p.join(sandbox.path, 'apply.json'))
                ..writeAsStringSync(
                  jsonEncode(<String, Object?>{
                    'schemaVersion': 1,
                    'operation': 'apply',
                    'source': <String, Object?>{
                      'harness': 'claude',
                      'scope': 'project',
                      'layer': 'project',
                      'file': '.claude/settings.json',
                    },
                    'changes': [
                      <String, Object?>{
                        'unit': 'model',
                        'action': 'set',
                        'value': 'opus',
                      },
                    ],
                    'planId': planId,
                    'clientsStopped': false,
                  }),
                );
              final refusal = await createExecutor().fake().execute([
                'agent',
                'config',
                'apply',
                '--request',
                applyRequest.path,
                ...common,
                '--yes',
              ]);
              expect(
                refusal,
                isA<MambaFailureResult>()
                    .having((value) => value.exitCode, 'exit code', 4)
                    .having((value) => value.output, 'output', isNull)
                    .having(
                      (value) => value.message,
                      'message',
                      contains('stopped-client'),
                    ),
              );
              applyRequest.writeAsStringSync(
                jsonEncode(<String, Object?>{
                  'schemaVersion': 1,
                  'operation': 'apply',
                  'source': <String, Object?>{
                    'harness': 'claude',
                    'scope': 'project',
                    'layer': 'project',
                    'file': '.claude/settings.json',
                  },
                  'changes': [
                    <String, Object?>{
                      'unit': 'model',
                      'action': 'set',
                      'value': 'opus',
                    },
                  ],
                  'planId': planId,
                  'clientsStopped': true,
                }),
              );
              final applied = _success(
                await createExecutor().fake().execute([
                  'agent',
                  'config',
                  'apply',
                  '--request',
                  applyRequest.path,
                  ...common,
                  '--yes',
                  '--clients-stopped',
                  '--format',
                  'json',
                ]),
              );
              final appliedEnvelope =
                  jsonDecode(applied.output!) as Map<String, Object?>;
              expect(appliedEnvelope['outcome'], 'applied');
              final settings = File(
                p.join(project.path, '.claude', 'settings.json'),
              );
              expect(
                (jsonDecode(settings.readAsStringSync())
                    as Map<String, Object?>)['model'],
                'opus',
              );
            } finally {
              await sandbox.delete(recursive: true);
            }
          },
        );
      });

      group('install', () {
        test('native source requires an explicit harness', () async {
          final result = await createExecutor().fake().execute([
            'agent',
            'install',
            'definition.md',
          ]);
          _failure(
            result,
            1,
            '--harness',
            phase: MambaExecutionPhase.parse,
            commandPath: const ['agent_resource', 'agent', 'install'],
          );
        });
      });
    });
  });
}
