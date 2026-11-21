import 'dart:convert';
import 'dart:io' show Directory, FileSystemException, Platform, Process;

import 'package:agent_resource/context_inject.dart';
import 'package:agent_resource/src/context/context_types.dart';
import 'package:mamba/mamba.dart';
import 'package:agent_resource/src/services/context_injection_service.dart';
import 'package:agent_resource/src/services/context_template_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';

import 'package:agent_resource/agent_resource.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:file/local.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  test('refuses a Windows junction in a Context destination', () async {
    if (!Platform.isWindows) return;
    final root = Directory.systemTemp.createTempSync('context-junction-');
    try {
      final project = Directory('${root.path}\\project')..createSync();
      final home = Directory('${root.path}\\home')..createSync();
      final state = Directory('${root.path}\\state')..createSync();
      final outside = Directory('${root.path}\\outside')..createSync();
      final link = '${project.path}\\.claude';
      final created = await Process.run('cmd', [
        '/c',
        'mklink',
        '/J',
        link,
        outside.path,
      ]);
      expect(
        created.exitCode,
        0,
        reason: '${created.stdout} ${created.stderr}',
      );
      final local = const LocalFileSystem();
      local.file('${state.path}\\context-templates\\notes.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('rules\n');
      final service = ContextInjectionService();
      expect(
        () => service.plan(
          options: LifecycleOptions(
            processWorkingDirectory: project.path,
            projectRoot: project.path,
            home: home.path,
            stateDir: state.path,
          ),
          templateName: 'notes',
          harnesses: [ContextHarness.claude],
          scope: ContextScope.project,
          variant: ContextVariant.dotClaude,
          folder: null,
          replace: false,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.toString(),
            'message',
            contains('SYMLINK_REFUSED'),
          ),
        ),
      );
      expect(local.file('${outside.path}\\CLAUDE.md').existsSync(), isFalse);
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  test('replaces an existing target on the local filesystem', () {
    final root = Directory.systemTemp.createTempSync('context-publication-');
    try {
      final local = const LocalFileSystem();
      final project = local.directory(local.path.join(root.path, 'project'))
        ..createSync();
      final home = local.directory(local.path.join(root.path, 'home'))
        ..createSync();
      final state = local.directory(local.path.join(root.path, 'state'))
        ..createSync();
      local.file(local.path.join(state.path, 'context-templates', 'notes.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('new\n');
      final target = local.file(local.path.join(project.path, 'CLAUDE.md'))
        ..writeAsStringSync('old\n');
      final options = LifecycleOptions(
        processWorkingDirectory: project.path,
        projectRoot: project.path,
        home: home.path,
        stateDir: state.path,
      );
      final service = ContextInjectionService();
      final plan = service.plan(
        options: options,
        templateName: 'notes',
        harnesses: [ContextHarness.claude],
        scope: ContextScope.project,
        variant: ContextVariant.standard,
        folder: null,
        replace: true,
      );
      final result = service.publish(
        options: options,
        reviewed: plan,
        suppliedPlanId: null,
      );
      expect(target.readAsStringSync(), 'new\n');
      expect(
        local.file(result.targets.single.recoveryPath!).readAsStringSync(),
        'old\n',
      );
    } finally {
      root.deleteSync(recursive: true);
    }
  });

  group('agent_resource', () {
    group('context', () {
      group('inject', () {
        late fslib.FileSystem fs;

        const roots = <String>[
          '--cwd',
          '/sandbox/project/',
          '--project-root',
          '/sandbox/project/',
          '--home',
          '/sandbox/home/',
          '--claude-config-dir',
          '/sandbox/home/claude/',
          '--codex-home',
          '/sandbox/home/codex/',
          '--pi-agent-dir',
          '/sandbox/home/pi/',
          '--state-dir',
          '/sandbox/state/',
        ];

        List<String> command(List<String> extra) => <String>[
          'context',
          'inject',
          ...extra,
          ...roots,
        ];

        void writeTemplate(String content) {
          fs.file('/sandbox/state/context-templates/notes.md')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(content);
        }

        Future<Map<String, dynamic>> publish(List<String> extra) async {
          final result = await createExecutor(fileSystem: fs).fake().execute(
            command(<String>[
              ...extra,
              '--apply',
              '--yes',
              '--unattended',
              '--format',
              'json',
            ]),
          );
          expect(result, isA<MambaSuccessResult>());
          final envelope =
              jsonDecode((result as MambaSuccessResult).output!)!
                  as Map<String, dynamic>;
          expect(envelope['outcome'], 'published');
          return envelope;
        }

        setUp(() {
          fs = MemoryFileSystem(style: FileSystemStyle.posix);
          for (final directory in [
            '/sandbox/project',
            '/sandbox/home',
            '/sandbox/state',
          ]) {
            fs.directory(directory).createSync(recursive: true);
          }
        });

        test('refuses a linked intermediate destination directory', () async {
          writeTemplate('rules\n');
          fs.directory('/sandbox/outside').createSync(recursive: true);
          fs.link('/sandbox/project/.claude').createSync('/sandbox/outside');

          final result = await createExecutor(fileSystem: fs).fake().execute(
            command(const <String>[
              'notes',
              '--harness',
              'claude',
              '--variant',
              'dot-claude',
              '--apply',
              '--yes',
              '--unattended',
            ]),
          );

          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 4)
                .having(
                  (value) => value.message,
                  'message',
                  contains('SYMLINK_REFUSED'),
                ),
          );
          expect(fs.file('/sandbox/outside/CLAUDE.md').existsSync(), isFalse);
        });

        test(
          'compensates an earlier write when a later target fails',
          () async {
            writeTemplate('rules\n');
            final first = fs.file('/sandbox/project/CLAUDE.md')
              ..writeAsStringSync('original\n');
            final injection = ContextInjectionService(
              fileSystem: fs,
              io: _FailSecondRename(fs),
            );
            final result =
                await createExecutor(
                  fileSystem: fs,
                  contextInject: ContextInjectCommand(
                    injection,
                    ContextTemplateService(fileSystem: fs),
                  ),
                ).fake().execute(
                  command(const <String>[
                    'notes',
                    '--harness',
                    'claude',
                    '--harness',
                    'codex',
                    '--apply',
                    '--yes',
                    '--unattended',
                  ]),
                );
            expect(
              result,
              isA<MambaFailureResult>()
                  .having(
                    (value) => value.message,
                    'message',
                    contains('CONTEXT_PARTIAL_FAILURE'),
                  )
                  .having(
                    (value) => value.message,
                    'recovery evidence',
                    contains('recovery'),
                  ),
            );
            expect(first.readAsStringSync(), 'original\n');
            expect(fs.file('/sandbox/project/AGENTS.md').existsSync(), isFalse);
          },
        );

        test(
          'preserves an independently changed published target on failure',
          () async {
            writeTemplate('rules\n');
            final first = fs.file('/sandbox/project/CLAUDE.md')
              ..writeAsStringSync('original\n');
            final injection = ContextInjectionService(
              fileSystem: fs,
              io: _FailSecondRename(
                fs,
                beforeFailure: () => first.writeAsStringSync('external\n'),
              ),
            );
            final result =
                await createExecutor(
                  fileSystem: fs,
                  contextInject: ContextInjectCommand(
                    injection,
                    ContextTemplateService(fileSystem: fs),
                  ),
                ).fake().execute(
                  command(const <String>[
                    'notes',
                    '--harness',
                    'claude',
                    '--harness',
                    'codex',
                    '--apply',
                    '--yes',
                    '--unattended',
                  ]),
                );
            expect(
              result,
              isA<MambaFailureResult>()
                  .having(
                    (value) => value.message,
                    'message',
                    contains('NOT compensated'),
                  )
                  .having(
                    (value) => value.message,
                    'recovery path',
                    contains('/sandbox/state/authoring-recovery/'),
                  ),
            );
            expect(first.readAsStringSync(), 'external\n');
            final recovery = fs
                .directory('/sandbox/state/authoring-recovery')
                .listSync(recursive: true)
                .whereType<fslib.File>()
                .single;
            expect(recovery.readAsStringSync(), 'original\n');
          },
        );

        test('refuses an oversized append before writing any target', () async {
          writeTemplate('more rules\n');
          final original = 'a' * (1024 * 1024);
          final first = fs.file('/sandbox/project/CLAUDE.md')
            ..writeAsStringSync(original);
          final result = await createExecutor(fileSystem: fs).fake().execute(
            command(const <String>[
              'notes',
              '--harness',
              'codex',
              '--harness',
              'claude',
              '--apply',
              '--yes',
              '--unattended',
            ]),
          );
          expect(
            result,
            isA<MambaFailureResult>().having(
              (value) => value.message,
              'message',
              contains('TARGET_TOO_LARGE: Proposed Context file'),
            ),
          );
          expect(first.readAsStringSync(), original);
          expect(fs.file('/sandbox/project/AGENTS.md').existsSync(), isFalse);
          expect(
            fs.directory('/sandbox/state/authoring-receipts').existsSync(),
            isFalse,
          );
        });

        test('removes committed receipts when a later receipt fails', () async {
          writeTemplate('rules\n');
          final injection = ContextInjectionService(
            fileSystem: fs,
            io: _FailSecondReceipt(fs),
          );
          final result =
              await createExecutor(
                fileSystem: fs,
                contextInject: ContextInjectCommand(
                  injection,
                  ContextTemplateService(fileSystem: fs),
                ),
              ).fake().execute(
                command(const <String>[
                  'notes',
                  '--harness',
                  'claude',
                  '--harness',
                  'codex',
                  '--apply',
                  '--yes',
                  '--unattended',
                ]),
              );
          expect(
            result,
            isA<MambaFailureResult>().having(
              (value) => value.message,
              'message',
              contains('CONTEXT_PARTIAL_FAILURE'),
            ),
          );
          expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
          expect(fs.file('/sandbox/project/AGENTS.md').existsSync(), isFalse);
          expect(
            fs.directory('/sandbox/state/authoring-receipts').listSync(),
            isEmpty,
          );
        });

        test(
          'rechecks each destination and compensates on later drift',
          () async {
            writeTemplate('rules\n');
            final second = fs.file('/sandbox/project/AGENTS.md')
              ..writeAsStringSync('before\n');
            final injection = ContextInjectionService(
              fileSystem: fs,
              io: _ChangeOnFirstRename(
                fs,
                () => second.writeAsStringSync('external\n'),
              ),
            );
            final result =
                await createExecutor(
                  fileSystem: fs,
                  contextInject: ContextInjectCommand(
                    injection,
                    ContextTemplateService(fileSystem: fs),
                  ),
                ).fake().execute(
                  command(const <String>[
                    'notes',
                    '--harness',
                    'claude',
                    '--harness',
                    'codex',
                    '--apply',
                    '--yes',
                    '--unattended',
                  ]),
                );
            expect(
              result,
              isA<MambaFailureResult>()
                  .having(
                    (value) => value.message,
                    'message',
                    contains('CONTEXT_PLAN_DRIFT'),
                  )
                  .having(
                    (value) => value.message,
                    'compensation',
                    contains('compensated'),
                  ),
            );
            expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
            expect(second.readAsStringSync(), 'external\n');
          },
        );

        test(
          'reports retained recovery when compensation also fails',
          () async {
            writeTemplate('rules\n');
            final first = fs.file('/sandbox/project/CLAUDE.md')
              ..writeAsStringSync('original\n');
            final injection = ContextInjectionService(
              fileSystem: fs,
              io: _FailPublicationAndRestore(fs),
            );
            final result =
                await createExecutor(
                  fileSystem: fs,
                  contextInject: ContextInjectCommand(
                    injection,
                    ContextTemplateService(fileSystem: fs),
                  ),
                ).fake().execute(
                  command(const <String>[
                    'notes',
                    '--harness',
                    'claude',
                    '--harness',
                    'codex',
                    '--apply',
                    '--yes',
                    '--unattended',
                  ]),
                );
            expect(
              result,
              isA<MambaFailureResult>()
                  .having(
                    (value) => value.message,
                    'message',
                    contains('NOT compensated'),
                  )
                  .having(
                    (value) => value.message,
                    'recovery',
                    contains('/sandbox/state/authoring-recovery/'),
                  ),
            );
            expect(first.readAsStringSync(), 'original\n\nrules\n');
            final recovery = fs
                .directory('/sandbox/state/authoring-recovery')
                .listSync(recursive: true)
                .whereType<fslib.File>()
                .single;
            expect(recovery.readAsStringSync(), 'original\n');
          },
        );

        test('writes a shared AGENTS.md once with both harnesses', () async {
          writeTemplate('shared rules\n');

          final envelope = await publish(const <String>[
            'notes',
            '--harness',
            'codex',
            '--harness',
            'pi',
          ]);
          final targets =
              (envelope['data'] as Map<String, dynamic>)['targets']!
                  as List<dynamic>;
          expect(targets, hasLength(1));
          expect(targets.single, containsPair('harnesses', ['codex', 'pi']));
          expect(
            fs.file('/sandbox/project/AGENTS.md').readAsStringSync(),
            'shared rules\n',
          );
          expect(
            fs
                .directory('/sandbox/state/authoring-receipts')
                .listSync()
                .where((entity) => entity.path.endsWith('.json')),
            hasLength(1),
          );
        });

        test('publishes raw markdown without a managed ledger', () async {
          writeTemplate('# Project notes\n\nUse TDD.\n');

          await publish(const <String>['notes', '--harness', 'claude']);
          final content = fs
              .file('/sandbox/project/CLAUDE.md')
              .readAsStringSync();
          expect(content, '# Project notes\n\nUse TDD.\n');
          expect(content, isNot(contains('<!--')));
          expect(
            fs.file('/sandbox/state/installations.json').existsSync(),
            isFalse,
          );
        });

        test('publishes to all three user-global roots', () async {
          writeTemplate('global rules\n');

          final envelope = await publish(const <String>[
            'notes',
            '--harness',
            'claude',
            '--harness',
            'codex',
            '--harness',
            'pi',
            '--scope',
            'user',
          ]);
          final targets =
              (envelope['data'] as Map<String, dynamic>)['targets']!
                  as List<dynamic>;
          expect(
            targets.map((target) => target['path']).toList(),
            equals(<String>[
              '/sandbox/home/claude/CLAUDE.md',
              '/sandbox/home/codex/AGENTS.md',
              '/sandbox/home/pi/AGENTS.md',
            ]),
          );
          for (final path in [
            '/sandbox/home/claude/CLAUDE.md',
            '/sandbox/home/codex/AGENTS.md',
            '/sandbox/home/pi/AGENTS.md',
          ]) {
            expect(fs.file(path).readAsStringSync(), 'global rules\n');
          }
        });

        test('creates, appends and replaces an antigravity file', () async {
          writeTemplate('shared rules\n');
          await publish(const <String>[
            'notes',
            '--harness',
            'antigravity',
            '--variant',
            'standard',
          ]);
          expect(
            fs.file('/sandbox/project/AGENTS.md').readAsStringSync(),
            'shared rules\n',
          );

          writeTemplate('more rules\n');
          final append = await publish(const <String>[
            'notes',
            '--harness',
            'antigravity',
            '--variant',
            'standard',
          ]);
          final appendTargets =
              (append['data'] as Map<String, dynamic>)['targets']!
                  as List<dynamic>;
          expect(appendTargets.single, containsPair('action', 'append'));
          expect(
            fs.file('/sandbox/project/AGENTS.md').readAsStringSync(),
            'shared rules\n\nmore rules\n',
          );

          final replace = await publish(const <String>[
            'notes',
            '--harness',
            'antigravity',
            '--variant',
            'standard',
            '--replace',
          ]);
          final replaceTargets =
              (replace['data'] as Map<String, dynamic>)['targets']!
                  as List<dynamic>;
          expect(replaceTargets.single, containsPair('action', 'replace'));
          expect(
            fs.file('/sandbox/project/AGENTS.md').readAsStringSync(),
            'more rules\n',
          );
        });

        test(
          'publishes antigravity context to overridden user roots',
          () async {
            writeTemplate('global rules\n');
            for (final testCase in <Map<String, String>>[
              {'variant': 'standard', 'path': '/sandbox/gemini/AGENTS.md'},
              {'variant': 'gemini', 'path': '/sandbox/gemini/GEMINI.md'},
              {
                'variant': 'dot-agents',
                'path': '/sandbox/gemini/config/AGENTS.md',
              },
            ]) {
              final envelope = await publish(<String>[
                'notes',
                '--harness',
                'antigravity',
                '--scope',
                'user',
                '--variant',
                testCase['variant']!,
                '--gemini-dir',
                '/sandbox/gemini/',
              ]);
              final targets =
                  (envelope['data'] as Map<String, dynamic>)['targets']!
                      as List<dynamic>;
              expect(targets, hasLength(1));
              expect(targets.single, containsPair('path', testCase['path']));
              expect(
                targets.single,
                containsPair('harnesses', ['antigravity']),
              );
              expect(
                fs.file(testCase['path']!).readAsStringSync(),
                'global rules\n',
              );
            }
            expect(
              fs
                  .directory('/sandbox/state/authoring-receipts')
                  .listSync()
                  .where((entity) => entity.path.endsWith('.json')),
              hasLength(3),
            );
          },
        );

        test(
          'writes one shared AGENTS.md for codex, pi and antigravity',
          () async {
            writeTemplate('shared rules\n');

            final envelope = await publish(const <String>[
              'notes',
              '--harness',
              'codex',
              '--harness',
              'pi',
              '--harness',
              'antigravity',
            ]);
            final targets =
                (envelope['data'] as Map<String, dynamic>)['targets']!
                    as List<dynamic>;
            expect(targets, hasLength(1));
            expect(
              targets.single,
              containsPair('harnesses', ['codex', 'pi', 'antigravity']),
            );
            expect(
              fs.file('/sandbox/project/AGENTS.md').readAsStringSync(),
              'shared rules\n',
            );
            expect(
              fs
                  .directory('/sandbox/state/authoring-receipts')
                  .listSync()
                  .where((entity) => entity.path.endsWith('.json')),
              hasLength(1),
            );
          },
        );
      });
    });
  });
}

