import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/pack_action.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/installation/installation_request.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_installation_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart' show MambaException;

import 'package:test/test.dart';

import 'support/installation_test_support.dart';
import 'support/trusted_temp.dart';

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
          sandbox = fs.directory(
            createTrustedTempPathSync('skill-install-local-'),
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

        test(
          'updates a direct copy from its recorded source and target',
          () async {
            final source = skill('recorded-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'codex',
              '--method',
              'copy',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            final options = LifecycleOptions(
              processWorkingDirectory: project.path,
              scope: LifecycleScope.project,
              cwd: project.path,
              projectRoot: project.path,
              home: home.path,
              stateDir: fs.path.join(sandbox.path, 'state'),
              approved: true,
            );
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final resolved = LifecycleContext.resolve(options, fileSystem: fs);
            final record = lifecycle.state.records(resolved).single;
            fs
                .file(fs.path.join(project.path, 'agent-resources.toml'))
                .writeAsStringSync(
                  'schema_version = 1\n[cli.install]\ntargets = ["claude"]\nskill_method = "canonical"\n',
                );
            fs
                .file(fs.path.join(source.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: review\ndescription: Reviews.\n---\nUpdated.\n',
                );
            final result = await executor().fake().execute([
              'skill',
              'update',
              record.installationId,
              ...context(),
              '--yes',
              '--format',
              'json',
            ]);
            expect(result, isA<MambaSuccessResult>());
            final data =
                jsonDecode((result as MambaSuccessResult).output!) as Map;
            expect(data['outcome'], 'updated');
            expect(
              fs
                  .file(fs.path.join(record.location, 'SKILL.md'))
                  .readAsStringSync(),
              contains('Updated.'),
            );
            final updated = lifecycle.state.records(resolved).single;
            expect(updated.installationRoute!.method, InstallationMethod.copy);
            expect(
              updated.installationRoute!.targets.map((target) => target.name),
              ['codex'],
            );
            expect(
              updated.installationRoute!.source.requestedLocator,
              source.path,
            );
            expect(
              fs
                  .directory(
                    fs.path.join(project.path, '.claude', 'skills', 'review'),
                  )
                  .existsSync(),
              isFalse,
            );
          },
        );

        test(
          'updates a direct canonical Skill without changing its route',
          () async {
            useLocalFileSystem();
            final source = skill('canonical-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'canonical',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            final options = LifecycleOptions(
              processWorkingDirectory: project.path,
              scope: LifecycleScope.project,
              cwd: project.path,
              projectRoot: project.path,
              home: home.path,
            );
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final resolved = LifecycleContext.resolve(options, fileSystem: fs);
            final record = lifecycle.state.records(resolved).single;
            final oldExposure = record.exposures.single.path;
            fs
                .file(fs.path.join(source.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: review\ndescription: Reviews.\n---\nCanonical update.\n',
                );
            final result = await executor().fake().execute([
              'skill',
              'update',
              record.installationId,
              ...context(),
              '--yes',
            ]);
            expect(result, isA<MambaSuccessResult>());
            final updated = lifecycle.state.records(resolved).single;
            expect(
              updated.installationRoute!.method,
              InstallationMethod.canonical,
            );
            expect(updated.exposures.single.path, oldExposure);
            expect(
              fs
                  .file(fs.path.join(updated.location, 'SKILL.md'))
                  .readAsStringSync(),
              contains('Canonical update.'),
            );
          },
        );

        test('reviews a canonical target change before publishing', () async {
          useLocalFileSystem();
          final source = skill('canonical-target-source');
          expect(
            await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'canonical',
              '--yes',
            ]),
            isA<MambaSuccessResult>(),
          );
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          final lifecycle = SkillLifecycleService(fileSystem: fs);
          final resolved = LifecycleContext.resolve(options, fileSystem: fs);
          final record = lifecycle.state.records(resolved).single;
          final exposure = record.exposures.single.path;
          final args = [
            'skill',
            'migrate',
            record.installationId,
            ...context(),
            '--method',
            'canonical',
            '--target',
            'codex',
            '--format',
            'json',
          ];
          final preview = await executor().fake().execute([
            ...args,
            '--dry-run',
          ]);
          expect(preview, isA<MambaSuccessResult>());
          final plan =
              jsonDecode((preview as MambaSuccessResult).output!) as Map;
          final data = plan['data'] as Map;
          expect(data['fromTargets'], ['claude']);
          expect(data['toTargets'], ['codex']);
          expect(
            fs.typeSync(exposure, followLinks: false),
            FileSystemEntityType.link,
          );
          final id = data['planId'] as String;
          expect(
            await executor().fake().execute([...args, '--reviewed-plan', id]),
            isA<MambaFailureResult>(),
          );
          expect(
            fs.typeSync(exposure, followLinks: false),
            FileSystemEntityType.link,
          );
          expect(
            await executor().fake().execute([
              ...args,
              '--reviewed-plan',
              id,
              '--yes',
            ]),
            isA<MambaSuccessResult>(),
          );
          expect(
            fs.typeSync(exposure, followLinks: false),
            FileSystemEntityType.notFound,
          );
          final updated = lifecycle.state.records(resolved).single;
          expect(updated.installationRoute!.targets.map((item) => item.name), [
            'codex',
          ]);
          expect(updated.exposures, isEmpty);
          expect(updated.knownConsumers, ['codex']);
        });

        test('canonical target addition refuses occupied exposure and stale review', () async {
          useLocalFileSystem();
          final source = skill('canonical-add-target');
          expect(
            await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'codex',
              '--method',
              'canonical',
              '--yes',
            ]),
            isA<MambaSuccessResult>(),
          );
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          final lifecycle = SkillLifecycleService(fileSystem: fs);
          final resolved = LifecycleContext.resolve(options, fileSystem: fs);
          final record = lifecycle.state.records(resolved).single;
          final location = fs.path.join(
            project.path,
            '.claude',
            'skills',
            'review',
          );
          fs.directory(location).createSync(recursive: true);
          final args = [
            'skill',
            'migrate',
            record.installationId,
            ...context(),
            '--method',
            'canonical',
            '--target',
            'claude',
            '--target',
            'codex',
            '--format',
            'json',
          ];
          expect(
            await executor().fake().execute([...args, '--dry-run']),
            isA<MambaFailureResult>(),
          );
          expect(fs.directory(location).existsSync(), isTrue);
          fs.directory(location).deleteSync();
          final preview = await executor().fake().execute([
            ...args,
            '--dry-run',
          ]);
          expect(preview, isA<MambaSuccessResult>());
          final data =
              (jsonDecode((preview as MambaSuccessResult).output!)
                      as Map)['data']
                  as Map;
          final plan = data['planId'] as String;
          fs.directory(location).createSync(recursive: true);
          expect(
            await executor().fake().execute([
              ...args,
              '--reviewed-plan',
              plan,
              '--yes',
            ]),
            isA<MambaFailureResult>(),
          );
          expect(fs.directory(location).existsSync(), isTrue);
          fs.directory(location).deleteSync();
          expect(
            await executor().fake().execute([
              ...args,
              '--reviewed-plan',
              plan,
              '--yes',
            ]),
            isA<MambaSuccessResult>(),
          );
          final updated = lifecycle.state.records(resolved).single;
          expect(
            updated.installationRoute!.targets.map((target) => target.name),
            ['claude', 'codex'],
          );
          expect(
            fs.typeSync(location, followLinks: false),
            FileSystemEntityType.link,
          );
        });

        test('updates each record of a multi-target copy group', () async {
          useLocalFileSystem();
          final source = skill('update-group');
          final install = await executor().fake().execute([
            'skill',
            'install',
            source.path,
            ...context(),
            '--source-kind',
            'resource',
            '--target',
            'claude',
            '--target',
            'codex',
            '--method',
            'copy',
            '--yes',
          ]);
          expect(install, isA<MambaSuccessResult>());
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            stateDir: fs.path.join(sandbox.path, 'state'),
          );
          final lifecycle = SkillLifecycleService(fileSystem: fs);
          final resolved = LifecycleContext.resolve(options, fileSystem: fs);
          final group = lifecycle.state
              .records(resolved)
              .where((record) => record.name == 'review')
              .toList();
          expect(group, hasLength(2));
          expect(
            group
                .map((record) => jsonEncode(record.installationRoute!.toJson()))
                .toSet(),
            hasLength(1),
            reason: 'group members share one recorded route',
          );

          for (final record in group) {
            final update = await executor().fake().execute([
              'skill',
              'update',
              record.installationId,
              ...context(),
              '--yes',
            ]);
            expect(
              update,
              isA<MambaSuccessResult>(),
              reason: 'update by id ${record.installationId}',
            );
          }
          final after = lifecycle.state
              .records(resolved)
              .where((record) => record.name == 'review')
              .toList();
          expect(after, hasLength(2));
          for (final record in after) {
            expect(record.installationRoute?.method, InstallationMethod.copy);
            expect(
              [for (final t in record.installationRoute!.targets) t.name]
                ..sort(),
              ['claude', 'codex'],
            );
          }
        });

        test(
          'migrates a multi-target copy group to canonical and back by id',
          () async {
            useLocalFileSystem();
            final source = skill('migration-group');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--target',
              'codex',
              '--method',
              'copy',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            final options = LifecycleOptions(
              processWorkingDirectory: project.path,
              scope: LifecycleScope.project,
              cwd: project.path,
              projectRoot: project.path,
              home: home.path,
              stateDir: fs.path.join(sandbox.path, 'state'),
            );
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final resolved = LifecycleContext.resolve(options, fileSystem: fs);
            final initial = lifecycle.state.records(resolved);
            expect(
              initial.where((record) => record.name == 'review'),
              hasLength(2),
              reason: 'a multi-target copy install must record one ledger record per target',
            );
            final oldId =
                initial
                    .where((record) => record.name == 'review')
                    .map((record) => record.installationId)
                    .toList()
                  ..sort();
            final migratedId = oldId.first;

            final args = [
              'skill',
              'migrate',
              migratedId,
              ...context(),
              '--method',
              'canonical',
              '--format',
              'json',
            ];
            final preview = await executor().fake().execute([
              ...args,
              '--dry-run',
            ]);
            expect(preview, isA<MambaSuccessResult>());
            final planId =
                ((jsonDecode((preview as MambaSuccessResult).output!)
                            as Map)['data']
                        as Map)['planId']
                    as String;
            final migrated = await executor().fake().execute([
              ...args,
              '--yes',
              '--reviewed-plan',
              planId,
            ]);
            expect(migrated, isA<MambaSuccessResult>());
            final canonical = lifecycle.state
                .records(resolved)
                .where((record) => record.name == 'review')
                .toList();
            expect(canonical, hasLength(1));
            expect(canonical.single.kind, ArtifactKind.skillCanonical);
            expect(canonical.single.installationId, migratedId);
            expect([...canonical.single.knownConsumers]..sort(), [
              'claude',
              'codex',
            ]);
            expect(
              fs
                  .file(
                    fs.path.join(
                      project.path,
                      '.agents',
                      'skills',
                      'review',
                      'SKILL.md',
                    ),
                  )
                  .existsSync(),
              isTrue,
            );
            // The shared route group was retired as one transaction; the
            // surviving id keeps `skill update` resolving the installation.
            final update = await executor().fake().execute([
              'skill',
              'update',
              migratedId,
              ...context(),
              '--yes',
            ]);
            expect(update, isA<MambaSuccessResult>());

            final reverseArgs = [
              'skill',
              'migrate',
              migratedId,
              ...context(),
              '--method',
              'copy',
              '--format',
              'json',
            ];
            final reversePreview = await executor().fake().execute([
              ...reverseArgs,
              '--dry-run',
            ]);
            expect(reversePreview, isA<MambaSuccessResult>());
            final reverseId =
                ((jsonDecode((reversePreview as MambaSuccessResult).output!)
                            as Map)['data']
                        as Map)['planId']
                    as String;
            final reverse = await executor().fake().execute([
              ...reverseArgs,
              '--yes',
              '--reviewed-plan',
              reverseId,
            ]);
            expect(reverse, isA<MambaSuccessResult>());
            final restored = lifecycle.state
                .records(resolved)
                .where((record) => record.name == 'review')
                .toList();
            expect(restored, hasLength(2));
            expect(restored.map((record) => record.kind).toSet(), {
              ArtifactKind.skillCopy,
            });
            expect(
              restored.any((record) => record.installationId == migratedId),
              isTrue,
            );
            expect(
              lifecycle.state.recordById(resolved, migratedId).installationId,
              migratedId,
            );
          },
        );

        test(
          'previews and confirms a direct copy to source-link migration',
          () async {
            useLocalFileSystem();
            final source = skill('migration-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            final options = LifecycleOptions(
              processWorkingDirectory: project.path,
              scope: LifecycleScope.project,
              cwd: project.path,
              projectRoot: project.path,
              home: home.path,
              stateDir: fs.path.join(sandbox.path, 'state'),
            );
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final resolved = LifecycleContext.resolve(options, fileSystem: fs);
            final record = lifecycle.state.records(resolved).single;
            final args = [
              'skill',
              'migrate',
              record.installationId,
              ...context(),
              '--method',
              'source-link',
              '--format',
              'json',
            ];
            final before = fs
                .file(fs.path.join(resolved.stateRoot(), 'installations.json'))
                .readAsStringSync();
            final preview = await executor().fake().execute([
              ...args,
              '--dry-run',
            ]);
            expect(preview, isA<MambaSuccessResult>());
            final plan =
                jsonDecode((preview as MambaSuccessResult).output!) as Map;
            expect(plan['outcome'], 'planned');
            expect((plan['data'] as Map)['fromMethod'], 'copy');
            expect((plan['data'] as Map)['toMethod'], 'source-link');
            expect(
              fs
                  .file(
                    fs.path.join(resolved.stateRoot(), 'installations.json'),
                  )
                  .readAsStringSync(),
              before,
            );
            expect(
              await executor().fake().execute(args),
              isA<MambaFailureResult>(),
            );
            expect(
              fs
                  .file(
                    fs.path.join(resolved.stateRoot(), 'installations.json'),
                  )
                  .readAsStringSync(),
              before,
            );
            final planId = (plan['data'] as Map)['planId'] as String;
            expect(
              await executor().fake().execute([
                ...args,
                '--reviewed-plan',
                planId,
              ]),
              isA<MambaFailureResult>(),
            );
            expect(
              fs
                  .file(
                    fs.path.join(resolved.stateRoot(), 'installations.json'),
                  )
                  .readAsStringSync(),
              before,
            );
            expect(
              await executor().fake().execute([...args, '--yes']),
              isA<MambaFailureResult>(),
            );
            final sourceFile = fs.file(fs.path.join(source.path, 'SKILL.md'));
            final original = sourceFile.readAsStringSync();
            sourceFile.writeAsStringSync('$original\nChanged after preview.\n');
            expect(
              await executor().fake().execute([
                ...args,
                '--yes',
                '--reviewed-plan',
                planId,
              ]),
              isA<MambaFailureResult>(),
            );
            expect(
              fs
                  .file(
                    fs.path.join(resolved.stateRoot(), 'installations.json'),
                  )
                  .readAsStringSync(),
              before,
            );
            sourceFile.writeAsStringSync(original);
            final applied = await executor().fake().execute([
              ...args,
              '--yes',
              '--reviewed-plan',
              planId,
            ]);
            expect(applied, isA<MambaSuccessResult>());
            expect(
              fs.typeSync(record.location, followLinks: false),
              FileSystemEntityType.link,
            );
            final updated = lifecycle.state.records(resolved).single;
            expect(
              updated.installationRoute!.method,
              InstallationMethod.sourceLink,
            );
            expect(
              updated.installationRoute!.targets.map((target) => target.name),
              ['claude'],
            );
            fs
                .file(fs.path.join(source.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: review\ndescription: Reviews.\n---\nLinked update.\n',
                );
            final linkUpdate = await executor().fake().execute([
              'skill',
              'update',
              record.installationId,
              ...context(),
              '--yes',
            ]);
            expect(linkUpdate, isA<MambaSuccessResult>());
            expect(
              fs
                  .file(fs.path.join(record.location, 'SKILL.md'))
                  .readAsStringSync(),
              contains('Linked update.'),
            );
            final reverseArgs = [
              'skill',
              'migrate',
              record.installationId,
              ...context(),
              '--method',
              'copy',
              '--format',
              'json',
            ];
            final reversePreview = await executor().fake().execute([
              ...reverseArgs,
              '--dry-run',
            ]);
            expect(reversePreview, isA<MambaSuccessResult>());
            final reversePlan = jsonDecode(
              (reversePreview as MambaSuccessResult).output!,
            ) as Map;
            final reverseId = (reversePlan['data'] as Map)['planId'] as String;
            final reverse = await executor().fake().execute([
              ...reverseArgs,
              '--yes',
              '--reviewed-plan',
              reverseId,
            ]);
            expect(reverse, isA<MambaSuccessResult>());
            expect(
              fs.typeSync(record.location, followLinks: false),
              FileSystemEntityType.directory,
            );
            expect(
              lifecycle.state
                  .records(resolved)
                  .single
                  .installationRoute!
                  .method,
              InstallationMethod.copy,
            );
          },
        );

        test(
          'refuses an unsupported Skill target before acquisition',
          () async {
            final source = skill('unsupported-target');
            final service = SkillInstallationService(
              fileSystem: fs,
              acquisition: acquisition,
              interaction: interaction,
              progress: noInstallationProgress,
            );
            final request = InstallationWorkflowRequest(
              source: source.path,
              options: LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                approved: true,
              ),
              sourceKind: AcquisitionSourceKind.resource,
              resourceIds: const [],
              allResources: false,
              targets: const [InstallationTarget.pi],
              method: InstallationMethod.copy,
              profile: null,
              ref: null,
              subpath: null,
              scopeExplicit: true,
            );
            await expectLater(
              service.run(request, interactive: false),
              throwsA(
                predicate(
                  (error) =>
                      error.toString().contains('pi') &&
                      error.toString().contains('Skill'),
                ),
              ),
            );
            expect(acquisition.calls, 0);
          },
        );

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

        for (final method in ['copy', 'source-link']) {
          test(
            'user Codex $method installs and removes from shared storage',
            () async {
              if (method == 'source-link') useLocalFileSystem();
              final source = skill('source');
              final command = executor().fake();
              final installed = await command.execute([
                'skill',
                'install',
                source.path,
                '--source-kind',
                'resource',
                '--target',
                'codex',
                '--method',
                method,
                ...context(scope: 'user'),
                '--yes',
                '--format',
                'json',
              ]);
              expect(
                installed,
                isA<MambaSuccessResult>().having(
                  (r) => r.exitCode,
                  'status',
                  0,
                ),
                reason: installed is MambaFailureResult
                    ? installed.message
                    : null,
              );
              final result = jsonDecode(
                (installed as MambaSuccessResult).output!,
              ) as Map<String, Object?>;
              expect(result['outcome'], 'installed');
              final data = result['data']! as Map<String, Object?>;
              final unit =
                  (data['units']! as List<Object?>).single!
                      as Map<String, Object?>;
              final id =
                  (unit['installationIds']! as List<Object?>).single! as String;
              final nativeFile = fs.file(
                fs.path.join(
                  home.path,
                  '.agents',
                  'skills',
                  'review',
                  'SKILL.md',
                ),
              );
              expect(nativeFile.existsSync(), isTrue);

              final removed = await command.execute([
                'skill',
                'remove',
                id,
                ...context(scope: 'user'),
                '--yes',
              ]);
              expect(
                removed,
                isA<MambaSuccessResult>().having(
                  (r) => r.exitCode,
                  'status',
                  0,
                ),
                reason: removed is MambaFailureResult ? removed.message : null,
              );
              expect(nativeFile.existsSync(), isFalse);
              expect(source.existsSync(), isTrue);
            },
          );
        }

        test(
          'user canonical Antigravity exposure can be detached and restored',
          () async {
            useLocalFileSystem();
            final source = skill('source');
            final gemini = fs.path.join(sandbox.path, 'gemini');
            final roots = [
              ...context(scope: 'user'),
              '--gemini-dir',
              '$gemini${fs.path.separator}',
            ];
            final install = [
              'skill',
              'install',
              source.path,
              '--source-kind',
              'resource',
              '--target',
              'antigravity',
              '--target',
              'codex',
              '--method',
              'canonical',
              ...roots,
              '--yes',
              '--format',
              'json',
            ];
            Future<Map<String, Object?>> run(
              List<String> args,
              String outcome,
            ) async {
              final result = await executor().fake().execute(args);
              expect(
                result,
                isA<MambaSuccessResult>().having(
                  (r) => r.exitCode,
                  'status',
                  0,
                ),
                reason: result is MambaFailureResult ? result.message : null,
              );
              final json = jsonDecode(
                (result as MambaSuccessResult).output!,
              ) as Map<String, Object?>;
              expect(json['outcome'], outcome);
              return json['data']! as Map<String, Object?>;
            }

            final installed = await run(install, 'installed');
            final canonical = fs.path.join(
              home.path,
              '.agents',
              'skills',
              'review',
            );
            final exposure = fs.link(
              fs.path.join(gemini, 'config', 'skills', 'review'),
            );
            expect(exposure.existsSync(), isTrue);
            expect(exposure.targetSync(), canonical);
            await run(install, 'unchanged');
            final unit =
                (installed['units']! as List<Object?>).single!
                    as Map<String, Object?>;
            final id =
                (unit['installationIds']! as List<Object?>).single! as String;

            final detached = await run([
              'skill',
              'remove',
              id,
              '--target',
              'antigravity',
              ...roots,
              '--yes',
              '--format',
              'json',
            ], 'detached');
            expect(exposure.existsSync(), isFalse);
            expect(
              fs.file(fs.path.join(canonical, 'SKILL.md')).existsSync(),
              isTrue,
            );

            await run([
              'skill',
              'backup',
              'restore',
              detached['outgoingBackupId']! as String,
              ...roots,
              '--yes',
              '--format',
              'json',
            ], 'restored');
            expect(exposure.targetSync(), canonical);
          },
        );

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

        test(
          'offers user scope when the project root cannot be used',
          () async {
            final source = skill('fallback-user');
            interaction.userScopeFallbacks.add(true);
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              '--target',
              'codex',
              '--method',
              'copy',
              '--dry-run',
              '--cwd',
              '${project.path}/',
              '--project-root',
              '${sandbox.path}/missing/',
              '--home',
              '${home.path}/',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(
              (result as MambaSuccessResult).output,
              contains('Scope: user'),
            );
            expect(interaction.userScopeFallbacks, isEmpty);
          },
        );

        test('omits a replay command for a sensitive source locator', () async {
          useLocalFileSystem();
          final server = await io.HttpServer.bind(
            io.InternetAddress.loopbackIPv4,
            0,
          );
          server.listen((request) {
            request.response.write(
              '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
            );
            request.response.close();
          });
          addTearDown(() => server.close(force: true));
          final locator =
              'http://127.0.0.1:${server.port}/SKILL.md?token=PRIVATE123';
          final result = await executor().fake().execute([
            'skill',
            'install',
            locator,
            '--target',
            'codex',
            '--method',
            'copy',
            '--source-kind',
            'resource',
            '--dry-run',
            ...context(),
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final output = (result as MambaSuccessResult).output!;
          expect(output, contains('Explicit command omitted'));
          expect(output, isNot(contains('PRIVATE123')));
        });

        test('interactive installation defaults to project scope', () async {
          final source = skill("default project's");
          final result = await executor().fake().execute([
            'skill',
            'install',
            source.path,
            '--target',
            'codex',
            '--method',
            'copy',
            '--dry-run',
            ...context().skip(2),
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final output = (result as MambaSuccessResult).output!;
          expect(output, contains('Scope: project'));
          expect(output, contains('Explicit command'));
          expect(output, contains('--scope project'));
          expect(output, contains('--source-kind resource'));
          expect(output, contains('--target codex'));
          expect(output, contains('--method copy'));
          expect(output, contains('--dry-run'));
          expect(output, contains(project.path));
          expect(output, isNot(contains('${home.path}/.agents/skills')));
          final command = output.split('\n').last.split('): ').last;
          final shell = await io.Process.run(
            io.Platform.isWindows ? 'powershell.exe' : 'sh',
            io.Platform.isWindows
                ? [
                    '-NoProfile',
                    '-Command',
                    'function agent_resource { \$args | ConvertTo-Json -Compress }; $command',
                  ]
                : [
                    '-c',
                    'agent_resource() { printf "%s\\n" "\$@"; }; $command',
                  ],
          );
          expect(shell.exitCode, 0, reason: '${shell.stderr}');
          final args = io.Platform.isWindows
              ? (jsonDecode(shell.stdout as String) as List).cast<String>()
              : (shell.stdout as String).trimRight().split('\n');
          expect(args, contains(source.path));
          final replay = await createExecutor(
            fileSystem: fs,
            skillInstallation: SkillInstallationService(
              fileSystem: fs,
              interaction: ScriptedInstallationInteraction(interactive: false),
              progress: noInstallationProgress,
            ),
          ).fake().execute(args);
          expect(
            replay,
            isA<MambaSuccessResult>(),
            reason: replay is MambaFailureResult ? replay.message : null,
          );
          expect(
            (replay as MambaSuccessResult).output,
            contains('Scope: project'),
          );
        });

        test('direct and pack previews disclose the same configured defaults and origins', () async {
          final collection = fs.directory(fs.path.join(sandbox.path, 'source'))
            ..createSync();
          final source = fs.directory(
            fs.path.join(collection.path, 'skills', 'review'),
          )..createSync(recursive: true);
          fs
              .file(fs.path.join(source.path, 'SKILL.md'))
              .writeAsStringSync(
                '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
              );
          fs
              .file(fs.path.join(collection.path, 'agent-resources.toml'))
              .writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/review"
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
          final direct = await executor().fake().execute([
            'skill',
            'install',
            source.path,
            ...context(),
            '--dry-run',
          ]);
          final pack =
              await Executor('agent_resource', 'Test.', '1.0.0', [
                PackActionCommand(
                  PackResourceType.skill,
                  PackOperation.install,
                  PackLifecycleService(fileSystem: fs),
                  fileSystem: fs,
                  stdinIsTerminal: () => true,
                  stdoutIsTerminal: () => true,
                ),
              ]).fake().execute([
                'install',
                'local/demo',
                '--scope',
                'project',
                '--cwd',
                '${project.path}/',
                '--project-root',
                '${project.path}/',
                '--home',
                '${home.path}/',
                '--dry-run',
              ]);
          expect(
            direct,
            isA<MambaSuccessResult>(),
            reason: direct is MambaFailureResult ? direct.message : null,
          );
          expect(
            pack,
            isA<MambaSuccessResult>(),
            reason: pack is MambaFailureResult ? pack.message : null,
          );
          for (final output in [
            (direct as MambaSuccessResult).output!,
            (pack as MambaSuccessResult).output!,
          ]) {
            expect(output, contains('codex'));
            expect(output, contains('copy'));
            expect(output, contains('project-config'));
          }
        });

        test('unattended plan reports explicit origins in JSON', () async {
          final source = skill('origins');
          final result = await executor().fake().execute([
            'skill',
            'install',
            source.path,
            '--source-kind',
            'resource',
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
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final data =
              (jsonDecode((result as MambaSuccessResult).output!)
                      as Map)['data']
                  as Map;
          expect(data['resolution'], {
            'scope': {'value': 'project', 'origin': 'explicit-argument'},
            'targets': {
              'value': ['codex'],
              'origin': 'explicit-argument',
            },
            'method': {'value': 'copy', 'origin': 'explicit-argument'},
          });
        });

        test(
          'ignores unsupported preferred targets instead of crashing',
          () async {
            final source = skill('unsupported-pref');
            fs.file('${project.path}/agent-resources.toml').writeAsStringSync(
              '''
schema_version = 1
[cli.install]
targets = ["shared"]
skill_method = "copy"
''',
            );
            interaction.targetSelections.add([InstallationTarget.codex]);
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--dry-run',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect((result as MambaSuccessResult).output, contains('[codex]'));
          },
        );

        test(
          'save prompt failure does not misreport a successful installation',
          () async {
            final source = skill('prompt-failure');
            interaction.approvals.add(true);
            interaction.preferencePromptFails = true;
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(
              interaction.presentedPlans.last,
              contains(
                'Installation succeeded, but preferences were not saved',
              ),
            );
          },
        );

        test(
          'offers eligible preference saving only after interactive success',
          () async {
            final source = skill('save-source');
            interaction.approvals.add(true);
            interaction.preferenceSaves.add(true);
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(interaction.preferenceOffers, [
              contains('cli.install.targets=codex'),
            ]);
            final config = fs.file(
              fs.path.join(project.path, 'agent-resources.toml'),
            );
            expect(config.readAsStringSync(), contains('targets = ["codex"]'));
            expect(
              config.readAsStringSync(),
              contains('skill_method = "copy"'),
            );
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
          expect(interaction.preferenceOffers, isEmpty);
          expect(output, contains('skill install: planned'));
          expect(output, contains('Scope: user'));
          expect(output, contains('Method: canonical'));
          expect(output, contains('code-review'));
          expect(output, contains('--source-kind collection'));
          expect(output, contains('--resource code-review'));
          expect(output, contains('--target codex'));
          expect(output, contains('--method canonical'));
          final command = output.split('\n').last.split('): ').last;
          final shell = await io.Process.run(
            io.Platform.isWindows ? 'powershell.exe' : 'sh',
            io.Platform.isWindows
                ? [
                    '-NoProfile',
                    '-Command',
                    'function agent_resource { \$args | ConvertTo-Json -Compress }; $command',
                  ]
                : [
                    '-c',
                    'agent_resource() { printf "%s\\n" "\$@"; }; $command',
                  ],
          );
          expect(shell.exitCode, 0, reason: '${shell.stderr}');
          final args = io.Platform.isWindows
              ? (jsonDecode(shell.stdout as String) as List).cast<String>()
              : (shell.stdout as String).trimRight().split('\n');
          final replay = await createExecutor(
            fileSystem: fs,
            skillInstallation: SkillInstallationService(
              fileSystem: fs,
              interaction: ScriptedInstallationInteraction(interactive: false),
              progress: noInstallationProgress,
            ),
          ).fake().execute(args);
          expect(
            replay,
            isA<MambaSuccessResult>(),
            reason: replay is MambaFailureResult ? replay.message : null,
          );
          expect(
            (replay as MambaSuccessResult).output,
            contains('code-review'),
          );
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
            expect(interaction.preferenceOffers, isEmpty);
          },
        );

        test(
          'records the source route and migrated artifacts for replay',
          () async {
            final source = skill('route-source');
            fs
                .file(fs.path.join(source.path, 'guide.md'))
                .writeAsStringSync('Guide');
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              '--source-kind',
              'resource',
              '--target',
              'codex',
              '--method',
              'copy',
              ...context(),
              '--yes',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            final state = LifecycleStateService(io: LifecycleIO(fs: fs));
            final records = state.records(
              LifecycleContext.resolve(
                LifecycleOptions(
                  processWorkingDirectory: project.path,
                  scope: LifecycleScope.project,
                  cwd: project.path,
                  projectRoot: project.path,
                  home: home.path,
                  stateDir: fs.path.join(sandbox.path, 'state'),
                ),
                fileSystem: fs,
              ),
            );
            final route = records.single.toJson()['installationRoute'] as Map;
            expect(
              records.single.installationRoute!.source.resolvedLocator,
              source.path,
            );
            expect(route['sourceKind'], 'resource');
            expect(route['scope'], 'project');
            expect(route['targets'], ['codex']);
            expect(route['method'], 'copy');
            expect((route['source'] as Map)['requestedLocator'], source.path);
            expect(route['sourceRelativePath'], '.');
            final bad = records.single.toJson();
            bad['installationRoute'] = {
              ...route,
              'sourceRelativePath': '../escape',
            };
            expect(
              () => InstallationRecord.fromJson(bad),
              throwsFormatException,
            );
            expect(
              route['derivedArtifacts'],
              contains(
                predicate(
                  (item) =>
                      item is Map &&
                      item['sourcePath'] == 'guide.md' &&
                      item['outputPath'] == 'references/guide.md',
                ),
              ),
            );
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
          expect(records.single.installationRoute!.targets.map((t) => t.name), [
            'claude',
            'codex',
          ]);
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

        test('canonical inventory follows only its tracked exposure', () async {
          useLocalFileSystem();
          final source = skill('canonical-inventory');
          fs
              .file(fs.path.join(source.path, 'SKILL.md'))
              .writeAsStringSync(
                '---\nname: review\ndescription: Reviews.\ndisable-model-invocation: true\n---\nBody.\n',
              );
          final installed = await executor().fake().execute([
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
          ]);
          expect(
            installed,
            isA<MambaSuccessResult>(),
            reason: installed is MambaFailureResult ? installed.message : null,
          );
          final prompts = await executor().fake().execute([
            'prompt',
            'list',
            ...context(),
            '--format',
            'json',
          ]);
          expect(
            prompts,
            isA<MambaSuccessResult>(),
            reason: prompts is MambaFailureResult ? prompts.message : null,
          );
          final promptEntries =
              jsonDecode((prompts as MambaSuccessResult).output!)['entries']
                  as List;
          expect(promptEntries, hasLength(1));
          expect(promptEntries.single['exposures'], hasLength(1));
          expect(promptEntries.single['directConsumers'], contains('codex'));
          final skills = await executor().fake().execute([
            'skill',
            'list',
            ...context(),
            '--format',
            'json',
          ]);
          expect(skills, isA<MambaSuccessResult>());
          final occurrences =
              (jsonDecode(
                    (skills as MambaSuccessResult).output!,
                  )['data']['occurrences']
                  as List);
          expect(
            occurrences.where((item) => item['installationId'] != null),
            hasLength(1),
          );
          final canonical = occurrences.singleWhere(
            (item) => item['installationId'] != null,
          );
          expect(canonical['exposures'], hasLength(1));
          expect(canonical['directConsumers'], contains('codex'));
          final filtered = await executor().fake().execute([
            'skill',
            'list',
            ...context(),
            '--destination',
            'claude',
            '--format',
            'json',
          ]);
          expect(filtered, isA<MambaSuccessResult>());
          expect(
            (jsonDecode(
                  (filtered as MambaSuccessResult).output!,
                )['data']['occurrences']
                as List),
            hasLength(1),
          );

          final exposure = io.Link(
            fs.path.join(project.path, '.claude', 'skills', 'review'),
          );
          final target = exposure.targetSync();
          final ledger = fs.file(
            fs.path.join(project.path, '.agent-resource', 'installations.json'),
          );
          final originalLedger = ledger.readAsStringSync();
          final document = jsonDecode(originalLedger) as Map<String, dynamic>;
          final installation =
              (document['installations'] as List).single as Map;
          final exposures = installation['exposures'] as List;
          final tracked = exposures.single as Map;
          final baseline = (tracked['baseline'] as List).single as Map;

          // The link text resolves to the canonical location only when the
          // untrusted recorded parent is used instead of the actual parent.
          final relative = fs.path.relative(target, from: project.path);
          final actualTarget = fs.path.normalize(
            fs.path.join(fs.path.dirname(exposure.path), relative),
          );
          fs.directory(actualTarget).createSync(recursive: true);
          exposure.deleteSync();
          exposure.createSync(relative);
          baseline['target'] = relative;
          baseline['originalParent'] = project.path;
          ledger.writeAsStringSync(jsonEncode(document));
          final rejectedParent = await executor().fake().execute([
            'prompt',
            'list',
            ...context(),
            '--format',
            'json',
          ]);
          expect(rejectedParent, isA<MambaFailureResult>());
          final skillParent = await executor().fake().execute([
            'skill',
            'list',
            ...context(),
            '--destination',
            'claude',
            '--format',
            'json',
          ]);
          expect(skillParent, isA<MambaSuccessResult>());
          final parentOccurrences =
              jsonDecode(
                    (skillParent as MambaSuccessResult).output!,
                  )['data']['occurrences']
                  as List;
          expect(
            parentOccurrences.where((item) => item['path'] == exposure.path),
            hasLength(1),
          );
          exposure.deleteSync();
          exposure.createSync(target);

          // A matching valid exposure cannot hide malformed or duplicate peers.
          for (final duplicate in [false, true]) {
            final modified = jsonDecode(originalLedger) as Map<String, dynamic>;
            final record = (modified['installations'] as List).single as Map;
            final siblings = record['exposures'] as List;
            final sibling = Map<String, dynamic>.from(siblings.single as Map);
            if (!duplicate) sibling['target'] = 'codex';
            siblings.add(sibling);
            ledger.writeAsStringSync(jsonEncode(modified));
            final rejected = await executor().fake().execute([
              'prompt',
              'list',
              ...context(),
              '--format',
              'json',
            ]);
            expect(
              rejected,
              isA<MambaFailureResult>(),
              reason: 'duplicate=$duplicate',
            );
          }
          ledger.writeAsStringSync(originalLedger);
          exposure.deleteSync();
          exposure.createSync(source.path);
          final changed = await executor().fake().execute([
            'prompt',
            'list',
            ...context(),
            '--format',
            'json',
          ]);
          expect(
            changed,
            isA<MambaFailureResult>().having((r) => r.exitCode, 'exit code', 4),
          );
          exposure.deleteSync();
          exposure.createSync(target);
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.agent-resource',
                  'installations.json',
                ),
              )
              .deleteSync();
          final untracked = await executor().fake().execute([
            'prompt',
            'list',
            ...context(),
            '--format',
            'json',
          ]);
          expect(
            untracked,
            isA<MambaFailureResult>().having((r) => r.exitCode, 'exit code', 4),
          );
        });

        test('canonical inventory rejects invalid sibling authority', () async {
          useLocalFileSystem();
          final source = skill('sibling-authority');
          fs
              .file(fs.path.join(source.path, 'SKILL.md'))
              .writeAsStringSync(
                '---\nname: review\ndescription: Reviews.\ndisable-model-invocation: true\n---\nBody.\n',
              );
          final roots = context(scope: 'user');
          final installed = await executor().fake().execute([
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
            ...roots,
            '--yes',
          ]);
          expect(
            installed,
            isA<MambaSuccessResult>(),
            reason: installed is MambaFailureResult ? installed.message : null,
          );
          Future<dynamic> inventory() => executor().fake().execute([
            'prompt',
            'list',
            ...roots,
            '--format',
            'json',
          ]);
          final valid = await inventory();
          expect(
            valid,
            isA<MambaSuccessResult>(),
            reason: valid is MambaFailureResult ? valid.message : null,
          );
          final ledger = fs.file(
            fs.path.join(sandbox.path, 'state', 'installations.json'),
          );
          final document =
              jsonDecode(ledger.readAsStringSync()) as Map<String, dynamic>;
          final record = (document['installations'] as List).single as Map;
          final siblings = record['exposures'] as List;
          final sibling = jsonDecode(jsonEncode(siblings.single)) as Map;
          sibling['target'] = 'antigravity';
          sibling['path'] = fs.path.join(
            home.path,
            '.gemini',
            'config',
            'skills',
            'review',
          );
          final baseline = (sibling['baseline'] as List).single as Map;
          siblings.add(sibling);
          baseline['originalParent'] = fs.path.dirname(
            sibling['path'] as String,
          );
          final validSibling = jsonEncode(document);
          ledger.writeAsStringSync(validSibling);
          final withSibling = await inventory();
          expect(
            withSibling,
            isA<MambaSuccessResult>(),
            reason: withSibling is MambaFailureResult
                ? withSibling.message
                : null,
          );
          for (final field in ['originalParent', 'target', 'nativeKind']) {
            final altered = jsonDecode(validSibling) as Map<String, dynamic>;
            final alteredRecord =
                (altered['installations'] as List).single as Map;
            final alteredSibling =
                (alteredRecord['exposures'] as List).last as Map;
            final alteredBaseline =
                (alteredSibling['baseline'] as List).single as Map;
            alteredBaseline[field] = switch (field) {
              'originalParent' => project.path,
              'target' => source.path,
              _ =>
                alteredSibling['nativeKind'] == 'symlink'
                    ? 'junction'
                    : 'symlink',
            };
            ledger.writeAsStringSync(jsonEncode(altered));
            final rejected = await inventory();
            expect(
              rejected,
              isA<MambaFailureResult>().having(
                (r) => r.exitCode,
                'exit code',
                4,
              ),
              reason: field,
            );
          }
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
        group('derived prompts', () {
          Directory manualSkill(
            String name, {
            String? nativeName,
            String body = 'Body.\n',
            List<String> frontmatter = const <String>[],
          }) {
            nativeName ??= name;
            final directory = fs.directory(fs.path.join(sandbox.path, name))
              ..createSync(recursive: true);
            fs
                .file(fs.path.join(directory.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: $nativeName\ndescription: Reviews.\n'
                  'disable-model-invocation: true\n'
                  '${frontmatter.join('\n')}'
                  '${frontmatter.isEmpty ? '' : '\n'}---\n$body',
                );
            return directory;
          }

          String promptPath(String name) =>
              fs.path.join(project.path, '.pi', 'prompts', '$name.md');

          test('publishes a derived prompt template with the skill', () async {
            final source = manualSkill('manual-source');
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            final prompt = fs.file(promptPath('manual-source'));
            expect(prompt.existsSync(), isTrue);
            expect(prompt.readAsStringSync(), endsWith('Body.\n'));
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final resolved = LifecycleContext.resolve(
              LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                stateDir: fs.path.join(sandbox.path, 'state'),
              ),
              fileSystem: fs,
            );
            final record = lifecycle.state.records(resolved).single;
            expect(record.installationRoute!.promptTargets, ['pi']);
            expect(record.derivedPrompts.single.path, prompt.path);
          });

          test('creates nothing without the flag', () async {
            final source = manualSkill('no-flag-source');
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--yes',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(fs.file(promptPath('no-flag-source')).existsSync(), isFalse);
          });

          test('derives independently of the requested Skill target', () async {
            final source = manualSkill('codex-target-source');
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'codex',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(
              fs.file(promptPath('codex-target-source')).existsSync(),
              isTrue,
            );
          });

          test(
            'fails an ineligible manual-only Skill with zero writes',
            () async {
              final source = manualSkill('ineligible-source');
              fs
                  .directory(fs.path.join(source.path, 'references'))
                  .createSync();
              fs
                  .file(fs.path.join(source.path, 'references', 'notes.txt'))
                  .writeAsStringSync('notes');
              final result = await executor().fake().execute([
                'skill',
                'install',
                source.path,
                ...context(),
                '--source-kind',
                'resource',
                '--target',
                'claude',
                '--method',
                'copy',
                '--prompt-target',
                'pi',
                '--yes',
              ]);
              expect(result, isA<MambaFailureResult>());
              expect(
                fs.file(promptPath('ineligible-source')).existsSync(),
                isFalse,
              );
              expect(
                fs
                    .directory(fs.path.join(project.path, '.claude', 'skills'))
                    .existsSync(),
                isFalse,
              );
              expect(
                fs
                    .file(
                      fs.path.join(sandbox.path, 'state', 'installations.json'),
                    )
                    .existsSync(),
                isFalse,
              );
            },
          );

          test(
            'reports unsupported metadata and keeps the body byte-identical',
            () async {
              const body = 'Line one.\nLine two.\n';
              final source = manualSkill(
                'metadata-source',
                body: body,
                frontmatter: const <String>['license: MIT'],
              );
              final result = await executor().fake().execute([
                'skill',
                'install',
                source.path,
                ...context(),
                '--source-kind',
                'resource',
                '--target',
                'claude',
                '--method',
                'copy',
                '--prompt-target',
                'pi',
                '--yes',
                '--format',
                'json',
              ]);
              expect(
                result,
                isA<MambaSuccessResult>(),
                reason: result is MambaFailureResult ? result.message : null,
              );
              final rendered = fs
                  .file(promptPath('metadata-source'))
                  .readAsStringSync();
              expect(rendered, endsWith(body));
              expect(rendered, contains('description'));
              expect(rendered, isNot(contains('license')));
              expect(rendered, isNot(contains('MIT')));
              final output = (result as MambaSuccessResult).output ?? '';
              expect(output, contains('license'));
            },
          );

          test('interactive asks once for several eligible Skills', () async {
            final collection = fs.directory(
              fs.path.join(sandbox.path, 'collection'),
            )..createSync(recursive: true);
            for (final id in ['first', 'second']) {
              final dir = fs.directory(
                fs.path.join(collection.path, 'skills', id),
              )..createSync(recursive: true);
              fs
                  .file(fs.path.join(dir.path, 'SKILL.md'))
                  .writeAsStringSync(
                    '---\nname: $id\ndescription: $id.\n'
                    'disable-model-invocation: true\n---\n$id body.\n',
                  );
            }
            fs
                .file(fs.path.join(collection.path, 'agent-resources.toml'))
                .writeAsStringSync('''
schema_version = 1
[[skills]]
id = "first"
path = "skills/first"
[[skills]]
id = "second"
path = "skills/second"
''');
            interaction.resourceSelections.add(['first', 'second']);
            interaction.targetSelections.add([InstallationTarget.claude]);
            interaction.derivedPromptAnswers.add(['pi']);
            interaction.approvals.add(true);
            final result = await executor().fake().execute([
              'skill',
              'install',
              collection.path,
              ...context(),
              '--source-kind',
              'collection',
              '--method',
              'copy',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(interaction.derivedPromptOffers, hasLength(1));
            final offered = interaction.derivedPromptOffers.single.join(', ');
            expect(offered, contains('first'));
            expect(offered, contains('second'));
            expect(offered, contains('pi'));
            expect(fs.file(promptPath('first')).existsSync(), isTrue);
            expect(fs.file(promptPath('second')).existsSync(), isTrue);
          });

          test('does not ask without a manual-only Skill', () async {
            final source = skill('plain-source', nativeName: 'plain-source');
            interaction.targetSelections.add([InstallationTarget.claude]);
            interaction.approvals.add(true);
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--method',
              'copy',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(interaction.derivedPromptOffers, isEmpty);
          });

          test('does not ask in user scope', () async {
            final source = manualSkill('user-scope-source');
            interaction.targetSelections.add([InstallationTarget.claude]);
            interaction.approvals.add(true);
            final result = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(scope: 'user'),
              '--source-kind',
              'resource',
              '--method',
              'copy',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(interaction.derivedPromptOffers, isEmpty);
          });

          test('update regenerates the template atomically', () async {
            final source = manualSkill('update-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final resolved = LifecycleContext.resolve(
              LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                stateDir: fs.path.join(sandbox.path, 'state'),
              ),
              fileSystem: fs,
            );
            final record = lifecycle.state.records(resolved).single;
            fs
                .file(fs.path.join(source.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: update-source\ndescription: Reviews.\n'
                  'disable-model-invocation: true\n---\nUpdated body.\n',
                );
            final result = await executor().fake().execute([
              'skill',
              'update',
              record.installationId,
              ...context(),
              '--yes',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(
              fs.file(promptPath('update-source')).readAsStringSync(),
              endsWith('Updated body.\n'),
            );
          });

          test('remove removes the template with the skill', () async {
            final source = manualSkill('remove-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            LifecycleContext resolved() => LifecycleContext.resolve(
              LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                stateDir: fs.path.join(sandbox.path, 'state'),
              ),
              fileSystem: fs,
            );
            final record = lifecycle.state.records(resolved()).single;
            final result = await executor().fake().execute([
              'skill',
              'remove',
              record.installationId,
              ...context(),
              '--yes',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(fs.file(promptPath('remove-source')).existsSync(), isFalse);
          });

          test(
            'canonical update regenerates the template atomically',
            () async {
              useLocalFileSystem();
              final source = manualSkill('canonical-update-source');
              final install = await executor().fake().execute([
                'skill',
                'install',
                source.path,
                ...context(),
                '--source-kind',
                'resource',
                '--target',
                'claude',
                '--method',
                'canonical',
                '--prompt-target',
                'pi',
                '--yes',
              ]);
              expect(
                install,
                isA<MambaSuccessResult>(),
                reason: install is MambaFailureResult ? install.message : null,
              );
              expect(
                fs.file(promptPath('canonical-update-source')).existsSync(),
                isTrue,
              );
              final lifecycle = SkillLifecycleService(fileSystem: fs);
              final resolved = LifecycleContext.resolve(
                LifecycleOptions(
                  processWorkingDirectory: project.path,
                  scope: LifecycleScope.project,
                  cwd: project.path,
                  projectRoot: project.path,
                  home: home.path,
                  stateDir: fs.path.join(sandbox.path, 'state'),
                ),
                fileSystem: fs,
              );
              final record = lifecycle.state.records(resolved).single;
              fs
                  .file(fs.path.join(source.path, 'SKILL.md'))
                  .writeAsStringSync(
                    '---\nname: canonical-update-source\n'
                    'description: Reviews.\n'
                    'disable-model-invocation: true\n'
                    '---\nCanonical body.\n',
                  );
              final result = await executor().fake().execute([
                'skill',
                'update',
                record.installationId,
                ...context(),
                '--yes',
              ]);
              expect(
                result,
                isA<MambaSuccessResult>(),
                reason: result is MambaFailureResult ? result.message : null,
              );
              expect(
                fs
                    .file(promptPath('canonical-update-source'))
                    .readAsStringSync(),
                endsWith('Canonical body.\n'),
              );
              final updated = lifecycle.state.records(resolved).single;
              expect(updated.derivedPrompts, hasLength(1));
            },
          );

          test('a locally edited template fails the update', () async {
            final source = manualSkill('local-edit-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            LifecycleContext resolved() => LifecycleContext.resolve(
              LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                stateDir: fs.path.join(sandbox.path, 'state'),
              ),
              fileSystem: fs,
            );
            final record = lifecycle.state.records(resolved()).single;
            fs
                .file(promptPath('local-edit-source'))
                .writeAsStringSync('Local edit.\n');
            fs
                .file(fs.path.join(source.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: local-edit-source\ndescription: Reviews.\n'
                  'disable-model-invocation: true\n---\nNew body.\n',
                );
            final result = await executor().fake().execute([
              'skill',
              'update',
              record.installationId,
              ...context(),
              '--yes',
            ]);
            expect(result, isA<MambaFailureResult>());
            // The local template edit is preserved, not silently replaced.
            expect(
              fs.file(promptPath('local-edit-source')).readAsStringSync(),
              'Local edit.\n',
            );
          });

          test(
            'copy to canonical migration keeps the template attached',
            () async {
              useLocalFileSystem();
              final source = manualSkill('migrate-keep-source');
              final install = await executor().fake().execute([
                'skill',
                'install',
                source.path,
                ...context(),
                '--source-kind',
                'resource',
                '--target',
                'claude',
                '--method',
                'copy',
                '--prompt-target',
                'pi',
                '--yes',
              ]);
              expect(install, isA<MambaSuccessResult>());
              final lifecycle = SkillLifecycleService(fileSystem: fs);
              LifecycleContext resolved() => LifecycleContext.resolve(
                LifecycleOptions(
                  processWorkingDirectory: project.path,
                  scope: LifecycleScope.project,
                  cwd: project.path,
                  projectRoot: project.path,
                  home: home.path,
                  stateDir: fs.path.join(sandbox.path, 'state'),
                ),
                fileSystem: fs,
              );
              final record = lifecycle.state.records(resolved()).single;
              final args = [
                'skill',
                'migrate',
                record.installationId,
                ...context(),
                '--method',
                'canonical',
                '--format',
                'json',
              ];
              final preview = await executor().fake().execute([
                ...args,
                '--dry-run',
              ]);
              expect(
                preview,
                isA<MambaSuccessResult>(),
                reason: preview is MambaFailureResult ? preview.message : null,
              );
              final planId =
                  ((jsonDecode((preview as MambaSuccessResult).output!)
                              as Map)['data']
                          as Map)['planId']
                      as String;
              final migrated = await executor().fake().execute([
                ...args,
                '--yes',
                '--reviewed-plan',
                planId,
              ]);
              expect(
                migrated,
                isA<MambaSuccessResult>(),
                reason: migrated is MambaFailureResult
                    ? migrated.message
                    : null,
              );
              final migratedRecord = lifecycle.state
                  .records(resolved())
                  .singleWhere((r) => r.name == 'migrate-keep-source');
              expect(
                migratedRecord.derivedPrompts.single.path,
                promptPath('migrate-keep-source'),
              );
              expect(
                fs.file(promptPath('migrate-keep-source')).existsSync(),
                isTrue,
              );
            },
          );

          test('legacy records without derived fields decode', () async {
            final source = manualSkill('legacy-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final resolved = LifecycleContext.resolve(
              LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                stateDir: fs.path.join(sandbox.path, 'state'),
              ),
              fileSystem: fs,
            );
            final ledgerFile = fs.file(
              fs.path.join(
                project.path,
                '.agent-resource',
                'installations.json',
              ),
            );
            final ledger = jsonDecode(ledgerFile.readAsStringSync()) as Map;
            final records = ledger['installations'] as List;
            for (final record in records) {
              (record as Map).remove('derivedPrompts');
              (record['installationRoute'] as Map?)?.remove('promptTargets');
            }
            ledgerFile.writeAsStringSync(jsonEncode(ledger));
            final loaded = lifecycle.state.records(resolved);
            expect(loaded, hasLength(1));
            expect(loaded.single.derivedPrompts, isEmpty);
            expect(loaded.single.installationRoute!.promptTargets, isEmpty);
          });

          test(
            'rejects a non-prompt-capable prompt target before writes',
            () async {
              final source = manualSkill('bad-target-source');
              final result = await executor().fake().execute([
                'skill',
                'install',
                source.path,
                ...context(),
                '--source-kind',
                'resource',
                '--target',
                'claude',
                '--method',
                'copy',
                '--prompt-target',
                'claude',
                '--yes',
              ]);
              expect(result, isA<MambaFailureResult>());
              expect(
                (result as MambaFailureResult).message,
                contains('not prompt-capable'),
              );
              expect(
                fs.file(promptPath('bad-target-source')).existsSync(),
                isFalse,
              );
              expect(
                fs
                    .directory(fs.path.join(project.path, '.claude', 'skills'))
                    .existsSync(),
                isFalse,
              );
            },
          );

          test('migrate --drop-prompt-targets removes the template', () async {
            useLocalFileSystem();
            final source = manualSkill('migrate-drop-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            LifecycleContext resolved() => LifecycleContext.resolve(
              LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                stateDir: fs.path.join(sandbox.path, 'state'),
              ),
              fileSystem: fs,
            );
            final record = lifecycle.state.records(resolved()).single;
            final args = [
              'skill',
              'migrate',
              record.installationId,
              ...context(),
              '--method',
              'canonical',
              '--drop-prompt-targets',
              '--format',
              'json',
            ];
            final preview = await executor().fake().execute([
              ...args,
              '--dry-run',
            ]);
            expect(
              preview,
              isA<MambaSuccessResult>(),
              reason: preview is MambaFailureResult ? preview.message : null,
            );
            final planId =
                ((jsonDecode((preview as MambaSuccessResult).output!)
                            as Map)['data']
                        as Map)['planId']
                    as String;
            final migrated = await executor().fake().execute([
              ...args,
              '--yes',
              '--reviewed-plan',
              planId,
            ]);
            expect(
              migrated,
              isA<MambaSuccessResult>(),
              reason: migrated is MambaFailureResult ? migrated.message : null,
            );
            final migratedRecord = lifecycle.state
                .records(resolved())
                .singleWhere((r) => r.name == 'migrate-drop-source');
            expect(migratedRecord.derivedPrompts, isEmpty);
            expect(migratedRecord.installationRoute!.promptTargets, isEmpty);
            expect(
              fs.file(promptPath('migrate-drop-source')).existsSync(),
              isFalse,
            );
          });

          test(
            'a failed update restores the old skill and old template',
            () async {
              final source = manualSkill('fail-update-source');
              final install = await executor().fake().execute([
                'skill',
                'install',
                source.path,
                ...context(),
                '--source-kind',
                'resource',
                '--target',
                'claude',
                '--method',
                'copy',
                '--prompt-target',
                'pi',
                '--yes',
              ]);
              expect(install, isA<MambaSuccessResult>());
              final options = LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                stateDir: fs.path.join(sandbox.path, 'state'),
                approved: true,
              );
              final resolved = LifecycleContext.resolve(
                options,
                fileSystem: fs,
              );
              final record = SkillLifecycleService(fileSystem: fs).state
                  .records(resolved)
                  .single;
              final skillPath = fs.path.join(record.location, 'SKILL.md');
              final oldSkill = fs.file(skillPath).readAsStringSync();
              final oldPrompt = fs
                  .file(promptPath('fail-update-source'))
                  .readAsStringSync();
              fs
                  .file(fs.path.join(source.path, 'SKILL.md'))
                  .writeAsStringSync(
                    '---\nname: fail-update-source\ndescription: Reviews.\n'
                    'disable-model-invocation: true\n---\nNew body.\n',
                  );
              final failing = SkillLifecycleService(
                state: LifecycleStateService(io: _FailOnPromptStageIO(fs: fs)),
              );
              await expectLater(
                failing.update(
                  LifecycleIdInput(id: record.installationId, options: options),
                ),
                throwsA(isA<MambaException>()),
              );
              expect(fs.file(skillPath).readAsStringSync(), oldSkill);
              expect(
                fs.file(promptPath('fail-update-source')).readAsStringSync(),
                oldPrompt,
              );
            },
          );

          test('an interrupted remove finishes through recovery', () async {
            final source = manualSkill('recover-remove-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            LifecycleContext resolved({bool approved = true}) =>
                LifecycleContext.resolve(
                  LifecycleOptions(
                    processWorkingDirectory: project.path,
                    scope: LifecycleScope.project,
                    cwd: project.path,
                    projectRoot: project.path,
                    home: home.path,
                    stateDir: fs.path.join(sandbox.path, 'state'),
                    approved: approved,
                  ),
                  fileSystem: fs,
                );
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final record = lifecycle.state.records(resolved()).single;
            final failing = SkillLifecycleService(
              state: LifecycleStateService(
                io: _FailOnQuarantineDeleteIO(fs: fs),
              ),
            );
            await expectLater(
              failing.state.remove(
                resource: failing,
                context: resolved(),
                installationId: record.installationId,
              ),
              throwsA(isA<MambaException>()),
            );
            expect(
              fs.file(promptPath('recover-remove-source')).existsSync(),
              isFalse,
            );
            final transaction = fs
                .directory(
                  fs.path.join(project.path, '.agent-resource', 'transactions'),
                )
                .listSync()
                .whereType<File>()
                .singleWhere(
                  (file) =>
                      (jsonDecode(file.readAsStringSync())
                          as Map)['operation'] ==
                      'remove',
                );
            final transactionId = fs.path.basenameWithoutExtension(
              transaction.path,
            );
            final recovered = await lifecycle.state.recover(
              resource: lifecycle,
              context: resolved(),
              transactionId: transactionId,
              action: 'complete',
            );
            expect(recovered.outcome, 'recovered');
            expect(
              fs.file(promptPath('recover-remove-source')).existsSync(),
              isFalse,
            );
            final promptQuarantine = fs.directory(
              fs.path.join(
                project.path,
                '.pi',
                '.agent-resource',
                'quarantine',
                transactionId,
              ),
            );
            expect(
              promptQuarantine.existsSync()
                  ? promptQuarantine.listSync().isEmpty
                  : true,
              isTrue,
            );
          });

          test('restore after remove brings back the template', () async {
            final source = manualSkill('restore-template-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            LifecycleContext resolved({bool approved = true}) =>
                LifecycleContext.resolve(
                  LifecycleOptions(
                    processWorkingDirectory: project.path,
                    scope: LifecycleScope.project,
                    cwd: project.path,
                    projectRoot: project.path,
                    home: home.path,
                    stateDir: fs.path.join(sandbox.path, 'state'),
                    approved: approved,
                  ),
                  fileSystem: fs,
                );
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final record = lifecycle.state.records(resolved()).single;
            final removed = await lifecycle.state.remove(
              resource: lifecycle,
              context: resolved(),
              installationId: record.installationId,
            );
            expect(
              fs.file(promptPath('restore-template-source')).existsSync(),
              isFalse,
            );
            final restored = await lifecycle.state.restore(
              resource: lifecycle,
              context: resolved(),
              backupId: removed.data['backupId']! as String,
            );
            expect(restored.outcome, 'restored');
            expect(
              fs.file(promptPath('restore-template-source')).readAsStringSync(),
              endsWith('Body.\n'),
            );
            final live = lifecycle.state.records(resolved()).single;
            expect(live.lifecycle, 'live');
            expect(live.derivedPrompts, hasLength(1));
          });

          test('a locally edited template refuses removal', () async {
            final source = manualSkill('edit-refuse-source');
            final install = await executor().fake().execute([
              'skill',
              'install',
              source.path,
              ...context(),
              '--source-kind',
              'resource',
              '--target',
              'claude',
              '--method',
              'copy',
              '--prompt-target',
              'pi',
              '--yes',
            ]);
            expect(install, isA<MambaSuccessResult>());
            LifecycleContext resolved({bool approved = true}) =>
                LifecycleContext.resolve(
                  LifecycleOptions(
                    processWorkingDirectory: project.path,
                    scope: LifecycleScope.project,
                    cwd: project.path,
                    projectRoot: project.path,
                    home: home.path,
                    stateDir: fs.path.join(sandbox.path, 'state'),
                    approved: approved,
                  ),
                  fileSystem: fs,
                );
            final lifecycle = SkillLifecycleService(fileSystem: fs);
            final record = lifecycle.state.records(resolved()).single;
            fs
                .file(promptPath('edit-refuse-source'))
                .writeAsStringSync('Local edit.\n');
            await expectLater(
              lifecycle.state.remove(
                resource: lifecycle,
                context: resolved(),
                installationId: record.installationId,
              ),
              throwsA(isA<MambaException>()),
            );
            expect(record.location, isNotEmpty);
            expect(fs.directory(record.location).existsSync(), isTrue);
            expect(
              fs.file(promptPath('edit-refuse-source')).readAsStringSync(),
              'Local edit.\n',
            );
          });
        });
      });
    });
  });
}

final class _FailOnQuarantineDeleteIO extends LifecycleIO {
  _FailOnQuarantineDeleteIO({required super.fs});

  @override
  void before(String operation, String path) {
    if (operation == 'delete' && path.contains('quarantine')) {
      throw const FileSystemException('Injected cleanup failure');
    }
  }
}

final class _FailOnPromptStageIO extends LifecycleIO {
  _FailOnPromptStageIO({required super.fs});

  @override
  void before(String operation, String path) {
    if (operation == 'rename' &&
        path.contains('staging') &&
        path.endsWith('fail-update-source.md')) {
      throw const FileSystemException('Injected publish failure');
    }
  }
}
