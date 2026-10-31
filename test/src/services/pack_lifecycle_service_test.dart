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
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('PackLifecycleService', () {
    late Directory sandbox;
    late Directory project;
    late Directory home;
    late Directory source;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('pack-lifecycle-test-');
      project = Directory(p.join(sandbox.path, 'project'))..createSync();
      home = Directory(p.join(sandbox.path, 'home'))..createSync();
      source = Directory(p.join(sandbox.path, 'source'))..createSync();
      File(p.join(source.path, 'agent-resources.toml')).writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/reviewer"
[[catalog.agents]]
path = "agents/reviewer.md"
profile = "claude"
''');
      final skill = Directory(p.join(source.path, 'skills', 'reviewer'))
        ..createSync(recursive: true);
      File(p.join(skill.path, 'SKILL.md')).writeAsStringSync('''---
name: reviewer
description: Reviews code.
---
# Reviewer
''');
      File(p.join(source.path, 'agents', 'reviewer.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''---
name: reviewer
description: Reviews code.
---
Review changes.
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
      bool dryRun = false,
      List<String> allowFolder = const [],
      List<String> keepLocal = const [],
      List<String> replaceLocal = const [],
      String? to,
      String? snapshot,
      String? method,
      bool localEdits = false,
      bool yes = true,
      bool interactive = false,
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
      method: type == PackResourceType.skill ? method ?? 'copy' : null,
      target: type == PackResourceType.skill ? 'codex' : null,
      allowFolder: allowFolder,
      keepLocal: keepLocal,
      replaceLocal: replaceLocal,
      to: to,
      snapshot: snapshot,
      localEdits: localEdits,
      dryRun: dryRun,
      yes: yes,
      interactive: interactive,
    );

    test(
      'validates consumer configuration without reading the source',
      () async {
        final result = await PackLifecycleService().execute(
          PackLifecycleRequest(
            operation: PackOperation.configValidate,
            resourceType: PackResourceType.skill,
            processWorkingDirectory: sandbox.path,
            environment: {
              'HOME': home.path,
              'APPDATA': p.join(home.path, 'AppData', 'Roaming'),
            },
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
          ),
        );

        expect(result.outcome, 'valid');
        expect(result.context['resolved'], isFalse);
        expect(
          Directory(p.join(project.path, '.agent-resource')).existsSync(),
          isFalse,
        );
      },
    );

    test('installs a native Skill and Agent with source evidence', () async {
      final service = PackLifecycleService();
      final skills = await service.execute(
        request(PackOperation.install, PackResourceType.skill),
      );
      final agents = await service.execute(
        request(PackOperation.install, PackResourceType.agent),
      );

      expect(skills.resources.single.disposition, 'installed');
      expect(agents.resources.single.disposition, 'installed');
      expect(
        File(p.join(project.path, '.agents', 'skills', 'reviewer', 'SKILL.md'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(project.path, '.claude', 'agents', 'reviewer.md'))
            .existsSync(),
        isTrue,
      );
      final lock = jsonDecode(
        File(p.join(project.path, '.agent-resource', 'installations.json'))
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

    test(
      'ordinary install replays exact lock without reacquiring source',
      () async {
        final service = PackLifecycleService();
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        source.deleteSync(recursive: true);

        final replay = await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );

        expect(replay.outcome, 'no-op');
        expect(replay.resources.single.disposition, 'unchanged');
        expect(replay.source['exactLockReplay'], isTrue);
      },
    );

    test('rejects unknown native names before any managed write', () async {
      expect(
        () => PackLifecycleService().execute(
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
        Directory(p.join(project.path, '.agent-resource')).existsSync(),
        isFalse,
      );
      expect(Directory(p.join(project.path, '.agents')).existsSync(), isFalse);
    });

    test('dry run publishes neither resources nor lock state', () async {
      final result = await PackLifecycleService().execute(
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
        Directory(p.join(project.path, '.agent-resource')).existsSync(),
        isFalse,
      );
      expect(Directory(p.join(project.path, '.agents')).existsSync(), isFalse);
    });

    test('requires bounded approval for an extra Skill root folder', () async {
      Directory(p.join(source.path, 'skills', 'reviewer', 'rules'))
          .createSync();

      expect(
        () => PackLifecycleService().execute(
          request(PackOperation.install, PackResourceType.skill),
        ),
        throwsA(isA<MambaException>()),
      );
      expect(
        Directory(p.join(project.path, '.agent-resource')).existsSync(),
        isFalse,
      );

      final result = await PackLifecycleService().execute(
        request(
          PackOperation.install,
          PackResourceType.skill,
          allowFolder: const ['reviewer:rules'],
        ),
      );
      expect(result.resources.single.disposition, 'installed');
      expect(
        Directory(
          p.join(project.path, '.agents', 'skills', 'reviewer', 'rules'),
        ).existsSync(),
        isTrue,
      );

      final upstream = File(
        p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
      );
      upstream.writeAsStringSync('${upstream.readAsStringSync()}\nSecond.\n');
      final updated = await PackLifecycleService().execute(
        request(PackOperation.update, PackResourceType.skill),
      );
      expect(updated.resources.single.disposition, 'updated');
      final lock = jsonDecode(
        File(p.join(project.path, '.agent-resource', 'installations.json'))
            .readAsStringSync(),
      ) as Map<String, Object?>;
      expect(lock['approvals'], isNotEmpty);
      expect(lock['selections'], isNotEmpty);
      expect(lock['operations'], isNotEmpty);
    });

    test(
      'configured extra folders drive the interactive review prompt',
      () async {
        Directory(p.join(source.path, 'skills', 'reviewer', 'rules'))
            .createSync();
        final config = File(p.join(project.path, 'agent-resources.toml'));
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
        expect(result.resources.single.disposition, 'installed');
        final lock = jsonDecode(
          File(p.join(project.path, '.agent-resource', 'installations.json'))
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
        final service = PackLifecycleService();
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final marker = File(
          p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        marker.writeAsStringSync(
          '${marker.readAsStringSync()}\nUpstream edit.\n',
        );

        final replay = await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );

        expect(replay.outcome, 'no-op');
        expect(replay.resources.single.disposition, 'unchanged');
        final live = File(
          p.join(project.path, '.agents', 'skills', 'reviewer', 'SKILL.md'),
        );
        expect(live.readAsStringSync(), isNot(contains('Upstream edit.')));

        final updated = await service.execute(
          request(PackOperation.update, PackResourceType.skill),
        );
        expect(updated.resources.single.disposition, 'updated');
        expect(live.readAsStringSync(), contains('Upstream edit.'));
      },
    );

    test(
      'update requires an explicit whole-resource local-edit choice',
      () async {
        final service = PackLifecycleService();
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final upstream = File(
          p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        upstream.writeAsStringSync(
          '${upstream.readAsStringSync()}\nUpstream edit.\n',
        );
        final live = File(
          p.join(project.path, '.agents', 'skills', 'reviewer', 'SKILL.md'),
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
        expect(kept.resources.single.disposition, 'keptLocal');
        expect(live.readAsStringSync(), contains('Local edit.'));
        expect(live.readAsStringSync(), isNot(contains('Upstream edit.')));
      },
    );

    test(
      'replace-local preserves edited bytes before publishing upstream',
      () async {
        final service = PackLifecycleService();
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final upstream = File(
          p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        upstream.writeAsStringSync(
          '${upstream.readAsStringSync()}\nUpstream edit.\n',
        );
        final live = File(
          p.join(project.path, '.agents', 'skills', 'reviewer', 'SKILL.md'),
        );
        live.writeAsStringSync('${live.readAsStringSync()}\nLocal edit.\n');

        final result = await service.execute(
          request(
            PackOperation.update,
            PackResourceType.skill,
            replaceLocal: const ['reviewer'],
          ),
        );

        expect(result.resources.single.disposition, 'updated');
        expect(live.readAsStringSync(), contains('Upstream edit.'));
        expect(live.readAsStringSync(), isNot(contains('Local edit.')));
        final lock = jsonDecode(
          File(p.join(project.path, '.agent-resource', 'installations.json'))
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final installation =
            (lock['installations']! as List<Object?>).single!
                as Map<String, Object?>;
        final backupIds = installation['backupIds']! as List<Object?>;
        expect(backupIds, hasLength(1));
        final backup = File(
          p.join(
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

    test(
      'changed source configuration requires reviewed source change',
      () async {
        final service = PackLifecycleService();
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final other = Directory(p.join(sandbox.path, 'other'))..createSync();
        for (final entity in source.listSync(recursive: true)) {
          final relative = p.relative(entity.path, from: source.path);
          final destination = p.join(other.path, relative);
          if (entity is Directory) {
            Directory(destination).createSync(recursive: true);
          } else if (entity is File) {
            File(destination)
              ..createSync(recursive: true)
              ..writeAsBytesSync(entity.readAsBytesSync());
          }
        }
        final config = File(p.join(project.path, 'agent-resources.toml'));
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

    test('source associate binds a matching adopted installation', () async {
      final destination = Directory(
        p.join(project.path, '.agents', 'skills', 'reviewer'),
      )..createSync(recursive: true);
      final adoptedSource = p.join(source.path, 'skills', 'reviewer');
      for (final entity in Directory(adoptedSource).listSync(recursive: true)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: adoptedSource);
        File(p.join(destination.path, relative))
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
      await SkillLifecycleService().adopt(
        SkillInstallInput(
          options: options,
          source: destination.path,
          destination: SkillDestination.shared,
        ),
      );

      final result = await PackLifecycleService().execute(
        request(
          PackOperation.sourceAssociate,
          PackResourceType.skill,
          only: const ['reviewer'],
        ),
      );

      expect(result.resources.single.disposition, 'updated');
      final lock = jsonDecode(
        File(p.join(project.path, '.agent-resource', 'installations.json'))
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final installation =
          (lock['installations']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(
        (installation['origin']! as Map<String, Object?>)['packKey'],
        'local/demo',
      );
    });

    test('rollback restores one stable Recorded snapshot ref', () async {
      final service = PackLifecycleService();
      final installed = await service.execute(
        request(PackOperation.install, PackResourceType.skill),
      );
      final firstRef = installed.resources.single.snapshot!;
      final upstream = File(
        p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
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

      expect(rolledBack.resources.single.disposition, 'rolledBack');
      expect(rolledBack.resources.single.snapshot, firstRef);
      expect(rolledBack.plan!.resources.single.action, 'rollback');
      expect(
        rolledBack.plan!.resources.single.changedPaths.map((path) => path.path),
        contains('SKILL.md'),
      );
      expect(
        File(p.join(project.path, '.agents', 'skills', 'reviewer', 'SKILL.md'))
            .readAsStringSync(),
        isNot(contains('Version two.')),
      );
      final lock = jsonDecode(
        File(p.join(project.path, '.agent-resource', 'installations.json'))
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
      'source-link update observes but never overwrites the target',
      () async {
        final service = PackLifecycleService();
        final installed = await service.execute(
          request(
            PackOperation.install,
            PackResourceType.skill,
            method: 'source-link',
          ),
        );
        expect(installed.resources.single.linkOnly, isTrue);
        final live = Link(
          p.join(project.path, '.agents', 'skills', 'reviewer'),
        );
        expect(live.existsSync(), isTrue);
        final target = File(
          p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        target.writeAsStringSync(
          '${target.readAsStringSync()}\nTarget edit.\n',
        );

        final observed = await service.execute(
          request(
            PackOperation.update,
            PackResourceType.skill,
            method: 'source-link',
          ),
        );

        expect(observed.resources.single.disposition, 'observed');
        expect(observed.resources.single.linkOnly, isTrue);
        expect(target.readAsStringSync(), contains('Target edit.'));
        expect(live.targetSync(), p.join(source.path, 'skills', 'reviewer'));
        final lock = jsonDecode(
          File(p.join(project.path, '.agent-resource', 'installations.json'))
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final installation =
            (lock['installations']! as List<Object?>).single!
                as Map<String, Object?>;
        expect(installation['backupIds'], isEmpty);
        expect(
          (installation['origin']!
              as Map<String, Object?>)['targetObservation'],
          isNotNull,
        );
      },
    );

    test(
      'a removed resource can be reinstalled with a fresh identity',
      () async {
        final service = PackLifecycleService();
        final installed = await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final firstLock = jsonDecode(
          File(p.join(project.path, '.agent-resource', 'installations.json'))
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

        expect(reinstalled.resources.single.disposition, 'installed');
        final lock = jsonDecode(
          File(p.join(project.path, '.agent-resource', 'installations.json'))
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final live = (lock['installations']! as List<Object?>)
            .map((value) => value! as Map<String, Object?>)
            .singleWhere((record) => record['lifecycle'] == 'live');
        expect(live['installationId'], isNot(original));
        expect(
          File(
            p.join(project.path, '.agents', 'skills', 'reviewer', 'SKILL.md'),
          ).existsSync(),
          isTrue,
        );
        expect(installed.resources.single.disposition, 'installed');
      },
    );

    test(
      'new resources stay unselected until --only requests inclusion',
      () async {
        final service = PackLifecycleService();
        await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final second = Directory(p.join(source.path, 'skills', 'writer'))
          ..createSync(recursive: true);
        File(p.join(second.path, 'SKILL.md')).writeAsStringSync('''---
name: writer
description: Writes docs.
---
# Writer
''');
        final catalog = File(p.join(source.path, 'agent-resources.toml'));
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
              .disposition,
          'observed',
        );
        expect(
          ordinary.warnings.map((warning) => warning.id),
          contains('new-resource-unselected'),
        );
        expect(
          Directory(p.join(project.path, '.agents', 'skills', 'writer'))
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
        expect(selected.resources.single.disposition, 'installed');
        expect(
          File(p.join(project.path, '.agents', 'skills', 'writer', 'SKILL.md'))
              .existsSync(),
          isTrue,
        );
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

      expect(rolledBack.resources.single.disposition, 'rolledBack');
      expect(rolledBack.resources.single.linkOnly, isTrue);
      expect(link.targetSync(), originalTarget);
      expect(target.readAsStringSync(), contains('Edited target.'));
    });

    test(
      'cleanup protects current and prunes expired history visibly',
      () async {
        final service = PackLifecycleService();
        final installed = await service.execute(
          request(PackOperation.install, PackResourceType.skill),
        );
        final firstRef = installed.resources.single.snapshot!;
        final upstream = File(
          p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
        );
        upstream.writeAsStringSync('${upstream.readAsStringSync()}\nSecond.\n');
        await service.execute(
          request(PackOperation.update, PackResourceType.skill),
        );
        final lockFile = File(
          p.join(project.path, '.agent-resource', 'installations.json'),
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
        final artifact = Directory(
          p.join(
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
      final service = PackLifecycleService();
      await service.execute(
        request(PackOperation.install, PackResourceType.skill),
      );
      final upstream = File(
        p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
      );
      upstream.writeAsStringSync('${upstream.readAsStringSync()}\nSecond.\n');
      final live = File(
        p.join(project.path, '.agents', 'skills', 'reviewer', 'SKILL.md'),
      );
      live.writeAsStringSync('${live.readAsStringSync()}\nLocal.\n');
      await service.execute(
        request(
          PackOperation.update,
          PackResourceType.skill,
          replaceLocal: const ['reviewer'],
        ),
      );
      final lockFile = File(
        p.join(project.path, '.agent-resource', 'installations.json'),
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

  group('PackLifecycleService releases', () {
    late Directory sandbox;
    late Directory project;
    late Directory home;
    late Directory source;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('pack-release-test-');
      project = Directory(p.join(sandbox.path, 'project'))..createSync();
      home = Directory(p.join(sandbox.path, 'home'))..createSync();
      source = Directory(p.join(sandbox.path, 'source'))..createSync();
      File(p.join(source.path, 'agent-resources.toml')).writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/reviewer"
''');
      final skill = Directory(p.join(source.path, 'skills', 'reviewer'))
        ..createSync(recursive: true);
      File(p.join(skill.path, 'SKILL.md')).writeAsStringSync('''---
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
      String? release,
      PackOperation operation = PackOperation.install,
      String? bump,
      bool includePrerelease = false,
      bool savePolicy = false,
      bool yes = true,
      bool interactive = false,
    }) => PackLifecycleRequest(
      operation: operation,
      resourceType: PackResourceType.skill,
      pack: 'owner/demo',
      processWorkingDirectory: project.path,
      environment: {
        'HOME': home.path,
        'USERPROFILE': home.path,
        'APPDATA': p.join(home.path, 'AppData', 'Roaming'),
      },
      scope: LifecycleScope.project,
      cwd: project.path,
      projectRoot: project.path,
      home: home.path,
      release: release,
      bump: bump,
      includePrerelease: includePrerelease,
      savePolicy: savePolicy,
      yes: yes,
      interactive: interactive,
    );

    test('first release install requires an exact literal tag', () async {
      expect(
        () => PackLifecycleService.withDependencies(
          acquisition: _LocalAcquisition(source.path),
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
        acquisition: _LocalAcquisition(source.path),
        releaseResolver: _FakeReleases(),
      ).execute(request(release: 'v1.2.0'));

      expect(result.resources.single.disposition, 'installed');
      final lock = jsonDecode(
        File(p.join(project.path, '.agent-resource', 'installations.json'))
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

    test('release update requires an explicit or saved bump', () async {
      final service = PackLifecycleService.withDependencies(
        acquisition: _LocalAcquisition(source.path),
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
        acquisition: _LocalAcquisition(source.path),
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

    test('changed attachment bytes require injected live acceptance', () async {
      final config = File(p.join(project.path, 'agent-resources.toml'));
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          'artifact = "archive"',
          'artifact = "attachment", attachment = "bundle.zip"',
        ),
      );
      final releases = _AttachmentReleases('old-digest');
      final prompts = <String>[];
      final service = PackLifecycleService.withDependencies(
        acquisition: _LocalAcquisition(source.path),
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
      expect(updated.outcome, 'no-op');

      releases.digest = 'declined-digest';
      final declined = PackLifecycleService.withDependencies(
        acquisition: _LocalAcquisition(source.path),
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
          acquisition: _LocalAcquisition(source.path),
          releaseResolver: _FakeReleases(),
        );
        await service.execute(request(release: 'v1.2.0'));
        final marker = File(
          p.join(source.path, 'skills', 'reviewer', 'SKILL.md'),
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

        expect(updated.resources.single.disposition, 'updated');
        expect(updated.plan!.policy, isNotNull);
        expect(updated.plan!.policy!.bump, 'minor');
        expect(updated.plan!.policy!.includePrerelease, isTrue);
        final configuration = File(p.join(project.path, 'agent-resources.toml'))
            .readAsStringSync();
        expect(configuration, contains('bump = "minor"'));
        expect(configuration, contains('include_prerelease = true'));
        final validated = await PackLifecycleService().execute(
          PackLifecycleRequest(
            operation: PackOperation.configValidate,
            resourceType: PackResourceType.skill,
            processWorkingDirectory: project.path,
            environment: {
              'HOME': home.path,
              'APPDATA': p.join(home.path, 'AppData', 'Roaming'),
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

final class _LocalAcquisition implements AcquisitionService {
  _LocalAcquisition(this.path);

  final String path;

  @override
  Future<AcquisitionWorkspace> acquire(AcquisitionRequest request) async {
    return AcquisitionWorkspace(
      selectedRoot: path,
      selectedFile: null,
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
      ),
    );
  }
}

final class _FakeReleases implements GithubReleaseResolver {
  @override
  Future<GithubReleaseInventory> inspect({
    required GitHubPackSource source,
  }) async => const GithubReleaseInventory(
    repository: GithubRepositoryIdentity(
      host: 'github.com',
      repository: 'owner/demo',
      id: 42,
    ),
    releases: [
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
        repository: const GithubRepositoryIdentity(
          host: 'github.com',
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
  _AttachmentReleases(this.digest);

  String digest;

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
  }) async => GithubReleaseResolution(
    release: const GithubReleaseEvidence(
      repository: GithubRepositoryIdentity(
        host: 'github.com',
        repository: 'owner/demo',
        id: 42,
      ),
      id: 100,
      literalTag: 'v1.2.0',
      isDraft: false,
      isPrerelease: false,
      commit: '0123456789012345678901234567890123456789',
    ),
    acquisition: GithubAttachmentAcquisition(
      id: 7,
      name: 'bundle.zip',
      downloadUri: _download,
      size: 1,
      digest: digest,
    ),
  );
}
