import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _FailAfterLedgerCommit extends LifecycleIO {
  var _armed = false;
  var _fail = true;

  @override
  void rename(String source, String destination) {
    if (_armed && _fail && destination.contains('transactions')) {
      _fail = false;
      throw const FileSystemException('Injected terminal journal failure');
    }
    super.rename(source, destination);
    if (destination.endsWith('installations.json') &&
        File(destination).readAsStringSync().contains('installationId')) {
      _armed = true;
    }
  }
}

final class _FailBeforeRestorePublish extends LifecycleIO {
  _FailBeforeRestorePublish(this.livePath);
  final String livePath;
  var _fail = true;

  @override
  void rename(String source, String destination) {
    if (_fail &&
        p.equals(destination, livePath) &&
        source.contains('staging')) {
      _fail = false;
      throw const FileSystemException('Injected publication failure');
    }
    super.rename(source, destination);
  }
}

final class _FailOnceAfterInstall extends LifecycleIO {
  _FailOnceAfterInstall(
    this.livePath, {
    required this.preventRollback,
    this.editLiveBeforeFailure = false,
  });

  final String livePath;
  final bool preventRollback;
  final bool editLiveBeforeFailure;
  var _published = false;
  var _failJournal = true;
  var _failRollback = true;

  @override
  void rename(String source, String destination) {
    if (preventRollback &&
        _published &&
        p.equals(source, livePath) &&
        _failRollback) {
      _failRollback = false;
      throw const FileSystemException('Injected rollback failure');
    }
    super.rename(source, destination);
    if (p.equals(destination, livePath)) _published = true;
  }

  @override
  void write(String path, List<int> bytes) {
    if (_published && path.contains('.json') && _failJournal) {
      _failJournal = false;
      if (editLiveBeforeFailure) {
        File(p.join(livePath, 'SKILL.md')).writeAsStringSync('new occupant');
      }
      throw const FileSystemException('Injected intent flush failure');
    }
    super.write(path, bytes);
  }
}

