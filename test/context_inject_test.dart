import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/context_inject.dart';
import 'package:agent_resource/src/context/context_types.dart';
import 'package:agent_resource/src/services/context_injection_service.dart';
import 'package:agent_resource/src/services/context_template_service.dart';
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

        group('apply', () {
          Future<String> plannedId(List<String> extra) async {
            final envelope = successJson(
              await exec(<String>[
                ...extra,
                '--format',
                'json',
                '--unattended',
              ]),
            );
            return (envelope['data'] as Map<String, dynamic>)['planId']!
                as String;
          }

          Future<Map<String, dynamic>> publish(
            String planId,
            List<String> extra,
          ) async => successJson(
            await exec(<String>[
              ...extra,
              '--apply',
              '--plan-id',
              planId,
              '--yes',
              '--format',
              'json',
              '--unattended',
            ]),
          );

          test('creates a raw markdown target with a receipt', () async {
            writeTemplate('styles', 'rules\n');
            final planId = await plannedId(const <String>[
              'styles',
              '--harness',
              'claude',
            ]);

            final envelope = await publish(planId, const <String>[
              'styles',
              '--harness',
              'claude',
            ]);
            expect(envelope['outcome'], equals('published'));
            final targets =
                (envelope['data'] as Map<String, dynamic>)['targets']
                    as List<dynamic>;
            expect(
              targets.single,
              containsPair('receiptId', startsWith('rcp_')),
            );
            expect(
              fs.file('/sandbox/project/CLAUDE.md').readAsStringSync(),
              'rules\n',
            );
            expect(
              fs.file('/sandbox/state/installations.json').existsSync(),
              isFalse,
            );
          });

          test('saves recovery evidence when appending', () async {
            writeTemplate('styles', 'new rules');
            fs
                .file('/sandbox/project/CLAUDE.md')
                .writeAsStringSync('old rules\n');
            final planId = await plannedId(const <String>[
              'styles',
              '--harness',
              'claude',
            ]);

            final envelope = await publish(planId, const <String>[
              'styles',
              '--harness',
              'claude',
            ]);
            final target =
                ((envelope['data'] as Map<String, dynamic>)['targets']
                            as List<dynamic>)
                        .single
                    as Map<String, dynamic>;
            expect(
              fs.file('/sandbox/project/CLAUDE.md').readAsStringSync(),
              'old rules\n\nnew rules\n',
            );
            final recoveryPath = target['recoveryPath'] as String;
            expect(fs.file(recoveryPath).readAsStringSync(), 'old rules\n');
            final receiptId = target['receiptId'] as String;
            final receipt = jsonDecode(
              fs
                  .file('/sandbox/state/authoring-receipts/$receiptId.json')
                  .readAsStringSync(),
            ) as Map<String, dynamic>;
            expect(receipt['operation'], equals('contextInject'));
          });

          test('replaces a target and keeps the previous bytes', () async {
            writeTemplate('styles', 'fresh rules');
            fs
                .file('/sandbox/project/CLAUDE.md')
                .writeAsStringSync('old rules\n');
            final planId = await plannedId(const <String>[
              'styles',
              '--harness',
              'claude',
              '--replace',
            ]);

            final envelope = await publish(planId, const <String>[
              'styles',
              '--harness',
              'claude',
              '--replace',
            ]);
            expect(
              fs.file('/sandbox/project/CLAUDE.md').readAsStringSync(),
              'fresh rules\n',
            );
            final target =
                ((envelope['data'] as Map<String, dynamic>)['targets']
                            as List<dynamic>)
                        .single
                    as Map<String, dynamic>;
            expect(
              fs.file(target['recoveryPath'] as String).readAsStringSync(),
              'old rules\n',
            );
          });

          test('refuses a stale plan id', () async {
            writeTemplate('styles', 'rules\n');

            expectFailure(
              await exec(const <String>[
                'styles',
                '--harness',
                'claude',
                '--apply',
                '--plan-id',
                'pln_0000000000000000000000000000000000000000000000000000000000000000',
                '--yes',
                '--format',
                'json',
                '--unattended',
              ]),
              'STALE_CONTEXT_PLAN',
            );
            expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
          });

          test('refuses a stale plan after template drift', () async {
            writeTemplate('styles', 'rules\n');
            final planId = await plannedId(const <String>[
              'styles',
              '--harness',
              'claude',
            ]);
            writeTemplate('styles', 'changed rules\n');

            expectFailure(
              await exec(<String>[
                'styles',
                '--harness',
                'claude',
                '--apply',
                '--plan-id',
                planId,
                '--yes',
                '--format',
                'json',
                '--unattended',
              ]),
              'STALE_CONTEXT_PLAN',
            );
            expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
          });

          test('refuses a stale plan after target drift', () async {
            writeTemplate('styles', 'rules\n');
            fs.file('/sandbox/project/CLAUDE.md').writeAsStringSync('old\n');
            final planId = await plannedId(const <String>[
              'styles',
              '--harness',
              'claude',
            ]);
            fs
                .file('/sandbox/project/CLAUDE.md')
                .writeAsStringSync('changed\n');

            expectFailure(
              await exec(<String>[
                'styles',
                '--harness',
                'claude',
                '--apply',
                '--plan-id',
                planId,
                '--yes',
                '--format',
                'json',
                '--unattended',
              ]),
              'STALE_CONTEXT_PLAN',
            );
            expect(
              fs.file('/sandbox/project/CLAUDE.md').readAsStringSync(),
              'changed\n',
            );
          });

          test('requires --yes in unattended mode', () async {
            writeTemplate('styles', 'rules\n');
            final planId = await plannedId(const <String>[
              'styles',
              '--harness',
              'claude',
            ]);

            expectFailure(
              await exec(<String>[
                'styles',
                '--harness',
                'claude',
                '--apply',
                '--plan-id',
                planId,
                '--format',
                'json',
                '--unattended',
              ]),
              'MISSING_APPROVAL',
            );
            expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
          });
        });

        group('advisory diagnostics', () {
          List<Object?> diagnosticCodes(Map<String, dynamic> envelope) =>
              (envelope['diagnostics'] as List<dynamic>)
                  .map((diagnostic) => diagnostic['code'])
                  .toList();

          test(
            'warns when a project codex target exceeds 32768 bytes',
            () async {
              writeTemplate('big', '${'x' * 32769}\n');

              final envelope = successJson(
                await exec(const <String>[
                  'big',
                  '--harness',
                  'codex',
                  '--format',
                  'json',
                  '--unattended',
                ]),
              );
              expect(envelope['outcome'], equals('planned'));
              expect(
                diagnosticCodes(envelope),
                contains('CODEX_BYTE_BUDGET_WARNING'),
              );
              final diagnostic =
                  (envelope['diagnostics'] as List<dynamic>).first
                      as Map<String, dynamic>;
              expect(diagnostic['severity'], equals('warning'));
              expect(diagnostic['category'], equals('advisory'));
              expect(diagnostic, containsPair('field', isNotNull));
              expect(diagnostic, containsPair('message', isNotNull));
            },
          );

          test('warns when an override shadows a target AGENTS.md', () async {
            writeTemplate('styles', 'rules\n');
            fs
                .file('/sandbox/project/AGENTS.override.md')
                .writeAsStringSync('override\n');

            final envelope = successJson(
              await exec(const <String>[
                'styles',
                '--harness',
                'codex',
                '--format',
                'json',
                '--unattended',
              ]),
            );
            expect(
              diagnosticCodes(envelope),
              contains('CONTEXT_SHADOWING_WARNING'),
            );
          });

          test(
            'notes AGENTS.md and CLAUDE.md shadowing in one folder',
            () async {
              writeTemplate('styles', 'rules\n');

              final envelope = successJson(
                await exec(const <String>[
                  'styles',
                  '--harness',
                  'claude',
                  '--harness',
                  'codex',
                  '--format',
                  'json',
                  '--unattended',
                ]),
              );
              expect(
                diagnosticCodes(envelope),
                contains('CONTEXT_SHADOWING_WARNING'),
              );
            },
          );
        });

        group('interactive selection', () {
          late ContextInjectionService injection;
          late ContextTemplateService templates;

          Future<MambaExecutionResult> execWith(
            ContextInjectCommand injected,
            List<String> extra,
          ) => createExecutor(
            fileSystem: fs,
            contextInject: injected,
          ).fake().execute(command(extra));

          setUp(() {
            injection = ContextInjectionService(fileSystem: fs);
            templates = ContextTemplateService(fileSystem: fs);
          });

          test('requires a harness in unattended mode', () async {
            writeTemplate('styles', 'rules\n');

            expectFailure(
              await exec(const <String>[
                'styles',
                '--format',
                'json',
                '--unattended',
              ]),
              'MISSING_TARGET_HARNESS',
            );
          });

          test('requires a template name in unattended mode', () async {
            expectFailure(
              await exec(const <String>[
                '--harness',
                'claude',
                '--format',
                'json',
                '--unattended',
              ]),
              'MISSING_TEMPLATE_NAME',
            );
          });

          test('refuses both positional and named template names', () async {
            writeTemplate('styles', 'rules\n');

            expectFailure(
              await exec(const <String>[
                'styles',
                '--name',
                'styles',
                '--harness',
                'claude',
                '--format',
                'json',
                '--unattended',
              ]),
              'AMBIGUOUS_TEMPLATE_NAME',
            );
          });

          test(
            'uses the selected harness and template interactively',
            () async {
              writeTemplate('styles', 'rules\n');
              final injected = ContextInjectCommand(
                injection,
                templates,
                selectHarnesses: () async => <ContextHarness>[
                  ContextHarness.pi,
                ],
                selectTemplate: (names) async => 'styles',
                hasTerminal: () => true,
              );

              final result = await execWith(injected, const <String>[
                '--interactive',
              ]);
              expect(result, isA<MambaSuccessResult>());
              expect(
                (result as MambaSuccessResult).output,
                contains('planned'),
              );
            },
          );

          test('refuses a cancelled harness selection', () async {
            writeTemplate('styles', 'rules\n');
            final injected = ContextInjectCommand(
              injection,
              templates,
              selectHarnesses: () async => null,
              hasTerminal: () => true,
            );

            final result = await execWith(injected, const <String>[
              'styles',
              '--interactive',
            ]);
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'exit code', 7)
                  .having(
                    (value) => value.message,
                    'message',
                    contains('CANCELLED'),
                  ),
            );
          });

          test('refuses a cancelled apply confirmation', () async {
            writeTemplate('styles', 'rules\n');
            final injected = ContextInjectCommand(
              injection,
              templates,
              confirm: () async => false,
              hasTerminal: () => true,
            );

            final result = await execWith(injected, const <String>[
              'styles',
              '--harness',
              'claude',
              '--apply',
              '--interactive',
            ]);
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'exit code', 7)
                  .having(
                    (value) => value.message,
                    'message',
                    contains('CANCELLED'),
                  ),
            );
            expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
          });
        });

        group('plan identity', () {
          Future<String> planId(List<String> extra) async {
            final envelope = successJson(
              await exec(<String>[
                ...extra,
                '--format',
                'json',
                '--unattended',
              ]),
            );
            return (envelope['data'] as Map<String, dynamic>)['planId']!
                as String;
          }

          test('binds the source template and every target state', () async {
            writeTemplate('styles', 'rules\n');
            fs.file('/sandbox/project/CLAUDE.md').writeAsStringSync('old\n');
            fs.file('/sandbox/project/AGENTS.md').writeAsStringSync('base\n');

            final baseline = await planId(const <String>[
              'styles',
              '--harness',
              'codex',
            ]);

            fs.file('/sandbox/project/AGENTS.md').writeAsStringSync('new\n');
            final targetDrift = await planId(const <String>[
              'styles',
              '--harness',
              'codex',
            ]);
            expect(targetDrift, isNot(equals(baseline)));

            fs.file('/sandbox/project/AGENTS.md').writeAsStringSync('base\n');
            writeTemplate('styles', 'changed rules\n');
            final sourceDrift = await planId(const <String>[
              'styles',
              '--harness',
              'codex',
            ]);
            expect(sourceDrift, isNot(equals(baseline)));
          });

          test('writes nothing with --dry-run', () async {
            writeTemplate('styles', 'rules\n');

            final envelope = successJson(
              await exec(const <String>[
                'styles',
                '--harness',
                'claude',
                '--dry-run',
                '--format',
                'json',
                '--unattended',
              ]),
            );
            expect(envelope['outcome'], equals('planned'));
            expect(fs.file('/sandbox/project/CLAUDE.md').existsSync(), isFalse);
          });
        });

        group('combine', () {
          const normalizedAppendDigest =
              '8bc1a592ae290cab2854458e4d42d1f9f850637c2b2a89be4571f56c4386b775';
          const freshDigest =
              '3f84e8942f9245cba2bd7ae643ec53f933b16f07c0c74a4737eba47e2c49584d';
          const emptyDigest =
              'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

          List<dynamic> plannedTargets(Map<String, dynamic> envelope) =>
              (envelope['data'] as Map<String, dynamic>)['targets']
                  as List<dynamic>;

          test('normalizes a single blank line when appending', () async {
            writeTemplate('styles', '\nnew rules');
            fs
                .file('/sandbox/project/CLAUDE.md')
                .writeAsStringSync('old rules\n\n\n');

            final targets = plannedTargets(
              successJson(
                await exec(const <String>[
                  'styles',
                  '--harness',
                  'claude',
                  '--format',
                  'json',
                  '--unattended',
                ]),
              ),
            );
            expect(targets.single, containsPair('action', 'append'));
            expect(targets.single, containsPair('proposedByteLength', 21));
            expect(
              targets.single,
              containsPair('proposedSha256', normalizedAppendDigest),
            );
          });

          test('adds one trailing newline when creating', () async {
            writeTemplate('styles', 'fresh rules');

            final targets = plannedTargets(
              successJson(
                await exec(const <String>[
                  'styles',
                  '--harness',
                  'claude',
                  '--format',
                  'json',
                  '--unattended',
                ]),
              ),
            );
            expect(targets.single, containsPair('action', 'create'));
            expect(targets.single, containsPair('proposedByteLength', 12));
            expect(targets.single, containsPair('proposedSha256', freshDigest));
          });

          test(
            'replaces the whole target with normalized template bytes',
            () async {
              writeTemplate('styles', 'fresh rules');
              fs
                  .file('/sandbox/project/CLAUDE.md')
                  .writeAsStringSync('stale rules\n');

              final targets = plannedTargets(
                successJson(
                  await exec(const <String>[
                    'styles',
                    '--harness',
                    'claude',
                    '--replace',
                    '--format',
                    'json',
                    '--unattended',
                  ]),
                ),
              );
              expect(targets.single, containsPair('action', 'replace'));
              expect(targets.single, containsPair('proposedByteLength', 12));
              expect(
                targets.single,
                containsPair('proposedSha256', freshDigest),
              );
            },
          );

          test('plans an empty template for create and replace', () async {
            writeTemplate('styles', '');

            final created = plannedTargets(
              successJson(
                await exec(const <String>[
                  'styles',
                  '--harness',
                  'claude',
                  '--format',
                  'json',
                  '--unattended',
                ]),
              ),
            );
            expect(created.single, containsPair('proposedByteLength', 0));
            expect(created.single, containsPair('proposedSha256', emptyDigest));

            fs.file('/sandbox/project/CLAUDE.md').writeAsStringSync('old\n');
            final replaced = plannedTargets(
              successJson(
                await exec(const <String>[
                  'styles',
                  '--harness',
                  'claude',
                  '--replace',
                  '--format',
                  'json',
                  '--unattended',
                ]),
              ),
            );
            expect(replaced.single, containsPair('proposedByteLength', 0));
          });

          test(
            'refuses appending an empty template to a non-empty target',
            () async {
              writeTemplate('styles', '');
              fs
                  .file('/sandbox/project/CLAUDE.md')
                  .writeAsStringSync('old rules\n');

              expectFailure(
                await exec(const <String>[
                  'styles',
                  '--harness',
                  'claude',
                  '--format',
                  'json',
                  '--unattended',
                ]),
                'EMPTY_TEMPLATE_APPEND_REFUSED',
              );
            },
          );

          test(
            'appends to a zero-byte target without a blank prefix',
            () async {
              writeTemplate('styles', 'fresh rules');
              fs.file('/sandbox/project/CLAUDE.md').writeAsStringSync('');

              final targets = plannedTargets(
                successJson(
                  await exec(const <String>[
                    'styles',
                    '--harness',
                    'claude',
                    '--format',
                    'json',
                    '--unattended',
                  ]),
                ),
              );
              expect(targets.single, containsPair('action', 'append'));
              expect(targets.single, containsPair('proposedByteLength', 12));
              expect(
                targets.single,
                containsPair('proposedSha256', freshDigest),
              );
            },
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
