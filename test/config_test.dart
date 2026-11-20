import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';
import 'package:toml/toml.dart' show TomlDocument;

void main() {
  group('agent_resource', () {
    group('config', () {
      test('shows its child commands', () async {
        final result = await createExecutor(
          fileSystem: MemoryFileSystem(style: FileSystemStyle.posix),
        ).fake().execute(['config', '--help']);

        expect(
          result,
          isA<MambaSuccessResult>()
              .having((value) => value.exitCode, 'exit code', 0)
              .having(
                (value) => value.output,
                'output',
                allOf(
                  contains('validate'),
                  contains('effective'),
                  contains('prefer'),
                ),
              ),
        );
      });

      group('effective', () {
        test('shows default settings with explicit paths and origins', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          final result = await createExecutor(fileSystem: fileSystem)
              .fake()
              .execute([
                'config',
                'effective',
                '--scope',
                'project',
                '--user-config',
                '/sandbox/user.toml',
                '--project-config',
                '/sandbox/project.toml',
                '--cwd',
                '/sandbox/',
                '--project-root',
                '/sandbox/project/',
              ]);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  [
                    'config.effective: valid',
                    'scope: project',
                    'paths:',
                    '  userConfig: /sandbox/user.toml '
                        '[explicit-argument @ --user-config]',
                    '  projectConfig: /sandbox/project.toml '
                        '[explicit-argument @ --project-config]',
                    '  selectedConfig: /sandbox/project.toml '
                        '[explicit-argument @ --project-config]',
                    '  cwd: /sandbox [explicit-argument @ --cwd]',
                    '  projectRoot: /sandbox/project '
                        '[explicit-argument @ --project-root]',
                    'settings:',
                    '  cli.install.targets: [] [built-in-default]',
                    '  cli.install.skill_method: unset [built-in-default]',
                    '  cli.retention.snapshot_days: 90 [built-in-default]',
                    'eligiblePreferences: cli.install.targets, '
                        'cli.install.skill_method, cli.retention.snapshot_days',
                  ].join('\n'),
                ),
          );
        });

        test('reports discovered paths and layered origins as JSON', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          const userPath =
              '/sandbox/home/.config/agent-resource/agent-resources.toml';
          const projectPath = '/sandbox/project/agent-resources.toml';
          _writeConfig(
            fileSystem,
            userPath,
            'schema_version = 1\n'
            '[cli.install]\n'
            'skill_method = "canonical"\n'
            '[cli.retention]\n'
            'snapshot_days = 45\n',
          );
          _writeConfig(
            fileSystem,
            projectPath,
            'schema_version = 1\n'
            '[cli.install]\n'
            'targets = ["codex"]\n',
          );

          final result =
              await createExecutor(
                fileSystem: fileSystem,
                configurationEnvironment: const <String, String>{
                  'HOME': '/sandbox/home',
                },
                configurationOperatingSystem: 'linux',
              ).fake().execute([
                'config',
                'effective',
                '--scope',
                'project',
                '--cwd',
                '/sandbox/',
                '--project-root',
                '/sandbox/project/',
                '--home',
                '/sandbox/home/',
                '--snapshot-days',
                '30',
                '--format',
                'json',
              ]);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having((value) => value.output, 'output', isA<String>()),
          );
          final success = result as MambaSuccessResult;
          final payload = jsonDecode(success.output as String);
          expect(payload, {
            'schemaVersion': 1,
            'operation': 'config.effective',
            'outcome': 'valid',
            'scope': 'project',
            'paths': [
              {
                'name': 'userConfig',
                'path': userPath,
                'origin': 'detection',
                'source': '--home',
              },
              {
                'name': 'projectConfig',
                'path': projectPath,
                'origin': 'detection',
                'source': 'projectRoot',
              },
              {
                'name': 'selectedConfig',
                'path': projectPath,
                'origin': 'detection',
                'source': 'projectRoot',
              },
              {
                'name': 'cwd',
                'path': '/sandbox',
                'origin': 'explicit-argument',
                'source': '--cwd',
              },
              {
                'name': 'projectRoot',
                'path': '/sandbox/project',
                'origin': 'explicit-argument',
                'source': '--project-root',
              },
            ],
            'settings': [
              {
                'key': 'cli.install.targets',
                'value': ['codex'],
                'origin': 'project-config',
                'source': projectPath,
              },
              {
                'key': 'cli.install.skill_method',
                'value': 'canonical',
                'origin': 'user-config',
                'source': userPath,
              },
              {
                'key': 'cli.retention.snapshot_days',
                'value': 30,
                'origin': 'explicit-argument',
                'source': '--snapshot-days',
              },
            ],
            'eligiblePreferences': const [
              'cli.install.targets',
              'cli.install.skill_method',
              'cli.retention.snapshot_days',
            ],
            'changes': <Object?>[],
            'applied': false,
          });
        });

        test('describes read-only effective inspection in help', () async {
          final result = await createExecutor(
            fileSystem: MemoryFileSystem(style: FileSystemStyle.posix),
          ).fake().execute(['config', 'effective', '--help']);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  allOf(
                    contains('origin of every resolved value'),
                    contains('read-only'),
                    contains('--format'),
                    contains('--config'),
                  ),
                ),
          );
        });

        test('shows explicit target and method origins', () async {
          final result =
              await createExecutor(
                fileSystem: MemoryFileSystem(style: FileSystemStyle.posix),
              ).fake().execute([
                'config',
                'effective',
                '--user-config',
                '/sandbox/user.toml',
                '--project-config',
                '/sandbox/project.toml',
                '--cwd',
                '/sandbox/',
                '--project-root',
                '/sandbox/project/',
                '--target',
                'claude',
                '--target',
                'codex',
                '--method',
                'copy',
                '--snapshot-days',
                '20',
                '--format',
                'json',
              ]);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having((value) => value.output, 'output', isA<String>()),
          );
          final success = result as MambaSuccessResult;
          final payload = jsonDecode(success.output as String);
          expect(payload['settings'], [
            {
              'key': 'cli.install.targets',
              'value': ['claude', 'codex'],
              'origin': 'explicit-argument',
              'source': '--target',
            },
            {
              'key': 'cli.install.skill_method',
              'value': 'copy',
              'origin': 'explicit-argument',
              'source': '--method',
            },
            {
              'key': 'cli.retention.snapshot_days',
              'value': 20,
              'origin': 'explicit-argument',
              'source': '--snapshot-days',
            },
          ]);
        });

        test('uses --config as the selected scope path', () async {
          final result =
              await createExecutor(
                fileSystem: MemoryFileSystem(style: FileSystemStyle.posix),
                configurationEnvironment: const <String, String>{
                  'HOME': '/sandbox/home',
                },
                configurationOperatingSystem: 'linux',
              ).fake().execute([
                'config',
                'effective',
                '--scope',
                'project',
                '--config',
                '/sandbox/chosen.toml',
                '--cwd',
                '/sandbox/',
                '--project-root',
                '/sandbox/project/',
                '--home',
                '/sandbox/home/',
                '--format',
                'json',
              ]);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having((value) => value.output, 'output', isA<String>()),
          );
          final success = result as MambaSuccessResult;
          final payload = jsonDecode(success.output as String);
          expect(
            payload['paths'],
            contains(
              equals(<String, Object?>{
                'name': 'selectedConfig',
                'path': '/sandbox/chosen.toml',
                'origin': 'explicit-argument',
                'source': '--config',
              }),
            ),
          );
        });

        final effectiveRejections =
            <({String name, List<String> arguments, String message})>[
              (
                name: 'invalid format',
                arguments: ['config', 'effective', '--format', 'xml'],
                message:
                    'Invalid choice for --format. Choose from: text, json.',
              ),
              (
                name: 'invalid target',
                arguments: ['config', 'effective', '--target', 'BAD'],
                message: "Option --target does not accept 'BAD'.",
              ),
              (
                name: 'invalid method',
                arguments: ['config', 'effective', '--method', 'bogus'],
                message: "Option --method does not accept 'bogus'.",
              ),
              (
                name: 'snapshot retention below range',
                arguments: ['config', 'effective', '--snapshot-days', '0'],
                message:
                    'Option --snapshot-days is outside its accepted range.',
              ),
              (
                name: 'explicit config conflict',
                arguments: [
                  'config',
                  'effective',
                  '--config',
                  '/tmp/a.toml',
                  '--user-config',
                  '/tmp/b.toml',
                ],
                message: 'Input --config conflicts with --user-config.',
              ),
            ];

        for (final testCase in effectiveRejections) {
          test('rejects ${testCase.name}', () async {
            final result = await createExecutor(
              fileSystem: MemoryFileSystem(style: FileSystemStyle.posix),
            ).fake().execute(testCase.arguments);

            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'exit code', 1)
                  .having((value) => value.message, 'message', testCase.message)
                  .having((value) => value.output, 'output', isNull)
                  .having(
                    (value) => value.error.phase,
                    'phase',
                    MambaExecutionPhase.parse,
                  )
                  .having((value) => value.error.commandPath, 'command path', [
                    'agent_resource',
                    'config',
                    'effective',
                  ]),
            );
          });
        }
      });

      group('prefer', () {
        test('previews safe changes without writing configuration', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          const userPath = '/sandbox/user.toml';
          const projectPath = '/sandbox/project.toml';
          const originalUser =
              'schema_version = 1\n'
              '[cli.install]\n'
              'skill_method = "canonical"\n';
          const originalProject =
              'schema_version = 1\n'
              '[cli.retention]\n'
              'snapshot_days = 45\n'
              '[packs."local/demo".source]\n'
              'kind = "local"\n'
              'path = "../source"\n';
          _writeConfig(fileSystem, userPath, originalUser);
          _writeConfig(fileSystem, projectPath, originalProject);

          final result = await createExecutor(fileSystem: fileSystem)
              .fake()
              .execute([
                'config',
                'prefer',
                '--scope',
                'project',
                '--user-config',
                userPath,
                '--project-config',
                projectPath,
                '--cwd',
                '/sandbox/',
                '--project-root',
                '/sandbox/project/',
                '--set',
                'cli.install.targets=claude,codex',
                '--set',
                'cli.install.skill_method=copy',
                '--set',
                'cli.retention.snapshot_days=30',
                '--format',
                'json',
              ]);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having((value) => value.output, 'output', isA<String>()),
          );
          final success = result as MambaSuccessResult;
          final payload = jsonDecode(success.output as String);
          expect(payload['operation'], 'config.prefer');
          expect(payload['outcome'], 'preview');
          expect(payload['applied'], isFalse);
          expect(
            payload['paths'],
            contains(
              equals(<String, Object?>{
                'name': 'selectedConfig',
                'path': projectPath,
                'origin': 'explicit-argument',
                'source': '--project-config',
              }),
            ),
          );
          expect(payload['changes'], [
            {
              'key': 'cli.install.targets',
              'value': ['claude', 'codex'],
              'origin': 'explicit-argument',
              'source': '--set',
            },
            {
              'key': 'cli.install.skill_method',
              'value': 'copy',
              'origin': 'explicit-argument',
              'source': '--set',
            },
            {
              'key': 'cli.retention.snapshot_days',
              'value': 30,
              'origin': 'explicit-argument',
              'source': '--set',
            },
          ]);
          expect(payload['settings'], [
            {
              'key': 'cli.install.targets',
              'value': ['claude', 'codex'],
              'origin': 'explicit-argument',
              'source': '--set',
            },
            {
              'key': 'cli.install.skill_method',
              'value': 'copy',
              'origin': 'explicit-argument',
              'source': '--set',
            },
            {
              'key': 'cli.retention.snapshot_days',
              'value': 30,
              'origin': 'explicit-argument',
              'source': '--set',
            },
          ]);
          final proposedConfig = payload['proposedConfig'] as String;
          final proposedMap = TomlDocument.parse(proposedConfig).toMap();
          final proposedCli = proposedMap['cli'] as Map<String, dynamic>;
          final proposedInstall =
              proposedCli['install'] as Map<String, dynamic>;
          final proposedRetention =
              proposedCli['retention'] as Map<String, dynamic>;
          expect(proposedInstall['targets'], ['claude', 'codex']);
          expect(proposedInstall['skill_method'], 'copy');
          expect(proposedRetention['snapshot_days'], 30);
          expect(
            (proposedMap['packs'] as Map<String, dynamic>).containsKey(
              'local/demo',
            ),
            isTrue,
          );
          expect(
            fileSystem.file(projectPath).readAsStringSync(),
            originalProject,
          );
          expect(fileSystem.file(userPath).readAsStringSync(), originalUser);
          expect(
            fileSystem.file('$projectPath.prefer.tmp').existsSync(),
            isFalse,
          );
        });

        final applyCases =
            <
              ({
                String scope,
                String targetPath,
                String otherPath,
                String origin,
              })
            >[
              (
                scope: 'project',
                targetPath: '/sandbox/project.toml',
                otherPath: '/sandbox/user.toml',
                origin: 'project-config',
              ),
              (
                scope: 'user',
                targetPath: '/sandbox/user.toml',
                otherPath: '/sandbox/project.toml',
                origin: 'user-config',
              ),
            ];

        for (final testCase in applyCases) {
          test('applies eligible preferences at ${testCase.scope} scope', () async {
            final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
            final applyResult = await createExecutor(fileSystem: fileSystem)
                .fake()
                .execute([
                  'config',
                  'prefer',
                  '--scope',
                  testCase.scope,
                  '--user-config',
                  '/sandbox/user.toml',
                  '--project-config',
                  '/sandbox/project.toml',
                  '--cwd',
                  '/sandbox/',
                  '--project-root',
                  '/sandbox/project/',
                  '--set',
                  'cli.install.targets=codex',
                  '--set',
                  'cli.retention.snapshot_days=14',
                  '--apply',
                ]);

            expect(
              applyResult,
              isA<MambaSuccessResult>()
                  .having((value) => value.exitCode, 'exit code', 0)
                  .having(
                    (value) => value.output,
                    'output',
                    allOf(
                      contains('config.prefer: applied'),
                      contains('applied: true'),
                      contains('preview:'),
                      contains(testCase.targetPath),
                      contains(
                        'cli.install.targets: ["codex"] '
                        '[explicit-argument @ --set]',
                      ),
                      contains(
                        'eligiblePreferences: cli.install.targets, '
                        'cli.install.skill_method, cli.retention.snapshot_days',
                      ),
                    ),
                  ),
            );
            final written = fileSystem.file(testCase.targetPath);
            expect(written.existsSync(), isTrue);
            expect(
              fileSystem.file('${testCase.targetPath}.prefer.tmp').existsSync(),
              isFalse,
            );
            expect(fileSystem.file(testCase.otherPath).existsSync(), isFalse);
            final writtenMap = TomlDocument.parse(written.readAsStringSync())
                .toMap();
            final writtenCli = writtenMap['cli'] as Map<String, dynamic>;
            final writtenInstall =
                writtenCli['install'] as Map<String, dynamic>;
            final writtenRetention =
                writtenCli['retention'] as Map<String, dynamic>;
            expect(writtenMap['schema_version'], 1);
            expect(writtenInstall['targets'], ['codex']);
            expect(writtenRetention['snapshot_days'], 14);

            final effectiveResult = await createExecutor(fileSystem: fileSystem)
                .fake()
                .execute([
                  'config',
                  'effective',
                  '--scope',
                  testCase.scope,
                  '--user-config',
                  '/sandbox/user.toml',
                  '--project-config',
                  '/sandbox/project.toml',
                  '--cwd',
                  '/sandbox/',
                  '--project-root',
                  '/sandbox/project/',
                  '--format',
                  'json',
                ]);

            expect(
              effectiveResult,
              isA<MambaSuccessResult>()
                  .having((value) => value.exitCode, 'exit code', 0)
                  .having((value) => value.output, 'output', isA<String>()),
            );
            final success = effectiveResult as MambaSuccessResult;
            final payload = jsonDecode(success.output as String);
            expect(
              payload['settings'],
              containsAll(<Map<String, Object?>>[
                <String, Object?>{
                  'key': 'cli.install.targets',
                  'value': ['codex'],
                  'origin': testCase.origin,
                  'source': testCase.targetPath,
                },
                <String, Object?>{
                  'key': 'cli.install.skill_method',
                  'value': null,
                  'origin': 'built-in-default',
                },
                <String, Object?>{
                  'key': 'cli.retention.snapshot_days',
                  'value': 14,
                  'origin': testCase.origin,
                  'source': testCase.targetPath,
                },
              ]),
            );
          });
        }

        final unsafeAssignments =
            <({String name, String assignment, String key, String secret})>[
              (
                name: 'blanket approval',
                assignment: 'cli.approval=yes',
                key: 'cli.approval',
                secret: 'yes',
              ),
              (
                name: 'credential reference',
                assignment: 'cli.credentials.token=super-secret',
                key: 'cli.credentials.token',
                secret: 'super-secret',
              ),
              (
                name: 'risk acknowledgement',
                assignment: 'cli.risk_acknowledgement=accepted',
                key: 'cli.risk_acknowledgement',
                secret: 'accepted',
              ),
              (
                name: 'credential-like safe-key value',
                assignment: 'cli.install.targets=api-token',
                key: 'cli.install.targets',
                secret: 'api-token',
              ),
            ];

        for (final testCase in unsafeAssignments) {
          test('refuses ${testCase.name} without writing', () async {
            final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
            final result = await createExecutor(fileSystem: fileSystem)
                .fake()
                .execute([
                  'config',
                  'prefer',
                  '--scope',
                  'project',
                  '--user-config',
                  '/sandbox/user.toml',
                  '--project-config',
                  '/sandbox/project.toml',
                  '--cwd',
                  '/sandbox/',
                  '--project-root',
                  '/sandbox/project/',
                  '--set',
                  testCase.assignment,
                  '--apply',
                ]);

            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'exit code', 2)
                  .having(
                    (value) => value.message.contains('Unsafe remembered'),
                    'diagnostic names refusal',
                    isTrue,
                  )
                  .having(
                    (value) => value.message.contains(testCase.key),
                    'diagnostic names preference',
                    isTrue,
                  )
                  .having(
                    (value) => value.message.contains(testCase.secret),
                    'diagnostic omits supplied value',
                    isFalse,
                  )
                  .having((value) => value.output, 'output', isNull)
                  .having(
                    (value) => value.error.phase,
                    'phase',
                    MambaExecutionPhase.run,
                  )
                  .having((value) => value.error.commandPath, 'command path', [
                    'agent_resource',
                    'config',
                    'prefer',
                  ]),
            );
            expect(
              fileSystem.file('/sandbox/project.toml').existsSync(),
              isFalse,
            );
            expect(
              fileSystem.file('/sandbox/project.toml.prefer.tmp').existsSync(),
              isFalse,
            );
          });
        }

        test('refuses unsafe keys already stored in configuration', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          const projectPath = '/sandbox/project.toml';
          const original =
              'schema_version = 1\n'
              '[cli.approval]\n'
              'enabled = true\n';
          _writeConfig(fileSystem, projectPath, original);
          final result = await createExecutor(fileSystem: fileSystem)
              .fake()
              .execute([
                'config',
                'prefer',
                '--scope',
                'project',
                '--user-config',
                '/sandbox/user.toml',
                '--project-config',
                projectPath,
                '--cwd',
                '/sandbox/',
                '--project-root',
                '/sandbox/project/',
                '--set',
                'cli.install.targets=codex',
                '--apply',
              ]);

          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 2)
                .having(
                  (value) => value.message.contains('Unsafe remembered'),
                  'diagnostic names refusal',
                  isTrue,
                )
                .having(
                  (value) => value.message.contains('cli.approval'),
                  'diagnostic names stored key',
                  isTrue,
                )
                .having(
                  (value) => value.message.contains('true'),
                  'diagnostic omits stored value',
                  isFalse,
                )
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.error.phase,
                  'phase',
                  MambaExecutionPhase.run,
                )
                .having((value) => value.error.commandPath, 'command path', [
                  'agent_resource',
                  'config',
                  'prefer',
                ]),
          );
          expect(fileSystem.file(projectPath).readAsStringSync(), original);
          expect(
            fileSystem.file('$projectPath.prefer.tmp').existsSync(),
            isFalse,
          );
        });

        test('describes preview and unsafe refusal in help', () async {
          final result = await createExecutor(
            fileSystem: MemoryFileSystem(style: FileSystemStyle.posix),
          ).fake().execute(['config', 'prefer', '--help']);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  allOf(
                    contains('--apply'),
                    contains('--set'),
                    contains('Previews'),
                    contains('credentials are refused'),
                  ),
                ),
          );
        });

        final preferRejections =
            <({String name, List<String> arguments, String message})>[
              (
                name: 'missing scope',
                arguments: ['config', 'prefer'],
                message: 'Option --scope is required.',
              ),
              (
                name: 'missing preference',
                arguments: ['config', 'prefer', '--scope', 'project'],
                message: 'Option --set is required.',
              ),
              (
                name: 'malformed preference assignment',
                arguments: [
                  'config',
                  'prefer',
                  '--scope',
                  'project',
                  '--set',
                  'noequals',
                ],
                message: "Option --set does not accept 'noequals'.",
              ),
              (
                name: 'explicit config conflict',
                arguments: [
                  'config',
                  'prefer',
                  '--scope',
                  'project',
                  '--set',
                  'cli.install.targets=codex',
                  '--config',
                  '/tmp/a.toml',
                  '--project-config',
                  '/tmp/b.toml',
                ],
                message: 'Input --config conflicts with --project-config.',
              ),
            ];

        for (final testCase in preferRejections) {
          test('rejects ${testCase.name}', () async {
            final result = await createExecutor(
              fileSystem: MemoryFileSystem(style: FileSystemStyle.posix),
            ).fake().execute(testCase.arguments);

            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'exit code', 1)
                  .having((value) => value.message, 'message', testCase.message)
                  .having((value) => value.output, 'output', isNull)
                  .having(
                    (value) => value.error.phase,
                    'phase',
                    MambaExecutionPhase.parse,
                  )
                  .having((value) => value.error.commandPath, 'command path', [
                    'agent_resource',
                    'config',
                    'prefer',
                  ]),
            );
          });
        }
      });
    });
  });
}

void _writeConfig(MemoryFileSystem fileSystem, String path, String source) {
  final file = fileSystem.file(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(source);
}
