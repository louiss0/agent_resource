import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('context', () {
      group('inject', () {
        late fslib.FileSystem fs;

        const templateDir = '/sandbox/state/context-templates';

        List<String> ctx() => const <String>[
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
          ...ctx(),
        ];

        Future<MambaExecutionResult> exec(List<String> extra) =>
            createExecutor(fileSystem: fs).fake().execute(command(extra));

        Map<String, dynamic> successJson(MambaExecutionResult result) {
          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having((value) => value.output, 'output', isNotNull),
          );
          return jsonDecode((result as MambaSuccessResult).output!)
              as Map<String, dynamic>;
        }

        void expectFailure(MambaExecutionResult result, String code) {
          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 4)
                .having((value) => value.message, 'message', contains(code))
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.error.phase,
                  'phase',
                  MambaExecutionPhase.run,
                )
                .having(
                  (value) => value.error.commandPath,
                  'command path',
                  <String>['agent_resource', 'context', 'inject'],
                ),
          );
        }

        void writeTemplate(String name, String content) {
          final file = fs.file('$templateDir/$name.md')
            ..parent.createSync(recursive: true);
          file.writeAsStringSync(content);
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

        test('plans default project-root injection without writing', () async {
          writeTemplate('styles', 'project rules\n');

          final envelope = successJson(
            await exec(const <String>[
              'styles',
              '--harness',
              'claude',
              '--format',
              'json',
              '--unattended',
            ]),
          );

          expect(envelope['command'], equals('context inject'));
          expect(envelope['outcome'], equals('planned'));
          final data = envelope['data'] as Map<String, dynamic>;
          expect(data['planId'], matches(RegExp(r'^pln_[a-f0-9]{64}$')));
          final targets = data['targets'] as List<dynamic>;
          expect(targets, hasLength(1));
          expect(
            targets.single,
            containsPair('path', '/sandbox/project/CLAUDE.md'),
          );
          expect(targets.single, containsPair('harnesses', ['claude']));
          expect(targets.single, containsPair('action', 'create'));
          expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
        });

        test(
          'refuses an unsupported variant for any selected harness',
          () async {
            writeTemplate('styles', 'project rules\n');

            expectFailure(
              await exec(const <String>[
                'styles',
                '--harness',
                'claude',
                '--harness',
                'codex',
                '--variant',
                'local',
                '--format',
                'json',
                '--unattended',
              ]),
              'UNSUPPORTED_CONTEXT_VARIANT',
            );
            expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
            expect(fs.file('/sandbox/project/AGENTS.md').existsSync(), isFalse);
          },
        );

        test('resolves a folder inside the project root', () async {
          writeTemplate('styles', 'project rules\n');
          fs.directory('/sandbox/project/lib/src').createSync(recursive: true);

          final envelope = successJson(
            await exec(const <String>[
              'styles',
              '--harness',
              'claude',
              '--folder',
              'lib/src',
              '--format',
              'json',
              '--unattended',
            ]),
          );
          final targets =
              (envelope['data'] as Map<String, dynamic>)['targets']
                  as List<dynamic>;
          expect(
            targets.single,
            containsPair('path', '/sandbox/project/lib/src/CLAUDE.md'),
          );
        });

        for (final testCase in <Map<String, String>>[
          {
            'label': 'outside the project root',
            'folder': '../outside',
            'code': 'FOLDER_OUTSIDE_PROJECT',
          },
          {
            'label': 'a missing directory',
            'folder': 'missing',
            'code': 'FOLDER_NOT_FOUND',
          },
          {
            'label': 'a regular file',
            'folder': 'notes.txt',
            'code': 'FOLDER_NOT_DIRECTORY',
          },
          {
            'label': 'a symlinked directory',
            'folder': 'linked',
            'code': 'SYMLINK_REFUSED',
          },
        ]) {
          test('refuses a folder ${testCase['label']}', () async {
            writeTemplate('styles', 'project rules\n');
            fs.file('/sandbox/project/notes.txt').writeAsStringSync('notes');
            fs.directory('/sandbox/outside').createSync(recursive: true);
            fs.link('/sandbox/project/linked').createSync('/sandbox/outside');

            expectFailure(
              await exec(<String>[
                'styles',
                '--harness',
                'claude',
                '--folder',
                testCase['folder']!,
                '--format',
                'json',
                '--unattended',
              ]),
              testCase['code']!,
            );
            expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
          });
        }

        test('refuses --folder with user scope', () async {
          writeTemplate('styles', 'project rules\n');

          expectFailure(
            await exec(const <String>[
              'styles',
              '--harness',
              'claude',
              '--scope',
              'user',
              '--folder',
              'lib',
              '--format',
              'json',
              '--unattended',
            ]),
            'FOLDER_SCOPE_CONFLICT',
          );
        });

        test('resolves user-global targets for all three harnesses', () async {
          writeTemplate('styles', 'project rules\n');

          final envelope = successJson(
            await exec(const <String>[
              'styles',
              '--harness',
              'claude',
              '--harness',
              'codex',
              '--harness',
              'pi',
              '--scope',
              'user',
              '--format',
              'json',
              '--unattended',
            ]),
          );
          final targets =
              (envelope['data'] as Map<String, dynamic>)['targets']
                  as List<dynamic>;
          expect(
            targets.map((target) => target['path']).toList(),
            equals(<String>[
              '/sandbox/home/claude/CLAUDE.md',
              '/sandbox/home/codex/AGENTS.md',
              '/sandbox/home/pi/AGENTS.md',
            ]),
          );
          expect(
            targets.map((target) => target['harnesses']).toList(),
            equals(<Object>[
              ['claude'],
              ['codex'],
              ['pi'],
            ]),
          );
        });

        test('deduplicates shared codex and pi target paths', () async {
          writeTemplate('styles', 'project rules\n');

          final envelope = successJson(
            await exec(const <String>[
              'styles',
              '--harness',
              'pi',
              '--harness',
              'codex',
              '--format',
              'json',
              '--unattended',
            ]),
          );
          final targets =
              (envelope['data'] as Map<String, dynamic>)['targets']
                  as List<dynamic>;
          expect(targets, hasLength(1));
          expect(
            targets.single,
            containsPair('path', '/sandbox/project/AGENTS.md'),
          );
          expect(targets.single, containsPair('harnesses', ['codex', 'pi']));
        });

        test('deduplicates shared override target paths', () async {
          writeTemplate('styles', 'project rules\n');

          final envelope = successJson(
            await exec(const <String>[
              'styles',
              '--harness',
              'codex',
              '--harness',
              'pi',
              '--variant',
              'override',
              '--format',
              'json',
              '--unattended',
            ]),
          );
          final targets =
              (envelope['data'] as Map<String, dynamic>)['targets']
                  as List<dynamic>;
          expect(targets, hasLength(1));
          expect(
            targets.single,
            containsPair('path', '/sandbox/project/AGENTS.override.md'),
          );
        });

        test('resolves an explicit override variant', () async {
          writeTemplate('styles', 'project rules\n');

          final envelope = successJson(
            await exec(const <String>[
              '--name',
              'styles',
              '--harness',
              'codex',
              '--variant',
              'override',
              '--format',
              'json',
              '--unattended',
            ]),
          );
          final targets =
              (envelope['data'] as Map<String, dynamic>)['targets']
                  as List<dynamic>;
          expect(
            targets.single,
            containsPair('path', '/sandbox/project/AGENTS.override.md'),
          );
        });
      });
    });
  });
}
