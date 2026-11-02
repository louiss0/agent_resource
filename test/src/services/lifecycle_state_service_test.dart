import 'dart:convert';

import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

final class _FailAfterLedgerCommit extends LifecycleIO {
  _FailAfterLedgerCommit(FileSystem fs) : super(fs: fs);
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
        fs.file(destination).readAsStringSync().contains('installationId')) {
      _armed = true;
    }
  }
}

final class _FailBeforeRestorePublish extends LifecycleIO {
  _FailBeforeRestorePublish(this.livePath, FileSystem fs) : super(fs: fs);
  final String livePath;
  var _fail = true;

  @override
  void rename(String source, String destination) {
    if (_fail &&
        fs.path.equals(destination, livePath) &&
        source.contains('staging')) {
      _fail = false;
      throw const FileSystemException('Injected publication failure');
    }
    super.rename(source, destination);
  }
}

final class _FailOnceAfterInstall extends LifecycleIO {
  _FailOnceAfterInstall(
    this.livePath,
    FileSystem fs, {
    required this.preventRollback,
    this.editLiveBeforeFailure = false,
  }) : super(fs: fs);

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
        fs.path.equals(source, livePath) &&
        _failRollback) {
      _failRollback = false;
      throw const FileSystemException('Injected rollback failure');
    }
    super.rename(source, destination);
    if (fs.path.equals(destination, livePath)) _published = true;
  }

  @override
  void write(String path, List<int> bytes) {
    if (_published && path.contains('.json') && _failJournal) {
      _failJournal = false;
      if (editLiveBeforeFailure) {
        fs
            .file(fs.path.join(livePath, 'SKILL.md'))
            .writeAsStringSync('new occupant');
      }
      throw const FileSystemException('Injected intent flush failure');
    }
    super.write(path, bytes);
  }
}

