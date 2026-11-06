import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/pack/github_release_resolver.dart';
import 'package:agent_resource/src/pack/pack_configuration.dart';
import 'package:agent_resource/src/pack/pack_models.dart';
import 'package:agent_resource/src/pack/release_policy.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('PackLifecycleService', () {
    late fslib.FileSystem fs;
    late fslib.Directory sandbox;
    late fslib.Directory project;
    late fslib.Directory home;
    late fslib.Directory source;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      sandbox = fs.directory('/sandbox')..createSync();
      project = fs.directory(fs.path.join(sandbox.path, 'project'))
        ..createSync();
      home = fs.directory(fs.path.join(sandbox.path, 'home'))..createSync();
      source = fs.directory(fs.path.join(sandbox.path, 'source'))..createSync();
      fs
          .file(fs.path.join(source.path, 'agent-resources.toml'))
          .writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/reviewer"
[[catalog.agents]]
path = "agents/reviewer.md"
profile = "claude"
''');
      final skill = fs.directory(
        fs.path.join(source.path, 'skills', 'reviewer'),
      )..createSync(recursive: true);
      fs.file(fs.path.join(skill.path, 'SKILL.md')).writeAsStringSync('''---
name: reviewer
description: Reviews code.
---
# Reviewer
''');
      fs.file(fs.path.join(source.path, 'agents', 'reviewer.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''---
name: reviewer
description: Reviews code.
---
Review changes.
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

    PackLifecycleRequest request(
      PackOperation operation,
      PackResourceType type, {
      List<String> only = const [],
      bool dryRun = false,
      List<String> allowFolder = const [],
      List<String> keepLocal = const [],
      List<String> replaceLocal = const [],
      List<String> approveRemoval = const [],
      String? to,
      String? snapshot,
      String? method,
      String? target,
      bool localEdits = false,
      bool yes = true,
      bool interactive = false,
      bool noSave = false,
      bool useDefaultTarget = true,
      bool skipNew = false,
      bool savePolicy = false,
      List<PackResourceType>? resourceTypes,
    }) {
      final selectedTypes = resourceTypes ?? [type];
      return PackLifecycleRequest(
        operation: operation,
        resourceType: type,
        resourceTypes: resourceTypes ?? const [],
        pack: 'local/demo',
        processWorkingDirectory: sandbox.path,
        environment: {
          'HOME': home.path,
          'USERPROFILE': home.path,
          'APPDATA': fs.path.join(home.path, 'AppData', 'Roaming'),
          'LOCALAPPDATA': fs.path.join(home.path, 'AppData', 'Local'),
        },
        scope: LifecycleScope.project,
        cwd: project.path,
        projectRoot: project.path,
        home: home.path,
        only: only,
        method:
            !selectedTypes.contains(PackResourceType.agent) &&
                type == PackResourceType.skill
            ? method ?? 'copy'
            : null,
        target:
            !selectedTypes.contains(PackResourceType.agent) &&
                type == PackResourceType.skill &&
                useDefaultTarget
            ? target ?? 'codex'
            : target,
        allowFolder: allowFolder,
        keepLocal: keepLocal,
        replaceLocal: replaceLocal,
        approveRemoval: approveRemoval,
        to: to,
        snapshot: snapshot,
        localEdits: localEdits,
        noSave: noSave,
        skipNew: skipNew,
        savePolicy: savePolicy,
        dryRun: dryRun,
        yes: yes,
        interactive: interactive,
      );
    }

    test(
      'validates consumer configuration without reading the source',
      () async {
        final result = await PackLifecycleService(fileSystem: fs).execute(
          PackLifecycleRequest(
            operation: PackOperation.configValidate,
            resourceType: PackResourceType.skill,
            processWorkingDirectory: sandbox.path,
            environment: {
              'HOME': home.path,
              'APPDATA': fs.path.join(home.path, 'AppData', 'Roaming'),
            },
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
          ),
        );

        expect(result.outcome, 'valid');
        expect(result.context['resolved'], isFalse);
        expect(
          fs
              .directory(fs.path.join(project.path, '.agent-resource'))
              .existsSync(),
          isFalse,
        );
      },
    );

    test('installs a native Skill and Agent with source evidence', () async {
      final service = PackLifecycleService(fileSystem: fs);
      final skills = await service.execute(
        request(PackOperation.install, PackResourceType.skill),
      );
      final agents = await service.execute(
        request(PackOperation.install, PackResourceType.agent),
      );

      expect(skills.resources.single.disposition.wireName, 'installed');
      expect(agents.resources.single.disposition.wireName, 'installed');
      expect(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agents',
                'skills',
                'reviewer',
                'SKILL.md',
              ),
            )
            .existsSync(),
        isTrue,
      );
      expect(
        fs
            .file(
              fs.path.join(project.path, '.claude', 'agents', 'reviewer.md'),
            )
            .existsSync(),
        isTrue,
      );
      final lock = jsonDecode(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agent-resource',
                'installations.json',
              ),
            )
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final installations = lock['installations']! as List<Object?>;
      expect(installations, hasLength(2));
      for (final value in installations) {
        final origin =
            (value! as Map<String, Object?>)['origin']! as Map<String, Object?>;
        expect(origin['packKey'], 'local/demo');
      }
    });

    test('mixed interactive approval publishes both types', () async {
      final confirmations = <String>[];
      final service = PackLifecycleService.withDependencies(
        fileSystem: fs,
        prompts: PackPrompts(
          confirmation: (label) async {
            confirmations.add(label);
            return true;
          },
        ),
      );

      final result = await service.execute(
        request(
          PackOperation.install,
          PackResourceType.skill,
          resourceTypes: PackResourceType.values,
          yes: false,
          interactive: true,
        ),
      );

      expect(result.operation, 'pack.install');
      expect(result.resources, hasLength(2));
      expect(confirmations, hasLength(1));
      expect(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agents',
                'skills',
                'reviewer',
                'SKILL.md',
              ),
            )
            .existsSync(),
        isTrue,
      );
      expect(
        fs
            .file(
              fs.path.join(project.path, '.claude', 'agents', 'reviewer.md'),
            )
            .existsSync(),
        isTrue,
      );
    });

    test('mixed interactive cancellation publishes no type or state', () async {
      final service = PackLifecycleService.withDependencies(
        fileSystem: fs,
        prompts: const PackPrompts(),
      );

      await expectLater(
        service.execute(
          request(
            PackOperation.install,
            PackResourceType.skill,
            resourceTypes: PackResourceType.values,
            yes: false,
            interactive: true,
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.exitCode,
            'exit code',
            PackProcessStatus.cancelled.code,
          ),
        ),
      );
      expect(
        fs.directory(fs.path.join(project.path, '.agents')).existsSync(),
        isFalse,
      );
      expect(
        fs.directory(fs.path.join(project.path, '.claude')).existsSync(),
        isFalse,
      );
      expect(
        fs
            .directory(fs.path.join(project.path, '.agent-resource'))
            .existsSync(),
        isFalse,
      );
    });

    test('mixed interactive prompt failure releases every review', () async {
      final service = PackLifecycleService.withDependencies(
        fileSystem: fs,
        prompts: PackPrompts(
          confirmation: (label) async =>
              throw StateError('confirmation unavailable'),
        ),
      );

      await expectLater(
        service.execute(
          request(
            PackOperation.install,
            PackResourceType.skill,
            resourceTypes: PackResourceType.values,
            yes: false,
            interactive: true,
          ),
        ),
        throwsStateError,
      );
      expect(
        fs.directory(fs.path.join(project.path, '.agents')).existsSync(),
        isFalse,
      );
      expect(
        fs.directory(fs.path.join(project.path, '.claude')).existsSync(),
        isFalse,
      );
      expect(
        fs
            .directory(fs.path.join(project.path, '.agent-resource'))
            .existsSync(),
        isFalse,
      );
    });

    test('typed requests preserve inapplicable save-policy warnings', () async {
      final result = await PackLifecycleService(fileSystem: fs).execute(
        request(
          PackOperation.install,
          PackResourceType.skill,
          resourceTypes: const [PackResourceType.skill],
          savePolicy: true,
        ),
      );

      expect(
        result.warnings.map((warning) => warning.message),
        contains(contains('--save-policy applies to update')),
      );
    });

    test(
      'ordinary install replays exact lock without reacquiring source',
      () async {
        final service = PackLifecycleService(fileSystem: fs);
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        source.deleteSync(recursive: true);

        final replay = await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );

        expect(replay.outcome, 'no-op');
        expect(replay.resources.single.disposition.wireName, 'unchanged');
        expect(replay.source['exactLockReplay'], isTrue);
      },
    );

    test(
      'no-save suppresses selection persistence but not operation evidence',
      () async {
        final result = await PackLifecycleService(fileSystem: fs).execute(
          request(PackOperation.install, PackResourceType.skill, noSave: true),
        );
        expect(result.resources.single.disposition.wireName, 'installed');
        final lock = jsonDecode(
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.agent-resource',
                  'installations.json',
                ),
              )
              .readAsStringSync(),
        ) as Map<String, Object?>;
        expect(lock['selections'], isEmpty);
        expect(lock['operations'], isNotEmpty);
      },
    );

    test('rejects unknown native names before any managed write', () async {
      expect(
        () => PackLifecycleService(fileSystem: fs).execute(
          request(
            PackOperation.install,
            PackResourceType.skill,
            only: const ['missing'],
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('missing'),
          ),
        ),
      );
      expect(
        fs
            .directory(fs.path.join(project.path, '.agent-resource'))
            .existsSync(),
        isFalse,
      );
      expect(
        fs.directory(fs.path.join(project.path, '.agents')).existsSync(),
        isFalse,
      );
    });

    test('dry run publishes neither resources nor lock state', () async {
      final result = await PackLifecycleService(fileSystem: fs).execute(
        request(PackOperation.install, PackResourceType.skill, dryRun: true),
      );

      expect(result.outcome, 'preview');
      expect(result.dryRun, isTrue);
      expect(result.plan, isNotNull);
      expect(result.plan!.planId, startsWith('plan_v1_'));
      expect(result.plan!.source['pack'], 'local/demo');
      expect(result.plan!.resources.single.action, 'install');
      expect(
        result.plan!.resources.single.changedPaths.map((path) => path.path),
        contains('SKILL.md'),
      );
      expect(
        result.resources.single.changedPaths.map((path) => path.path),
        contains('SKILL.md'),
      );
      expect(result.resources.single.changedPaths.single.change, 'added');
      expect(
        fs
            .directory(fs.path.join(project.path, '.agent-resource'))
            .existsSync(),
        isFalse,
      );
      expect(
        fs.directory(fs.path.join(project.path, '.agents')).existsSync(),
        isFalse,
      );
    });

    test('blocked dry-run fails with a review plan and no writes', () async {
      fs
          .directory(fs.path.join(source.path, 'skills', 'reviewer', 'rules'))
          .createSync();
      final before = fs
          .directory(project.path)
          .listSync(recursive: true)
          .length;

      expect(
        () => PackLifecycleService(fileSystem: fs).execute(
          request(PackOperation.install, PackResourceType.skill, dryRun: true),
        ),
        throwsA(
          isA<MambaException>()
              .having(
                (error) => error.message,
                'message',
                allOf(
                  contains('Dry-run is blocked'),
                  contains('review plan plan_v1_'),
                  contains('blocker:'),
                  contains('rules'),
                ),
              )
              .having(
                (error) => error.exitCode,
                'exitCode',
                PackProcessStatus.invalidInput.code,
              ),
        ),
      );
      expect(
        fs.directory(project.path).listSync(recursive: true).length,
        before,
      );
      expect(
        fs
            .directory(fs.path.join(project.path, '.agent-resource'))
            .existsSync(),
        isFalse,
      );
    });

    test('requires bounded approval for an extra Skill root folder', () async {
      fs
          .directory(fs.path.join(source.path, 'skills', 'reviewer', 'rules'))
          .createSync();

      expect(
        () => PackLifecycleService(fileSystem: fs)
            .execute(request(PackOperation.install, PackResourceType.skill)),
        throwsA(isA<MambaException>()),
      );
      expect(
        fs
            .directory(fs.path.join(project.path, '.agent-resource'))
            .existsSync(),
        isFalse,
      );

      final result = await PackLifecycleService(fileSystem: fs).execute(
        request(
          PackOperation.install,
          PackResourceType.skill,
          allowFolder: const ['reviewer:rules'],
        ),
      );
      expect(result.resources.single.disposition.wireName, 'installed');
      expect(
        fs
            .directory(
              fs.path.join(
                project.path,
                '.agents',
                'skills',
                'reviewer',
                'rules',
              ),
            )
            .existsSync(),
        isTrue,
      );

      final upstream = fs.file(
        fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
      );
      upstream.writeAsStringSync('${upstream.readAsStringSync()}\nSecond.\n');
      final lockFile = fs.file(
        fs.path.join(project.path, '.agent-resource', 'installations.json'),
      );
      final before =
          jsonDecode(lockFile.readAsStringSync()) as Map<String, Object?>;
      for (final value in before['installations']! as List<Object?>) {
        final origin =
            (value! as Map<String, Object?>)['origin']! as Map<String, Object?>;
        origin.remove('approvedExtraFolders');
      }
      lockFile.writeAsStringSync(jsonEncode(before));
      final updated = await PackLifecycleService(fileSystem: fs)
          .execute(request(PackOperation.update, PackResourceType.skill));
      expect(updated.resources.single.disposition.wireName, 'updated');
      final lock =
          jsonDecode(lockFile.readAsStringSync()) as Map<String, Object?>;
      expect(lock['approvals'], isNotEmpty);
      expect(lock['selections'], isNotEmpty);
      expect(lock['operations'], isNotEmpty);
    });

    test('interactive install prompts for a missing Skill target', () async {
      final config = fs.file(
        fs.path.join(project.path, 'agent-resources.toml'),
      );
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst('targets = ["codex"]\n', ''),
      );
      final prompts = <String>[];
      final result =
          await PackLifecycleService.withDependencies(
            fileSystem: fs,
            prompts: PackPrompts(
              confirmation: (label) async {
                prompts.add(label);
                return true;
              },
              choice: (label, choices) async {
                prompts.add(label);
                return 'claude';
              },
            ),
          ).execute(
            request(
              PackOperation.install,
              PackResourceType.skill,
              yes: false,
              interactive: true,
              useDefaultTarget: false,
            ),
          );

      expect(result.resources.single.disposition.wireName, 'installed');
      expect(prompts, contains(contains('Skill target')));
      expect(
        fs
            .file(
              fs.path.join(
                project.path,
                '.claude',
                'skills',
                'reviewer',
                'SKILL.md',
              ),
            )
            .existsSync(),
        isTrue,
      );
    });

    test(
      'configured extra folders drive the interactive review prompt',
      () async {
        fs
            .directory(fs.path.join(source.path, 'skills', 'reviewer', 'rules'))
            .createSync();
        final config = fs.file(
          fs.path.join(project.path, 'agent-resources.toml'),
        );
        config.writeAsStringSync('''
