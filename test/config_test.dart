import 'dart:convert';
import 'dart:io' as io;

import 'package:agent_resource/agent_resource.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';
import 'package:toml/toml.dart' show TomlDocument;

void main() {
  group('agent_resource', () {
    group('config', () {
      test('shows its child commands', () async {
        final result = await _executor(
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
          final result = await _executor(fileSystem: fileSystem)
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
                '/sandbox/project/',
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
                    '  cwd: /sandbox/project [explicit-argument @ --cwd]',
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
              await _executor(
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
                '/sandbox/project/',
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
                'path': '/sandbox/project',
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
          final result = await _executor(
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
                    contains('--pack'),
                  ),
                ),
          );
        });

        test('shows explicit target and method origins', () async {
          final result =
              await _executor(
                fileSystem: MemoryFileSystem(style: FileSystemStyle.posix),
              ).fake().execute([
                'config',
                'effective',
                '--user-config',
                '/sandbox/user.toml',
                '--project-config',
                '/sandbox/project.toml',
                '--cwd',
                '/sandbox/project/',
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
              await _executor(
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
                '/sandbox/project/',
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
            final result = await _executor(
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

        test(
          'discovers the Git project root from a nested directory',
          () async {
            final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
            fileSystem.directory('/repo/.git').createSync(recursive: true);
            fileSystem
                .directory('/repo/src/nested')
                .createSync(recursive: true);
            _writeConfig(
              fileSystem,
              '/repo/agent-resources.toml',
              'schema_version = 1\n'
                  '[cli.install]\n'
                  'targets = ["codex"]\n',
            );
            _writeConfig(
              fileSystem,
              '/sandbox/user.toml',
              'schema_version = 1\n',
            );

            final result = await _executor(fileSystem: fileSystem)
                .fake()
                .execute([
                  'config',
                  'effective',
                  '--scope',
                  'project',
                  '--cwd',
                  '/repo/src/nested/',
                  '--user-config',
                  '/sandbox/user.toml',
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
                  'name': 'projectRoot',
                  'path': '/repo',
                  'origin': 'detection',
                  'source': '.git',
                }),
              ),
            );
            expect(
              payload['paths'],
              contains(
                equals(<String, Object?>{
                  'name': 'selectedConfig',
                  'path': '/repo/agent-resources.toml',
                  'origin': 'detection',
                  'source': 'projectRoot',
                }),
              ),
            );
            expect(
              payload['settings'],
              contains(
                equals(<String, Object?>{
                  'key': 'cli.install.targets',
                  'value': ['codex'],
                  'origin': 'project-config',
                  'source': '/repo/agent-resources.toml',
                }),
              ),
            );
          },
        );

        test('reports pack install overrides as pack-config origins', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          const projectPath = '/sandbox/project.toml';
          const packSource = '/sandbox/project.toml#packs."owner/repo".install';
          _writeConfig(
            fileSystem,
            projectPath,
            'schema_version = 1\n'
            '[cli.install]\n'
            'targets = ["codex"]\n'
            'skill_method = "copy"\n'
            '[packs."owner/repo".source]\n'
            'kind = "local"\n'
            'path = "../source"\n'
            '[packs."owner/repo".install]\n'
            'targets = ["claude"]\n'
            'skill_method = "canonical"\n',
          );

          final result = await _executor(fileSystem: fileSystem)
              .fake()
              .execute([
                'config',
                'effective',
                '--scope',
                'project',
                '--pack',
                'owner/repo',
                '--user-config',
                '/sandbox/user.toml',
                '--project-config',
                projectPath,
                '--cwd',
                '/sandbox/project/',
                '--project-root',
                '/sandbox/project/',
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
            <String, Object?>{
              'key': 'cli.install.targets',
              'value': ['claude'],
              'origin': 'pack-config',
              'source': packSource,
            },
            <String, Object?>{
              'key': 'cli.install.skill_method',
              'value': 'canonical',
              'origin': 'pack-config',
              'source': packSource,
            },
            <String, Object?>{
              'key': 'cli.retention.snapshot_days',
              'value': 90,
              'origin': 'built-in-default',
            },
          ]);
        });

        test('refuses an unknown pack selection', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          const projectPath = '/sandbox/project.toml';
          _writeConfig(
            fileSystem,
            projectPath,
            'schema_version = 1\n'
            '[packs."owner/repo".source]\n'
            'kind = "local"\n'
            'path = "../source"\n',
          );

          final result = await _executor(fileSystem: fileSystem)
              .fake()
              .execute([
                'config',
                'effective',
                '--scope',
                'project',
                '--pack',
                'missing',
                '--user-config',
                '/sandbox/user.toml',
                '--project-config',
                projectPath,
                '--cwd',
                '/sandbox/project/',
                '--project-root',
                '/sandbox/project/',
              ]);

          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 2)
                .having(
                  (value) => value.message.contains(
                    'No configured pack matches missing',
                  ),
                  'diagnostic names missing pack',
                  isTrue,
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
                  'effective',
                ]),
          );
        });

        test('labels XDG_CONFIG_HOME as the user config origin', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          const userPath = '/sandbox/xdg/agent-resource/agent-resources.toml';

          final result =
              await _executor(
                fileSystem: fileSystem,
                configurationEnvironment: const <String, String>{
                  'HOME': '/sandbox/home',
                  'XDG_CONFIG_HOME': '/sandbox/xdg',
                },
                configurationOperatingSystem: 'linux',
              ).fake().execute([
                'config',
                'effective',
                '--scope',
                'user',
                '--cwd',
                '/sandbox/project/',
                '--project-root',
                '/sandbox/project/',
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
                'name': 'userConfig',
                'path': userPath,
                'origin': 'detection',
                'source': 'XDG_CONFIG_HOME',
              }),
            ),
          );
          expect(
            payload['paths'],
            contains(
              equals(<String, Object?>{
                'name': 'selectedConfig',
                'path': userPath,
                'origin': 'detection',
                'source': 'XDG_CONFIG_HOME',
              }),
            ),
          );
        });
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

          final result = await _executor(fileSystem: fileSystem)
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
                '/sandbox/project/',
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
            final applyResult = await _executor(fileSystem: fileSystem)
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
                  '/sandbox/project/',
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

            final effectiveResult = await _executor(fileSystem: fileSystem)
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
                  '/sandbox/project/',
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
            final result = await _executor(fileSystem: fileSystem)
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
                  '/sandbox/project/',
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
          final result = await _executor(fileSystem: fileSystem)
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
                '/sandbox/project/',
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
          final result = await _executor(
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
                    contains('credentials are'),
                    contains('refused and never remembered'),
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
            final result = await _executor(
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

        test(
          'applies at the Git project root from a nested directory',
          () async {
            final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
            fileSystem.directory('/repo/.git').createSync(recursive: true);
            fileSystem
                .directory('/repo/src/nested')
                .createSync(recursive: true);
            _writeConfig(
              fileSystem,
              '/repo/agent-resources.toml',
              'schema_version = 1\n'
                  '[cli.retention]\n'
                  'snapshot_days = 45\n',
            );
            _writeConfig(
              fileSystem,
              '/sandbox/user.toml',
              'schema_version = 1\n',
            );

            final result = await _executor(fileSystem: fileSystem)
                .fake()
                .execute([
                  'config',
                  'prefer',
                  '--scope',
                  'project',
                  '--cwd',
                  '/repo/src/nested/',
                  '--user-config',
                  '/sandbox/user.toml',
                  '--set',
                  'cli.retention.snapshot_days=21',
                  '--apply',
                  '--format',
                  'json',
                ]);

            expect(
              result,
              isA<MambaSuccessResult>()
                  .having((value) => value.exitCode, 'exit code', 0)
                  .having((value) => value.output, 'output', isA<String>()),
            );
            final written = fileSystem.file('/repo/agent-resources.toml');
            final writtenMap = TomlDocument.parse(written.readAsStringSync())
                .toMap();
            final writtenCli = writtenMap['cli'] as Map<String, dynamic>;
            final writtenRetention =
                writtenCli['retention'] as Map<String, dynamic>;
            expect(writtenRetention['snapshot_days'], 21);
            expect(
              fileSystem
                  .file('/repo/src/nested/agent-resources.toml')
                  .existsSync(),
              isFalse,
            );
            expect(
              fileSystem
                  .file('/repo/agent-resources.toml.prefer.tmp')
                  .existsSync(),
              isFalse,
            );
          },
        );

        test(
          'preserves comments and formatting during focused apply',
          () async {
            final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
            const projectPath = '/sandbox/project.toml';
            const original =
                '# Consumer configuration\n'
                'schema_version = 1   # keep schema\n'
                '\n'
                '[cli.install] # install table\n'
                '  targets = ["claude"]    # old targets\n'
                'skill_method = "canonical" # method\n'
                '\n'
                '[cli.retention]\n'
                '# retention window\n'
                'snapshot_days = 45  # days\n'
                '\n'
                '[packs."local/demo".source]\n'
                'kind = "local"\n'
                'path = "../source" # keep path\n';
            const expected =
                '# Consumer configuration\n'
                'schema_version = 1   # keep schema\n'
                '\n'
                '[cli.install] # install table\n'
                '  targets = ["codex", "shared"]    # old targets\n'
                'skill_method = "canonical" # method\n'
                '\n'
                '[cli.retention]\n'
                '# retention window\n'
                'snapshot_days = 30  # days\n'
                '\n'
                '[packs."local/demo".source]\n'
                'kind = "local"\n'
                'path = "../source" # keep path\n';
            _writeConfig(fileSystem, projectPath, original);

            final result = await _executor(fileSystem: fileSystem)
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
                  '/sandbox/project/',
                  '--project-root',
                  '/sandbox/project/',
                  '--set',
                  'cli.install.targets=codex,shared',
                  '--set',
                  'cli.retention.snapshot_days=30',
                  '--apply',
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
            expect(payload['proposedConfig'], expected);
            expect(fileSystem.file(projectPath).readAsStringSync(), expected);
            expect(
              fileSystem.file('$projectPath.prefer.tmp').existsSync(),
              isFalse,
            );
          },
        );

        test('refuses layouts that cannot preserve safe formatting', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          const projectPath = '/sandbox/project.toml';
          const original =
              '# keep this comment\n'
              'schema_version = 1\n'
              'cli = { install = { targets = ["claude"] } }\n';
          _writeConfig(fileSystem, projectPath, original);

          final result = await _executor(fileSystem: fileSystem)
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
                '/sandbox/project/',
                '--project-root',
                '/sandbox/project/',
                '--set',
                'cli.install.skill_method=copy',
                '--apply',
              ]);

          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 2)
                .having(
                  (value) => value.message.contains('Cannot safely preserve'),
                  'diagnostic names refusal',
                  isTrue,
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

        test('preserves unrelated files at the old staging path', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          const projectPath = '/sandbox/project.toml';
          const oldStagingPath = '/sandbox/project.toml.prefer.tmp';
          _writeConfig(
            fileSystem,
            projectPath,
            'schema_version = 1\n[cli.retention]\nsnapshot_days = 45\n',
          );
          _writeConfig(fileSystem, oldStagingPath, 'unrelated data');

          final result = await _executor(fileSystem: fileSystem)
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
                '/sandbox/project/',
                '--project-root',
                '/sandbox/project/',
                '--set',
                'cli.retention.snapshot_days=30',
                '--apply',
              ]);

          expect(result, isA<MambaSuccessResult>());
          expect(
            fileSystem.file(oldStagingPath).readAsStringSync(),
            'unrelated data',
          );
          expect(
            fileSystem
                .directory('/sandbox')
                .listSync()
                .where(
                  (entity) => entity.path.contains('agent-resource-prefer-'),
                ),
            isEmpty,
          );
        });

        test('refuses symlink configuration targets', () async {
          final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
          const projectPath = '/sandbox/project.toml';
          const realPath = '/sandbox/real.toml';
          const original =
              'schema_version = 1\n[cli.retention]\nsnapshot_days = 45\n';
          _writeConfig(fileSystem, realPath, original);
          fileSystem.link(projectPath).createSync(realPath);

          final result = await _executor(fileSystem: fileSystem)
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
                '/sandbox/project/',
                '--project-root',
                '/sandbox/project/',
                '--set',
                'cli.retention.snapshot_days=30',
                '--apply',
              ]);

          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 2)
                .having(
                  (value) => value.message.contains('Cannot safely publish'),
                  'diagnostic names safety refusal',
                  isTrue,
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
          expect(fileSystem.file(realPath).readAsStringSync(), original);
          expect(
            fileSystem.typeSync(projectPath, followLinks: false),
            io.FileSystemEntityType.link,
          );
        });

        test('preserves target identity without rename replacement', () async {
          final temporaryDirectory = io.Directory.systemTemp.createTempSync(
            'agent_resource_config_test_',
          );
          addTearDown(() {
            if (temporaryDirectory.existsSync()) {
              temporaryDirectory.deleteSync(recursive: true);
            }
          });
          final projectPath = io.Directory(temporaryDirectory.path).uri
              .resolve('project.toml')
              .toFilePath();
          final fileSystem = _PublicationProbeFileSystem(
            local.LocalFileSystem(),
            projectPath,
          );
          final cwd = '${temporaryDirectory.path}${fileSystem.path.separator}';
          const original =
              '# keep this comment\n'
              'schema_version = 1\n'
              '[cli.retention]\n'
              'snapshot_days = 45 # keep days\n';
          fileSystem.file(projectPath).writeAsStringSync(original);

          final result = await _executor(fileSystem: fileSystem)
              .fake()
              .execute([
                'config',
                'prefer',
                '--scope',
                'project',
                '--user-config',
                fileSystem.path.join(temporaryDirectory.path, 'user.toml'),
                '--project-config',
                projectPath,
                '--cwd',
                cwd,
                '--project-root',
                cwd,
                '--set',
                'cli.retention.snapshot_days=30',
                '--apply',
              ]);

          expect(result, isA<MambaSuccessResult>());
          expect(fileSystem.openCount, greaterThan(0));
          expect(
            fileSystem.file(projectPath).readAsStringSync(),
            contains('snapshot_days = 30'),
          );
          expect(
            temporaryDirectory.listSync().where(
              (entity) => entity.path.contains('agent-resource-prefer-'),
            ),
            isEmpty,
          );
        });

        for (final failure in _PublicationFailure.values) {
          test('keeps original bytes when ${failure.name} fails', () async {
            final temporaryDirectory = io.Directory.systemTemp.createTempSync(
              'agent_resource_config_test_',
            );
            addTearDown(() {
              if (temporaryDirectory.existsSync()) {
                temporaryDirectory.deleteSync(recursive: true);
              }
            });
            final projectPath = io.Directory(temporaryDirectory.path).uri
                .resolve('project.toml')
                .toFilePath();
            final fileSystem = _FailingPublicationFileSystem(
              local.LocalFileSystem(),
              projectPath,
              failure,
            );
            final cwd =
                '${temporaryDirectory.path}${fileSystem.path.separator}';
            const original =
                '# keep this comment\n'
                'schema_version = 1\n'
                '[cli.retention]\n'
                'snapshot_days = 45 # keep days\n';
            fileSystem.file(projectPath).writeAsStringSync(original);

            final result = await _executor(fileSystem: fileSystem)
                .fake()
                .execute([
                  'config',
                  'prefer',
                  '--scope',
                  'project',
                  '--user-config',
                  fileSystem.path.join(temporaryDirectory.path, 'user.toml'),
                  '--project-config',
                  projectPath,
                  '--cwd',
                  cwd,
                  '--project-root',
                  cwd,
                  '--set',
                  'cli.retention.snapshot_days=30',
                  '--apply',
                ]);

            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'exit code', 1)
                  .having(
                    (value) =>
                        value.message.contains('Could not write configuration'),
                    'diagnostic names publication failure',
                    isTrue,
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
            expect(
              temporaryDirectory.listSync().where(
                (entity) => entity.path.contains('agent-resource-prefer-'),
              ),
              isEmpty,
            );
          });
        }
      });
    });
  });
}