void main() {
  group('LifecycleStateService', () {
    test('dry-run creates no management or staging artifacts', () async {
      final sandbox = await Directory.systemTemp.createTemp('lifecycle-dry-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final source = Directory(p.join(sandbox.path, 'source'))..createSync();
        File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
          '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
        );
        final result = await SkillLifecycleService().install(
          SkillInstallInput(
            options: LifecycleOptions(
              processWorkingDirectory: project.path,
              cwd: project.path,
              projectRoot: project.path,
              home: home.path,
              dryRun: true,
            ),
            source: source.path,
            destination: SkillDestination.claude,
          ),
        );
        expect(result.outcome, 'planned');
        expect(
          Directory(p.join(project.path, '.agent-resource')).existsSync(),
          isFalse,
        );
        expect(
          Directory(p.join(project.path, '.claude')).existsSync(),
          isFalse,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test('automatic rollback refuses a changed live occupant', () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'lifecycle-occupant-',
      );
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final source = Directory(p.join(sandbox.path, 'source'))..createSync();
        File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
          '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
        );
        final live = p.join(project.path, '.claude', 'skills', 'review');
        final io = _FailOnceAfterInstall(
          live,
          preventRollback: false,
          editLiveBeforeFailure: true,
        );
        try {
          await SkillLifecycleService(state: LifecycleStateService(io: io))
              .install(
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
          fail('The injected failure did not surface.');
        } on MambaException catch (error) {
          expect(error.exitCode, 6);
          expect(error.message, contains('requires recovery'));
        }
        expect(
          File(p.join(live, 'SKILL.md')).readAsStringSync(),
          'new occupant',
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'replacement rollback preserves a new occupant and original quarantine',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'replace-occupant-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          Directory source(String directory, String description) {
            final result = Directory(p.join(sandbox.path, directory))
              ..createSync();
            File(p.join(result.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: review\ndescription: $description\n---\nBody.\n',
            );
            return result;
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
          final installed = await service.install(
            SkillInstallInput(
              options: options(),
              source: source('one', 'First.').path,
              destination: SkillDestination.claude,
            ),
          );
          final live = p.join(project.path, '.claude', 'skills', 'review');
          final io = _FailOnceAfterInstall(
            live,
            preventRollback: false,
            editLiveBeforeFailure: true,
          );
          try {
            await SkillLifecycleService(state: LifecycleStateService(io: io))
                .replace(
                  LifecycleReplaceInput(
                    options: options(approved: true),
                    installationId: installed.data['installationId']! as String,
                    source: source('two', 'Second.').path,
                  ),
                );
            fail('The injected replacement failure did not surface.');
          } on MambaException catch (error) {
            expect(error.exitCode, 6);
          }
          expect(
            File(p.join(live, 'SKILL.md')).readAsStringSync(),
            'new occupant',
          );
          final quarantines = Directory(
            p.join(project.path, '.claude', '.agent-resource', 'quarantine'),
          ).listSync(recursive: true);
          expect(
            quarantines.whereType<File>().map((file) => file.path),
            isNotEmpty,
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    for (final complete in [false, true]) {
      test(
        complete
            ? 'fresh service completes only the evidenced installation publication'
            : 'fresh service rolls back an interrupted installation safely',
        () async {
          final sandbox = await Directory.systemTemp.createTemp(
            'lifecycle-fault-',
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
            final live = p.join(project.path, '.claude', 'skills', 'review');
            LifecycleOptions options({bool approved = false}) =>
                LifecycleOptions(
                  processWorkingDirectory: project.path,
                  scope: LifecycleScope.project,
                  cwd: project.path,
                  projectRoot: project.path,
                  home: home.path,
                  approved: approved,
                );
            final io = _FailOnceAfterInstall(live, preventRollback: true);
            String transactionId = '';
            try {
              await SkillLifecycleService(state: LifecycleStateService(io: io))
                  .install(
                    SkillInstallInput(
                      options: options(),
                      source: source.path,
                      destination: SkillDestination.claude,
                    ),
                  );
              fail('The injected failure did not surface.');
            } on MambaException catch (error) {
              expect(error.exitCode, 6);
              transactionId = RegExp('transaction (trx_[a-f0-9]{32})')
                  .firstMatch(error.message)!
                  .group(1)!;
            }
            expect(Directory(live).existsSync(), isTrue);
            final recovered = await SkillLifecycleService().recover(
              options(approved: true),
              transactionId: transactionId,
              action: complete ? 'complete' : 'rollback',
            );
            expect(recovered.outcome, 'recovered');
            expect(
              recovered.data['stateEstablished'],
              complete ? 'committed' : 'rolledBack',
            );
            expect(Directory(live).existsSync(), complete);
            final records = SkillLifecycleService().state.records(
              LifecycleContext.resolve(options()),
            );
            expect(records, hasLength(complete ? 1 : 0));
            final inspected = await SkillLifecycleService().recover(
              options(),
              transactionId: transactionId,
            );
            expect(inspected.outcome, 'inspected');
            expect(inspected.data['availableActions'], isEmpty);
          } finally {
            await sandbox.delete(recursive: true);
          }
        },
      );
    }
    test('adoption rollback removes only management evidence', () async {
      final sandbox = await Directory.systemTemp.createTemp('adopt-rollback-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final skill = Directory(
          p.join(project.path, '.claude', 'skills', 'review'),
        )..createSync(recursive: true);
        final marker = File(p.join(skill.path, 'SKILL.md'))
          ..writeAsStringSync(
            '---\nname: review\ndescription: Reviews.\n---\nOriginal.\n',
          );
        final before = marker.readAsBytesSync();
        LifecycleOptions options({bool approved = false}) => LifecycleOptions(
          processWorkingDirectory: project.path,
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          approved: approved,
        );
        String transactionId = '';
        try {
          await SkillLifecycleService(
            state: LifecycleStateService(io: _FailAfterLedgerCommit()),
          ).adopt(
            SkillInstallInput(
              options: options(),
              source: skill.path,
              destination: SkillDestination.claude,
            ),
          );
          fail('The injected adoption failure did not surface.');
        } on MambaException catch (error) {
          expect(error.exitCode, 6);
          transactionId = RegExp(r'trx_[a-f0-9]{32}')
              .firstMatch(error.message)!
              .group(0)!;
        }
        final recovered = await SkillLifecycleService().recover(
          options(approved: true),
          transactionId: transactionId,
          action: 'rollback',
        );
        expect(recovered.data['stateEstablished'], 'rolledBack');
        expect(marker.readAsBytesSync(), before);
        expect(
          SkillLifecycleService().state.records(
            LifecycleContext.resolve(options()),
          ),
          isEmpty,
        );
        expect(
          Directory(
            p.join(project.path, '.claude', '.agent-resource', 'quarantine'),
          ).existsSync(),
          isFalse,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'restore completion publishes staged output after verified absence',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'restore-complete-',
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
          final id = installed.data['installationId']! as String;
          final removed = await service.remove(
            LifecycleIdInput(options: options(approved: true), id: id),
          );
          final live = p.join(project.path, '.claude', 'skills', 'review');
          String transactionId = '';
          try {
            await SkillLifecycleService(
              state: LifecycleStateService(io: _FailBeforeRestorePublish(live)),
            ).restore(
              LifecycleIdInput(
                options: options(approved: true),
                id: removed.data['backupId']! as String,
              ),
            );
            fail('The injected restore failure did not surface.');
          } on MambaException catch (error) {
            transactionId = RegExp(r'trx_[a-f0-9]{32}')
                .firstMatch(error.message)!
                .group(0)!;
          }
          expect(Directory(live).existsSync(), isFalse);
          final recovered = await service.recover(
            options(approved: true),
            transactionId: transactionId,
            action: 'complete',
          );
          expect(recovered.data['stateEstablished'], 'committed');
          expect(
            File(p.join(live, 'SKILL.md')).readAsStringSync(),
            contains('Original.'),
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'removal completion rejects edited quarantine and remains inspectable',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'remove-complete-',
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
          String transactionId = '';
          try {
            await SkillLifecycleService(
              state: LifecycleStateService(io: _FailAfterLedgerCommit()),
            ).remove(
              LifecycleIdInput(
                options: options(approved: true),
                id: installed.data['installationId']! as String,
              ),
            );
            fail('The injected removal failure did not surface.');
          } on MambaException catch (error) {
            expect(error.exitCode, 6);
            transactionId = RegExp(r'trx_[a-f0-9]{32}')
                .firstMatch(error.message)!
                .group(0)!;
          }
          final quarantineRoot = Directory(
            p.join(
              project.path,
              '.claude',
              '.agent-resource',
              'quarantine',
              transactionId,
              'review',
            ),
          );
          File(p.join(quarantineRoot.path, 'SKILL.md'))
              .writeAsStringSync('edited');
          try {
            await service.recover(
              options(approved: true),
              transactionId: transactionId,
              action: 'complete',
            );
            fail('Edited quarantine was unexpectedly completed.');
          } on MambaException catch (error) {
            expect(error.exitCode, 6);
          }
          expect(
            File(p.join(quarantineRoot.path, 'SKILL.md')).readAsStringSync(),
            'edited',
          );
          final inspected = await service.recover(
            options(),
            transactionId: transactionId,
          );
          expect(inspected.data['availableActions'], contains('complete'));
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
    test('committed-pending completion refuses missing quarantine', () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'missing-quarantine-',
      );
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final source = Directory(p.join(sandbox.path, 'source'))..createSync();
        File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
          '---\nname: review\ndescription: Reviews.\n---\nOriginal.\n',
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
        String transactionId = '';
        try {
          await SkillLifecycleService(
            state: LifecycleStateService(io: _FailAfterLedgerCommit()),
          ).remove(
            LifecycleIdInput(
              options: options(approved: true),
              id: installed.data['installationId']! as String,
            ),
          );
          fail('The injected removal failure did not surface.');
        } on MambaException catch (error) {
          transactionId = RegExp(r'trx_[a-f0-9]{32}')
              .firstMatch(error.message)!
              .group(0)!;
        }
        final transactionFile = File(
          p.join(
            project.path,
            '.agent-resource',
            'transactions',
            '$transactionId.json',
          ),
        );
        final journal = jsonDecode(
          transactionFile.readAsStringSync(),
        ) as Map<String, Object?>;
        journal['phase'] = 'committedCleanupPending';
        transactionFile.writeAsStringSync(jsonEncode(journal));
        Directory(
          p.join(
            project.path,
            '.claude',
            '.agent-resource',
            'quarantine',
            transactionId,
          ),
        ).deleteSync(recursive: true);
        try {
          await service.recover(
            options(approved: true),
            transactionId: transactionId,
            action: 'complete',
          );
          fail('Missing quarantine was guessed as completed cleanup.');
        } on MambaException catch (error) {
          expect(error.exitCode, 6);
          expect(error.message, contains('quarantine'));
        }
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'rollback recognizes an already-restored original installation',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'rollback-retry-',
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
          String transactionId = '';
          try {
            await SkillLifecycleService(
              state: LifecycleStateService(io: _FailAfterLedgerCommit()),
            ).remove(
              LifecycleIdInput(
                options: options(approved: true),
                id: installed.data['installationId']! as String,
              ),
            );
            fail('The injected removal failure did not surface.');
          } on MambaException catch (error) {
            transactionId = RegExp(r'trx_[a-f0-9]{32}')
                .firstMatch(error.message)!
                .group(0)!;
          }
          final live = Directory(
            p.join(project.path, '.claude', 'skills', 'review'),
          );
          final quarantine = Directory(
            p.join(
              project.path,
              '.claude',
              '.agent-resource',
              'quarantine',
              transactionId,
              'review',
            ),
          );
          // A crash after this physical restoration but before the original
          // ledger is restored must not replay the rename on retry.
          quarantine.renameSync(live.path);
          final recovered = await service.recover(
            options(approved: true),
            transactionId: transactionId,
            action: 'rollback',
          );
          expect(recovered.data['stateEstablished'], 'rolledBack');
          expect(live.existsSync(), isTrue);
          expect(quarantine.existsSync(), isFalse);
          expect(
            service.state
                .recordById(
                  LifecycleContext.resolve(options()),
                  installed.data['installationId']! as String,
                )
                .lifecycle,
            'live',
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