${config.readAsStringSync()}
[packs."local/demo".resources.skills]
[[packs."local/demo".resources.skills.overrides]]
name = "reviewer"
extra_folders = ["rules"]
''');
        final prompts = <String>[];
        final result =
            await PackLifecycleService.withDependencies(
              fileSystem: fs,
              prompts: PackPrompts(
                confirmation: (label) async {
                  prompts.add(label);
                  return true;
                },
              ),
            ).execute(
              request(
                PackOperation.install,
                PackResourceType.skill,
                yes: false,
                interactive: true,
              ),
            );

        expect(prompts, contains(contains('requests extra root folder rules')));
        expect(result.resources.single.disposition.wireName, 'installed');
        final lock = jsonDecode(
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.agent-resource',
                  'installations.json',
                ),
              )
              .readAsStringSync(),
        ) as Map<String, Object?>;
        expect(
          (lock['approvals']! as List<Object?>)
              .map((value) => value! as Map<String, Object?>)
              .where((value) => value['folder'] == 'rules'),
          isNotEmpty,
        );
      },
    );

    test(
      'ordinary install replays the lock instead of advancing changed source',
      () async {
        final service = PackLifecycleService(fileSystem: fs);
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final marker = fs.file(
          fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        marker.writeAsStringSync(
          '${marker.readAsStringSync()}\nUpstream edit.\n',
        );

        final replay = await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );

        expect(replay.outcome, 'no-op');
        expect(replay.resources.single.disposition.wireName, 'unchanged');
        final live = fs.file(
          fs.path.join(
            project.path,
            '.agents',
            'skills',
            'reviewer',
            'SKILL.md',
          ),
        );
        expect(live.readAsStringSync(), isNot(contains('Upstream edit.')));

        final updated = await service.execute(
          request(PackOperation.update, PackResourceType.skill),
        );
        expect(updated.resources.single.disposition.wireName, 'updated');
        expect(live.readAsStringSync(), contains('Upstream edit.'));
      },
    );

    test('target selects one same-name Skill installation', () async {
      final config = fs.file(
        fs.path.join(project.path, 'agent-resources.toml'),
      );
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          'targets = ["codex"]',
          'targets = ["claude", "codex"]',
        ),
      );
      final service = PackLifecycleService(fileSystem: fs);
      await service.execute(
        request(
          PackOperation.install,
          PackResourceType.skill,
          useDefaultTarget: false,
        ),
      );
      final upstream = fs.file(
        fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
      );
      upstream.writeAsStringSync('${upstream.readAsStringSync()}\nUpdate.\n');

      final result = await service.execute(
        request(PackOperation.update, PackResourceType.skill, target: 'codex'),
      );

      expect(result.resources.single.disposition.wireName, 'updated');
      expect(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agents',
                'skills',
                'reviewer',
                'SKILL.md',
              ),
            )
            .readAsStringSync(),
        contains('Update.'),
      );
      expect(
        fs
            .file(
              fs.path.join(
                project.path,
                '.claude',
                'skills',
                'reviewer',
                'SKILL.md',
              ),
            )
            .readAsStringSync(),
        isNot(contains('Update.')),
      );

      final rolledBack = await service.execute(
        request(
          PackOperation.rollback,
          PackResourceType.skill,
          only: const ['reviewer'],
          snapshot: result.resources.single.previousSnapshot,
          target: 'codex',
        ),
      );
      expect(rolledBack.resources.single.disposition.wireName, 'rolledBack');
      expect(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agents',
                'skills',
                'reviewer',
                'SKILL.md',
              ),
            )
            .readAsStringSync(),
        isNot(contains('Update.')),
      );
    });

    test(
      'update requires an explicit whole-resource local-edit choice',
      () async {
        final service = PackLifecycleService(fileSystem: fs);
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final upstream = fs.file(
          fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        upstream.writeAsStringSync(
          '${upstream.readAsStringSync()}\nUpstream edit.\n',
        );
        final live = fs.file(
          fs.path.join(
            project.path,
            '.agents',
            'skills',
            'reviewer',
            'SKILL.md',
          ),
        );
        live.writeAsStringSync('${live.readAsStringSync()}\nLocal edit.\n');

        expect(
          () => service.execute(
            request(PackOperation.update, PackResourceType.skill),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('--keep-local'),
            ),
          ),
        );
        expect(live.readAsStringSync(), contains('Local edit.'));

        final kept = await service.execute(
          request(
            PackOperation.update,
            PackResourceType.skill,
            keepLocal: const ['reviewer'],
          ),
        );
        expect(kept.resources.single.disposition.wireName, 'keptLocal');
        expect(live.readAsStringSync(), contains('Local edit.'));
        expect(live.readAsStringSync(), isNot(contains('Upstream edit.')));
      },
    );

    test(
      'replace-local preserves edited bytes before publishing upstream',
      () async {
        final service = PackLifecycleService(fileSystem: fs);
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final upstream = fs.file(
          fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        upstream.writeAsStringSync(
          '${upstream.readAsStringSync()}\nUpstream edit.\n',
        );
        final live = fs.file(
          fs.path.join(
            project.path,
            '.agents',
            'skills',
            'reviewer',
            'SKILL.md',
          ),
        );
        live.writeAsStringSync('${live.readAsStringSync()}\nLocal edit.\n');

        final result = await service.execute(
          request(
            PackOperation.update,
            PackResourceType.skill,
            replaceLocal: const ['reviewer'],
          ),
        );

        expect(result.resources.single.disposition.wireName, 'updated');
        expect(live.readAsStringSync(), contains('Upstream edit.'));
        expect(live.readAsStringSync(), isNot(contains('Local edit.')));
        final lock = jsonDecode(
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.agent-resource',
                  'installations.json',
                ),
              )
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final installation =
            (lock['installations']! as List<Object?>).single!
                as Map<String, Object?>;
        final backupIds = installation['backupIds']! as List<Object?>;
        expect(backupIds, hasLength(1));
        final backup = fs.file(
          fs.path.join(
            project.path,
            '.agent-resource',
            'backups',
            backupIds.single! as String,
            'artifact',
            'SKILL.md',
          ),
        );
        expect(backup.readAsStringSync(), contains('Local edit.'));
      },
    );

    test('canonical replace-local preserves edits before updating', () async {
      final service = PackLifecycleService(fileSystem: fs);
      await service.execute(
        request(
          PackOperation.install,
          PackResourceType.skill,
          method: 'canonical',
        ),
      );
      final upstream = fs.file(
        fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
      );
      upstream.writeAsStringSync('${upstream.readAsStringSync()}\nUpstream.\n');
      final live = fs.file(
        fs.path.join(project.path, '.agents', 'skills', 'reviewer', 'SKILL.md'),
      );
      live.writeAsStringSync('${live.readAsStringSync()}\nLocal edit.\n');

      final result = await service.execute(
        request(
          PackOperation.update,
          PackResourceType.skill,
          replaceLocal: const ['reviewer'],
        ),
      );

      expect(result.resources.single.disposition.wireName, 'updated');
      expect(live.readAsStringSync(), contains('Upstream.'));
      expect(live.readAsStringSync(), isNot(contains('Local edit.')));
      final lock = jsonDecode(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agent-resource',
                'installations.json',
              ),
            )
            .readAsStringSync(),
      ) as Map<String, Object?>;
      expect(
        (lock['snapshots']! as List<Object?>).any(
          (value) =>
              (value! as Map<String, Object?>)['retentionClass'] == 'localEdit',
        ),
        isTrue,
      );

      live.writeAsStringSync('${live.readAsStringSync()}\nRollback edit.\n');
      final rolledBack = await service.execute(
        request(
          PackOperation.rollback,
          PackResourceType.skill,
          only: const ['reviewer'],
          snapshot: result.resources.single.previousSnapshot,
          replaceLocal: const ['reviewer'],
        ),
      );
      expect(rolledBack.resources.single.disposition.wireName, 'rolledBack');
      expect(live.readAsStringSync(), isNot(contains('Upstream.')));
      expect(live.readAsStringSync(), isNot(contains('Rollback edit.')));
    });

    test(
      'changed source configuration requires reviewed source change',
      () async {
        final service = PackLifecycleService(fileSystem: fs);
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final other = fs.directory(fs.path.join(sandbox.path, 'other'))
          ..createSync();
        for (final entity in source.listSync(recursive: true)) {
          final relative = fs.path.relative(entity.path, from: source.path);
          final destination = fs.path.join(other.path, relative);
          if (entity is fslib.Directory) {
            fs.directory(destination).createSync(recursive: true);
          } else if (entity is fslib.File) {
            fs.file(destination)
              ..createSync(recursive: true)
              ..writeAsBytesSync(entity.readAsBytesSync());
          }
        }
        final config = fs.file(
          fs.path.join(project.path, 'agent-resources.toml'),
        );
        config.writeAsStringSync(
          config.readAsStringSync().replaceFirst(
            'path = "../source"',
            'path = "../other"',
          ),
        );

        expect(
          () => service.execute(
            request(PackOperation.install, PackResourceType.skill),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('source change'),
            ),
          ),
        );
      },
    );

    test('mixed source change preserves an empty public only filter', () async {
      final service = PackLifecycleService(fileSystem: fs);
      await service.execute(
        request(
          PackOperation.install,
          PackResourceType.skill,
          resourceTypes: PackResourceType.values,
        ),
      );
      final other = fs.directory(fs.path.join(sandbox.path, 'other'))
        ..createSync();
      for (final entity in source.listSync(recursive: true)) {
        final relative = fs.path.relative(entity.path, from: source.path);
        final destination = fs.path.join(other.path, relative);
        if (entity is fslib.Directory) {
          fs.directory(destination).createSync(recursive: true);
        } else if (entity is fslib.File) {
          fs.file(destination)
            ..createSync(recursive: true)
            ..writeAsBytesSync(entity.readAsBytesSync());
        }
      }
      final config = fs.file(
        fs.path.join(project.path, 'agent-resources.toml'),
      );
      config.writeAsStringSync('''
