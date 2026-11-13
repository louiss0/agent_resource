import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/prompt_read_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('prompt', () {
      group('inspect', () {
        late fslib.FileSystem fs;
        late fslib.Directory sandbox;

        setUp(() {
          fs = MemoryFileSystem(style: FileSystemStyle.posix);
          sandbox = fs.directory('/sandbox')..createSync();
        });

        tearDown(() async {
          if (sandbox.existsSync()) await sandbox.delete(recursive: true);
        });

        /// Writes a skill-backed Prompt package.
        void writePackage(String relative, String frontmatter) {
          final directory = fs.directory(fs.path.join(sandbox.path, relative))
            ..createSync(recursive: true);
          fs
              .file(fs.path.join(directory.path, 'SKILL.md'))
              .writeAsStringSync(frontmatter);
        }

        /// The inspected report of one path.
        Future<Map<String, Object?>> inspect(
          String relative, {
          List<String> args = const [],
        }) async {
          final result =
              await createExecutor(
                promptRead: PromptReadService(fileSystem: fs),
                fileSystem: fs,
              ).fake().execute([
                'prompt',
                'inspect',
                '--path',
                fs.path.join(sandbox.path, relative),
                '--format',
                'json',
                ...args,
              ]);
          if (result is MambaFailureResult) {
            fail('list failed: ${result.message}');
          }
          return Map<String, Object?>.from(
            jsonDecode((result as MambaSuccessResult).output!) as Map,
          );
        }

        test('reports the differing views of a mixed-control source', () async {
          writePackage('skills/manual', '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual
''');

          final report = await inspect('skills/manual');

          expect(report['form'], 'skill');
          expect(report['globalCompatibility'], 'incompatible');
          expect(report['placement'], 'unknown');
          final views = {
            for (final view in report['views']! as List)
              (view! as Map)['consumer']!: (view as Map)['classification'],
          };
          expect(views, {
            'claude': 'prompt',
            'codex': 'nonPrompt',
            'pi': 'prompt',
          });
        });

        test(
          'an arbitrary template without a target remains unclassified',
          () async {
            fs
                .file(fs.path.join(sandbox.path, 'template.md'))
                .writeAsStringSync(
                  '---\ndescription: Example.\n---\nprivate body\n',
                );
            final report = await inspect('template.md');
            final views = (report['views']! as List)
                .cast<Map<Object?, Object?>>();
            expect(views.map((view) => view['classification']).toSet(), {
              'unclassified',
            });
            expect(jsonEncode(report), isNot(contains('private body')));
          },
        );

        test('never discloses the instruction body', () async {
          writePackage('skills/manual', '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
The secret instruction body.
''');

          final result =
              await createExecutor(
                promptRead: PromptReadService(fileSystem: fs),
                fileSystem: fs,
              ).fake().execute([
                'prompt',
                'inspect',
                '--path',
                fs.path.join(sandbox.path, 'skills/manual'),
                '--format',
                'json',
              ]);

          expect(
            (result as MambaSuccessResult).output,
            isNot(contains('secret instruction body')),
          );
        });

        test(
          'reports an operational failure without a partial report',
          () async {
            final result =
                await createExecutor(
                  promptRead: PromptReadService(fileSystem: fs),
                  fileSystem: fs,
                ).fake().execute([
                  'prompt',
                  'inspect',
                  '--path',
                  fs.path.join(sandbox.path, 'missing'),
                  '--format',
                  'json',
                ]);

            expect(result, isA<MambaFailureResult>());
          },
        );

        test('rejects a missing path before any inspection', () async {
          final result = await createExecutor(
            promptRead: PromptReadService(fileSystem: fs),
            fileSystem: fs,
          ).fake().execute(['prompt', 'inspect']);

          expect(result, isA<MambaFailureResult>());
        });
      });

      group('validate', () {
        late fslib.FileSystem fs;
        late fslib.Directory sandbox;

        setUp(() {
          fs = MemoryFileSystem(style: FileSystemStyle.posix);
          sandbox = fs.directory('/sandbox')..createSync();
        });

        tearDown(() async {
          if (sandbox.existsSync()) await sandbox.delete(recursive: true);
        });

        void writePackage(String frontmatter) {
          final directory = fs.directory(
            fs.path.join(sandbox.path, 'skills/manual'),
          )..createSync(recursive: true);
          fs
              .file(fs.path.join(directory.path, 'SKILL.md'))
              .writeAsStringSync(frontmatter);
        }

        test('fails an invalid Prompt view with status two', () async {
          writePackage('''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual
''');
          fs
              .directory(fs.path.join(sandbox.path, 'skills/manual/references'))
              .createSync(recursive: true);
          fs
              .file(
                fs.path.join(sandbox.path, 'skills/manual/references/notes.md'),
              )
              .writeAsStringSync('Notes.\n');

          final result =
              await createExecutor(
                promptRead: PromptReadService(fileSystem: fs),
                fileSystem: fs,
              ).fake().execute([
                'prompt',
                'validate',
                '--path',
                fs.path.join(sandbox.path, 'skills/manual'),
                '--target',
                'claude',
              ]);

          expect(result, isA<MambaFailureResult>());
          expect((result as MambaFailureResult).exitCode, 2);
        });

        test('accepts a valid Prompt view of the selected harness', () async {
          writePackage('''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual
''');

          final result =
              await createExecutor(
                promptRead: PromptReadService(fileSystem: fs),
                fileSystem: fs,
              ).fake().execute([
                'prompt',
                'validate',
                '--path',
                fs.path.join(sandbox.path, 'skills/manual'),
                '--target',
                'claude',
              ]);

          expect(result, isA<MambaSuccessResult>());
        });

        test('refuses a harness that is not a Prompt of the source', () async {
          writePackage('''
---
name: manual
description: An ordinary skill.
---
# Manual
''');

          final result =
              await createExecutor(
                promptRead: PromptReadService(fileSystem: fs),
                fileSystem: fs,
              ).fake().execute([
                'prompt',
                'validate',
                '--path',
                fs.path.join(sandbox.path, 'skills/manual'),
                '--target',
                'claude',
              ]);

          expect(result, isA<MambaFailureResult>());
          expect((result as MambaFailureResult).exitCode, 2);
        });
      });

      group('list', () {
        late fslib.FileSystem fs;
        late fslib.Directory sandbox;
        late fslib.Directory project;
        late fslib.Directory home;

        setUp(() {
          fs = MemoryFileSystem(style: FileSystemStyle.posix);
          sandbox = fs.directory('/sandbox')..createSync();
          project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          home = fs.directory(fs.path.join(sandbox.path, 'home'))..createSync();
        });

        tearDown(() async {
          if (sandbox.existsSync()) await sandbox.delete(recursive: true);
        });

        /// Writes a skill-backed Prompt package under a native root.
        void writePackage(String root, String name, String frontmatter) {
          final directory = fs.directory(fs.path.join(root, name))
            ..createSync(recursive: true);
          fs
              .file(fs.path.join(directory.path, 'SKILL.md'))
              .writeAsStringSync(frontmatter);
        }

        Future<Map<String, Object?>> list({
          List<String> args = const [],
          String scope = 'project',
          String? cwd,
        }) async {
          final result =
              await createExecutor(
                promptRead: PromptReadService(fileSystem: fs),
                fileSystem: fs,
              ).fake().execute([
                'prompt',
                'list',
                '--scope',
                scope,
                '--cwd',
                '${cwd ?? project.path}${fs.path.separator}',
                '--project-root',
                '${project.path}${fs.path.separator}',
                '--home',
                '${home.path}${fs.path.separator}',
                '--format',
                'json',
                ...args,
              ]);
          if (result is MambaFailureResult) {
            fail('list failed: ${result.message}');
          }
          return Map<String, Object?>.from(
            jsonDecode((result as MambaSuccessResult).output!) as Map,
          );
        }

        test(
          'reports the native Prompt surfaces once per occurrence',
          () async {
            writePackage(
              fs.path.join(project.path, '.claude/skills'),
              'manual',
              '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual
''',
            );
            writePackage(
              fs.path.join(project.path, '.pi/skills'),
              'pi-manual',
              '''
---
name: pi-manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Pi manual
''',
            );
            final template = fs.directory(
              fs.path.join(project.path, '.pi/prompts'),
            )..createSync(recursive: true);
            fs
                .file(fs.path.join(template.path, 'assistant.md'))
                .writeAsStringSync('''---
description: A Pi template.
---
Assist the user.
''');

            final report = await list();
            final entries = (report['entries']! as List)
                .map((entry) => Map<String, Object?>.from(entry! as Map))
                .toList();

            expect(entries, hasLength(3));
            expect(entries.map((entry) => entry['destination']).toSet(), {
              'claude',
              'pi',
              'piTemplate',
            });
            final claude = entries.firstWhere(
              (entry) => entry['destination'] == 'claude',
            );
            expect(claude['management'], 'unmanaged');
            final views = {
              for (final view in claude['views']! as List)
                (view! as Map)['consumer']!: (view as Map)['classification'],
            };
            expect(views['claude'], 'prompt');
          },
        );

        test('user shared skill and Pi template retain native views', () async {
          writePackage(
            fs.path.join(home.path, '.agents/skills'),
            'shared',
            '---\nname: shared\ndescription: Shared prompt.\ndisable-model-invocation: true\n---\nsecret shared body\n',
          );
          final templates = fs.directory(
            fs.path.join(home.path, '.pi/agent/prompts'),
          )..createSync(recursive: true);
          fs
              .file(fs.path.join(templates.path, 'assist.md'))
              .writeAsStringSync(
                '---\ndescription: Assist.\n---\nsecret template body\n',
              );
          final report = await list(scope: 'user');
          final entries = (report['entries']! as List)
              .cast<Map<Object?, Object?>>();
          expect(entries.map((e) => e['destination']).toSet(), {
            'shared',
            'piTemplate',
          });
          expect(
            entries.every((e) => e['installationScope'] == 'user'),
            isTrue,
          );
          final template = entries.singleWhere(
            (e) => e['destination'] == 'piTemplate',
          );
          expect(
            template['views'],
            contains(
              isA<Map<Object?, Object?>>()
                  .having((v) => v['consumer'], 'consumer', 'pi')
                  .having(
                    (v) => v['classification'],
                    'classification',
                    'prompt',
                  ),
            ),
          );
          expect(jsonEncode(report), isNot(contains('secret')));
        });

        test('scans cwd ancestors only through project root', () async {
          final nested = fs.directory(fs.path.join(project.path, 'one/two'))
            ..createSync(recursive: true);
          for (final parent in [
            sandbox.path,
            project.path,
            fs.path.dirname(nested.path),
            nested.path,
          ]) {
            writePackage(
              fs.path.join(parent, '.agents/skills'),
              'prompt',
              '---\nname: prompt\ndescription: Prompt.\ndisable-model-invocation: true\n---\nBody\n',
            );
          }
          final report = await list(cwd: nested.path);
          final entries = (report['entries']! as List)
              .cast<Map<Object?, Object?>>();
          expect(entries.map((e) => e['root']).toSet(), {
            for (final parent in [
              project.path,
              fs.path.dirname(nested.path),
              nested.path,
            ])
              fs.path.join(parent, '.agents/skills'),
          });
        });

        Future<MambaFailureResult> failure() async {
          final result =
              await createExecutor(
                promptRead: PromptReadService(fileSystem: fs),
                fileSystem: fs,
              ).fake().execute([
                'prompt',
                'list',
                '--scope',
                'project',
                '--cwd',
                '${project.path}/',
                '--project-root',
                '${project.path}/',
                '--home',
                '${home.path}/',
                '--format',
                'json',
              ]);
          expect(result, isA<MambaFailureResult>());
          final rejected = result as MambaFailureResult;
          expect(rejected.output, isNull);
          return rejected;
        }

        test('refuses a linked native entry', () async {
          final root = fs.directory(
            fs.path.join(project.path, '.agents/skills'),
          )..createSync(recursive: true);
          final target = fs.directory(fs.path.join(sandbox.path, 'outside'))
            ..createSync();
          fs.link(fs.path.join(root.path, 'linked')).createSync(target.path);
          final result = await failure();
          expect(result.exitCode, 4);
          expect(result.message, contains('linked'));
          expect(target.listSync(), isEmpty);
        });

        test('refuses a linked skill marker', () async {
          final package = fs.directory(
            fs.path.join(project.path, '.agents/skills/linked'),
          )..createSync(recursive: true);
          final target = fs.file(fs.path.join(sandbox.path, 'marker'))
            ..writeAsStringSync('secret marker');
          fs
              .link(fs.path.join(package.path, 'SKILL.md'))
              .createSync(target.path);
          final result = await failure();
          expect(result.message.toLowerCase(), contains('link'));
          expect(target.readAsStringSync(), 'secret marker');
        });

        test('operational inspection failure aborts inventory', () async {
          writePackage(
            fs.path.join(project.path, '.agents/skills'),
            'large',
            '---\nname: large\ndescription: Large.\n---\nBody\n',
          );
          final package = fs.directory(
            fs.path.join(project.path, '.agents/skills/large'),
          );
          for (var i = 0; i < 1024; i++) {
            fs.file(fs.path.join(package.path, 'extra$i')).createSync();
          }
          final result = await failure();
          expect(result.message, contains('1024-entry'));
          expect(result.message, isNot(contains('INSPECTION_UNAVAILABLE')));
          expect(package.listSync(), hasLength(1025));
        });

        test('fails if a native root is a file', () async {
          final parent = fs.directory(fs.path.join(project.path, '.agents'))
            ..createSync();
          fs
              .file(fs.path.join(parent.path, 'skills'))
              .writeAsStringSync('sentinel');
          final result = await failure();
          expect(result.exitCode, 3);
          expect(result.message, contains('not a directory'));
          expect(
            fs.file(fs.path.join(parent.path, 'skills')).readAsStringSync(),
            'sentinel',
          );
        });

        test(
          'fails rather than emitting a partial report over the entry budget',
          () async {
            final root = fs.directory(
              fs.path.join(project.path, '.agents/skills'),
            )..createSync(recursive: true);
            for (var i = 0; i < 10001; i++) {
              fs.file(fs.path.join(root.path, 'entry$i')).createSync();
            }
            final result = await failure();
            expect(result.exitCode, 3);
            expect(result.message, contains('10,000-entry budget'));
            expect(root.listSync(), hasLength(10001));
          },
        );

        test(
          'target filters applicable views without ordinary Skill fallback',
          () async {
            final root = fs.path.join(project.path, '.agents/skills');
            writePackage(
              root,
              'mixed',
              '---\nname: mixed\ndescription: Mixed.\ndisable-model-invocation: true\n---\nRead scripts/tool.py\n',
            );
            writePackage(
              root,
              'ordinary',
              '---\nname: ordinary\ndescription: Ordinary.\n---\nBody\n',
            );
            final claude = await list(args: ['--target', 'claude']);
            final entries = (claude['entries']! as List)
                .cast<Map<Object?, Object?>>();
            expect(entries, hasLength(1));
            expect(entries.single['path'], endsWith('/mixed'));
            expect(entries.single['placement'], 'project');
            final views = (entries.single['views']! as List)
                .cast<Map<Object?, Object?>>();
            expect(
              views.singleWhere((view) => view['consumer'] == 'claude'),
              containsPair('valid', false),
            );
            expect(
              views.singleWhere((view) => view['consumer'] == 'codex'),
              containsPair('valid', true),
            );
            final codex = await list(args: ['--target', 'codex']);
            expect(codex['entries'], isEmpty);
            expect(jsonEncode(claude), isNot(contains('Read scripts/tool.py')));
          },
        );

        test(
          'refuses a linked native root ancestor before reading descendants',
          () async {
            final outside = fs.directory('/sandbox/outside')..createSync();
            fs
                .link(fs.path.join(project.path, '.agents'))
                .createSync(outside.path);
            final result = await failure();
            expect(result.exitCode, 4);
            expect(result.message, contains('linked'));
            expect(outside.listSync(), isEmpty);
          },
        );

        test(
          'missing-root absence confirmation shares the entry budget',
          () async {
            final parent = fs.directory(fs.path.join(project.path, '.claude'))
              ..createSync();
            for (var i = 0; i < 10001; i++) {
              fs.file(fs.path.join(parent.path, 'unrelated$i')).createSync();
            }
            final result = await failure();
            expect(result.exitCode, 3);
            expect(result.message, contains('10,000-entry budget'));
            expect(parent.listSync(), hasLength(10001));
            expect(
              fs.directory(fs.path.join(parent.path, 'skills')).existsSync(),
              isFalse,
            );
          },
        );

        test('never writes a management artifact', () async {
          writePackage(
            fs.path.join(project.path, '.claude/skills'),
            'manual',
            '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual
''',
          );
          final before = project.listSync(recursive: true).length;

          await list();

          expect(project.listSync(recursive: true).length, before);
          expect(
            fs
                .directory(fs.path.join(project.path, '.agent-resource'))
                .existsSync(),
            isFalse,
          );
        });
      });

      test('native input IO failure aborts Prompt and Skill commands without writes', () async {
        var active = false;
        final operations = <FileSystemOp>[];
        final guarded = MemoryFileSystem(
          style: FileSystemStyle.posix,
          opHandle: (context, operation) {
            if (!active) return;
            operations.add(operation);
            if (operation == FileSystemOp.open &&
                context == '/project/.agents/skills/demo/agents/openai.yaml') {
              throw FileSystemException(
                'injected native read failure',
                context,
              );
            }
          },
        );
        guarded.directory('/home').createSync();
        guarded
            .directory('/project/.agents/skills/demo/agents')
            .createSync(recursive: true);
        final marker = guarded.file('/project/.agents/skills/demo/SKILL.md')
          ..writeAsStringSync(
            '---\nname: demo\ndescription: Demo.\ndisable-model-invocation: true\n---\nsecret body\n',
          );
        final sidecar = guarded.file(
          '/project/.agents/skills/demo/agents/openai.yaml',
        )..writeAsStringSync('policy: {}');
        final before = {
          for (final file in [marker, sidecar])
            file.path: file.readAsBytesSync(),
        };
        final context = [
          '--scope',
          'project',
          '--cwd',
          '/project/',
          '--project-root',
          '/project/',
          '--home',
          '/home/',
          '--format',
          'json',
        ];
        for (final args in [
          [
            'prompt',
            'inspect',
            '--path',
            '/project/.agents/skills/demo',
            '--format',
            'json',
          ],
          [
            'prompt',
            'validate',
            '--path',
            '/project/.agents/skills/demo',
            '--target',
            'claude',
          ],
          ['prompt', 'list', ...context],
          ['skill', 'list', ...context],
        ]) {
          operations.clear();
          active = true;
          final result = await createExecutor(fileSystem: guarded)
              .fake()
              .execute(args);
          active = false;
          expect(result, isA<MambaFailureResult>(), reason: '$args');
          final failure = result as MambaFailureResult;
          expect(failure.output, isNull);
          expect(failure.message, contains('injected native read failure'));
          expect(failure.message, isNot(contains('secret body')));
          expect(operations, isNot(contains(FileSystemOp.write)));
          expect(operations, isNot(contains(FileSystemOp.create)));
          for (final entry in before.entries) {
            expect(guarded.file(entry.key).readAsBytesSync(), entry.value);
          }
          expect(
            guarded.directory('/project/.agent-resource').existsSync(),
            isFalse,
          );
        }
      });

      test('Pi template validation is recognized but installation stays unsupported', () async {
        final fs = MemoryFileSystem(style: FileSystemStyle.posix);
        fs.file('/assist.md').writeAsStringSync(r'Assist $1.');
        final result = await createExecutor(fileSystem: fs).fake().execute([
          'prompt',
          'validate',
          '--path',
          '/assist.md',
          '--target',
          'pi',
          '--format',
          'json',
        ]);
        expect(result, isA<MambaSuccessResult>());
        final report =
            jsonDecode((result as MambaSuccessResult).output!) as Map;
        final pi = (report['views'] as List)
            .cast<Map<Object?, Object?>>()
            .singleWhere((view) => view['consumer'] == 'pi');
        expect(pi['classification'], 'prompt');
        expect(pi['valid'], true);
        expect(pi['installationSupported'], false);
        expect(report['placement'], 'unknown');
      });

      test(
        'invalid Prompt validation retains JSON diagnostics without content',
        () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          fs.directory('/demo').createSync();
          fs
              .file('/demo/SKILL.md')
              .writeAsStringSync(
                '---\nname: demo\ndescription: Demo.\ndisable-model-invocation: true\n---\nSECRET BODY scripts/tool.py\n',
              );
          for (final format in ['json', 'text']) {
            final result = await createExecutor(fileSystem: fs).fake().execute([
              'prompt',
              'validate',
              '--path',
              '/demo',
              '--target',
              'claude',
              '--format',
              format,
            ]);
            expect(result, isA<MambaFailureResult>());
            final failure = result as MambaFailureResult;
            expect(failure.exitCode, 2);
            expect(failure.output, isNull);
            expect(failure.message, isNot(contains('SECRET BODY')));
            expect(failure.message, contains('RESOURCE_REFERENCE'));
            if (format == 'json') {
              final report = jsonDecode(failure.message) as Map;
              final views = (report['views'] as List)
                  .cast<Map<Object?, Object?>>();
              final claude = views.singleWhere(
                (view) => view['consumer'] == 'claude',
              );
              expect(claude['classification'], 'prompt');
              expect(claude['valid'], false);
              expect(
                claude['diagnostics'],
                contains(
                  isA<Map<Object?, Object?>>()
                      .having(
                        (diagnostic) => diagnostic['code'],
                        'code',
                        'RESOURCE_REFERENCE',
                      )
                      .having((diagnostic) => diagnostic['line'], 'line', 6),
                ),
              );
            }
          }
        },
      );

      test('ownership ledger is read once for multiple native occurrences', () async {
        var reads = 0;
        final fs = MemoryFileSystem(
          style: FileSystemStyle.posix,
          opHandle: (context, operation) {
            if (context == '/project/.agent-resource/installations.json' &&
                operation == FileSystemOp.open) {
              reads++;
            }
          },
        );
        fs.directory('/home').createSync();
        fs.directory('/project/.agent-resource').createSync(recursive: true);
        final ledger = fs.file('/project/.agent-resource/installations.json')
          ..writeAsStringSync('{"schemaVersion":1,"installations":[]}');
        for (final name in ['one', 'two']) {
          fs
              .directory('/project/.agents/skills/$name')
              .createSync(recursive: true);
          fs
              .file('/project/.agents/skills/$name/SKILL.md')
              .writeAsStringSync(
                '---\nname: $name\ndescription: Example.\ndisable-model-invocation: true\n---\nBody\n',
              );
        }
        reads = 0;
        final result = await createExecutor(fileSystem: fs).fake().execute([
          'prompt',
          'list',
          '--scope',
          'project',
          '--cwd',
          '/project/',
          '--project-root',
          '/project/',
          '--home',
          '/home/',
          '--format',
          'json',
        ]);
        expect(result, isA<MambaSuccessResult>());
        final report =
            jsonDecode((result as MambaSuccessResult).output!) as Map;
        expect(report['entries'], hasLength(2));
        expect(reads, 1);
        expect(
          ledger.readAsStringSync(),
          '{"schemaVersion":1,"installations":[]}',
        );
      });

      test('the registered help lists the read-only commands', () async {
        final result = await createExecutor().fake().execute([
          'prompt',
          '--help',
        ]);

        expect(result, isA<MambaSuccessResult>());
        final output = (result as MambaSuccessResult).output!;
        expect(output, contains('inspect'));
        expect(output, contains('validate'));
        expect(output, contains('list'));
      });
    });
  });
}
