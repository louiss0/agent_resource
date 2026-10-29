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
                '--source-kind',
                'resource',
                '--target',
                'claude',
                '--method',
                'copy',
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
                  '--source-kind',
                  'resource',
                  '--target',
                  'claude',
                  '--method',
                  'source-link',
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
              final unit =
                  (data['units']! as List<Object?>).single!
                      as Map<String, Object?>;
              expect(unit['method'], 'source-link');
              final entry =
                  (unit['entries']! as List<Object?>).single!
                      as Map<String, Object?>;
              expect(entry['kind'], 'link');
              expect(entry['target'], 'claude');
              expect(entry['linkTarget'], source.path);
              expect(
                entry['nativeLinkKind'],
                anyOf('posix-directory-symlink', 'windows-directory-symlink'),
              );
              expect(entry['path'], contains('.claude'));
              expect(
                Directory(p.join(project.path, '.claude')).existsSync(),
                isFalse,
              );
            } finally {
              await sandbox.delete(recursive: true);
            }
          },
        );

        test(
          'unknown options and retired interactive input reject before effects',
          () async {
            final result = await createExecutor().fake().execute([
              'skill',
              'install',
              '--not-an-input',
            ]);
            _failure(
              result,
              1,
              '--not-an-input',
              phase: MambaExecutionPhase.parse,
              commandPath: const ['agent_resource', 'skill', 'install'],
            );

            final conflict = await createExecutor().fake().execute([
              'skill',
              'install',
              '--interactive',
              '--format',
              'json',
            ]);
            _failure(
              conflict,
              1,
              'retired',
              phase: MambaExecutionPhase.run,
              commandPath: const ['agent_resource', 'skill', 'install'],
            );
          },
        );
      });

      group('adopt', () {
        test('rejects a mode selector', () async {
          final result = await createExecutor().fake().execute([
            'skill',
            'adopt',
            'source${Platform.pathSeparator}',
            '--destination',
            'claude',
            '--mode',
            'link',
          ]);
          _failure(
            result,
            1,
            '--mode',
            phase: MambaExecutionPhase.parse,
            commandPath: const ['agent_resource', 'skill', 'adopt'],
          );
        });
      });

      group('backup', () {
        group('restore', () {
          test('rejects a mode selector', () async {
            final result = await createExecutor().fake().execute([
              'skill',
              'backup',
              'restore',
              'bak_00000000000000000000000000000000',
              '--mode',
              'link',
            ]);
            _failure(
              result,
              1,
              '--mode',
              phase: MambaExecutionPhase.parse,
              commandPath: const [
                'agent_resource',
                'skill',
                'backup',
                'restore',
              ],
            );
          });
        });
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
      test(
        'help lists lifecycle, authoring, and conversion commands',
        () async {
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
            'compose',
            'clone',
            'edit',
            'convert',
          ]) {
            expect(output, contains(command));
          }
          for (final unsupported in ['register']) {
            expect(output, isNot(contains(unsupported)));
          }
        },
      );

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
        late Directory sandbox;
        late Directory project;
        late Directory home;
        late File request;

        setUp(() {
          sandbox = Directory.systemTemp.createTempSync('config-cli-');
          project = Directory(p.join(sandbox.path, 'project'))..createSync();
          home = Directory(p.join(sandbox.path, 'home'))..createSync();
          request = File(p.join(sandbox.path, 'plan.json'))
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
        });

        tearDown(() {
          if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
        });

        List<String> common() => [
          '--scope',
          'project',
          '--cwd',
          '${project.path}${Platform.pathSeparator}',
          '--project-root',
          '${project.path}${Platform.pathSeparator}',
          '--home',
          '${home.path}${Platform.pathSeparator}',
        ];

        Future<String> plan() async {
          final planned = _success(
            await createExecutor().fake().execute([
              'agent',
              'config',
              'plan',
              '--request',
              request.path,
              ...common(),
              '--format',
              'json',
            ]),
          );
          final envelope = jsonDecode(planned.output!) as Map<String, Object?>;
          expect(envelope['outcome'], 'planned');
          expect(
            File(p.join(project.path, '.claude', 'settings.json')).existsSync(),
            isFalse,
          );
          return (envelope['data']! as Map<String, Object?>)['planId']!
              as String;
        }

        group('plan', () {
          test('is read-only and returns a stable plan ID', () async {
            final first = await plan();
            final second = await plan();
            expect(second, first);
          });
        });

        group('apply', () {
          test(
            'requires quiescence acknowledgement before publication',
            () async {
              final planId = await plan();
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
                ...common(),
                '--yes',
              ]);
              _failure(
                refusal,
                4,
                'stopped-client',
                phase: MambaExecutionPhase.run,
                commandPath: const [
                  'agent_resource',
                  'agent',
                  'config',
                  'apply',
                ],
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
                  ...common(),
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
            },
          );
        });
      });

      group('install', () {
        test('native source requires explicit unattended scope', () async {
          final result = await createExecutor().fake().execute([
            'agent',
            'install',
            'definition.md',
          ]);
          _failure(
            result,
            1,
            '--scope',
            phase: MambaExecutionPhase.run,
            commandPath: const ['agent_resource', 'agent', 'install'],
          );
        });
      });
    });
  });
}
