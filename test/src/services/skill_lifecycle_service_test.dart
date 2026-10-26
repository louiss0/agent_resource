import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SkillLifecycleService', () {
    test(
      'install copies the complete tree and records an unchanged baseline',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'skill-lifecycle-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = Directory(p.join(sandbox.path, 'source'))
            ..createSync();
          File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: Reviews changes.\n---\nReview.\n',
          );
          File(p.join(source.path, 'assets', 'fixture.bin'))
            ..createSync(recursive: true)
            ..writeAsBytesSync(const [0, 1, 2, 255]);
          final service = SkillLifecycleService();
          final result = await service.install(
            SkillInstallInput(
              options: LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
              ),
              source: source.path,
              destination: SkillDestination.claude,
            ),
          );

          expect(result.outcome, 'installed');
          final destination = Directory(
            p.join(project.path, '.claude', 'skills', 'review'),
          );
          expect(destination.existsSync(), isTrue);
          expect(
            File(p.join(destination.path, 'assets', 'fixture.bin'))
                .readAsBytesSync(),
            const [0, 1, 2, 255],
          );
          expect(File(p.join(source.path, 'SKILL.md')).existsSync(), isTrue);
          final ledger = jsonDecode(
            File(p.join(project.path, '.agent-resource', 'installations.json'))
                .readAsStringSync(),
          ) as Map<String, Object?>;
          final installations = ledger['installations']! as List<Object?>;
          expect(installations, hasLength(1));
          final record = installations.single! as Map<String, Object?>;
          expect(record['artifactKind'], 'skill-copy');
          expect(record['location'], destination.path);
          expect(record['lifecycle'], 'live');
          expect(result.data['installationId'], record['installationId']);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
    test(
      'adoption preserves native bytes and re-adoption preserves identity',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('skill-adopt-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final skill = Directory(
            p.join(project.path, '.agents', 'skills', 'review'),
          )..createSync(recursive: true);
          final marker = File(p.join(skill.path, 'SKILL.md'))
            ..writeAsStringSync(
              '---\nname: review\ndescription: Reviews changes.\n---\n\r\nKeep exact bytes.\r\n',
            );
          final before = marker.readAsBytesSync();
          final service = SkillLifecycleService();
          LifecycleOptions options() => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          final input = SkillInstallInput(
            options: options(),
            source: skill.path,
            destination: SkillDestination.shared,
            harnesses: const [SkillHarness.claude],
          );
          final adopted = await service.adopt(input);
          final again = await service.adopt(input);

          expect(adopted.outcome, 'adopted');
          expect(again.outcome, 'alreadyManaged');
          expect(again.data['installationId'], adopted.data['installationId']);
          expect(marker.readAsBytesSync(), before);
          expect(
            Directory(p.join(skill.path, '.agent-resource')).existsSync(),
            isFalse,
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
    test('replacement preserves identity and removal retains independent backups', () async {
      final sandbox = await Directory.systemTemp.createTemp('skill-replace-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        Directory(p.join(sandbox.path, 'outside')).createSync();
        LifecycleOptions options({bool approved = false}) => LifecycleOptions(
          processWorkingDirectory: project.path,
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          approved: approved,
        );
        Directory source(String name, String description) {
          final directory = Directory(p.join(sandbox.path, name))..createSync();
          File(p.join(directory.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: $description\n---\n$description\n',
          );
          return directory;
        }

        final service = SkillLifecycleService();
        final installed = await service.install(
          SkillInstallInput(
            options: options(),
            source: source('one', 'First version.').path,
            destination: SkillDestination.claude,
          ),
        );
        final id = installed.data['installationId']! as String;
        final replaced = await service.replace(
          LifecycleReplaceInput(
            options: options(approved: true),
            installationId: id,
            source: source('two', 'Second version.').path,
          ),
        );
        expect(replaced.outcome, 'replaced');
        expect(replaced.data['installationId'], id);
        final replacementBackup = Directory(
          p.join(
            project.path,
            '.agent-resource',
            'backups',
            replaced.data['backupId']! as String,
            'artifact',
          ),
        );
        expect(
          File(p.join(replacementBackup.path, 'SKILL.md')).readAsStringSync(),
          contains('First version.'),
        );
        final removed = await service.remove(
          LifecycleIdInput(options: options(approved: true), id: id),
        );
        expect(removed.outcome, 'removed');
        expect(
          Directory(p.join(project.path, '.claude', 'skills', 'review'))
              .existsSync(),
          isFalse,
        );
        final backups = await service.backupList(options());
        expect(backups.data['backups']! as List<Object?>, hasLength(2));
        File(p.join(replacementBackup.path, 'SKILL.md'))
            .writeAsStringSync('backup-only edit');
        expect(
          Directory(p.join(project.path, '.claude', 'skills')).existsSync(),
          isTrue,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
    test('restore after removal preserves identity and cleanup requires intact evidence', () async {
      final sandbox = await Directory.systemTemp.createTemp('skill-restore-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final source = Directory(p.join(sandbox.path, 'source'))..createSync();
        File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
          '---\nname: review\ndescription: Restorable.\n---\nOriginal bytes.\n',
        );
        LifecycleOptions options({bool approved = false}) => LifecycleOptions(
          processWorkingDirectory: project.path,
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          approved: approved,
        );
        final service = SkillLifecycleService();
        final installed = await service.install(
          SkillInstallInput(
            options: options(),
            source: source.path,
            destination: SkillDestination.shared,
          ),
        );
        final id = installed.data['installationId']! as String;
        final removed = await service.remove(
          LifecycleIdInput(options: options(approved: true), id: id),
        );
        final backupId = removed.data['backupId']! as String;
        final restored = await service.restore(
          LifecycleIdInput(options: options(approved: true), id: backupId),
        );
        expect(restored.outcome, 'restored');
        expect(restored.data['installationId'], id);
        final restoredMarker = File(
          p.join(project.path, '.agents', 'skills', 'review', 'SKILL.md'),
        );
        expect(restoredMarker.readAsStringSync(), contains('Original bytes.'));
        final cleaned = await service.cleanup(
          LifecycleIdInput(options: options(approved: true), id: backupId),
        );
        expect(cleaned.outcome, 'cleaned');
        final backups = await service.backupList(options());
        expect(backups.data['backups'], isEmpty);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
    test(
      'requested profiles add blocking reserved-name and sidecar gates',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'skill-profiles-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          LifecycleOptions options() => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            dryRun: true,
          );
          Directory source(String directory, String name) {
            final source = Directory(p.join(sandbox.path, directory))
              ..createSync();
            File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: $name\ndescription: Fixture.\n---\nBody.\n',
            );
            return source;
          }

          final service = SkillLifecycleService();
          for (final (input, token) in [
            (
              SkillInstallInput(
                options: options(),
                source: source('reserved', 'synced').path,
                destination: SkillDestination.claude,
              ),
              'reserves',
            ),
            (
              SkillInstallInput(
                options: options(),
                source: source('sidecar', 'review').path,
                destination: SkillDestination.codex,
              ),
              'policy',
            ),
          ]) {
            if (input.destination == SkillDestination.codex) {
              File(p.join(input.source, 'agents', 'openai.yaml'))
                ..createSync(recursive: true)
                ..writeAsStringSync('policy: []');
            }
            try {
              await service.install(input);
              fail('Invalid profile input unexpectedly passed.');
            } on MambaException catch (error) {
              expect(error.exitCode, 2);
              expect(error.message, contains(token));
            }
          }
          expect(
            Directory(p.join(project.path, '.claude')).existsSync(),
            isFalse,
          );
          expect(
            Directory(p.join(project.path, '.codex')).existsSync(),
            isFalse,
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'stored IDs cannot redirect mutation to a crafted native root',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'skill-authority-',
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
          LifecycleOptions options({bool approved = false}) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            approved: approved,
          );
          final service = SkillLifecycleService();
          final installed = await service.install(
            SkillInstallInput(
              options: options(),
              source: source.path,
              destination: SkillDestination.claude,
            ),
          );
          final ledgerFile = File(
            p.join(project.path, '.agent-resource', 'installations.json'),
          );
          final ledger =
              jsonDecode(ledgerFile.readAsStringSync()) as Map<String, Object?>;
          final record =
              (ledger['installations']! as List<Object?>).single!
                  as Map<String, Object?>;
          final outside = Directory(p.join(sandbox.path, 'outside', 'review'))
            ..createSync(recursive: true);
          File(p.join(outside.path, 'SKILL.md')).writeAsStringSync(
            File(
              p.join(project.path, '.claude', 'skills', 'review', 'SKILL.md'),
            ).readAsStringSync(),
          );
          record['nativeRoot'] = p.dirname(outside.path);
          record['location'] = outside.path;
          ledgerFile.writeAsStringSync(jsonEncode(ledger));
          try {
            await service.remove(
              LifecycleIdInput(
                options: options(approved: true),
                id: installed.data['installationId']! as String,
              ),
            );
            fail('Crafted authority was unexpectedly accepted.');
          } on MambaException catch (error) {
            expect(error.exitCode, 4);
            expect(error.message, contains('native authority'));
          }
          expect(outside.existsSync(), isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
    test(
      'fresh install after removal gets a new ID and blocks old restore',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'skill-fresh-id-',
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
          LifecycleOptions options({bool approved = false}) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            approved: approved,
          );
          final service = SkillLifecycleService();
          SkillInstallInput install() => SkillInstallInput(
            options: options(),
            source: source.path,
            destination: SkillDestination.claude,
          );
          final first = await service.install(install());
          final firstId = first.data['installationId']! as String;
          final removed = await service.remove(
            LifecycleIdInput(options: options(approved: true), id: firstId),
          );
          final second = await service.install(install());
          final secondId = second.data['installationId']! as String;
          expect(secondId, isNot(firstId));
          final liveMarker = File(
            p.join(project.path, '.claude', 'skills', 'review', 'SKILL.md'),
          );
          final before = liveMarker.readAsBytesSync();
          try {
            await service.restore(
              LifecycleIdInput(
                options: options(approved: true),
                id: removed.data['backupId']! as String,
              ),
            );
            fail('Historical restore overwrote a new occupant.');
          } on MambaException catch (error) {
            expect(error.exitCode, 4);
            expect(error.message, contains('occupied'));
          }
          expect(liveMarker.readAsBytesSync(), before);
          expect(
            service.state.records(LifecycleContext.resolve(options())),
            hasLength(2),
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
