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