${config.readAsStringSync()}
[packs."local/other".source]
kind = "local"
path = "../other"
[packs."local/other".update]
track = { kind = "local" }
''');

      final result = await service.execute(
        request(
          PackOperation.sourceChange,
          PackResourceType.skill,
          resourceTypes: PackResourceType.values,
          to: 'local/other',
          skipNew: true,
        ),
      );

      expect(result.operation, 'pack.source.change');
      expect(result.resources, hasLength(2));
      expect(
        result.resources.map((resource) => resource.type),
        containsAll(['skill', 'agent']),
      );
    });

    test('source associate binds a matching adopted installation', () async {
      final destination = fs.directory(
        fs.path.join(project.path, '.agents', 'skills', 'reviewer'),
      )..createSync(recursive: true);
      final adoptedSource = fs.path.join(source.path, 'skills', 'reviewer');
      for (final entity
          in fs.directory(adoptedSource).listSync(recursive: true)) {
        if (entity is! fslib.File) continue;
        final relative = fs.path.relative(entity.path, from: adoptedSource);
        fs.file(fs.path.join(destination.path, relative))
          ..createSync(recursive: true)
          ..writeAsBytesSync(entity.readAsBytesSync());
      }
      final options = LifecycleOptions(
        processWorkingDirectory: project.path,
        scope: LifecycleScope.project,
        projectRoot: project.path,
        home: home.path,
        approved: true,
      );
      await SkillLifecycleService(fileSystem: fs).adopt(
        SkillInstallInput(
          options: options,
          source: destination.path,
          destination: SkillDestination.shared,
        ),
      );

      final lockFile = fs.file(
        fs.path.join(project.path, '.agent-resource', 'installations.json'),
      );
      final beforePreview = lockFile.readAsBytesSync();
      final preview = await PackLifecycleService(fileSystem: fs).execute(
        request(
          PackOperation.sourceAssociate,
          PackResourceType.skill,
          only: const ['reviewer'],
          dryRun: true,
        ),
      );

      expect(preview.outcome, 'preview');
      expect(lockFile.readAsBytesSync(), beforePreview);

      final result = await PackLifecycleService(fileSystem: fs).execute(
        request(
          PackOperation.sourceAssociate,
          PackResourceType.skill,
          only: const ['reviewer'],
        ),
      );

      expect(result.resources.single.disposition.wireName, 'updated');
      final lock =
          jsonDecode(lockFile.readAsStringSync()) as Map<String, Object?>;
      final installation =
          (lock['installations']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(
        (installation['origin']! as Map<String, Object?>)['packKey'],
        'local/demo',
      );
    });

    test('recovery failure stops removals and preserves its status', () async {
      final writer = fs.directory(fs.path.join(source.path, 'skills', 'writer'))
        ..createSync(recursive: true);
      fs.file(fs.path.join(writer.path, 'SKILL.md')).writeAsStringSync('''---
