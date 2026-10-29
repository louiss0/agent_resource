import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_installation_service.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/installation_test_support.dart';

final class _CountingAcquisition implements AcquisitionService {
  var calls = 0;

  @override
  Future<AcquisitionWorkspace> acquire(AcquisitionRequest request) {
    calls++;
    return const AcquisitionService().acquire(request);
  }
}

void main() {
  group('agent_resource', () {
    group('skill', () {
      group('install', () {
        late Directory sandbox;
        late Directory project;
        late Directory home;
        late ScriptedInstallationInteraction interaction;
        late _CountingAcquisition acquisition;

        setUp(() async {
          sandbox = await Directory.systemTemp.createTemp('skill-install-cli-');
          project = Directory(p.join(sandbox.path, 'project'))..createSync();
          home = Directory(p.join(sandbox.path, 'home'))..createSync();
          interaction = ScriptedInstallationInteraction();
          acquisition = _CountingAcquisition();
        });

        tearDown(() async {
          if (sandbox.existsSync()) await sandbox.delete(recursive: true);
        });

        Executor executor() => createExecutor(
          skillInstallation: SkillInstallationService(
            acquisition: acquisition,
            interaction: interaction,
            progress: noInstallationProgress,
          ),
        );

        Directory skill(String name, {String nativeName = 'review'}) {
          final directory = Directory(p.join(sandbox.path, name))..createSync();
          File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: $nativeName\ndescription: Reviews.\n---\nBody.\n',
          );
          return directory;
        }

        List<String> context({String scope = 'project'}) => [
          '--scope',
          scope,
          '--cwd',
          '${project.path}${Platform.pathSeparator}',
          '--project-root',
          '${project.path}${Platform.pathSeparator}',
          '--home',
          '${home.path}${Platform.pathSeparator}',
          '--claude-config-dir',
          '${p.join(sandbox.path, 'claude')}${Platform.pathSeparator}',
          '--codex-home',
          '${p.join(sandbox.path, 'codex')}${Platform.pathSeparator}',
          '--state-dir',
          '${p.join(sandbox.path, 'state')}${Platform.pathSeparator}',
        ];

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
              Directory(p.join(sandbox.path, 'state')).existsSync(),
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
          final repository = Directory(p.join(sandbox.path, 'repository'))
            ..createSync();
          for (final path in ['skills/review', 'skills/category/other']) {
            final directory = Directory(p.join(repository.path, path))
              ..createSync(recursive: true);
            final name = p.basename(directory.path);
            File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: $name\ndescription: A skill.\n---\nBody.\n',
            );
            File(p.join(directory.path, 'reference.txt'))
                .writeAsStringSync('Bundled reference');
          }
          interaction.resourceSelections.add(['skills/category/other']);
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
            File(
              p.join(
                project.path,
                '.agents',
                'skills',
                'other',
                'reference.txt',
              ),
            ).readAsStringSync(),
            'Bundled reference',
          );
          expect(
            Directory(p.join(project.path, '.agents', 'skills', 'review'))
                .existsSync(),
            isFalse,
          );
        });

        test(
          'unattended discovery requires explicit resource selection',
          () async {
            final repository = Directory(p.join(sandbox.path, 'repository'))
              ..createSync();
            final directory = Directory(
              p.join(repository.path, 'skills', 'review'),
            )..createSync(recursive: true);
            File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
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
          'packages/tools/review',
        ]) {
          test(
            'discovers $sourcePath with explicit unattended selection',
            () async {
              final repository = Directory(p.join(sandbox.path, 'repository'))
                ..createSync();
              final directory = Directory(p.join(repository.path, sourcePath))
                ..createSync(recursive: true);
              File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
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
            final repository = Directory(p.join(sandbox.path, 'repository'))
              ..createSync();
            final directory = Directory(
              p.join(repository.path, 'skills', 'review'),
            )..createSync(recursive: true);
            File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
            );
            File(p.join(repository.path, 'agent-resources.toml'))
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
          final repository = Directory(p.join(sandbox.path, 'repository'))
            ..createSync();
          for (final sourcePath in [
            'skills/review',
            'skills/review/examples/nested',
            'skills/.hidden/hidden',
            'skills/node_modules/dependency',
          ]) {
            final directory = Directory(p.join(repository.path, sourcePath))
              ..createSync(recursive: true);
            final name = p.basename(directory.path);
            File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
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
            final repository = Directory(p.join(sandbox.path, 'repository'))
              ..createSync();
            for (final sourcePath in [
              'packages/chosen/skills/review',
              'skills/outside',
            ]) {
              final directory = Directory(p.join(repository.path, sourcePath))
                ..createSync(recursive: true);
              final name = p.basename(directory.path);
              File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
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
            final repository = Directory(p.join(sandbox.path, 'repository'))
              ..createSync();
            for (final sourcePath in ['skills/review', 'examples/outside']) {
              final directory = Directory(p.join(repository.path, sourcePath))
                ..createSync(recursive: true);
              final name = p.basename(directory.path);
              File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
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
            final collection = Directory(
              p.join(sandbox.path, 'single-collection'),
            )..createSync();
            final selected = Directory(
              p.join(collection.path, 'skills', 'review'),
            )..createSync(recursive: true);
            File(p.join(selected.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
            );
            File(p.join(collection.path, 'agent-resources.toml'))
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
          final collection = Directory(p.join(sandbox.path, 'collection'))
            ..createSync();
          final selected = Directory(
            p.join(collection.path, 'skills', 'review'),
          )..createSync(recursive: true);
          File(p.join(selected.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
          );
          final other = Directory(p.join(collection.path, 'skills', 'other'))
            ..createSync(recursive: true);
          File(p.join(other.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: other\ndescription: Other.\n---\nBody.\n',
          );
          File(p.join(collection.path, 'agent-resources.toml'))
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
          expect(Directory(p.join(home.path, '.agents')).existsSync(), isFalse);
          expect(
            Directory(p.join(sandbox.path, 'state')).existsSync(),
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
          final content = p.join(project.path, '.agents', 'skills', 'review');
          final before = File(p.join(content, 'SKILL.md')).readAsBytesSync();
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
          expect(File(p.join(content, 'SKILL.md')).readAsBytesSync(), before);
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
            File(p.join(directory.path, 'notes.md'))
                .writeAsStringSync('Not part of the direct-file package.\n');
            final result = await executor().fake().execute([
              'skill',
              'install',
              p.join(directory.path, 'SKILL.md'),
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
              p.join(directory.path, 'SKILL.md'),
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
            final content = Directory(
              p.join(project.path, '.agents', 'skills', 'review'),
            );
            expect(File(p.join(content.path, 'SKILL.md')).existsSync(), isTrue);
            expect(
              File(p.join(content.path, 'notes.md')).existsSync(),
              isFalse,
            );
            expect(
              content.listSync().map((entity) => p.basename(entity.path)),
              ['SKILL.md'],
            );
          },
        );

        test('canonical apply and verified repeat produce installed then unchanged', () async {
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
          final content = p.join(project.path, '.agents', 'skills', 'review');
          final exposure = p.join(project.path, '.claude', 'skills', 'review');
          expect(File(p.join(content, 'SKILL.md')).existsSync(), isTrue);
          expect(
            FileSystemEntity.typeSync(exposure, followLinks: false),
            FileSystemEntityType.link,
          );
          expect(Link(exposure).targetSync(), content);

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
          expect(File(p.join(content, 'SKILL.md')).existsSync(), isTrue);
        });

        test('general batch preflight conflicts use status one', () async {
          final collection = Directory(p.join(sandbox.path, 'conflicts'))
            ..createSync();
          for (final id in ['one', 'two']) {
            final directory = Directory(p.join(collection.path, id))
              ..createSync();
            File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: review\ndescription: Same native name.\n---\nBody.\n',
            );
          }
          File(p.join(collection.path, 'agent-resources.toml'))
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
            final collection = Directory(p.join(sandbox.path, 'collection'))
              ..createSync();
            final valid = Directory(p.join(collection.path, 'valid'))
              ..createSync();
            File(p.join(valid.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: valid\ndescription: Valid.\n---\nBody.\n',
            );
            final invalid = Directory(p.join(collection.path, 'invalid'))
              ..createSync();
            File(p.join(invalid.path, 'SKILL.md'))
                .writeAsStringSync('not a skill');
            File(p.join(collection.path, 'agent-resources.toml'))
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