Executor _executor({
  fslib.FileSystem? fileSystem,
  Map<String, String>? configurationEnvironment,
  String? configurationOperatingSystem,
}) {
  fslib.FileSystem resolved =
      fileSystem ?? MemoryFileSystem(style: FileSystemStyle.posix);
  if (resolved is MemoryFileSystem) {
    for (final path in const <String>[
      '/sandbox',
      '/sandbox/project',
      '/sandbox/home',
    ]) {
      resolved.directory(path).createSync(recursive: true);
    }
    resolved = _LockEnabledFileSystem(resolved);
  }
  return createExecutor(
    fileSystem: resolved,
    configurationEnvironment: configurationEnvironment,
    configurationOperatingSystem: configurationOperatingSystem,
  );
}

void _writeConfig(MemoryFileSystem fileSystem, String path, String source) {
  final file = fileSystem.file(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(source);
}

enum _PublicationFailure { lock, write }

final class _LockEnabledFileSystem extends fslib.ForwardingFileSystem {
  _LockEnabledFileSystem(super.delegate);

  @override
  fslib.File file(dynamic path) => _LockEnabledFile(this, super.file(path));
}

final class _LockEnabledFile
    extends fslib.ForwardingFileSystemEntity<fslib.File, io.File>
    with fslib.ForwardingFile {
  _LockEnabledFile(this.fileSystem, this.delegate);

  @override
  final fslib.FileSystem fileSystem;

  @override
  final io.File delegate;

  @override
  io.RandomAccessFile openSync({io.FileMode mode = io.FileMode.read}) =>
      _LockEnabledRandomAccessFile(delegate.openSync(mode: mode));

  @override
  fslib.Directory wrapDirectory(io.Directory delegate) =>
      fileSystem.directory(delegate.path);

  @override
  fslib.File wrapFile(io.File delegate) =>
      _LockEnabledFile(fileSystem, delegate);

  @override
  fslib.Link wrapLink(io.Link delegate) => fileSystem.link(delegate.path);
}

final class _LockEnabledRandomAccessFile with fslib.ForwardingRandomAccessFile {
  _LockEnabledRandomAccessFile(this.delegate);

  @override
  final io.RandomAccessFile delegate;

  @override
  void lockSync([
    io.FileLock mode = io.FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) {}

  @override
  void unlockSync([int start = 0, int end = -1]) {}
}

final class _PublicationProbeFileSystem extends _LockEnabledFileSystem {
  _PublicationProbeFileSystem(super.delegate, this.targetPath);

  final String targetPath;
  var openCount = 0;

  @override
  fslib.File file(dynamic path) => _PublicationProbeFile(
    this,
    super.file(path),
    targetPath,
    () => openCount++,
  );
}

final class _PublicationProbeFile
    extends fslib.ForwardingFileSystemEntity<fslib.File, io.File>
    with fslib.ForwardingFile {
  _PublicationProbeFile(
    this.fileSystem,
    this.delegate,
    this.targetPath,
    this._onOpen,
  );

  @override
  final fslib.FileSystem fileSystem;

  @override
  final io.File delegate;

  final String targetPath;
  final void Function() _onOpen;

  @override
  io.RandomAccessFile openSync({io.FileMode mode = io.FileMode.read}) {
    if (path == targetPath) _onOpen();
    return delegate.openSync(mode: mode);
  }

  @override
  fslib.File renameSync(String newPath) =>
      throw io.FileSystemException('unsafe replacement', path);

  @override
  fslib.Directory wrapDirectory(io.Directory delegate) =>
      fileSystem.directory(delegate.path);

  @override
  fslib.File wrapFile(io.File delegate) =>
      _PublicationProbeFile(fileSystem, delegate, targetPath, _onOpen);

  @override
  fslib.Link wrapLink(io.Link delegate) => fileSystem.link(delegate.path);
}

final class _FailingPublicationFileSystem extends _LockEnabledFileSystem {
  _FailingPublicationFileSystem(super.delegate, this.targetPath, this.failure);

  final String targetPath;
  final _PublicationFailure failure;

  @override
  fslib.File file(dynamic path) {
    final file = super.file(path);
    if (file.path != targetPath) return file;
    return _FailingPublicationFile(this, file, failure);
  }
}

final class _FailingPublicationFile
    extends fslib.ForwardingFileSystemEntity<fslib.File, io.File>
    with fslib.ForwardingFile {
  _FailingPublicationFile(this.fileSystem, this.delegate, this.failure);

  @override
  final fslib.FileSystem fileSystem;

  @override
  final io.File delegate;

  final _PublicationFailure failure;

  @override
  io.RandomAccessFile openSync({io.FileMode mode = io.FileMode.read}) =>
      _FailingPublicationRandomAccessFile(
        delegate.openSync(mode: mode),
        failure,
      );

  @override
  fslib.Directory wrapDirectory(io.Directory delegate) =>
      fileSystem.directory(delegate.path);

  @override
  fslib.File wrapFile(io.File delegate) =>
      _FailingPublicationFile(fileSystem, delegate, failure);

  @override
  fslib.Link wrapLink(io.Link delegate) => fileSystem.link(delegate.path);
}

final class _FailingPublicationRandomAccessFile
    with fslib.ForwardingRandomAccessFile {
  _FailingPublicationRandomAccessFile(this.delegate, this.failure);

  @override
  final io.RandomAccessFile delegate;

  final _PublicationFailure failure;
  var _failedWrite = false;

  @override
  void lockSync([
    io.FileLock mode = io.FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) {
    if (failure == _PublicationFailure.lock) {
      throw io.FileSystemException('concurrent configuration update', path);
    }
    delegate.lockSync(mode, start, end);
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    if (failure == _PublicationFailure.write && !_failedWrite) {
      _failedWrite = true;
      throw io.FileSystemException('injected publication write failure', path);
    }
    delegate.writeFromSync(buffer, start, end);
  }

  @override
  void unlockSync([int start = 0, int end = -1]) =>
      delegate.unlockSync(start, end);
}