name: writer
description: Writes docs.
---
# Writer
''');
      final catalog = fs.file(
        fs.path.join(source.path, 'agent-resources.toml'),
      );
      catalog.writeAsStringSync(
        '${catalog.readAsStringSync()}\n'
        '[[catalog.skills]]\npath = "skills/writer"\n',
      );
      await PackLifecycleService(fileSystem: fs)
          .execute(request(PackOperation.install, PackResourceType.skill));
      final upstream = fs.file(
        fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
      );
      upstream.writeAsStringSync('${upstream.readAsStringSync()}\nUpdate.\n');
      writer.deleteSync(recursive: true);
      catalog.writeAsStringSync(
        catalog.readAsStringSync().replaceFirst(
          '\n[[catalog.skills]]\npath = "skills/writer"\n',
          '',
        ),
      );
      final service = PackLifecycleService.withDependencies(
        fileSystem: fs,
        state: LifecycleStateService(io: _RecoveryRequiredIO()),
      );

      await expectLater(
        () => service.execute(
          request(
            PackOperation.update,
            PackResourceType.skill,
            approveRemoval: const ['writer'],
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.exitCode,
            'exitCode',
            PackProcessStatus.recoveryRequired.code,
          ),
        ),
      );
      expect(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agents',
                'skills',
                'writer',
                'SKILL.md',
              ),
            )
            .existsSync(),
        isTrue,
      );
    });

    test('rollback restores one stable Recorded snapshot ref', () async {
      final service = PackLifecycleService(fileSystem: fs);
      final installed = await service.execute(
        request(PackOperation.install, PackResourceType.skill),
      );
      final firstRef = installed.resources.single.snapshot!;
      final upstream = fs.file(
        fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
      );
      upstream.writeAsStringSync(
        '${upstream.readAsStringSync()}\nVersion two.\n',
      );
      final updated = await service.execute(
        request(PackOperation.update, PackResourceType.skill),
      );
      expect(updated.resources.single.snapshot, isNot(firstRef));

      final rolledBack = await service.execute(
        request(
          PackOperation.rollback,
          PackResourceType.skill,
          only: const ['reviewer'],
          snapshot: firstRef,
        ),
      );

      expect(rolledBack.resources.single.disposition.wireName, 'rolledBack');
      expect(rolledBack.resources.single.snapshot, firstRef);
      expect(rolledBack.plan!.resources.single.action, 'rollback');
      expect(
        rolledBack.plan!.resources.single.changedPaths.map((path) => path.path),
        contains('SKILL.md'),
      );
      expect(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agents',
                'skills',
                'reviewer',
                'SKILL.md',
              ),
            )
            .readAsStringSync(),
        isNot(contains('Version two.')),
      );
      final lock = jsonDecode(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agent-resource',
                'installations.json',
              ),
            )
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final snapshots = lock['snapshots']! as List<Object?>;
      expect(snapshots, hasLength(2));
      final current = snapshots
          .map((value) => value! as Map<String, Object?>)
          .singleWhere((snapshot) => snapshot['noncurrentAt'] == null);
      expect(current['ref'], firstRef);
    });

    test(
      'a removed resource can be reinstalled with a fresh identity',
      () async {
        final service = PackLifecycleService(fileSystem: fs);
        final installed = await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final firstLock = jsonDecode(
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.agent-resource',
                  'installations.json',
                ),
              )
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final original =
            ((firstLock['installations']! as List<Object?>).single!
                as Map<String, Object?>)['installationId'];
        await service.execute(
          request(
            PackOperation.remove,
            PackResourceType.skill,
            only: const ['reviewer'],
          ),
        );

        final reinstalled = await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );

        expect(reinstalled.resources.single.disposition.wireName, 'installed');
        final lock = jsonDecode(
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.agent-resource',
                  'installations.json',
                ),
              )
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final live = (lock['installations']! as List<Object?>)
            .map((value) => value! as Map<String, Object?>)
            .singleWhere((record) => record['lifecycle'] == 'live');
        expect(live['installationId'], isNot(original));
        expect(
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.agents',
                  'skills',
                  'reviewer',
                  'SKILL.md',
                ),
              )
              .existsSync(),
          isTrue,
        );
        expect(installed.resources.single.disposition.wireName, 'installed');
      },
    );

    test(
      'new resources stay unselected until --only requests inclusion',
      () async {
        final service = PackLifecycleService(fileSystem: fs);
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final second = fs.directory(
          fs.path.join(source.path, 'skills', 'writer'),
        )..createSync(recursive: true);
        fs.file(fs.path.join(second.path, 'SKILL.md')).writeAsStringSync('''---
