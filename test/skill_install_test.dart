import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_installation_service.dart';
import 'package:mamba/executor.dart';

import 'package:test/test.dart';

import 'support/installation_test_support.dart';

final class _CountingAcquisition implements AcquisitionService {
  var calls = 0;
  late FileSystem fileSystem;

  @override
  Future<AcquisitionWorkspace> acquire(AcquisitionRequest request) {
    calls++;
    return AcquisitionService(fileSystem: fileSystem).acquire(request);
  }
}

void main() {
  group('agent_resource', () {
    group('skill', () {
      group('install', () {
        late FileSystem fs;
        late Directory sandbox;
        late Directory project;
        late Directory home;
        late ScriptedInstallationInteraction interaction;
        late _CountingAcquisition acquisition;

        setUp(() async {
          fs = MemoryFileSystem(style: FileSystemStyle.posix)
            ..currentDirectory = '/';
          sandbox = fs.systemTempDirectory.createTempSync('skill-install-cli-');
          project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          home = fs.directory(fs.path.join(sandbox.path, 'home'))..createSync();
          interaction = ScriptedInstallationInteraction();
          acquisition = _CountingAcquisition()..fileSystem = fs;
        });

        tearDown(() async {
          if (sandbox.existsSync()) await sandbox.delete(recursive: true);
        });

        void useLocalFileSystem() {
          fs = const LocalFileSystem();
          sandbox = fs.systemTempDirectory.createTempSync(
            'skill-install-local-',
          );
          project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          home = fs.directory(fs.path.join(sandbox.path, 'home'))..createSync();
          acquisition.fileSystem = fs;
        }

        Executor executor() => createExecutor(
          fileSystem: fs,
          skillInstallation: SkillInstallationService(
            fileSystem: fs,
            acquisition: acquisition,
            interaction: interaction,
            progress: noInstallationProgress,
          ),
        );

        Directory skill(String name, {String nativeName = 'review'}) {
          final directory = fs.directory(fs.path.join(sandbox.path, name))
            ..createSync();
          fs
              .file(fs.path.join(directory.path, 'SKILL.md'))
              .writeAsStringSync(
                '---\nname: $nativeName\ndescription: Reviews.\n---\nBody.\n',
              );
          return directory;
        }

        List<String> context({String scope = 'project'}) => [
          '--scope',
          scope,
          '--cwd',
          '${project.path}${fs.path.separator}',
          '--project-root',
          '${project.path}${fs.path.separator}',
          '--home',
          '${home.path}${fs.path.separator}',
          '--claude-config-dir',
          '${fs.path.join(sandbox.path, 'claude')}${fs.path.separator}',
          '--codex-home',
          '${fs.path.join(sandbox.path, 'codex')}${fs.path.separator}',
          '--state-dir',
          '${fs.path.join(sandbox.path, 'state')}${fs.path.separator}',
        ];

        for (final entry in ['metadata.json', 'rules']) {
          test('rejects unsupported root entry $entry before writes', () async {
            final source = skill('source');
            if (entry.contains('.')) {
              fs
                  .file(fs.path.join(source.path, entry))
                  .writeAsStringSync('extra');
            } else {
              fs.directory(fs.path.join(source.path, entry)).createSync();
            }
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
              '--yes',
            ]);
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((r) => r.exitCode, 'status', 2)
                  .having(
                    (r) => r.message,
                    'message',
                    contains('Unsupported Skill root entry: $entry'),
                  ),
            );
            expect(project.listSync(recursive: true), isEmpty);
            expect(
              fs.directory(fs.path.join(sandbox.path, 'state')).existsSync(),
              isFalse,
            );
          });
        }

        test(
          'mixed discovered batch rejects rules before any writes',
          () async {
            final repository = fs.directory(
              fs.path.join(sandbox.path, 'repository'),
            )..createSync();
            for (final name in ['valid', 'invalid']) {
              final dir = fs.directory(
                fs.path.join(repository.path, 'skills', name),
              )..createSync(recursive: true);
              fs
                  .file(fs.path.join(dir.path, 'SKILL.md'))
                  .writeAsStringSync(
                    '---\nname: $name\ndescription: Valid.\n---\nBody.\n',
                  );
              if (name == 'invalid') {
                fs.directory(fs.path.join(dir.path, 'rules')).createSync();
              }
            }
            final result = await executor().fake().execute([
              'skill',
              'install',
              repository.path,
              '--all-resources',
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
              '--yes',
            ]);
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((r) => r.exitCode, 'status', 2)
                  .having(
                    (r) => r.message,
                    'message',
                    contains('Unsupported Skill root entry: rules'),
                  ),
            );
            expect(project.listSync(recursive: true), isEmpty);
            expect(
              fs.directory(fs.path.join(sandbox.path, 'state')).existsSync(),
              isFalse,
            );
          },
        );

        test(
          'accepts permitted resource directories and their nested files',
          () async {
            final source = skill('source');
            for (final name in ['references', 'scripts', 'assets']) {
              final nested = fs.directory(
                fs.path.join(source.path, name, 'nested'),
              )..createSync(recursive: true);
              fs
                  .file(fs.path.join(nested.path, 'content'))
                  .writeAsStringSync('content');
            }
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
              '--yes',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>().having((r) => r.exitCode, 'status', 0),
            );
            for (final name in ['references', 'scripts', 'assets']) {
              expect(
                fs
                    .file(
                      fs.path.join(
                        project.path,
                        '.agents',
                        'skills',
                        'review',
                        name,
                        'nested',
                        'content',
                      ),
                    )
                    .existsSync(),
                isTrue,
              );
            }
          },
        );

        test('rejects a file in place of a permitted directory', () async {
          final source = skill('source');
          fs
              .file(fs.path.join(source.path, 'scripts'))
              .writeAsStringSync('not a directory');
          final result = await executor().fake().execute([
            'skill',
            'install',
            source.path,
            '--target',
            'codex',
            '--method',
            'copy',
            ...context(),
            '--yes',
          ]);
          expect(
            result,
            isA<MambaFailureResult>()
                .having((r) => r.exitCode, 'status', 2)
                .having(
                  (r) => r.message,
                  'message',
                  contains('scripts must be a directory'),
                ),
          );
          expect(project.listSync(recursive: true), isEmpty);
        });

        test('initializes user state containing only coordination', () async {
          final source = skill('source');
          final coordination = fs.directory(
            fs.path.join(sandbox.path, 'state', 'coordination'),
          )..createSync(recursive: true);
          final lock = fs.file(
            fs.path.join(coordination.path, 'lifecycle.lock'),
          )..writeAsStringSync('');
          final result = await executor().fake().execute([
            'skill',
            'install',
            source.path,
            '--target',
            'codex',
            '--method',
            'canonical',
            ...context(scope: 'user'),
            '--yes',
          ]);
          expect(result, isA<MambaSuccessResult>());
          expect(
            fs
                .file(
                  fs.path.join(
                    home.path,
                    '.agents',
                    'skills',
                    'review',
                    'SKILL.md',
                  ),
                )
                .existsSync(),
            isTrue,
          );
          expect(
            fs
                .file(fs.path.join(sandbox.path, 'state', 'installations.json'))
                .existsSync(),
            isTrue,
          );
          expect(lock.existsSync(), isTrue);
        });

        test('refuses missing ledger when other state entries exist', () async {
          final source = skill('source');
          final state = fs.directory(fs.path.join(sandbox.path, 'state'))
            ..createSync();
          final sentinel = fs.file(fs.path.join(state.path, 'sentinel'))
            ..writeAsStringSync('preserve');
          final result = await executor().fake().execute([
            'skill',
            'install',
            source.path,
            '--target',
            'codex',
            '--method',
            'canonical',
            ...context(scope: 'user'),
            '--yes',
          ]);
          expect(
            result,
            isA<MambaFailureResult>()
                .having((result) => result.exitCode, 'status', 4)
                .having(
                  (result) => result.message,
                  'message',
                  contains('Installation ownership evidence is missing'),
                ),
          );
          expect(sentinel.readAsStringSync(), 'preserve');
          expect(
            fs.directory(fs.path.join(home.path, '.agents')).existsSync(),
            isFalse,
          );
        });

        test('help and parser conflicts cause no acquisition or filesystem effects', () async {
          final help = await executor().fake().execute([
            'skill',
            'install',
            '--help',
          ]);
          expect(
            help,
            isA<MambaSuccessResult>().having((r) => r.exitCode, 'status', 0),
          );
          expect((help as MambaSuccessResult).output, contains('--method'));
          expect(help.output, contains('--target'));

          final conflict = await executor().fake().execute([
            'skill',
            'install',
            'source',
            '--resource',
            'one',
            '--all-resources',
          ]);
          expect(
            conflict,
            isA<MambaFailureResult>()
                .having((r) => r.exitCode, 'status', 1)
                .having((r) => r.output, 'output', isNull)
                .having(
                  (r) => r.error.phase,
                  'phase',
                  MambaExecutionPhase.parse,
                )
                .having((r) => r.error.commandPath, 'path', [
                  'agent_resource',
                  'skill',
                  'install',
                ]),
          );
          expect(acquisition.calls, 0);
          expect(project.listSync(recursive: true), isEmpty);
        });

        for (final testCase in [
          (flag: '--destination', value: 'claude', guidance: '--target'),
          (flag: '--harness', value: 'claude', guidance: '--target'),
          (flag: '--mode', value: 'link', guidance: '--method'),
          (flag: '--interactive', value: null, guidance: 'retired'),
        ]) {
          test(
            '${testCase.flag} rejects with migration guidance before effects',
            () async {
              final result = await executor().fake().execute([
                'skill',
                'install',
                'source',
                testCase.flag,
                if (testCase.value != null) testCase.value!,
              ]);
              expect(result, isA<MambaFailureResult>());
              expect(
                (result as MambaFailureResult).message,
                contains(testCase.guidance),
              );
              expect(result.error.phase, MambaExecutionPhase.run);
              expect(acquisition.calls, 0);
            },
          );
        }

        test(
          'unattended exact dry-run emits schema v2 and no management writes',
          () async {
            final source = skill('exact');
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--target',
              'codex',
              '--method',
              'canonical',
              ...context(),
              '--dry-run',
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            final success = result as MambaSuccessResult;
            expect(success.exitCode, 0);
            final envelope =
                jsonDecode(success.output!) as Map<String, Object?>;
            expect(envelope['schemaVersion'], 2);
            expect(envelope['outcome'], 'planned');
            final data = envelope['data']! as Map<String, Object?>;
            final units = data['units']! as List<Object?>;
            final unit = units.single! as Map<String, Object?>;
            expect(unit['method'], 'canonical');
            expect(unit['entries'], hasLength(3));
            expect(project.listSync(recursive: true), isEmpty);
            expect(
              fs.directory(fs.path.join(sandbox.path, 'state')).existsSync(),
              isFalse,
            );
          },
        );

        test(
          'unattended mode does not inherit interactive defaults or approval',
          () async {
            final source = skill('exact');
            for (final testCase in [
              (
                args: <String>[
                  '--source-kind',
                  'resource',
                  '--target',
                  'claude',
                  '--method',
                  'canonical',
                ],
                message: '--scope',
              ),
              (
                args: <String>[
                  '--source-kind',
                  'resource',
                  '--target',
                  'claude',
                  '--scope',
                  'project',
                ],
                message: '--method',
              ),
              (
                args: <String>[
                  '--source-kind',
                  'resource',
                  '--method',
                  'canonical',
                  '--scope',
                  'project',
                ],
                message: '--target',
              ),
            ]) {
              final result = await executor().fake().execute([
                'skill',
                'install',
                source.path,
                ...testCase.args,
                '--dry-run',
                '--format',
                'json',
              ]);
              expect(result, isA<MambaFailureResult>());
              expect(
                (result as MambaFailureResult).message,
                contains(testCase.message),
              );
              expect(result.output, isNull);
            }
            final approval = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'canonical',
              ...context(),
              '--format',
              'json',
            ]);
            expect(
              approval,
              isA<MambaFailureResult>().having((r) => r.exitCode, 'status', 4),
            );
            expect(project.listSync(recursive: true), isEmpty);
          },
        );

        test('discovers nested skills without a catalog and installs selected content', () async {
          final repository = fs.directory(
            fs.path.join(sandbox.path, 'repository'),
          )..createSync();
          for (final path in ['skills/review', 'skills/category/other']) {
            final directory = fs.directory(fs.path.join(repository.path, path))
              ..createSync(recursive: true);
            final name = fs.path.basename(directory.path);
            fs
                .file(fs.path.join(directory.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: $name\ndescription: A skill.\n---\nBody.\n',
                );
            fs
                .directory(fs.path.join(directory.path, 'references'))
                .createSync();
            fs
                .file(
                  fs.path.join(directory.path, 'references', 'reference.txt'),
                )
                .writeAsStringSync('Bundled reference');
          }
          interaction.resourceSelections
            ..add([])
            ..add(['skills/category/other']);
          final result = await executor().fake().execute([
            'skill',
            'install',
            repository.path,
            '--target',
            'codex',
            '--method',
            'copy',
            ...context(),
            '--yes',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>().having((r) => r.exitCode, 'status', 0),
            reason: result is MambaFailureResult ? result.message : null,
          );
          expect((result as MambaSuccessResult).output, contains('installed'));
          expect(interaction.resourceSelections, isEmpty);
          expect(
            fs
                .file(
                  fs.path.join(
                    project.path,
                    '.agents',
                    'skills',
                    'other',
                    'references',
                    'reference.txt',
                  ),
                )
                .readAsStringSync(),
            'Bundled reference',
          );
          expect(
            fs
                .directory(
                  fs.path.join(project.path, '.agents', 'skills', 'review'),
                )
                .existsSync(),
            isFalse,
          );
        });

        test(
          'unattended discovery requires explicit resource selection',
          () async {
            final repository = fs.directory(
              fs.path.join(sandbox.path, 'repository'),
            )..createSync();
            final directory = fs.directory(
              fs.path.join(repository.path, 'skills', 'review'),
            )..createSync(recursive: true);
            fs
                .file(fs.path.join(directory.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
                );
            final result = await executor().fake().execute([
              'skill',
              'install',
              repository.path,
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
              '--dry-run',
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((r) => r.exitCode, 'status', 1)
                  .having(
                    (r) => r.message,
                    'message',
                    contains('--resource or --all-resources'),
                  )
                  .having((r) => r.output, 'output', isNull)
                  .having(
                    (r) => r.error.phase,
                    'phase',
                    MambaExecutionPhase.run,
                  )
                  .having((r) => r.error.commandPath, 'command', [
                    'agent_resource',
                    'skill',
                    'install',
                  ]),
            );
            expect(project.listSync(recursive: true), isEmpty);
          },
        );

        for (final sourcePath in [
          'skills/category/review',
          '.agents/skills/review',
        ]) {
          test(
            'discovers $sourcePath with explicit unattended selection',
            () async {
              final repository = fs.directory(
                fs.path.join(sandbox.path, 'repository'),
              )..createSync();
              final directory = fs.directory(
                fs.path.join(repository.path, sourcePath),
              )..createSync(recursive: true);
              fs
                  .file(fs.path.join(directory.path, 'SKILL.md'))
                  .writeAsStringSync(
                    '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
                  );
              final result = await executor().fake().execute([
                'skill',
                'install',
                repository.path,
                '--resource',
                sourcePath,
                '--target',
                'codex',
                '--method',
                'copy',
                ...context(),
                '--dry-run',
                '--format',
                'json',
              ]);
              expect(
                result,
                isA<MambaSuccessResult>().having(
                  (r) => r.exitCode,
                  'status',
                  0,
                ),
                reason: result is MambaFailureResult ? result.message : null,
              );
              final output = jsonDecode(
                (result as MambaSuccessResult).output!,
              ) as Map<String, dynamic>;
              expect(output['outcome'], 'planned');
              expect(output['data']['units'].single['resourceId'], sourcePath);
              expect(
                output['data']['source'].containsKey('configDigest'),
                isFalse,
              );
              expect(project.listSync(recursive: true), isEmpty);
            },
          );
        }

        test(
          'curated catalog remains authoritative over discovered skills',
          () async {
            final repository = fs.directory(
              fs.path.join(sandbox.path, 'repository'),
            )..createSync();
            final directory = fs.directory(
              fs.path.join(repository.path, 'skills', 'review'),
            )..createSync(recursive: true);
            fs
                .file(fs.path.join(directory.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
                );
            fs
                .file(fs.path.join(repository.path, 'agent-resources.toml'))
                .writeAsStringSync(
                  'schema_version = 1\n[[skills]]\nid = "curated-review"\npath = "skills/review"\n',
                );
            final result = await executor().fake().execute([
              'skill',
              'install',
              repository.path,
              '--all-resources',
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
              '--dry-run',
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>().having((r) => r.exitCode, 'status', 0),
            );
            final output = jsonDecode(
              (result as MambaSuccessResult).output!,
            ) as Map<String, dynamic>;
            expect(
              output['data']['units'].single['resourceId'],
              'curated-review',
            );
            expect(output['data']['source']['configDigest'], isNotEmpty);
          },
        );

        test('discovery stops at package boundaries and skips hidden dependency trees', () async {
          final repository = fs.directory(
            fs.path.join(sandbox.path, 'repository'),
          )..createSync();
          for (final sourcePath in [
            'skills/review',
            'skills/review/references/nested',
            'skills/.hidden/hidden',
            'skills/node_modules/dependency',
          ]) {
            final directory = fs.directory(
              fs.path.join(repository.path, sourcePath),
            )..createSync(recursive: true);
            final name = fs.path.basename(directory.path);
            fs
                .file(fs.path.join(directory.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: $name\ndescription: Reviews.\n---\nBody.\n',
                );
          }
          final result = await executor().fake().execute([
            'skill',
            'install',
            repository.path,
            '--all-resources',
            '--target',
            'codex',
            '--method',
            'copy',
            ...context(),
            '--dry-run',
            '--format',
            'json',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>().having((r) => r.exitCode, 'status', 0),
          );
          final output = jsonDecode(
            (result as MambaSuccessResult).output!,
          ) as Map<String, dynamic>;
          expect(output['data']['units'], hasLength(1));
          expect(output['data']['units'].single['resourceId'], 'skills/review');
        });

        test(
          'subpath discovery cannot select Skills outside the selected root',
          () async {
            final repository = fs.directory(
              fs.path.join(sandbox.path, 'repository'),
            )..createSync();
            for (final sourcePath in [
              'packages/chosen/skills/review',
              'skills/outside',
            ]) {
              final directory = fs.directory(
                fs.path.join(repository.path, sourcePath),
              )..createSync(recursive: true);
              final name = fs.path.basename(directory.path);
              fs
                  .file(fs.path.join(directory.path, 'SKILL.md'))
                  .writeAsStringSync(
                    '---\nname: $name\ndescription: Reviews.\n---\nBody.\n',
                  );
            }
            final result = await executor().fake().execute([
              'skill',
              'install',
              repository.path,
              '--subpath',
              'packages/chosen',
              '--all-resources',
              '--source-kind',
              'collection',
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
              '--dry-run',
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>().having((r) => r.exitCode, 'status', 0),
              reason: result is MambaFailureResult ? result.message : null,
            );
            final output = jsonDecode(
              (result as MambaSuccessResult).output!,
            ) as Map<String, dynamic>;
            expect(output['data']['units'], hasLength(1));
            expect(
              output['data']['units'].single['resourceId'],
              'skills/review',
            );
          },
        );

        test(
          'conventional skills folder takes precedence over fallback tree',
          () async {
            final repository = fs.directory(
              fs.path.join(sandbox.path, 'repository'),
            )..createSync();
            for (final sourcePath in ['skills/review', 'examples/outside']) {
              final directory = fs.directory(
                fs.path.join(repository.path, sourcePath),
              )..createSync(recursive: true);
              final name = fs.path.basename(directory.path);
              fs
                  .file(fs.path.join(directory.path, 'SKILL.md'))
                  .writeAsStringSync(
                    '---\nname: $name\ndescription: Reviews.\n---\nBody.\n',
                  );
            }
            final result = await executor().fake().execute([
              'skill',
              'install',
              repository.path,
              '--all-resources',
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
              '--dry-run',
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>().having((r) => r.exitCode, 'status', 0),
            );
            final output = jsonDecode(
              (result as MambaSuccessResult).output!,
            ) as Map<String, dynamic>;
            expect(output['data']['units'], hasLength(1));
            expect(
              output['data']['units'].single['resourceId'],
              'skills/review',
            );
          },
        );

        test(
          'interactive single-offering collection still requires selection',
          () async {
            final collection = fs.directory(
              fs.path.join(sandbox.path, 'single-collection'),
            )..createSync();
            final selected = fs.directory(
              fs.path.join(collection.path, 'skills', 'review'),
            )..createSync(recursive: true);
            fs
                .file(fs.path.join(selected.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
                );
            fs
                .file(fs.path.join(collection.path, 'agent-resources.toml'))
                .writeAsStringSync('''
schema_version = 1
[[skills]]
id = "code-review"
path = "skills/review"
''');
            interaction.resourceSelections.add(['code-review']);
            interaction.targetSelections.add([InstallationTarget.codex]);
            final result = await executor().fake().execute([
              'skill',
              'install',
              collection.path,
              ...context(),
              '--dry-run',
            ]);
            expect(result, isA<MambaSuccessResult>());
            expect(interaction.resourceSelections, isEmpty);
          },
        );

        test('interactive collection dry-run uses typed prompts and disclosed defaults', () async {
          final collection = fs.directory(
            fs.path.join(sandbox.path, 'collection'),
          )..createSync();
          final selected = fs.directory(
            fs.path.join(collection.path, 'skills', 'review'),
          )..createSync(recursive: true);
          fs
              .file(fs.path.join(selected.path, 'SKILL.md'))
              .writeAsStringSync(
                '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
              );
          final other = fs.directory(
            fs.path.join(collection.path, 'skills', 'other'),
          )..createSync(recursive: true);
          fs
              .file(fs.path.join(other.path, 'SKILL.md'))
              .writeAsStringSync(
                '---\nname: other\ndescription: Other.\n---\nBody.\n',
              );
          fs
              .file(fs.path.join(collection.path, 'agent-resources.toml'))
              .writeAsStringSync('''
schema_version = 1
[[skills]]
id = "code-review"
path = "skills/review"
[[skills]]
id = "other"
path = "skills/other"
''');
          interaction.sources.add(collection.path);
          interaction.resourceSelections.add(['code-review']);
          interaction.targetSelections.add([InstallationTarget.codex]);
          final result = await executor().fake().execute([
            'skill',
            'install',
            ...context(scope: 'user'),
            '--dry-run',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final output = (result as MambaSuccessResult).output!;
          expect(output, contains('skill install: planned'));
          expect(output, contains('Scope: user'));
          expect(output, contains('Method: canonical'));
          expect(output, contains('code-review'));
          expect(interaction.approvals, isEmpty);
          expect(
            fs.directory(fs.path.join(home.path, '.agents')).existsSync(),
            isFalse,
          );
          expect(
            fs.directory(fs.path.join(sandbox.path, 'state')).existsSync(),
            isFalse,
          );
        });

        test(
          'interactive decline is successful pre-write cancellation',
          () async {
            final source = skill('exact');
            interaction.targetSelections.add([InstallationTarget.claude]);
            interaction.approvals.add(false);
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              '--source-kind',
              'resource',
              ...context(),
            ]);
            expect(
              result,
              isA<MambaSuccessResult>().having((r) => r.exitCode, 'status', 0),
            );
            expect(
              (result as MambaSuccessResult).output,
              contains('cancelled'),
            );
            expect(project.listSync(recursive: true), isEmpty);
          },
        );

        test('consumer-only canonical addition records Codex without rewriting content', () async {
          useLocalFileSystem();
          final source = skill('consumer-addition');
          List<String> install(List<String> targets) => [
            'skill',
            'install',
            source.path,
            '--source-kind',
            'resource',
            for (final target in targets) ...['--target', target],
            '--method',
            'canonical',
            ...context(),
            '--yes',
            '--format',
            'json',
          ];
          final first = await executor().fake().execute(install(['claude']));
          expect(first, isA<MambaSuccessResult>());
          final content = fs.path.join(
            project.path,
            '.agents',
            'skills',
            'review',
          );
          final before = fs
              .file(fs.path.join(content, 'SKILL.md'))
              .readAsBytesSync();
          final second = await executor().fake().execute(
            install(['claude', 'codex']),
          );
          expect(
            second,
            isA<MambaSuccessResult>(),
            reason: second is MambaFailureResult ? second.message : null,
          );
          final envelope = jsonDecode(
            (second as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          expect(envelope['outcome'], 'installed');
          expect(
            fs.file(fs.path.join(content, 'SKILL.md')).readAsBytesSync(),
            before,
          );
          final records = LifecycleStateService().records(
            LifecycleContext.resolve(
              LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
              ),
            ),
          );
          expect(
            records.single.knownConsumers,
            containsAll(['claude', 'codex']),
          );
        });

        test(
          'direct SKILL.md installs only that file and discloses the boundary',
          () async {
            final directory = skill('direct-file');
            fs
                .file(fs.path.join(directory.path, 'notes.md'))
                .writeAsStringSync('Not part of the direct-file package.\n');
            final result = await executor().fake().execute([
              'skill',
              'install',
              fs.path.join(directory.path, 'SKILL.md'),
              '--source-kind',
              'resource',
              '--target',
              'codex',
              '--method',
              'canonical',
              ...context(),
              '--format',
              'json',
              '--dry-run',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            final envelope = jsonDecode(
              (result as MambaSuccessResult).output!,
            ) as Map<String, Object?>;
            final data = envelope['data']! as Map<String, Object?>;
            final source = data['source']! as Map<String, Object?>;
            expect(source['packageBoundary'], 'single-file');
            final diagnostics = envelope['diagnostics']! as List<Object?>;
            expect(
              (diagnostics.single! as Map<String, Object?>)['code'],
              'single-file-boundary',
            );

            final installed = await executor().fake().execute([
              'skill',
              'install',
              fs.path.join(directory.path, 'SKILL.md'),
              '--source-kind',
              'resource',
              '--target',
              'codex',
              '--method',
              'canonical',
              ...context(),
              '--format',
              'json',
              '--yes',
            ]);
            expect(
              installed,
              isA<MambaSuccessResult>(),
              reason: installed is MambaFailureResult
                  ? installed.message
                  : null,
            );
            final content = fs.directory(
              fs.path.join(project.path, '.agents', 'skills', 'review'),
            );
            expect(
              fs.file(fs.path.join(content.path, 'SKILL.md')).existsSync(),
              isTrue,
            );
            expect(
              fs.file(fs.path.join(content.path, 'notes.md')).existsSync(),
              isFalse,
            );
            expect(
              content.listSync().map((entity) => fs.path.basename(entity.path)),
              ['SKILL.md'],
            );
          },
        );

        test('canonical apply and verified repeat produce installed then unchanged', () async {
          useLocalFileSystem();
          final source = skill('exact');
          final args = [
            'skill',
            'install',
            source.path,
            '--source-kind',
            'resource',
            '--target',
            'claude',
            '--target',
            'codex',
            '--method',
            'canonical',
            ...context(),
            '--yes',
            '--format',
            'json',
          ];
          final first = await executor().fake().execute(args);
          expect(
            first,
            isA<MambaSuccessResult>(),
            reason: first is MambaFailureResult ? first.message : null,
          );
          final installed = jsonDecode(
            (first as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          expect(installed['outcome'], 'installed');
          final content = fs.path.join(
            project.path,
            '.agents',
            'skills',
            'review',
          );
          final exposure = fs.path.join(
            project.path,
            '.claude',
            'skills',
            'review',
          );
          expect(
            fs.file(fs.path.join(content, 'SKILL.md')).existsSync(),
            isTrue,
          );
          expect(
            io.FileSystemEntity.typeSync(exposure, followLinks: false),
            io.FileSystemEntityType.link,
          );
          expect(io.Link(exposure).targetSync(), content);

          final second = await executor().fake().execute(args);
          expect(
            second,
            isA<MambaSuccessResult>(),
            reason: second is MambaFailureResult ? second.message : null,
          );
          final unchanged = jsonDecode(
            (second as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          expect(unchanged['outcome'], 'unchanged');
          final firstData = installed['data']! as Map<String, Object?>;
          final secondData = unchanged['data']! as Map<String, Object?>;
          expect(secondData['planId'], isNot(firstData['planId']));
          final firstUnit =
              (firstData['units']! as List<Object?>).single!
                  as Map<String, Object?>;
          final secondUnit =
              (secondData['units']! as List<Object?>).single!
                  as Map<String, Object?>;
          expect(secondUnit['installationIds'], firstUnit['installationIds']);
          expect(
            fs.file(fs.path.join(content, 'SKILL.md')).existsSync(),
            isTrue,
          );
        });

        test('general batch preflight conflicts use status one', () async {
          final collection = fs.directory(
            fs.path.join(sandbox.path, 'conflicts'),
          )..createSync();
          for (final id in ['one', 'two']) {
            final directory = fs.directory(fs.path.join(collection.path, id))
              ..createSync();
            fs
                .file(fs.path.join(directory.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: review\ndescription: Same native name.\n---\nBody.\n',
                );
          }
          fs
              .file(fs.path.join(collection.path, 'agent-resources.toml'))
              .writeAsStringSync('''
schema_version = 1
[[skills]]
id = "one"
path = "one"
[[skills]]
id = "two"
path = "two"
''');
          final result = await executor().fake().execute([
            'skill',
            'install',
            collection.path,
            '--all-resources',
            '--target',
            'codex',
            '--method',
            'copy',
            ...context(),
            '--yes',
            '--format',
            'json',
          ]);
          expect(
            result,
            isA<MambaFailureResult>().having((r) => r.exitCode, 'status', 1),
          );
          expect(project.listSync(recursive: true), isEmpty);
        });

        test(
          'full preflight blocks every selected unit when one is invalid',
          () async {
            final collection = fs.directory(
              fs.path.join(sandbox.path, 'collection'),
            )..createSync();
            final valid = fs.directory(fs.path.join(collection.path, 'valid'))
              ..createSync();
            fs
                .file(fs.path.join(valid.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: valid\ndescription: Valid.\n---\nBody.\n',
                );
            final invalid = fs.directory(
              fs.path.join(collection.path, 'invalid'),
            )..createSync();
            fs
                .file(fs.path.join(invalid.path, 'SKILL.md'))
                .writeAsStringSync('not a skill');
            fs
                .file(fs.path.join(collection.path, 'agent-resources.toml'))
                .writeAsStringSync('''
schema_version = 1
[[skills]]
id = "valid"
path = "valid"
[[skills]]
id = "invalid"
path = "invalid"
''');
            final result = await executor().fake().execute([
              'skill',
              'install',
              collection.path,
              '--source-kind',
              'collection',
              '--all-resources',
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
              '--yes',
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaFailureResult>().having((r) => r.exitCode, 'status', 2),
            );
            expect(
              (result as MambaFailureResult).message,
              contains('no installation writes'),
            );
            expect(result.output, isNull);
            expect(project.listSync(recursive: true), isEmpty);
          },
        );
      });
    });
  });
}