void main() {
  group('LifecycleStateService', () {
    late MemoryFileSystem fs;
    var sandboxId = 0;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
    });

    Directory createSandbox() =>
        fs.directory(fs.path.join('/tmp', 'lifecycle-${++sandboxId}'))
          ..createSync(recursive: true);

    SkillLifecycleService createService({LifecycleStateService? state}) =>
        SkillLifecycleService(
          state: state ?? LifecycleStateService(io: LifecycleIO(fs: fs)),
        );
    test('dry-run creates no management or staging artifacts', () async {
      final sandbox = createSandbox();
      try {
        final project = fs.directory(fs.path.join(sandbox.path, 'project'))
          ..createSync();
        final home = fs.directory(fs.path.join(sandbox.path, 'home'))
          ..createSync();
        final source = fs.directory(fs.path.join(sandbox.path, 'source'))
          ..createSync();
        fs
            .file(fs.path.join(source.path, 'SKILL.md'))
            .writeAsStringSync(
              '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
            );
        final result = await createService().install(
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
          fs
              .directory(fs.path.join(project.path, '.agent-resource'))
              .existsSync(),
          isFalse,
        );
        expect(
          fs.directory(fs.path.join(project.path, '.claude')).existsSync(),
          isFalse,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test('automatic rollback refuses a changed live occupant', () async {
      final sandbox = createSandbox();
      try {
        final project = fs.directory(fs.path.join(sandbox.path, 'project'))
          ..createSync();
        final home = fs.directory(fs.path.join(sandbox.path, 'home'))
          ..createSync();
        final source = fs.directory(fs.path.join(sandbox.path, 'source'))
          ..createSync();
        fs
            .file(fs.path.join(source.path, 'SKILL.md'))
            .writeAsStringSync(
              '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
            );
        final live = fs.path.join(project.path, '.claude', 'skills', 'review');
        final io = _FailOnceAfterInstall(
          live,
          fs,
          preventRollback: false,
          editLiveBeforeFailure: true,
        );
        try {
          await createService(state: LifecycleStateService(io: io)).install(
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
          fs.file(fs.path.join(live, 'SKILL.md')).readAsStringSync(),
          'new occupant',
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'replacement rollback preserves a new occupant and original quarantine',
      () async {
        final sandbox = createSandbox();
        try {
          final project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          final home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync();
          Directory source(String directory, String description) {
            final result = fs.directory(fs.path.join(sandbox.path, directory))
              ..createSync();
            fs
                .file(fs.path.join(result.path, 'SKILL.md'))
                .writeAsStringSync(
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
          final service = createService();
          final installed = await service.install(
            SkillInstallInput(
              options: options(),
              source: source('one', 'First.').path,
              destination: SkillDestination.claude,
            ),
          );
          final live = fs.path.join(
            project.path,
            '.claude',
            'skills',
            'review',
          );
          final io = _FailOnceAfterInstall(
            live,
            fs,
            preventRollback: false,
            editLiveBeforeFailure: true,
          );
          try {
            await createService(state: LifecycleStateService(io: io)).replace(
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
            fs.file(fs.path.join(live, 'SKILL.md')).readAsStringSync(),
            'new occupant',
          );
          final quarantines = fs
              .directory(
                fs.path.join(
                  project.path,
                  '.claude',
                  '.agent-resource',
                  'quarantine',
                ),
              )
              .listSync(recursive: true);
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
          final sandbox = createSandbox();
          try {
            final project = fs.directory(fs.path.join(sandbox.path, 'project'))
              ..createSync();
            final home = fs.directory(fs.path.join(sandbox.path, 'home'))
              ..createSync();
            final source = fs.directory(fs.path.join(sandbox.path, 'source'))
              ..createSync();
            fs
                .file(fs.path.join(source.path, 'SKILL.md'))
                .writeAsStringSync(
                  '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
                );
            final live = fs.path.join(
              project.path,
              '.claude',
              'skills',
              'review',
            );
            LifecycleOptions options({bool approved = false}) =>
                LifecycleOptions(
                  processWorkingDirectory: project.path,
                  scope: LifecycleScope.project,
                  cwd: project.path,
                  projectRoot: project.path,
                  home: home.path,
                  approved: approved,
                );
            final io = _FailOnceAfterInstall(live, fs, preventRollback: true);
            String transactionId = '';
            try {
              await createService(state: LifecycleStateService(io: io)).install(
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
            expect(fs.directory(live).existsSync(), isTrue);
            final recovered = await createService().recover(
              options(approved: true),
              transactionId: transactionId,
              action: complete ? 'complete' : 'rollback',
            );
            expect(recovered.outcome, 'recovered');
            expect(
              recovered.data['stateEstablished'],
              complete ? 'committed' : 'rolledBack',
            );
            expect(fs.directory(live).existsSync(), complete);
            final records = createService().state.records(
              LifecycleContext.resolve(options(), fileSystem: fs),
            );
            expect(records, hasLength(complete ? 1 : 0));
            final inspected = await createService().recover(
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
      final sandbox = createSandbox();
      try {
        final project = fs.directory(fs.path.join(sandbox.path, 'project'))
          ..createSync();
        final home = fs.directory(fs.path.join(sandbox.path, 'home'))
          ..createSync();
        final skill = fs.directory(
          fs.path.join(project.path, '.claude', 'skills', 'review'),
        )..createSync(recursive: true);
        final marker = fs.file(fs.path.join(skill.path, 'SKILL.md'))
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
          await createService(
            state: LifecycleStateService(io: _FailAfterLedgerCommit(fs)),
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
        final recovered = await createService().recover(
          options(approved: true),
          transactionId: transactionId,
          action: 'rollback',
        );
        expect(recovered.data['stateEstablished'], 'rolledBack');
        expect(marker.readAsBytesSync(), before);
        expect(
          createService().state.records(
            LifecycleContext.resolve(options(), fileSystem: fs),
          ),
          isEmpty,
        );
        expect(
          fs
              .directory(
                fs.path.join(
                  project.path,
                  '.claude',
                  '.agent-resource',
                  'quarantine',
                ),
              )
              .existsSync(),
          isFalse,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'restore completion publishes staged output after verified absence',
      () async {
        final sandbox = createSandbox();
        try {
          final project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          final home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync();
          final source = fs.directory(fs.path.join(sandbox.path, 'source'))
            ..createSync();
          fs
              .file(fs.path.join(source.path, 'SKILL.md'))
              .writeAsStringSync(
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
          final service = createService();
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
          final live = fs.path.join(
            project.path,
            '.claude',
            'skills',
            'review',
          );
          String transactionId = '';
          try {
            await createService(
              state: LifecycleStateService(
                io: _FailBeforeRestorePublish(live, fs),
              ),
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
          expect(fs.directory(live).existsSync(), isFalse);
          final recovered = await service.recover(
            options(approved: true),
            transactionId: transactionId,
            action: 'complete',
          );
          expect(recovered.data['stateEstablished'], 'committed');
          expect(
            fs.file(fs.path.join(live, 'SKILL.md')).readAsStringSync(),
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
        final sandbox = createSandbox();
        try {
          final project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          final home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync();
          final source = fs.directory(fs.path.join(sandbox.path, 'source'))
            ..createSync();
          fs
              .file(fs.path.join(source.path, 'SKILL.md'))
              .writeAsStringSync(
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
          final service = createService();
          final installed = await service.install(
            SkillInstallInput(
              options: options(),
              source: source.path,
              destination: SkillDestination.claude,
            ),
          );
          String transactionId = '';
          try {
            await createService(
              state: LifecycleStateService(io: _FailAfterLedgerCommit(fs)),
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
          final quarantineRoot = fs.directory(
            fs.path.join(
              project.path,
              '.claude',
              '.agent-resource',
              'quarantine',
              transactionId,
              'review',
            ),
          );
          fs
              .file(fs.path.join(quarantineRoot.path, 'SKILL.md'))
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
            fs
                .file(fs.path.join(quarantineRoot.path, 'SKILL.md'))
                .readAsStringSync(),
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
      final sandbox = createSandbox();
      try {
        final project = fs.directory(fs.path.join(sandbox.path, 'project'))
          ..createSync();
        final home = fs.directory(fs.path.join(sandbox.path, 'home'))
          ..createSync();
        final source = fs.directory(fs.path.join(sandbox.path, 'source'))
          ..createSync();
        fs
            .file(fs.path.join(source.path, 'SKILL.md'))
            .writeAsStringSync(
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
        final service = createService();
        final installed = await service.install(
          SkillInstallInput(
            options: options(),
            source: source.path,
            destination: SkillDestination.claude,
          ),
        );
        String transactionId = '';
        try {
          await createService(
            state: LifecycleStateService(io: _FailAfterLedgerCommit(fs)),
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
        final transactionFile = fs.file(
          fs.path.join(
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
        fs
            .directory(
              fs.path.join(
                project.path,
                '.claude',
                '.agent-resource',
                'quarantine',
                transactionId,
              ),
            )
            .deleteSync(recursive: true);
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
        final sandbox = createSandbox();
        try {
          final project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          final home = fs.directory(fs.path.join(sandbox.path, 'home'))
            ..createSync();
          final source = fs.directory(fs.path.join(sandbox.path, 'source'))
            ..createSync();
          fs
              .file(fs.path.join(source.path, 'SKILL.md'))
              .writeAsStringSync(
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
          final service = createService();
          final installed = await service.install(
            SkillInstallInput(
              options: options(),
              source: source.path,
              destination: SkillDestination.claude,
            ),
          );
          String transactionId = '';
          try {
            await createService(
              state: LifecycleStateService(io: _FailAfterLedgerCommit(fs)),
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
          final live = fs.directory(
            fs.path.join(project.path, '.claude', 'skills', 'review'),
          );
          final quarantine = fs.directory(
            fs.path.join(
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
                  LifecycleContext.resolve(options(), fileSystem: fs),
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