class _FailSecondRename extends LifecycleIO {
  _FailSecondRename(fslib.FileSystem fs, {this.beforeFailure}) : super(fs: fs);
  final void Function()? beforeFailure;
  int renames = 0;
  @override
  void before(String operation, String path) {
    if (operation == 'rename' && ++renames == 2) {
      beforeFailure?.call();
      throw const FileSystemException('injected publication failure');
    }
  }
}

class _FailSecondReceipt extends LifecycleIO {
  _FailSecondReceipt(fslib.FileSystem fs) : super(fs: fs);
  int receipts = 0;
  @override
  void before(String operation, String path) {
    if (operation == 'write' &&
        path.contains('authoring-receipts') &&
        ++receipts == 2) {
      throw const FileSystemException('injected receipt failure');
    }
  }
}

class _ChangeOnFirstRename extends LifecycleIO {
  _ChangeOnFirstRename(fslib.FileSystem fs, this.change) : super(fs: fs);
  final void Function() change;
  bool changed = false;
  @override
  void before(String operation, String path) {
    if (operation == 'rename' && !changed) {
      changed = true;
      change();
    }
  }
}

class _FailPublicationAndRestore extends LifecycleIO {
  _FailPublicationAndRestore(fslib.FileSystem fs) : super(fs: fs);
  int renames = 0;
  @override
  void before(String operation, String path) {
    if (operation == 'rename' && ++renames >= 2) {
      throw const FileSystemException('injected rename failure');
    }
  }
}
