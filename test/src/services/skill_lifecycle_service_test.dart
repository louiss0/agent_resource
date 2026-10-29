import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

bool _tryDirectoryLink(String path, String target) {
  try {
    Link(path).createSync(target);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Deterministic supported-directory-link simulation for hosts where creating
/// native links is unavailable. Content still uses the real filesystem.
final class _SimulatedLinkIO extends LifecycleIO {
  final links = <String, String>{};

  String _key(String path) => p.normalize(path);

  @override
  FileSystemEntityType type(String path, {required bool followLinks}) {
    if (links.containsKey(_key(path))) return FileSystemEntityType.link;
    return super.type(path, followLinks: followLinks);
  }

  @override
  String linkKind(String path) {
    if (!links.containsKey(_key(path))) {
      return super.linkKind(path);
    }
    return 'posix-directory-symlink';
  }

  @override
  String readLink(String path) {
    final target = links[_key(path)];
    if (target == null) return super.readLink(path);
    return target;
  }

  @override
  void createLink(String path, String target) {
    if (links.containsKey(_key(path))) {
      throw FileSystemException('Link already exists', path);
    }
    links[_key(path)] = target;
  }

  @override
  void rename(String source, String destination) {
    final target = links.remove(_key(source));
    if (target != null) {
      links[_key(destination)] = target;
      return;
    }
    super.rename(source, destination);
  }

  @override
  void delete(String path) {
    if (links.remove(_key(path)) != null) return;
    super.delete(path);
  }
}

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
      'linked dry-run exposes entry and consumer observations without writes',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'skill-link-plan-',
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
          final result = await SkillLifecycleService().install(
            SkillInstallInput(
              options: LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                dryRun: true,
              ),
              source: source.path,
              destination: SkillDestination.claude,
              mode: SkillMode.link,
            ),
          );
          expect(result.outcome, 'planned');
          expect(result.data['nativeForm'], 'skill-link');
          expect(
            result.data['nativeLinkKind'],
            anyOf('posix-directory-symlink', 'windows-directory-symlink'),
          );
          expect(result.data['linkTarget'], source.path);
          expect(result.data['targetResolved'], source.path);
          expect(result.data['consumerEffects'], ['claude']);
          expect(result.data['ownership'], 'verifiedAbsent');
          expect(
            Directory(p.join(project.path, '.claude')).existsSync(),
            isFalse,
          );
          expect(
            Directory(p.join(project.path, '.agent-resource')).existsSync(),
            isFalse,
          );

          final shared = await SkillLifecycleService().install(
            SkillInstallInput(
              options: LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
                dryRun: true,
              ),
              source: source.path,
              destination: SkillDestination.shared,
              harnesses: const [SkillHarness.claude],
              mode: SkillMode.link,
            ),
          );
          expect(shared.data['validatedProfiles'], ['claude']);
          expect(shared.data['consumerEffects'], ['claude', 'codex']);
          expect(
            Directory(p.join(project.path, '.agents')).existsSync(),
            isFalse,
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

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
    test(
      'linked install preserves entry ownership through drift and conversion',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('skill-link-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          Directory source(String directory, String body) {
            final result = Directory(p.join(sandbox.path, directory))
              ..createSync();
            File(p.join(result.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: review\ndescription: Reviews.\n---\n$body\n',
            );
            return result;
          }

          final first = source('first', 'First.');
          final probe = p.join(sandbox.path, 'probe');
          if (!_tryDirectoryLink(probe, first.path)) {
            // Native positive evidence is unavailable on this host. Do not
            // substitute a junction or portable fake for the required workflow.
            print('directory symlink capability unavailable');
            return;
          }
          Link(probe).deleteSync();
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
              source: first.path,
              destination: SkillDestination.claude,
              mode: SkillMode.link,
            ),
          );
          final id = installed.data['installationId']! as String;
          final live = p.join(project.path, '.claude', 'skills', 'review');
          expect(
            FileSystemEntity.typeSync(live, followLinks: false),
            FileSystemEntityType.link,
          );
          expect(Link(live).targetSync(), first.path);
          File(p.join(first.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: Reviews.\n---\nEdited.\n',
          );
          final record = service.state.recordById(
            LifecycleContext.resolve(options()),
            id,
          );
          expect(service.state.verify(record), ModificationStatus.unchanged);
          final second = source('second', 'Second.');
          final linkedAgain = await service.replace(
            LifecycleReplaceInput(
              options: options(approved: true),
              installationId: id,
              source: second.path,
            ),
          );
          expect(linkedAgain.data['installationId'], id);
          expect(
            FileSystemEntity.typeSync(live, followLinks: false),
            FileSystemEntityType.link,
          );
          expect(Link(live).targetSync(), second.path);
          final copied = await service.replace(
            LifecycleReplaceInput(
              options: options(approved: true),
              installationId: id,
              source: second.path,
            ),
            mode: SkillMode.copy,
          );
          expect(copied.data['installationId'], id);
          expect(
            FileSystemEntity.typeSync(live, followLinks: false),
            FileSystemEntityType.directory,
          );
          final linked = await service.replace(
            LifecycleReplaceInput(
              options: options(approved: true),
              installationId: id,
              source: second.path,
            ),
            mode: SkillMode.link,
          );
          expect(linked.data['installationId'], id);
          expect(
            FileSystemEntity.typeSync(live, followLinks: false),
            FileSystemEntityType.link,
          );
          second.deleteSync(recursive: true);
          final removed = await service.remove(
            LifecycleIdInput(options: options(approved: true), id: id),
          );
          expect(removed.outcome, 'removed');
          expect(first.existsSync(), isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'relative link adoption restores entry evidence after validation',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'skill-relative-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = Directory(p.join(sandbox.path, 'source'))
            ..createSync();
          File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: Reviews.\n---\nOriginal.\n',
          );
          final live = p.join(project.path, '.claude', 'skills', 'review');
          Directory(p.dirname(live)).createSync(recursive: true);
          final relative = p.relative(source.path, from: p.dirname(live));
          if (!_tryDirectoryLink(live, relative)) {
            print('directory symlink capability unavailable');
            return;
          }
          LifecycleOptions options({bool approved = false}) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            approved: approved,
          );
          final service = SkillLifecycleService();
          final adopted = await service.adopt(
            SkillInstallInput(
              options: options(),
              source: live,
              destination: SkillDestination.claude,
            ),
          );
          expect(adopted.outcome, 'adopted');
          expect(Link(live).targetSync(), relative);
          final id = adopted.data['installationId']! as String;
          final removed = await service.remove(
            LifecycleIdInput(options: options(approved: true), id: id),
          );
          source.deleteSync(recursive: true);
          try {
            await service.restore(
              LifecycleIdInput(
                options: options(approved: true),
                id: removed.data['backupId']! as String,
              ),
            );
            fail('Normal restore accepted a broken target.');
          } on MambaException {
            // Current native validation is mandatory for normal restore.
          }
          source.createSync();
          File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: Reviews.\n---\nRecreated.\n',
          );
          final restored = await service.restore(
            LifecycleIdInput(
              options: options(approved: true),
              id: removed.data['backupId']! as String,
            ),
          );
          expect(restored.outcome, 'restored');
          expect(Link(live).targetSync(), relative);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
    test(
      'deterministic link semantics cover mode retention and conversion',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'skill-sim-link-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          Directory source(String directory, String body) {
            final result = Directory(p.join(sandbox.path, directory))
              ..createSync();
            File(p.join(result.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: review\ndescription: Reviews.\n---\n$body\n',
            );
            return result;
          }

          final first = source('first', 'First.');
          final second = source('second', 'Second.');
          final io = _SimulatedLinkIO();
          LifecycleOptions options({bool approved = false}) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            approved: approved,
          );
          final service = SkillLifecycleService(
            state: LifecycleStateService(io: io),
          );
          final installed = await service.install(
            SkillInstallInput(
              options: options(),
              source: first.path,
              destination: SkillDestination.claude,
              mode: SkillMode.link,
            ),
          );
          final id = installed.data['installationId']! as String;
          final live = p.join(project.path, '.claude', 'skills', 'review');
          expect(io.type(live, followLinks: false), FileSystemEntityType.link);
          expect(io.readLink(live), first.path);
          File(p.join(first.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: Reviews.\n---\nEdited.\n',
          );
          expect(
            service.state.verify(
              service.state.recordById(LifecycleContext.resolve(options()), id),
            ),
            ModificationStatus.unchanged,
          );
          final retained = await service.replace(
            LifecycleReplaceInput(
              options: options(approved: true),
              installationId: id,
              source: second.path,
            ),
          );
          expect(retained.data['installationId'], id);
          expect(io.type(live, followLinks: false), FileSystemEntityType.link);
          expect(io.readLink(live), second.path);
          final copied = await service.replace(
            LifecycleReplaceInput(
              options: options(approved: true),
              installationId: id,
              source: second.path,
            ),
            mode: SkillMode.copy,
          );
          expect(copied.data['installationId'], id);
          expect(
            io.type(live, followLinks: false),
            FileSystemEntityType.directory,
          );
          expect(
            File(p.join(live, 'SKILL.md')).readAsStringSync(),
            contains('Second.'),
          );
          final linked = await service.replace(
            LifecycleReplaceInput(
              options: options(approved: true),
              installationId: id,
              source: second.path,
            ),
            mode: SkillMode.link,
          );
          expect(linked.data['installationId'], id);
          expect(io.type(live, followLinks: false), FileSystemEntityType.link);
          second.deleteSync(recursive: true);
          final removed = await service.remove(
            LifecycleIdInput(options: options(approved: true), id: id),
          );
          expect(removed.outcome, 'removed');
          expect(first.existsSync(), isTrue);
          expect(io.links.containsKey(live), isFalse);
          final backups = await service.backupList(options());
          final backupsData = backups.data['backups']! as List<Object?>;
          expect(backupsData, isNotEmpty);
          final linkedReports = backupsData.where(
            (backup) =>
                (backup! as Map<String, Object?>)['artifactKind'] ==
                'skill-link',
          );
          expect(linkedReports, isNotEmpty);
          for (final backup in linkedReports) {
            final report = backup! as Map<String, Object?>;
            expect(report['targetContentHistory'], 'notSnapshot');
            expect(report['nativeLinkKind'], 'posix-directory-symlink');
            expect(report['linkTarget'], isNotNull);
            expect(report['originalParent'], isNotNull);
          }
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'deterministic relative-link backup retains original-parent semantics',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'skill-sim-relative-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = Directory(p.join(sandbox.path, 'source'))
            ..createSync();
          File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: Reviews.\n---\nOriginal.\n',
          );
          final live = p.join(project.path, '.codex', 'skills', 'review');
          Directory(p.dirname(live)).createSync(recursive: true);
          final relative = p.relative(source.path, from: p.dirname(live));
          final io = _SimulatedLinkIO()..links[p.normalize(live)] = relative;
          LifecycleOptions options({bool approved = false}) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            approved: approved,
          );
          final service = SkillLifecycleService(
            state: LifecycleStateService(io: io),
          );
          final adopted = await service.adopt(
            SkillInstallInput(
              options: options(),
              source: live,
              destination: SkillDestination.codex,
            ),
          );
          final id = adopted.data['installationId']! as String;
          expect(io.readLink(live), relative);
          final removed = await service.remove(
            LifecycleIdInput(options: options(approved: true), id: id),
          );
          source.deleteSync(recursive: true);
          try {
            await service.restore(
              LifecycleIdInput(
                options: options(approved: true),
                id: removed.data['backupId']! as String,
              ),
            );
            fail('Normal restore accepted a broken target.');
          } on MambaException {
            // Current target validation is mandatory for normal restore.
          }
          source.createSync();
          File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
            '---\nname: review\ndescription: Reviews.\n---\nRecreated.\n',
          );
          final sidecar = File(p.join(source.path, 'agents', 'openai.yaml'))
            ..createSync(recursive: true)
            ..writeAsStringSync('policy: []');
          try {
            await service.restore(
              LifecycleIdInput(
                options: options(approved: true),
                id: removed.data['backupId']! as String,
              ),
            );
            fail('Normal restore bypassed current Codex profile validation.');
          } on MambaException catch (error) {
            expect(error.exitCode, 2);
            expect(error.message, contains('policy'));
          }
          expect(
            io.type(live, followLinks: false),
            FileSystemEntityType.notFound,
          );
          sidecar.writeAsStringSync(
            'policy:\n  allow_implicit_invocation: true\n',
          );
          final restored = await service.restore(
            LifecycleIdInput(
              options: options(approved: true),
              id: removed.data['backupId']! as String,
            ),
          );
          expect(restored.outcome, 'restored');
          expect(io.readLink(live), relative);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