name: writer
description: Writes docs.
---
# Writer
''');
        final catalog = fs.file(
          fs.path.join(source.path, 'agent-resources.toml'),
        );
        catalog.writeAsStringSync(
          '${catalog.readAsStringSync()}\n'
          '[[catalog.skills]]\npath = "skills/writer"\n',
        );

        final ordinary = await service.execute(
          request(PackOperation.update, PackResourceType.skill),
        );
        expect(
          ordinary.resources
              .singleWhere((result) => result.name == 'writer')
              .disposition
              .wireName,
          'observed',
        );
        expect(
          ordinary.warnings.map((warning) => warning.id),
          contains('new-resource-unselected'),
        );
        expect(
          fs
              .directory(
                fs.path.join(project.path, '.agents', 'skills', 'writer'),
              )
              .existsSync(),
          isFalse,
        );

        final selected = await service.execute(
          request(
            PackOperation.update,
            PackResourceType.skill,
            only: const ['writer'],
          ),
        );
        expect(selected.resources.single.disposition.wireName, 'installed');
        expect(
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.agents',
                  'skills',
                  'writer',
                  'SKILL.md',
                ),
              )
              .existsSync(),
          isTrue,
        );

        final next = await service.execute(
          request(PackOperation.update, PackResourceType.skill),
        );
        expect(
          next.resources
              .singleWhere((result) => result.name == 'writer')
              .disposition
              .wireName,
          'unchanged',
        );
      },
    );

    test('cancelling review does not persist a declined addition', () async {
      final service = PackLifecycleService.withDependencies(
        fileSystem: fs,
        prompts: PackPrompts(confirmation: (label) async => false),
      );
      await service.execute(
        request(PackOperation.install, PackResourceType.skill),
      );
      final second = fs.directory(fs.path.join(source.path, 'skills', 'writer'))
        ..createSync(recursive: true);
      fs.file(fs.path.join(second.path, 'SKILL.md')).writeAsStringSync('''---
