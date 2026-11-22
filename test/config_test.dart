import 'dart:convert';
import 'dart:io' as io;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/config.dart';
import 'package:agent_resource/src/services/configuration_publication_service.dart';
import 'package:agent_resource/src/services/configuration_workflow_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:mamba/mamba.dart' show MambaException;
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

import 'support/trusted_temp.dart';

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

        test(
          'applies a user preference when its parent does not exist',
          () async {
            final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
            const userPath = '/sandbox/home/new/config.toml';
            final result = await _executor(fileSystem: fileSystem)
                .fake()
                .execute([
                  'config',
                  'prefer',
                  '--scope',
                  'user',
                  '--user-config',
                  userPath,
                  '--project-config',
                  '/sandbox/project.toml',
                  '--cwd',
                  '/sandbox/project/',
                  '--project-root',
                  '/sandbox/project/',
                  '--set',
                  'cli.retention.snapshot_days=14',
                  '--apply',
                ]);
            expect(result, isA<MambaSuccessResult>());
            expect(
              fileSystem.file(userPath).readAsStringSync(),
              contains('snapshot_days = 14'),
            );
          },
        );

        test(
          'applies user preferences when project state is on another volume',
          () async {
            final fs = MemoryFileSystem(style: FileSystemStyle.posix);
            _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
            fs.directory('/project').createSync(recursive: true);
            final lifecycleIO = _SeparateVolumesIO(fs: fs);
            final workflow = ConfigurationWorkflowService(
              fileSystem: fs,
              environment: const {'HOME': '/user'},
              publication: ConfigurationPublicationService(
                fileSystem: fs,
                io: lifecycleIO,
              ),
            );
            final executor = Executor('agent_resource', 'test', '1.0.0', [
              ConfigCommand(workflow: workflow, fileSystem: fs),
            ]);
            final result = await executor.fake().execute([
              'config',
              'prefer',
              '--scope',
              'user',
              '--user-config',
              '/user/config.toml',
              '--project-config',
              '/project/config.toml',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(
              fs.file('/user/config.toml').readAsStringSync(),
              contains('snapshot_days = 14'),
            );
          },
        );

        test(
          'blocks another project after interrupted shared user publication',
          () async {
            final fs = MemoryFileSystem(style: FileSystemStyle.posix);
            _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
            fs.directory('/project-a').createSync(recursive: true);
            fs.directory('/project-b').createSync(recursive: true);
            final lifecycleIO = _InterruptAfterQuarantineIO(fs: fs);
            final workflow = ConfigurationWorkflowService(
              fileSystem: fs,
              environment: const {'HOME': '/user'},
              publication: ConfigurationPublicationService(
                fileSystem: fs,
                io: lifecycleIO,
              ),
            );
            final executor = Executor('agent_resource', 'test', '1.0.0', [
              ConfigCommand(workflow: workflow, fileSystem: fs),
            ]);
            List<String> args(String project) => [
              'config',
              'prefer',
              '--scope',
              'user',
              '--user-config',
              '/user/config.toml',
              '--project-config',
              '$project/config.toml',
              '--cwd',
              '$project/',
              '--project-root',
              '$project/',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ];
            await expectLater(
              executor.fake().execute(args('/project-a')),
              throwsA(isA<StateError>()),
            );
            final result = await executor.fake().execute(args('/project-b'));
            expect(
              result,
              isA<MambaFailureResult>().having(
                (r) => r.message,
                'message',
                contains('recovery'),
              ),
            );
            expect(fs.file('/user/config.toml').existsSync(), isFalse);
          },
        );

        test('discovers interrupted configuration in both lifecycle recovery commands', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
          fs.directory('/project').createSync(recursive: true);
          final lifecycleIO = _InterruptAfterQuarantineIO(fs: fs);
          final workflow = ConfigurationWorkflowService(
            fileSystem: fs,
            environment: const {'HOME': '/user'},
            publication: ConfigurationPublicationService(
              fileSystem: fs,
              io: lifecycleIO,
            ),
          );
          final executor = Executor('agent_resource', 'test', '1.0.0', [
            ConfigCommand(workflow: workflow, fileSystem: fs),
          ]);
          await expectLater(
            executor.fake().execute([
              'config',
              'prefer',
              '--scope',
              'user',
              '--user-config',
              '/user/config.toml',
              '--project-config',
              '/project/config.toml',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ]),
            throwsA(isA<StateError>()),
          );
          for (final resource in ['skill', 'agent']) {
            final result = await createExecutor(fileSystem: fs).fake().execute([
              resource,
              'recover',
              '--scope',
              'project',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--configuration-target',
              '/user/config.toml',
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            final output = jsonDecode(
              (result as MambaSuccessResult).output as String,
            ) as Map<String, dynamic>;
            expect(
              output['data']['transactions'],
              contains(
                isA<Map<String, dynamic>>().having(
                  (v) => v['target'],
                  'target',
                  '/user/config.toml',
                ),
              ),
            );
          }
        });

        test(
          'rolls back an interrupted configuration quarantine with approval',
          () async {
            final fs = MemoryFileSystem(style: FileSystemStyle.posix);
            _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
            fs.directory('/project').createSync(recursive: true);
            final lifecycleIO = _InterruptAfterQuarantineIO(fs: fs);
            final workflow = ConfigurationWorkflowService(
              fileSystem: fs,
              environment: const {'HOME': '/user'},
              publication: ConfigurationPublicationService(
                fileSystem: fs,
                io: lifecycleIO,
              ),
            );
            final config = Executor('agent_resource', 'test', '1.0.0', [
              ConfigCommand(workflow: workflow, fileSystem: fs),
            ]);
            await expectLater(
              config.fake().execute([
                'config',
                'prefer',
                '--scope',
                'user',
                '--user-config',
                '/user/config.toml',
                '--project-config',
                '/project/config.toml',
                '--cwd',
                '/project/',
                '--project-root',
                '/project/',
                '--set',
                'cli.retention.snapshot_days=14',
                '--apply',
              ]),
              throwsA(isA<StateError>()),
            );
            final recovery = createExecutor(fileSystem: fs).fake();
            final common = [
              '--scope',
              'project',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--configuration-target',
              '/user/config.toml',
              '--format',
              'json',
            ];
            final listing = await recovery.execute([
              'skill',
              'recover',
              ...common,
            ]) as MambaSuccessResult;
            final data =
                jsonDecode(listing.output as String) as Map<String, dynamic>;
            final id =
                (data['data']['transactions'] as List).single['transactionId']
                    as String;
            final rejected = await recovery.execute([
              'skill',
              'recover',
              id,
              ...common,
              '--action',
              'rollback',
            ]);
            expect(rejected, isA<MambaFailureResult>());
            expect(fs.file('/user/config.toml').existsSync(), isFalse);
            final applied = await recovery.execute([
              'skill',
              'recover',
              id,
              ...common,
              '--action',
              'rollback',
              '--yes',
            ]);
            expect(
              applied,
              isA<MambaSuccessResult>(),
              reason: applied is MambaFailureResult ? applied.message : null,
            );
            expect(
              fs.file('/user/config.toml').readAsStringSync(),
              'schema_version = 1\n',
            );
          },
        );

        test('retains readable recovery evidence when a phase write is interrupted', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
          fs.directory('/project').createSync(recursive: true);
          final lifecycleIO = _InterruptPhaseWriteIO(fs: fs);
          final workflow = ConfigurationWorkflowService(
            fileSystem: fs,
            environment: const {'HOME': '/user'},
            publication: ConfigurationPublicationService(
              fileSystem: fs,
              io: lifecycleIO,
            ),
          );
          final config = Executor('agent_resource', 'test', '1.0.0', [
            ConfigCommand(workflow: workflow, fileSystem: fs),
          ]);
          await expectLater(
            config.fake().execute([
              'config',
              'prefer',
              '--scope',
              'user',
              '--user-config',
              '/user/config.toml',
              '--project-config',
              '/project/config.toml',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ]),
            throwsA(isA<StateError>()),
          );
          final result = await createExecutor(fileSystem: fs).fake().execute([
            'agent',
            'recover',
            '--scope',
            'project',
            '--cwd',
            '/project/',
            '--project-root',
            '/project/',
            '--configuration-target',
            '/user/config.toml',
            '--format',
            'json',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final data = jsonDecode(
            (result as MambaSuccessResult).output as String,
          ) as Map<String, dynamic>;
          final transactions = data['data']['transactions'] as List<dynamic>;
          expect(transactions, hasLength(1));
          final id = transactions.single['transactionId'] as String;
          final recovered = await createExecutor(fileSystem: fs)
              .fake()
              .execute([
                'agent',
                'recover',
                id,
                '--scope',
                'project',
                '--cwd',
                '/project/',
                '--project-root',
                '/project/',
                '--configuration-target',
                '/user/config.toml',
                '--action',
                'rollback',
                '--yes',
              ]);
          expect(
            recovered,
            isA<MambaSuccessResult>(),
            reason: recovered is MambaFailureResult ? recovered.message : null,
          );
          expect(
            fs.file('/user/config.toml').readAsStringSync(),
            'schema_version = 1\n',
          );
        });

        test(
          'completes an interrupted published configuration with approval',
          () async {
            final fs = MemoryFileSystem(style: FileSystemStyle.posix);
            _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
            fs.directory('/project').createSync(recursive: true);
            final lifecycleIO = _InterruptAfterPublishIO(fs: fs);
            final workflow = ConfigurationWorkflowService(
              fileSystem: fs,
              environment: const {'HOME': '/user'},
              publication: ConfigurationPublicationService(
                fileSystem: fs,
                io: lifecycleIO,
              ),
            );
            final config = Executor('agent_resource', 'test', '1.0.0', [
              ConfigCommand(workflow: workflow, fileSystem: fs),
            ]);
            await expectLater(
              config.fake().execute([
                'config',
                'prefer',
                '--scope',
                'user',
                '--user-config',
                '/user/config.toml',
                '--project-config',
                '/project/config.toml',
                '--cwd',
                '/project/',
                '--project-root',
                '/project/',
                '--set',
                'cli.retention.snapshot_days=14',
                '--apply',
              ]),
              throwsA(isA<StateError>()),
            );
            final recovery = createExecutor(fileSystem: fs).fake();
            final common = [
              '--scope',
              'project',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--configuration-target',
              '/user/config.toml',
              '--format',
              'json',
            ];
            final listing = await recovery.execute([
              'agent',
              'recover',
              ...common,
            ]) as MambaSuccessResult;
            final data =
                jsonDecode(listing.output as String) as Map<String, dynamic>;
            final id =
                (data['data']['transactions'] as List<dynamic>)
                        .single['transactionId']
                    as String;
            final result = await recovery.execute([
              'agent',
              'recover',
              id,
              ...common,
              '--action',
              'complete',
              '--yes',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(
              fs.file('/user/config.toml').readAsStringSync(),
              contains('snapshot_days = 14'),
            );
            final after = await recovery.execute([
              'agent',
              'recover',
              ...common,
            ]) as MambaSuccessResult;
            expect(
              (jsonDecode(after.output as String)
                  as Map<String, dynamic>)['data']['transactions'],
              isEmpty,
            );
          },
        );

        test('refuses a recovery plan if published bytes changed', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
          fs.directory('/project').createSync(recursive: true);
          final lifecycleIO = _InterruptAfterPublishIO(fs: fs);
          final workflow = ConfigurationWorkflowService(
            fileSystem: fs,
            environment: const {'HOME': '/user'},
            publication: ConfigurationPublicationService(
              fileSystem: fs,
              io: lifecycleIO,
            ),
          );
          final config = Executor('agent_resource', 'test', '1.0.0', [
            ConfigCommand(workflow: workflow, fileSystem: fs),
          ]);
          await expectLater(
            config.fake().execute([
              'config',
              'prefer',
              '--scope',
              'user',
              '--user-config',
              '/user/config.toml',
              '--project-config',
              '/project/config.toml',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ]),
            throwsA(isA<StateError>()),
          );
          final recovery = createExecutor(fileSystem: fs).fake();
          final common = [
            '--scope',
            'project',
            '--cwd',
            '/project/',
            '--project-root',
            '/project/',
            '--configuration-target',
            '/user/config.toml',
            '--format',
            'json',
          ];
          final listing = await recovery.execute([
            'skill',
            'recover',
            ...common,
          ]) as MambaSuccessResult;
          final data =
              jsonDecode(listing.output as String) as Map<String, dynamic>;
          final id =
              (data['data']['transactions'] as List<dynamic>)
                      .single['transactionId']
                  as String;
          fs.file('/user/config.toml').writeAsStringSync('external change\n');
          final result = await recovery.execute([
            'skill',
            'recover',
            id,
            ...common,
            '--action',
            'complete',
            '--dry-run',
          ]);
          expect(result, isA<MambaFailureResult>());
          expect(
            fs.file('/user/config.toml').readAsStringSync(),
            'external change\n',
          );
        });

        test('rolls back an interrupted first-time configuration publication across all scopes', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          fs.directory('/user').createSync(recursive: true);
          fs.directory('/project').createSync(recursive: true);
          final workflow = ConfigurationWorkflowService(
            fileSystem: fs,
            environment: const {'HOME': '/user'},
            publication: ConfigurationPublicationService(
              fileSystem: fs,
              io: _InterruptBeforeStageIO(fs: fs),
            ),
          );
          final config = Executor('agent_resource', 'test', '1.0.0', [
            ConfigCommand(workflow: workflow, fileSystem: fs),
          ]);
          await expectLater(
            config.fake().execute([
              'config',
              'prefer',
              '--scope',
              'user',
              '--user-config',
              '/user/config.toml',
              '--project-config',
              '/project/config.toml',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ]),
            throwsA(isA<StateError>()),
          );
          final recovery = createExecutor(fileSystem: fs).fake();
          final common = [
            '--scope',
            'all',
            '--cwd',
            '/project/',
            '--project-root',
            '/project/',
            '--configuration-target',
            '/user/config.toml',
            '--format',
            'json',
          ];
          final listing = await recovery.execute([
            'skill',
            'recover',
            ...common,
          ]) as MambaSuccessResult;
          final data =
              jsonDecode(listing.output as String) as Map<String, dynamic>;
          final id =
              (data['data']['transactions'] as List<dynamic>)
                      .single['transactionId']
                  as String;
          final result = await recovery.execute([
            'skill',
            'recover',
            id,
            ...common,
            '--action',
            'rollback',
            '--yes',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          expect(fs.file('/user/config.toml').existsSync(), isFalse);
        });

        test('skill lifecycle recovery respects a nested configuration reservation', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          fs.directory('/project').createSync(recursive: true);
          fs.directory('/home').createSync(recursive: true);
          _writeConfig(
            fs,
            '/source/SKILL.md',
            '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
          );
          const live = '/project/.claude/skills/review';
          final installIO = _InterruptSkillInstallIO(live, fs);
          final skill = SkillLifecycleService(
            state: LifecycleStateService(io: installIO),
          );
          String? id;
          try {
            await skill.install(
              SkillInstallInput(
                options: LifecycleOptions(
                  processWorkingDirectory: '/',
                  cwd: '/project',
                  projectRoot: '/project',
                  home: '/home',
                  scope: LifecycleScope.project,
                ),
                source: '/source',
                destination: SkillDestination.claude,
              ),
            );
            fail('Expected interrupted install');
          } on MambaException catch (error) {
            id = RegExp(r'transaction (trx_[a-f0-9]{32})')
                .firstMatch(error.message)
                ?.group(1);
          }
          expect(id, isNotNull);
          final target = '$live/agent-resources.toml';
          _writeConfig(fs, target, 'schema_version = 1\n');
          final workflow = ConfigurationWorkflowService(
            fileSystem: fs,
            environment: const {'HOME': '/home'},
            publication: ConfigurationPublicationService(
              fileSystem: fs,
              io: _InterruptTargetIO(fs: fs, target: target),
            ),
          );
          final config = Executor('agent_resource', 'test', '1.0.0', [
            ConfigCommand(workflow: workflow, fileSystem: fs),
          ]);
          await expectLater(
            config.fake().execute([
              'config',
              'prefer',
              '--scope',
              'project',
              '--project-config',
              target,
              '--user-config',
              '/home/config.toml',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ]),
            throwsA(isA<StateError>()),
          );
          final result = await createExecutor(fileSystem: fs).fake().execute([
            'skill',
            'recover',
            id!,
            '--action',
            'rollback',
            '--yes',
            '--scope',
            'project',
            '--cwd',
            '/project/',
            '--project-root',
            '/project/',
            '--home',
            '/home/',
          ]);
          expect(
            result,
            isA<MambaFailureResult>().having(
              (r) => r.message,
              'message',
              contains('configuration'),
            ),
          );
        });

        test('discovers and rolls back legacy project-scoped configuration evidence', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
          fs.directory('/project').createSync(recursive: true);
          final workflow = ConfigurationWorkflowService(
            fileSystem: fs,
            environment: const {'HOME': '/user'},
            publication: ConfigurationPublicationService(
              fileSystem: fs,
              io: _InterruptAfterQuarantineIO(fs: fs),
            ),
          );
          final config = Executor('agent_resource', 'test', '1.0.0', [
            ConfigCommand(workflow: workflow, fileSystem: fs),
          ]);
          await expectLater(
            config.fake().execute([
              'config',
              'prefer',
              '--scope',
              'user',
              '--user-config',
              '/user/config.toml',
              '--project-config',
              '/project/config.toml',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ]),
            throwsA(isA<StateError>()),
          );
          final evidence = fs
              .directory('/user/.agent-resource-configuration')
              .listSync(recursive: true)
              .whereType<fslib.File>()
              .singleWhere((file) => file.path.endsWith('.json'));
          final legacy = fs.directory(
            '/project/.agent-resource/configuration-transactions',
          )..createSync(recursive: true);
          evidence.renameSync(
            fs.path.join(legacy.path, fs.path.basename(evidence.path)),
          );
          final recovery = createExecutor(fileSystem: fs).fake();
          final common = [
            '--scope',
            'project',
            '--cwd',
            '/project/',
            '--project-root',
            '/project/',
            '--configuration-target',
            '/user/config.toml',
            '--format',
            'json',
          ];
          final listing = await recovery.execute([
            'agent',
            'recover',
            ...common,
          ]) as MambaSuccessResult;
          final data =
              jsonDecode(listing.output as String) as Map<String, dynamic>;
          final id =
              (data['data']['transactions'] as List<dynamic>)
                      .single['transactionId']
                  as String;
          final result = await recovery.execute([
            'agent',
            'recover',
            id,
            ...common,
            '--action',
            'rollback',
            '--yes',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          expect(
            fs.file('/user/config.toml').readAsStringSync(),
            'schema_version = 1\n',
          );
        });

        test(
          'recovery removes verified orphan staging after interruption',
          () async {
            final fs = MemoryFileSystem(style: FileSystemStyle.posix);
            fs.directory('/user').createSync(recursive: true);
            fs.directory('/project').createSync(recursive: true);
            final workflow = ConfigurationWorkflowService(
              fileSystem: fs,
              environment: const {'HOME': '/user'},
              publication: ConfigurationPublicationService(
                fileSystem: fs,
                io: _OrphanStageIO(fs: fs),
              ),
            );
            final config = Executor('agent_resource', 'test', '1.0.0', [
              ConfigCommand(workflow: workflow, fileSystem: fs),
            ]);
            await expectLater(
              config.fake().execute([
                'config',
                'prefer',
                '--scope',
                'user',
                '--user-config',
                '/user/config.toml',
                '--project-config',
                '/project/config.toml',
                '--cwd',
                '/project/',
                '--project-root',
                '/project/',
                '--set',
                'cli.retention.snapshot_days=14',
                '--apply',
              ]),
              throwsA(isA<StateError>()),
            );
            expect(
              fs
                  .directory('/user')
                  .listSync()
                  .where((e) => e.path.contains('agent-resource-prefer-')),
              isNotEmpty,
            );
            final recovery = createExecutor(fileSystem: fs).fake();
            final common = [
              '--scope',
              'project',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--configuration-target',
              '/user/config.toml',
              '--format',
              'json',
            ];
            final listing = await recovery.execute([
              'skill',
              'recover',
              ...common,
            ]) as MambaSuccessResult;
            final data =
                jsonDecode(listing.output as String) as Map<String, dynamic>;
            final id =
                (data['data']['transactions'] as List<dynamic>)
                        .single['transactionId']
                    as String;
            final result = await recovery.execute([
              'skill',
              'recover',
              id,
              ...common,
              '--action',
              'rollback',
              '--yes',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(
              fs
                  .directory('/user')
                  .listSync()
                  .where((e) => e.path.contains('agent-resource-prefer-')),
              isEmpty,
            );
          },
        );

        test('rolls back a verified published configuration without losing original bytes', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
          fs.directory('/project').createSync(recursive: true);
          final workflow = ConfigurationWorkflowService(
            fileSystem: fs,
            environment: const {'HOME': '/user'},
            publication: ConfigurationPublicationService(
              fileSystem: fs,
              io: _InterruptAfterPublishIO(fs: fs),
            ),
          );
          final config = Executor('agent_resource', 'test', '1.0.0', [
            ConfigCommand(workflow: workflow, fileSystem: fs),
          ]);
          await expectLater(
            config.fake().execute([
              'config',
              'prefer',
              '--scope',
              'user',
              '--user-config',
              '/user/config.toml',
              '--project-config',
              '/project/config.toml',
              '--cwd',
              '/project/',
              '--project-root',
              '/project/',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ]),
            throwsA(isA<StateError>()),
          );
          final recovery = createExecutor(fileSystem: fs).fake();
          final common = [
            '--scope',
            'project',
            '--cwd',
            '/project/',
            '--project-root',
            '/project/',
            '--configuration-target',
            '/user/config.toml',
            '--format',
            'json',
          ];
          final listing = await recovery.execute([
            'agent',
            'recover',
            ...common,
          ]) as MambaSuccessResult;
          final data =
              jsonDecode(listing.output as String) as Map<String, dynamic>;
          final id =
              (data['data']['transactions'] as List<dynamic>)
                      .single['transactionId']
                  as String;
          final result = await recovery.execute([
            'agent',
            'recover',
            id,
            ...common,
            '--action',
            'rollback',
            '--yes',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          expect(
            fs.file('/user/config.toml').readAsStringSync(),
            'schema_version = 1\n',
          );
        });

        test(
          'blocks alternate Windows casing of a reserved configuration target',
          () async {
            final fs = MemoryFileSystem(style: FileSystemStyle.windows);
            fs.directory(r'C:\projectA').createSync(recursive: true);
            fs.directory(r'C:\projectB').createSync(recursive: true);
            fs.directory(r'C:\user').createSync(recursive: true);
            const target = r'C:\user\config.toml';
            fs.file(target).writeAsStringSync('schema_version = 1\n');
            final workflow = ConfigurationWorkflowService(
              fileSystem: fs,
              environment: const {'HOME': r'C:\user'},
              publication: ConfigurationPublicationService(
                fileSystem: fs,
                io: _InterruptTargetIO(fs: fs, target: target),
              ),
            );
            final executor = Executor('agent_resource', 'test', '1.0.0', [
              ConfigCommand(workflow: workflow, fileSystem: fs),
            ]);
            List<String> args(String project, String user) => [
              'config',
              'prefer',
              '--scope',
              'user',
              '--user-config',
              user,
              '--project-config',
              r'C:\projectA\config.toml',
              '--cwd',
              '$project\\',
              '--project-root',
              '$project\\',
              '--set',
              'cli.retention.snapshot_days=14',
              '--apply',
            ];
            await expectLater(
              executor.fake().execute(args(r'C:\projectA', target)),
              throwsA(isA<StateError>()),
            );
            final result = await executor.fake().execute(
              args(r'C:\projectB', r'C:\user\CONFIG.toml'),
            );
            expect(
              result,
              isA<MambaFailureResult>().having(
                (r) => r.message,
                'message',
                contains('recovery'),
              ),
            );
          },
        );

        test('serializes shared target publications from separate processes', () async {
          final root = io.Directory(
            createTrustedTempPathSync('config-coordination-'),
          );
          try {
            final projectA = io.Directory(
              '${root.path}${io.Platform.pathSeparator}a',
            )..createSync();
            final projectB = io.Directory(
              '${root.path}${io.Platform.pathSeparator}b',
            )..createSync();
            final target = io.File(
              '${root.path}${io.Platform.pathSeparator}config.toml',
            )..writeAsStringSync('schema_version = 1\n');
            final marker = io.File(
              '${root.path}${io.Platform.pathSeparator}held',
            );
            final script = io.File(
              '${root.path}${io.Platform.pathSeparator}worker.dart',
            )..writeAsStringSync(_coordinationWorker);
            final packages = io.File('.dart_tool/package_config.json')
                .absolute
                .path;
            final kernel =
                '${root.path}${io.Platform.pathSeparator}worker.dill';
            final compiled = await io.Process.run(
              io.Platform.resolvedExecutable,
              [
                'compile',
                'kernel',
                '--packages=$packages',
                '-o',
                kernel,
                script.path,
              ],
            ).timeout(const Duration(seconds: 45));
            expect(
              compiled.exitCode,
              0,
              reason: '${compiled.stdout} ${compiled.stderr}',
            );
            Future<io.Process> start(io.Directory project, bool hold) =>
                io.Process.start(io.Platform.resolvedExecutable, [
                  '--packages=$packages',
                  kernel,
                  project.path,
                  target.path,
                  marker.path,
                  hold.toString(),
                ]);
            final first = await start(projectA, true);
            final firstOut = first.stdout.transform(utf8.decoder).join();
            final firstErr = first.stderr.transform(utf8.decoder).join();
            for (var i = 0; i < 150 && !marker.existsSync(); i++) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            if (!marker.existsSync()) {
              final code = await first.exitCode;
              fail(
                'First worker exited $code: ${await firstOut} ${await firstErr}',
              );
            }
            final second = await start(projectB, false);
            final secondOut = second.stdout.transform(utf8.decoder).join();
            final secondErr = second.stderr.transform(utf8.decoder).join();
            final secondCode = await second.exitCode;
            final firstCode = await first.exitCode;
            expect(firstCode, 0, reason: '${await firstOut} ${await firstErr}');
            expect(
              secondCode,
              isNot(0),
              reason: '${await secondOut} ${await secondErr}',
            );
            expect(target.readAsStringSync(), contains('snapshot_days = 14'));
          } finally {
            root.deleteSync(recursive: true);
          }
        }, timeout: const Timeout(Duration(seconds: 90)));

        test('does not serialize unrelated publications from separate processes', () async {
          final root = io.Directory(
            createTrustedTempPathSync('config-coordination-'),
          );
          io.Process? first;
          io.Process? second;
          try {
            final projectA = io.Directory(
              '${root.path}${io.Platform.pathSeparator}a',
            )..createSync();
            final projectB = io.Directory(
              '${root.path}${io.Platform.pathSeparator}b',
            )..createSync();
            final target = io.File(
              '${root.path}${io.Platform.pathSeparator}config.toml',
            )..writeAsStringSync('schema_version = 1\n');
            final otherTarget = io.File(
              '${root.path}${io.Platform.pathSeparator}other.toml',
            )..writeAsStringSync('schema_version = 1\n');
            final marker = io.File(
              '${root.path}${io.Platform.pathSeparator}held',
            );
            final script = io.File(
              '${root.path}${io.Platform.pathSeparator}worker.dart',
            )..writeAsStringSync(_coordinationWorker);
            final packages = io.File('.dart_tool/package_config.json')
                .absolute
                .path;
            final kernel =
                '${root.path}${io.Platform.pathSeparator}worker.dill';
            final compiled = await io.Process.run(
              io.Platform.resolvedExecutable,
              [
                'compile',
                'kernel',
                '--packages=$packages',
                '-o',
                kernel,
                script.path,
              ],
            ).timeout(const Duration(seconds: 45));
            expect(
              compiled.exitCode,
              0,
              reason: '${compiled.stdout} ${compiled.stderr}',
            );
            Future<io.Process> start(
              io.Directory project,
              io.File file,
              bool hold,
            ) => io.Process.start(io.Platform.resolvedExecutable, [
              '--packages=$packages',
              kernel,
              project.path,
              file.path,
              marker.path,
              hold.toString(),
            ]);
            first = await start(projectA, target, true);
            final firstOut = first.stdout.transform(utf8.decoder).join();
            final firstErr = first.stderr.transform(utf8.decoder).join();
            for (var i = 0; i < 150 && !marker.existsSync(); i++) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            if (!marker.existsSync()) {
              final code = await first.exitCode;
              fail(
                'First worker exited $code: ${await firstOut} ${await firstErr}',
              );
            }
            second = await start(projectB, otherTarget, false);
            final secondOut = second.stdout.transform(utf8.decoder).join();
            final secondErr = second.stderr.transform(utf8.decoder).join();
            final secondCode = await second.exitCode.timeout(
              const Duration(seconds: 6),
              onTimeout: () {
                throw StateError('Unrelated publication was blocked');
              },
            );
            final firstCode = await first.exitCode;
            expect(firstCode, 0, reason: '${await firstOut} ${await firstErr}');
            expect(
              secondCode,
              0,
              reason: '${await secondOut} ${await secondErr}',
            );
            expect(target.readAsStringSync(), contains('snapshot_days = 14'));
            expect(
              otherTarget.readAsStringSync(),
              contains('snapshot_days = 14'),
            );
          } finally {
            first?.kill();
            second?.kill();
            if (first != null) await first.exitCode;
            if (second != null) await second.exitCode;
            root.deleteSync(recursive: true);
          }
        }, timeout: const Timeout(Duration(seconds: 90)));

        test('can retry after a pre-publication rename failure', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          _writeConfig(fs, '/user/config.toml', 'schema_version = 1\n');
          fs.directory('/project').createSync(recursive: true);
          final lifecycleIO = _FailOnceRenameIO(fs: fs);
          final workflow = ConfigurationWorkflowService(
            fileSystem: fs,
            environment: const {'HOME': '/user'},
            publication: ConfigurationPublicationService(
              fileSystem: fs,
              io: lifecycleIO,
            ),
          );
          final executor = Executor('agent_resource', 'test', '1.0.0', [
            ConfigCommand(workflow: workflow, fileSystem: fs),
          ]);
          final args = [
            'config',
            'prefer',
            '--scope',
            'user',
            '--user-config',
            '/user/config.toml',
            '--project-config',
            '/project/config.toml',
            '--cwd',
            '/project/',
            '--project-root',
            '/project/',
            '--set',
            'cli.retention.snapshot_days=14',
            '--apply',
          ];
          expect(
            await executor.fake().execute(args),
            isA<MambaFailureResult>(),
          );
          expect(
            fs.file('/user/config.toml').readAsStringSync(),
            'schema_version = 1\n',
          );
          final retry = await executor.fake().execute(args);
          expect(
            retry,
            isA<MambaSuccessResult>(),
            reason: retry is MambaFailureResult ? retry.message : null,
          );
        });

        for (final apply in [false, true]) {
          for (final targets in [
            'not-a-harness',
            'claude,not-a-harness',
            'codex,codex',
            'claude,',
          ]) {
            test(
              'rejects $targets in ${apply ? 'apply' : 'preview'} without writing',
              () async {
                final fs = MemoryFileSystem(style: FileSystemStyle.posix);
                const path = '/sandbox/project.toml';
                const original = 'schema_version = 1\n';
                _writeConfig(fs, path, original);
                final result = await _executor(fileSystem: fs).fake().execute([
                  'config',
                  'prefer',
                  '--scope',
                  'project',
                  '--user-config',
                  '/sandbox/user.toml',
                  '--project-config',
                  path,
                  '--cwd',
                  '/sandbox/project/',
                  '--project-root',
                  '/sandbox/project/',
                  '--set',
                  'cli.install.targets=$targets',
                  if (apply) '--apply',
                ]);
                expect(
                  result,
                  isA<MambaFailureResult>()
                      .having((r) => r.exitCode, 'exit code', 2)
                      .having(
                        (r) => r.message,
                        'message',
                        contains('requires unique supported targets'),
                      )
                      .having((r) => r.output, 'output', isNull)
                      .having(
                        (r) => r.error.phase,
                        'phase',
                        MambaExecutionPhase.run,
                      )
                      .having((r) => r.error.commandPath, 'command path', [
                        'agent_resource',
                        'config',
                        'prefer',
                      ]),
                );
                expect(fs.file(path).readAsStringSync(), original);
              },
            );
          }
          test(
            'accepts supported targets in ${apply ? 'apply' : 'preview'}',
            () async {
              final fs = MemoryFileSystem(style: FileSystemStyle.posix);
              const path = '/sandbox/project.toml';
              final result = await _executor(fileSystem: fs).fake().execute([
                'config',
                'prefer',
                '--scope',
                'project',
                '--user-config',
                '/sandbox/user.toml',
                '--project-config',
                path,
                '--cwd',
                '/sandbox/project/',
                '--project-root',
                '/sandbox/project/',
                '--set',
                'cli.install.targets=claude,codex,shared,pi',
                if (apply) '--apply',
              ]);
              expect(
                result,
                isA<MambaSuccessResult>()
                    .having((r) => r.exitCode, 'exit code', 0)
                    .having(
                      (r) => r.output,
                      'output',
                      contains(
                        apply
                            ? 'config.prefer: applied'
                            : 'config.prefer: preview',
                      ),
                    ),
              );
              if (apply) {
                final map = TomlDocument.parse(fs.file(path).readAsStringSync())
                    .toMap();
                expect((map['cli'] as Map)['install']['targets'], [
                  'claude',
                  'codex',
                  'shared',
                  'pi',
                ]);
              } else {
                expect(fs.file(path).existsSync(), isFalse);
              }
            },
          );
        }

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
                    contains('rename'),
                    contains('recovery'),
                    contains('power-loss'),
                    allOf(
                      contains('credentials are'),
                      contains('refused and never remembered'),
                    ),
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
                .having((value) => value.exitCode, 'exit code', 4)
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
      });
    });
  });
}

Executor _executor({
  fslib.FileSystem? fileSystem,
  Map<String, String>? configurationEnvironment,
  String? configurationOperatingSystem,
}) {
  final resolved = fileSystem ?? MemoryFileSystem(style: FileSystemStyle.posix);
  if (resolved is MemoryFileSystem) {
    for (final path in const <String>[
      '/sandbox',
      '/sandbox/project',
      '/sandbox/home',
    ]) {
      resolved.directory(path).createSync(recursive: true);
    }
  }
  return createExecutor(
    fileSystem: resolved,
    configurationEnvironment: configurationEnvironment,
    configurationOperatingSystem: configurationOperatingSystem,
  );
}

final class _FailOnceRenameIO extends LifecycleIO {
  _FailOnceRenameIO({required super.fs});
  var failed = false;

  @override
  void rename(String source, String destination) {
    if (!failed && source == '/user/config.toml') {
      failed = true;
      throw io.FileSystemException('Injected rename failure', source);
    }
    super.rename(source, destination);
  }
}

final class _SeparateVolumesIO extends LifecycleIO {
  _SeparateVolumesIO({required super.fs});

  @override
  void rename(String source, String destination) {
    if (source.startsWith('/user/') && destination.startsWith('/project/')) {
      throw io.FileSystemException('Cross-device rename', source);
    }
    super.rename(source, destination);
  }
}

void _writeConfig(MemoryFileSystem fileSystem, String path, String source) {
  final file = fileSystem.file(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(source);
}

final class _InterruptAfterQuarantineIO extends LifecycleIO {
  _InterruptAfterQuarantineIO({required super.fs});
  @override
  void rename(String source, String destination) {
    super.rename(source, destination);
    if (source == '/user/config.toml') {
      throw StateError('simulated interruption');
    }
  }
}

final class _InterruptPhaseWriteIO extends LifecycleIO {
  _InterruptPhaseWriteIO({required super.fs});
  int writes = 0;
  @override
  void write(String path, List<int> bytes) {
    if (path.contains('/configuration-transactions/') &&
        path.endsWith('.json')) {
      writes++;
      if (writes == 2) {
        fs.file(path).writeAsStringSync('{');
        throw StateError('simulated phase interruption');
      }
    }
    super.write(path, bytes);
  }
}

final class _InterruptAfterPublishIO extends LifecycleIO {
  _InterruptAfterPublishIO({required super.fs});
  @override
  void rename(String source, String destination) {
    super.rename(source, destination);
    if (destination == '/user/config.toml' && source.endsWith('/config.toml')) {
      throw StateError('simulated publication interruption');
    }
  }
}

final class _InterruptBeforeStageIO extends LifecycleIO {
  _InterruptBeforeStageIO({required super.fs});
  @override
  void write(String path, List<int> bytes) {
    if (path.endsWith('/config.toml') &&
        path.contains('agent-resource-prefer-')) {
      throw StateError('simulated staging interruption');
    }
    super.write(path, bytes);
  }
}

final class _InterruptTargetIO extends LifecycleIO {
  _InterruptTargetIO({required super.fs, required this.target});
  final String target;
  @override
  void rename(String source, String destination) {
    super.rename(source, destination);
    if (source == target) throw StateError('simulated interruption');
  }
}

final class _InterruptSkillInstallIO extends LifecycleIO {
  _InterruptSkillInstallIO(this.live, fslib.FileSystem fs) : super(fs: fs);
  final String live;
  bool published = false;
  bool failWrite = true;
  bool failRollback = true;
  @override
  void rename(String source, String destination) {
    if (published && source == live && failRollback) {
      failRollback = false;
      throw const io.FileSystemException('injected rollback failure');
    }
    super.rename(source, destination);
    if (destination == live) published = true;
  }

  @override
  void write(String path, List<int> bytes) {
    if (published && path.contains('.json') && failWrite) {
      failWrite = false;
      throw const io.FileSystemException('injected journal failure');
    }
    super.write(path, bytes);
  }
}

final class _OrphanStageIO extends LifecycleIO {
  _OrphanStageIO({required super.fs});
  @override
  void write(String path, List<int> bytes) {
    if (path.endsWith('/config.toml') &&
        path.contains('agent-resource-prefer-')) {
      super.write(path, bytes);
      throw StateError('simulated interruption');
    }
    super.write(path, bytes);
  }

  @override
  void delete(String path) {
    if (path.contains('agent-resource-prefer-')) {
      throw StateError('simulated crash before cleanup');
    }
    super.delete(path);
  }
}

const _coordinationWorker = r'''
import 'dart:io';
import 'package:agent_resource/config.dart';
import 'package:agent_resource/src/services/configuration_workflow_service.dart';
import 'package:agent_resource/src/services/configuration_publication_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/local.dart';
import 'package:mamba/mamba.dart';
import 'package:mamba/executor.dart';
class PausingIO extends LifecycleIO {
  PausingIO(this.target, this.marker, this.hold) : super(fs: const LocalFileSystem());
  final String target;
  final String marker;
  final bool hold;
  bool paused = false;
  @override
  void write(String path, List<int> bytes) {
    if (hold && !paused && path.contains('configuration-transactions') && path.endsWith('.json')) {
      paused = true;
      File(marker).writeAsStringSync('held');
      sleep(const Duration(seconds: 10));
    }
    super.write(path, bytes);
  }
}
Future<void> main(List<String> args) async {
  final project = args[0], target = args[1], marker = args[2], hold = args[3] == 'true';
  const fs = LocalFileSystem();
  final workflow = ConfigurationWorkflowService(fileSystem: fs, environment: {'HOME': project},
    publication: ConfigurationPublicationService(fileSystem: fs, io: PausingIO(target, marker, hold)));
  final executor = Executor('agent_resource', 'test', '1.0.0', [ConfigCommand(workflow: workflow, fileSystem: fs)]);
  final result = await executor.fake().execute(['config', 'prefer', '--scope', 'user', '--user-config', target,
    '--project-config', '$project${Platform.pathSeparator}config.toml', '--cwd', '$project${Platform.pathSeparator}',
    '--project-root', '$project${Platform.pathSeparator}', '--set', 'cli.retention.snapshot_days=14', '--apply']);
  if (result is MambaFailureResult) { stderr.writeln(result.message); exitCode = 1; } else { stdout.writeln((result as MambaSuccessResult).output); }
}
''';