name: writer
description: Writes docs.
---
# Writer
''');
      final catalog = fs.file(
        fs.path.join(source.path, 'agent-resources.toml'),
      );
      catalog.writeAsStringSync(
        '${catalog.readAsStringSync()}\n'
        '[[catalog.skills]]\npath = "skills/writer"\n',
      );
      final lockFile = fs.file(
        fs.path.join(project.path, '.agent-resource', 'installations.json'),
      );
      final beforeReview = lockFile.readAsBytesSync();

      await expectLater(
        () => service.execute(
          request(
            PackOperation.update,
            PackResourceType.skill,
            yes: false,
            interactive: true,
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.exitCode,
            'exitCode',
            PackProcessStatus.cancelled.code,
          ),
        ),
      );
      expect(lockFile.readAsBytesSync(), beforeReview);
    });

    test(
      'cleanup protects current and prunes expired history visibly',
      () async {
        final service = PackLifecycleService(fileSystem: fs);
        final installed = await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final firstRef = installed.resources.single.snapshot!;
        final upstream = fs.file(
          fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        upstream.writeAsStringSync('${upstream.readAsStringSync()}\nSecond.\n');
        await service.execute(
          request(PackOperation.update, PackResourceType.skill),
        );
        final lockFile = fs.file(
          fs.path.join(project.path, '.agent-resource', 'installations.json'),
        );
        final lock =
            jsonDecode(lockFile.readAsStringSync()) as Map<String, Object?>;
        final snapshots = lock['snapshots']! as List<Object?>;
        final oldSnapshot = snapshots
            .map((value) => value! as Map<String, Object?>)
            .singleWhere((snapshot) => snapshot['ref'] == firstRef);
        oldSnapshot['noncurrentAt'] = DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 100))
            .toIso8601String();
        lockFile.writeAsStringSync(jsonEncode(lock));

        final preview = await service.execute(
          request(PackOperation.cleanup, PackResourceType.skill, dryRun: true),
        );
        expect(preview.outcome, 'preview');
        expect(
          (preview.source['prunedSnapshotRefs']! as List<Object?>),
          contains(firstRef),
        );
        final artifact = fs.directory(
          fs.path.join(
            project.path,
            '.agent-resource',
            'snapshots',
            oldSnapshot['contentDigest']! as String,
            'artifact',
          ),
        );
        expect(artifact.existsSync(), isTrue);

        final cleaned = await service.execute(
          request(PackOperation.cleanup, PackResourceType.skill),
        );
        expect(cleaned.outcome, 'completed');
        expect(cleaned.plan!.cleanupRefs, contains(firstRef));
        expect(artifact.existsSync(), isFalse);
        final after =
            jsonDecode(lockFile.readAsStringSync()) as Map<String, Object?>;
        final pruned = (after['snapshots']! as List<Object?>)
            .map((value) => value! as Map<String, Object?>)
            .singleWhere((snapshot) => snapshot['ref'] == firstRef);
        expect(pruned['contentAvailable'], isFalse);

        final current = (after['snapshots']! as List<Object?>)
            .map((value) => value! as Map<String, Object?>)
            .singleWhere((snapshot) => snapshot['noncurrentAt'] == null);
        expect(current['ref'], isNot(firstRef));
      },
    );

    test('local-edit backups require explicit cleanup selection', () async {
      final service = PackLifecycleService(fileSystem: fs);
      await service.execute(
        request(PackOperation.install, PackResourceType.skill),
      );
      final upstream = fs.file(
        fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
      );
      upstream.writeAsStringSync('${upstream.readAsStringSync()}\nSecond.\n');
      final live = fs.file(
        fs.path.join(project.path, '.agents', 'skills', 'reviewer', 'SKILL.md'),
      );
      live.writeAsStringSync('${live.readAsStringSync()}\nLocal.\n');
      await service.execute(
        request(
          PackOperation.update,
          PackResourceType.skill,
          replaceLocal: const ['reviewer'],
        ),
      );
      final lockFile = fs.file(
        fs.path.join(project.path, '.agent-resource', 'installations.json'),
      );
      final lock =
          jsonDecode(lockFile.readAsStringSync()) as Map<String, Object?>;
      final edited = (lock['snapshots']! as List<Object?>)
          .map((value) => value! as Map<String, Object?>)
          .singleWhere((snapshot) => snapshot['retentionClass'] == 'localEdit');
      edited['noncurrentAt'] = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 1000))
          .toIso8601String();
      lockFile.writeAsStringSync(jsonEncode(lock));

      final ordinary = await service.execute(
        request(PackOperation.cleanup, PackResourceType.skill),
      );
      expect(ordinary.outcome, 'no-op');
      expect(ordinary.warnings, isEmpty);

      final explicit = await service.execute(
        request(
          PackOperation.cleanup,
          PackResourceType.skill,
          localEdits: true,
        ),
      );
      expect(explicit.outcome, 'completed');
      expect(explicit.warnings.single.id, 'local-edit-cleanup');
      expect(
        (explicit.source['prunedSnapshotRefs']! as List<Object?>),
        contains(edited['ref']),
      );
    });
  });

  group('PackLifecycleService host links', () {
    late Directory sandbox;
    late Directory project;
    late Directory home;
    late Directory source;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('pack-host-link-');
      project = Directory(p.join(sandbox.path, 'project'))..createSync();
      home = Directory(p.join(sandbox.path, 'home'))..createSync();
      source = Directory(p.join(sandbox.path, 'source'))..createSync();
      File(p.join(source.path, 'agent-resources.toml')).writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/reviewer"
''');
      File(p.join(source.path, 'skills', 'reviewer', 'SKILL.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''---
name: reviewer
description: Reviews code.
---
# Reviewer
''');
      File(p.join(project.path, 'agent-resources.toml')).writeAsStringSync('''
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

    PackLifecycleRequest request(
      PackOperation operation,
      PackResourceType type, {
      List<String> only = const [],
      String? snapshot,
      String? method,
      String? target,
      bool useDefaultTarget = true,
    }) => PackLifecycleRequest(
      operation: operation,
      resourceType: type,
      pack: 'local/demo',
      processWorkingDirectory: sandbox.path,
      environment: {
        'HOME': home.path,
        'USERPROFILE': home.path,
        'APPDATA': p.join(home.path, 'AppData', 'Roaming'),
        'LOCALAPPDATA': p.join(home.path, 'AppData', 'Local'),
      },
      scope: LifecycleScope.project,
      cwd: project.path,
      projectRoot: project.path,
      home: home.path,
      only: only,
      method: method ?? 'copy',
      target: useDefaultTarget ? target ?? 'codex' : target,
      snapshot: snapshot,
      yes: true,
    );

    test(
      'canonical rollback restores historical exposures and consumers',
      () async {
        final service = PackLifecycleService();
        final installed = await service.execute(
          request(
            PackOperation.install,
            PackResourceType.skill,
            method: 'canonical',
            target: 'claude',
          ),
        );
        final firstRef = installed.resources.single.snapshot!;
        final exposure = Link(
          p.join(project.path, '.claude', 'skills', 'reviewer'),
        );
        expect(exposure.existsSync(), isTrue);
        final lockFile = File(
          p.join(project.path, '.agent-resource', 'installations.json'),
        );
        final lock =
            jsonDecode(lockFile.readAsStringSync()) as Map<String, Object?>;
        final id =
            (lock['installations']! as List<Object?>)
                    .map((value) => value! as Map<String, Object?>)
                    .singleWhere(
                      (record) => record['artifactKind'] == 'skill-canonical',
                    )['installationId']!
                as String;
        await SkillLifecycleService().remove(
          LifecycleIdInput(
            options: LifecycleOptions(
              processWorkingDirectory: project.path,
              scope: LifecycleScope.project,
              projectRoot: project.path,
              home: home.path,
              approved: true,
            ),
            id: id,
          ),
          target: SkillHarness.claude,
        );
        expect(exposure.existsSync(), isFalse);

        final rolledBack = await service.execute(
          request(
            PackOperation.rollback,
            PackResourceType.skill,
            only: const ['reviewer'],
            snapshot: firstRef,
            useDefaultTarget: false,
          ),
        );

        expect(rolledBack.resources.single.disposition.wireName, 'rolledBack');
        expect(exposure.existsSync(), isTrue);
        expect(File(p.join(exposure.path, 'SKILL.md')).existsSync(), isTrue);
        final after =
            jsonDecode(lockFile.readAsStringSync()) as Map<String, Object?>;
        final canonical = (after['installations']! as List<Object?>)
            .map((value) => value! as Map<String, Object?>)
            .singleWhere(
              (record) => record['artifactKind'] == 'skill-canonical',
            );
        expect(canonical['knownConsumers'], contains('claude'));
      },
    );

    test('source-link rollback restores only the recorded link', () async {
      final service = PackLifecycleService();
      final installed = await service.execute(
        request(
          PackOperation.install,
          PackResourceType.skill,
          method: 'source-link',
        ),
      );
      final firstRef = installed.resources.single.snapshot!;
      final link = Link(p.join(project.path, '.agents', 'skills', 'reviewer'));
      final originalTarget = link.targetSync();
      final target = File(
        p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
      );
      target.writeAsStringSync(
        '${target.readAsStringSync()}\nEdited target.\n',
      );

      final rolledBack = await service.execute(
        request(
          PackOperation.rollback,
          PackResourceType.skill,
          method: 'source-link',
          only: const ['reviewer'],
          snapshot: firstRef,
        ),
      );

      expect(rolledBack.resources.single.disposition.wireName, 'rolledBack');
      expect(rolledBack.resources.single.linkOnly, isTrue);
      expect(link.targetSync(), originalTarget);
      expect(target.readAsStringSync(), contains('Edited target.'));
    });
  });

  group('PackLifecycleService releases (memory filesystem)', () {
    late fslib.FileSystem fs;
    late fslib.Directory sandbox;
    late fslib.Directory project;
    late fslib.Directory home;
    late fslib.Directory source;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      sandbox = fs.directory('/sandbox')..createSync();
      project = fs.directory(fs.path.join(sandbox.path, 'project'))
        ..createSync();
      home = fs.directory(fs.path.join(sandbox.path, 'home'))..createSync();
      source = fs.directory(fs.path.join(sandbox.path, 'source'))..createSync();
      fs
          .file(fs.path.join(source.path, 'agent-resources.toml'))
          .writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/reviewer"
''');
      final skill = fs.directory(
        fs.path.join(source.path, 'skills', 'reviewer'),
      )..createSync(recursive: true);
      fs.file(fs.path.join(skill.path, 'SKILL.md')).writeAsStringSync('''---
name: reviewer
description: Reviews code.
---
# Reviewer
''');
      fs
          .file(fs.path.join(project.path, 'agent-resources.toml'))
          .writeAsStringSync('''
schema_version = 1
[cli.install]
targets = ["codex"]
skill_method = "copy"
[packs."owner/demo".source]
kind = "github"
repository = "owner/demo"
[packs."owner/demo".update]
track = { kind = "release", artifact = "archive" }
''');
    });

    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    PackLifecycleRequest request({
      String pack = 'owner/demo',
      String? release,
      PackOperation operation = PackOperation.install,
      String? bump,
      bool includePrerelease = false,
      bool savePolicy = false,
      bool yes = true,
      bool interactive = false,
      bool noSave = false,
      List<PackResourceType> resourceTypes = const [],
    }) => PackLifecycleRequest(
      operation: operation,
      resourceType: PackResourceType.skill,
      resourceTypes: resourceTypes,
      pack: pack,
      processWorkingDirectory: project.path,
      environment: {
        'HOME': home.path,
        'USERPROFILE': home.path,
        'APPDATA': fs.path.join(home.path, 'AppData', 'Roaming'),
      },
      scope: LifecycleScope.project,
      cwd: project.path,
      projectRoot: project.path,
      home: home.path,
      release: release,
      bump: bump,
      includePrerelease: includePrerelease,
      savePolicy: savePolicy,
      noSave: noSave,
      yes: yes,
      interactive: interactive,
    );

    test('first release install requires an exact literal tag', () async {
      expect(
        () => PackLifecycleService.withDependencies(
          fileSystem: fs,
          acquisition: _LocalAcquisition(source.path, fileSystem: fs),
          releaseResolver: _FakeReleases(),
        ).execute(request()),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('exact literal tag'),
          ),
        ),
      );
    });

    test('records provider, release, and source evidence separately', () async {
      final result = await PackLifecycleService.withDependencies(
        fileSystem: fs,
        acquisition: _LocalAcquisition(source.path, fileSystem: fs),
        releaseResolver: _FakeReleases(),
      ).execute(request(release: 'v1.2.0'));

      expect(result.resources.single.disposition.wireName, 'installed');
      final lock = jsonDecode(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agent-resource',
                'installations.json',
              ),
            )
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final installation =
          (lock['installations']! as List<Object?>).single!
              as Map<String, Object?>;
      final origin = installation['origin']! as Map<String, Object?>;
      expect(origin['provider'], {'host': 'github.com', 'repositoryId': 42});
      expect(
        (origin['release']! as Map<String, Object?>)['literalTag'],
        'v1.2.0',
      );
      expect(
        (origin['release']! as Map<String, Object?>)['commit'],
        '0123456789012345678901234567890123456789',
      );
      expect((origin['source']! as Map<String, Object?>)['kind'], 'local');
    });

    test('records the verified enterprise provider host', () async {
      final config = fs.file(
        fs.path.join(project.path, 'agent-resources.toml'),
      );
      config.writeAsStringSync(
        config
            .readAsStringSync()
            .replaceAll(
              'packs."owner/demo"',
              'packs."github.example.test/owner/demo"',
            )
            .replaceFirst(
              'repository = "owner/demo"',
              'repository = "owner/demo"\nhost = "github.example.test"',
            ),
      );
      await PackLifecycleService.withDependencies(
        fileSystem: fs,
        acquisition: _LocalAcquisition(source.path, fileSystem: fs),
        releaseResolver: _FakeReleases(host: 'github.example.test'),
      ).execute(
        request(pack: 'github.example.test/owner/demo', release: 'v1.2.0'),
      );

      final lock = jsonDecode(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agent-resource',
                'installations.json',
              ),
            )
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final installation =
          (lock['installations']! as List<Object?>).single!
              as Map<String, Object?>;
      final origin = installation['origin']! as Map<String, Object?>;
      expect(origin['provider'], {
        'host': 'github.example.test',
        'repositoryId': 42,
      });
    });

    test('typed requests preserve save-policy conflicts', () async {
      await expectLater(
        PackLifecycleService.withDependencies(
          fileSystem: fs,
          acquisition: _LocalAcquisition(source.path, fileSystem: fs),
          releaseResolver: _FakeReleases(),
        ).execute(
          request(
            operation: PackOperation.update,
            bump: 'minor',
            savePolicy: true,
            noSave: true,
            resourceTypes: const [PackResourceType.skill],
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('--no-save and --save-policy'),
          ),
        ),
      );
    });

    test('release update requires an explicit or saved bump', () async {
      final service = PackLifecycleService.withDependencies(
        fileSystem: fs,
        acquisition: _LocalAcquisition(source.path, fileSystem: fs),
        releaseResolver: _FakeReleases(),
      );
      await service.execute(request(release: 'v1.2.0'));

      expect(
        () => service.execute(request(operation: PackOperation.update)),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('--bump'),
          ),
        ),
      );
    });

    test('release and bump cannot be combined', () async {
      final service = PackLifecycleService.withDependencies(
        fileSystem: fs,
        acquisition: _LocalAcquisition(source.path, fileSystem: fs),
        releaseResolver: _FakeReleases(),
      );
      await service.execute(request(release: 'v1.2.0'));

      expect(
        () => service.execute(
          request(
            operation: PackOperation.update,
            release: 'v1.3.0',
            bump: 'minor',
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('--release and --bump'),
          ),
        ),
      );
    });

    test('a new release does not require same-attachment acceptance', () async {
      final config = fs.file(
        fs.path.join(project.path, 'agent-resources.toml'),
      );
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          'artifact = "archive"',
          'artifact = "attachment", attachment = "bundle.zip"',
        ),
      );
      final releases = _AttachmentReleases('old-digest', advanceOnBump: true);
      final service = PackLifecycleService.withDependencies(
        fileSystem: fs,
        acquisition: _LocalAcquisition(source.path, fileSystem: fs),
        releaseResolver: releases,
      );
      await service.execute(request(release: 'v1.2.0'));

      releases.digest = 'new-digest';
      final updated = await service.execute(
        request(operation: PackOperation.update, bump: 'minor'),
      );

      expect(updated.outcome, 'completed');
      expect(updated.resources.single.disposition.wireName, 'updated');
      final lock = jsonDecode(
        fs
            .file(
              fs.path.join(
                project.path,
                '.agent-resource',
                'installations.json',
              ),
            )
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final installation =
          (lock['installations']! as List<Object?>).single!
              as Map<String, Object?>;
      final origin = installation['origin']! as Map<String, Object?>;
      expect((origin['release']! as Map<String, Object?>)['id'], 101);
      expect(
        (origin['source']! as Map<String, Object?>)['requestedLocator'],
        contains('/v1.3.0/'),
      );
    });

    test(
      'rejects attachment bytes that disagree with provider evidence',
      () async {
        final config = fs.file(
          fs.path.join(project.path, 'agent-resources.toml'),
        );
        config.writeAsStringSync(
          config.readAsStringSync().replaceFirst(
            'artifact = "archive"',
            'artifact = "attachment", attachment = "bundle.zip"',
          ),
        );
        final service = PackLifecycleService.withDependencies(
          fileSystem: fs,
          acquisition: _LocalAcquisition(
            source.path,
            fileSystem: fs,
            downloadDigest: 'actual',
          ),
          releaseResolver: _AttachmentReleases('sha256:expected'),
        );

        await expectLater(
          () => service.execute(request(release: 'v1.2.0')),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('digest'),
            ),
          ),
        );
        expect(
          fs
              .directory(fs.path.join(project.path, '.agent-resource'))
              .existsSync(),
          isFalse,
        );
      },
    );

    test('changed attachment bytes require injected live acceptance', () async {
      final config = fs.file(
        fs.path.join(project.path, 'agent-resources.toml'),
      );
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          'artifact = "archive"',
          'artifact = "attachment", attachment = "bundle.zip"',
        ),
      );
      final releases = _AttachmentReleases('old-digest');
      final prompts = <String>[];
      final service = PackLifecycleService.withDependencies(
        fileSystem: fs,
        acquisition: _LocalAcquisition(source.path, fileSystem: fs),
        releaseResolver: releases,
        prompts: PackPrompts(
          confirmation: (label) async {
            prompts.add(label);
            return true;
          },
        ),
      );
      await service.execute(request(release: 'v1.2.0'));

      releases.digest = 'new-digest';
      final updated = await service.execute(
        request(
          operation: PackOperation.update,
          bump: 'minor',
          yes: false,
          interactive: true,
        ),
      );

      expect(prompts, contains(contains('changed or unverified bytes')));
      expect(updated.outcome, 'completed');
      expect(updated.resources.single.disposition.wireName, 'updated');

      releases.digest = 'declined-digest';
      final declined = PackLifecycleService.withDependencies(
        fileSystem: fs,
        acquisition: _LocalAcquisition(source.path, fileSystem: fs),
        releaseResolver: releases,
        prompts: PackPrompts(
          confirmation: (label) async =>
              !label.contains('changed or unverified'),
        ),
      );
      expect(
        () => declined.execute(
          request(
            operation: PackOperation.update,
            bump: 'minor',
            yes: false,
            interactive: true,
          ),
        ),
        throwsA(
          isA<MambaException>()
              .having(
                (error) => error.message,
                'message',
                contains('Changed attachment review cancelled'),
              )
              .having(
                (error) => error.exitCode,
                'exitCode',
                PackProcessStatus.cancelled.code,
              ),
        ),
      );
    });

    test(
      'save-policy persists release eligibility only after success',
      () async {
        final service = PackLifecycleService.withDependencies(
          fileSystem: fs,
          acquisition: _LocalAcquisition(source.path, fileSystem: fs),
          releaseResolver: _FakeReleases(),
        );
        await service.execute(request(release: 'v1.2.0'));
        final marker = fs.file(
          fs.path.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        marker.writeAsStringSync('${marker.readAsStringSync()}\nSecond.\n');

        final updated = await service.execute(
          request(
            operation: PackOperation.update,
            bump: 'minor',
            includePrerelease: true,
            savePolicy: true,
          ),
        );

        expect(updated.resources.single.disposition.wireName, 'updated');
        expect(updated.plan!.policy, isNotNull);
        expect(updated.plan!.policy!.bump, 'minor');
        expect(updated.plan!.policy!.includePrerelease, isTrue);
        final configuration = fs
            .file(fs.path.join(project.path, 'agent-resources.toml'))
            .readAsStringSync();
        expect(configuration, contains('bump = "minor"'));
        expect(configuration, contains('include_prerelease = true'));
        final validated = await PackLifecycleService(fileSystem: fs).execute(
          PackLifecycleRequest(
            operation: PackOperation.configValidate,
            resourceType: PackResourceType.skill,
            processWorkingDirectory: project.path,
            environment: {
              'HOME': home.path,
              'APPDATA': fs.path.join(home.path, 'AppData', 'Roaming'),
            },
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
          ),
        );
        expect(validated.outcome, 'valid');
      },
    );
  });
}

final class _RecoveryRequiredIO extends LifecycleIO {
  var _publicationFailed = false;

  @override
  void write(String path, List<int> bytes) {
    if (path.contains('transactions')) {
      final text = String.fromCharCodes(bytes);
      if (!_publicationFailed && text.contains('"phase":"published"')) {
        _publicationFailed = true;
        throw const FileSystemException('Injected publication failure');
      }
      if (text.contains('"phase":"failedRestored"')) {
        throw const FileSystemException('Injected terminal journal failure');
      }
    }
    super.write(path, bytes);
  }
}

final class _LocalAcquisition implements AcquisitionService {
  _LocalAcquisition(this.path, {required this.fileSystem, this.downloadDigest});

  final String path;
  final fslib.FileSystem fileSystem;
  final String? downloadDigest;

  @override
  Future<AcquisitionWorkspace> acquire(AcquisitionRequest request) async {
    return AcquisitionWorkspace(
      selectedRoot: path,
      selectedFile: null,
      fileSystem: fileSystem,
      provenance: AcquisitionProvenance(
        kind: AcquisitionLocatorKind.local,
        requestedLocator: request.locator,
        resolvedLocator: path,
        subpath: request.subpath,
        temporary: false,
        directFile: false,
        durableLocalDirectory: true,
        requestedRef: request.ref,
        resolvedCommit: '0123456789012345678901234567890123456789',
        downloadDigest: downloadDigest,
      ),
    );
  }
}

final class _FakeReleases implements GithubReleaseResolver {
  _FakeReleases({this.host = 'github.com'});

  final String host;

  @override
  Future<GithubReleaseInventory> inspect({
    required GitHubPackSource source,
  }) async => GithubReleaseInventory(
    repository: GithubRepositoryIdentity(
      host: host,
      repository: 'owner/demo',
      id: 42,
    ),
    releases: [
      GithubReleaseEvidence(
        repository: GithubRepositoryIdentity(
          host: host,
          repository: 'owner/demo',
          id: 42,
        ),
        id: 100,
        literalTag: 'v1.2.0',
        isDraft: false,
        isPrerelease: false,
      ),
    ],
  );

  @override
  Future<GithubReleaseResolution> resolve({
    required GitHubPackSource source,
    required ReleaseTrack track,
    required ReleasePolicy policy,
    ReleaseCandidate? current,
    String? exactTag,
  }) async {
    final selected = policy.select(
      candidates: const [
        ReleaseCandidate(literalTag: 'v1.2.0', id: '100'),
        ReleaseCandidate(literalTag: 'v1.3.0', id: '101'),
      ],
      current: current,
      exactTag: exactTag,
    );
    return GithubReleaseResolution(
      release: GithubReleaseEvidence(
        repository: GithubRepositoryIdentity(
          host: host,
          repository: 'owner/demo',
          id: 42,
        ),
        id: int.parse(selected.id!),
        literalTag: selected.literalTag,
        isDraft: selected.isDraft,
        isPrerelease: selected.isPrerelease,
        commit: '0123456789012345678901234567890123456789',
      ),
      acquisition: GithubArchiveAcquisition(
        repositoryUri: Uri.parse('https://github.com/owner/demo'),
        gitRef: selected.literalTag,
        commit: '0123456789012345678901234567890123456789',
      ),
    );
  }
}

final class _AttachmentReleases implements GithubReleaseResolver {
  _AttachmentReleases(this.digest, {this.advanceOnBump = false});

  String digest;
  final bool advanceOnBump;

  static final _download = Uri.parse(
    'https://github.com/owner/demo/releases/download/v1.2.0/bundle.zip',
  );

  @override
  Future<GithubReleaseInventory> inspect({
    required GitHubPackSource source,
  }) async => GithubReleaseInventory(
    repository: const GithubRepositoryIdentity(
      host: 'github.com',
      repository: 'owner/demo',
      id: 42,
    ),
    releases: const [
      GithubReleaseEvidence(
        repository: GithubRepositoryIdentity(
          host: 'github.com',
          repository: 'owner/demo',
          id: 42,
        ),
        id: 100,
        literalTag: 'v1.2.0',
        isDraft: false,
        isPrerelease: false,
      ),
    ],
  );

  @override
  Future<GithubReleaseResolution> resolve({
    required GitHubPackSource source,
    required ReleaseTrack track,
    required ReleasePolicy policy,
    ReleaseCandidate? current,
    String? exactTag,
  }) async {
    final selected = advanceOnBump
        ? policy.select(
            candidates: const [
              ReleaseCandidate(literalTag: 'v1.2.0', id: '100'),
              ReleaseCandidate(literalTag: 'v1.3.0', id: '101'),
            ],
            current: current,
            exactTag: exactTag,
          )
        : null;
    final releaseId = selected == null ? 100 : int.parse(selected.id!);
    final literalTag = selected?.literalTag ?? 'v1.2.0';
    return GithubReleaseResolution(
      release: GithubReleaseEvidence(
        repository: const GithubRepositoryIdentity(
          host: 'github.com',
          repository: 'owner/demo',
          id: 42,
        ),
        id: releaseId,
        literalTag: literalTag,
        isDraft: false,
        isPrerelease: false,
        commit: '0123456789012345678901234567890123456789',
      ),
      acquisition: GithubAttachmentAcquisition(
        id: 7,
        name: 'bundle.zip',
        downloadUri: advanceOnBump
            ? Uri.parse(
                'https://github.com/owner/demo/releases/download/'
                '$literalTag/bundle.zip',
              )
            : _download,
        size: 1,
        digest: digest,
      ),
    );
  }
}
