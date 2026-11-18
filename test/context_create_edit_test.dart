import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/authoring/editor_process.dart';
import 'package:agent_resource/src/services/context_template_authoring_service.dart';
import 'package:agent_resource/src/services/editor_interaction_service.dart';
import 'package:agent_resource/src/services/instruction_draft_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('context', () {
      late fslib.FileSystem fs;

      const templateDir = '/sandbox/state/context-templates';
      const draftsDir = '/sandbox/state/instruction-drafts';
      final planIdPattern = RegExp(r'^pln_[a-f0-9]{64}$');

      List<String> ctx() => const <String>[
        '--cwd',
        '/sandbox/project/',
        '--home',
        '/sandbox/home/',
        '--state-dir',
        '/sandbox/state/',
      ];

      List<String> command(String verb, List<String> extra) => <String>[
        'context',
        verb,
        ...extra,
        ...ctx(),
      ];

      Future<MambaExecutionResult> exec(
        List<String> tokens, {
        ContextTemplateAuthoringService? authoring,
        List<int>? standardInput,
      }) => createExecutor(fileSystem: fs, contextAuthoring: authoring)
          .fake(
            standardInput: standardInput == null
                ? null
                : ProcessedStandardInput(standardInput),
          )
          .execute(tokens);

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

      void expectFailure(
        MambaExecutionResult result, {
        required String code,
        required String verb,
        int exitCode = 4,
      }) {
        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', exitCode)
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
                <String>['agent_resource', 'context', verb],
              ),
        );
      }

      void writeTemplate(String name, String content) {
        final file = fs.file('$templateDir/$name.md')
          ..parent.createSync(recursive: true);
        file.writeAsStringSync(content);
      }

      ContextTemplateAuthoringService authoring({
        bool terminal = false,
        Future<String?> Function(String label)? ask,
        Future<String?> Function(List<String> options)? select,
        Future<bool> Function(String summary)? confirm,
        EditorProcessRunner? processRunner,
        EditorRecoveryPrompt? recover,
        LifecycleIO? io,
      }) => ContextTemplateAuthoringService(
        fileSystem: fs,
        io: io,
        terminal: () => terminal,
        ask: ask,
        select: select,
        confirm: confirm,
        editor: EditorInteractionService(
          drafts: InstructionDraftService(
            fileSystem: fs,
            privacy: (_) {},
            verifier: (_) {},
          ),
          processRunner:
              processRunner ??
              (request) async {
                fs.file(request.arguments.last).writeAsStringSync('Edited.\n');
                return const EditorProcessOutcome(started: true, exitCode: 0);
              },
          environment: const EditorSessionEnvironment(
            hasTerminal: true,
            hasDisplay: true,
          ),
          acknowledge: (request) async => true,
          recover: recover ?? (request) async => const EditorRecoveryCancel(),
          executables: const _FakeResolver(),
          fileSystem: fs,
        ),
      );

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

      group('create', () {
        test('plans an empty template without writing it', () async {
          final envelope = successJson(
            await exec(
              command('create', ['alpha', '--empty', '--format', 'json']),
            ),
          );
          final data = envelope['data'] as Map<String, dynamic>;

          expect(envelope['schemaVersion'], equals(1));
          expect(envelope['command'], equals('context create'));
          expect(envelope['outcome'], equals('planned'));
          expect(data['planId'], matches(planIdPattern));
          expect(data['name'], equals('alpha'));
          expect(data['path'], equals('$templateDir/alpha.md'));
          expect(data['byteLength'], equals(0));
          expect(data['isEmpty'], isTrue);
          expect(data['sha256'], isA<String>());
          expect(envelope['diagnostics'], isEmpty);
          expect(fs.file('$templateDir/alpha.md').existsSync(), isFalse);
          expect(fs.directory(draftsDir).existsSync(), isFalse);
        });

        test('publishes a 0-byte template without a draft or editor', () async {
          final envelope = successJson(
            await exec(
              command('create', [
                'alpha',
                '--empty',
                '--apply',
                '--yes',
                '--format',
                'json',
              ]),
            ),
          );

          expect(envelope['command'], equals('context create'));
          expect(envelope['outcome'], equals('published'));
          final template = fs.file('$templateDir/alpha.md');
          expect(template.existsSync(), isTrue);
          expect(template.readAsBytesSync(), isEmpty);
          expect(fs.directory(draftsDir).existsSync(), isFalse);
          expect(
            fs
                .directory('/sandbox/state/authoring-receipts')
                .listSync()
                .where((entity) => entity.path.endsWith('.json')),
            isNotEmpty,
          );
        });

        test('renders a deterministic text envelope with a plan id', () async {
          final result = await exec(
            command('create', ['alpha', '--empty', '--show-instructions']),
          );

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  allOf(
                    contains('context create: planned'),
                    contains('planId: pln_'),
                    contains('content:'),
                    contains('diagnostics:'),
                  ),
                ),
          );
        });

        for (final invalid in <String>[
          '../escape',
          'alpha.md',
          'Alpha',
          'con',
          'a' * 65,
        ]) {
          test('refuses the non-portable name $invalid', () async {
            expectFailure(
              await exec(
                command('create', [invalid, '--empty', '--format', 'json']),
              ),
              code: 'INVALID_TEMPLATE_NAME',
              verb: 'create',
            );
          });
        }

        test('refuses both positional and --name', () async {
          expectFailure(
            await exec(
              command('create', [
                'alpha',
                '--name',
                'alpha',
                '--empty',
                '--format',
                'json',
              ]),
            ),
            code: 'AMBIGUOUS_TEMPLATE_NAME',
            verb: 'create',
          );
        });

        test('refuses a missing name in unattended mode', () async {
          expectFailure(
            await exec(command('create', ['--empty', '--format', 'json'])),
            code: 'MISSING_TEMPLATE_NAME',
            verb: 'create',
          );
        });

        test('prompts for the name on an interactive session', () async {
          final asked = <String>[];
          final service = authoring(
            terminal: true,
            ask: (label) async {
              asked.add(label);
              return 'beta';
            },
          );

          final result = await exec(
            command('create', ['--empty', '--interactive']),
            authoring: service,
          );

          expect(asked, hasLength(1));
          expect(
            result,
            isA<MambaSuccessResult>().having(
              (value) => value.output,
              'output',
              allOf(contains('name: beta'), contains('pln_')),
            ),
          );
        });

        test('refuses --empty with body and editor flags', () async {
          for (final flag in <String>[
            '--body-text',
            '--body-stdin',
            '--editor',
          ]) {
            final result = await exec(
              command('create', <String>[
                'alpha',
                '--empty',
                flag,
                if (flag == '--body-text') 'body',
                if (flag == '--editor') 'code --wait',
              ]),
            );
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.message, 'message', isNotEmpty)
                  .having((value) => value.output, 'output', isNull)
                  .having(
                    (value) => value.error.phase,
                    'phase',
                    MambaExecutionPhase.parse,
                  )
                  .having(
                    (value) => value.error.commandPath,
                    'command path',
                    <String>['agent_resource', 'context', 'create'],
                  ),
              reason: 'Flag $flag must conflict with --empty.',
            );
          }
          final fileResult = await exec(
            command('create', [
              'alpha',
              '--empty',
              '--body-file',
              '/sandbox/home/body.md',
            ]),
          );
          expect(
            fileResult,
            isA<MambaFailureResult>().having(
              (value) => value.error.phase,
              'phase',
              MambaExecutionPhase.parse,
            ),
          );
        });

        test('publishes literal body flags without an editor', () async {
          final fsBody = fs.file('/sandbox/home/body.md')
            ..writeAsStringSync('file body\n');
          expect(fsBody.existsSync(), isTrue);

          final envelope = successJson(
            await exec(
              command('create', [
                'alpha',
                '--body-file',
                '/sandbox/home/body.md',
                '--apply',
                '--yes',
                '--format',
                'json',
              ]),
            ),
          );

          expect(envelope['outcome'], equals('published'));
          expect(
            fs.file('$templateDir/alpha.md').readAsStringSync(),
            equals('file body\n'),
          );
          expect(fs.directory(draftsDir).existsSync(), isFalse);
        });

        test('reads --body-text and buffered --body-stdin', () async {
          final literal = successJson(
            await exec(
              command('create', [
                'alpha',
                '--body-text',
                'literal body\n',
                '--apply',
                '--yes',
                '--format',
                'json',
              ]),
            ),
          );
          expect(literal['outcome'], equals('published'));
          expect(
            fs.file('$templateDir/alpha.md').readAsStringSync(),
            equals('literal body\n'),
          );

          final piped = successJson(
            await exec(
              command('create', [
                'beta',
                '--body-stdin',
                '--apply',
                '--yes',
                '--format',
                'json',
              ]),
              standardInput: utf8.encode('piped body\n'),
            ),
          );
          expect(piped['outcome'], equals('published'));
          expect(
            fs.file('$templateDir/beta.md').readAsStringSync(),
            equals('piped body\n'),
          );
        });

        for (final body in <String>['', '   \n\t']) {
          test(
            'refuses a whitespace-only flag body (${body.length} bytes)',
            () async {
              expectFailure(
                await exec(
                  command('create', [
                    'alpha',
                    '--body-text',
                    body,
                    '--format',
                    'json',
                  ]),
                ),
                code: 'BODY_EMPTY',
                verb: 'create',
              );
              expect(fs.file('$templateDir/alpha.md').existsSync(), isFalse);
            },
          );
        }

        test('reports instruction content only when asked', () async {
          final hidden = successJson(
            await exec(
              command('create', [
                'alpha',
                '--body-text',
                'secret rules',
                '--format',
                'json',
              ]),
            ),
          );
          expect(
            (hidden['data'] as Map<String, dynamic>).containsKey('content'),
            isFalse,
          );
          final shown = successJson(
            await exec(
              command('create', [
                'alpha',
                '--body-text',
                'secret rules',
                '--show-instructions',
                '--format',
                'json',
              ]),
            ),
          );
          expect(
            (shown['data'] as Map<String, dynamic>)['content'],
            equals('secret rules'),
          );
        });

        test('refuses an occupied name at planning and publication', () async {
          writeTemplate('alpha', 'existing');
          expectFailure(
            await exec(
              command('create', ['alpha', '--empty', '--format', 'json']),
            ),
            code: 'TARGET_OCCUPIED',
            verb: 'create',
          );
          final plan = successJson(
            await exec(
              command('create', ['beta', '--empty', '--format', 'json']),
            ),
          );
          writeTemplate('beta', 'raced');
          expectFailure(
            await exec(
              command('create', [
                'beta',
                '--empty',
                '--plan-id',
                plan['data']['planId'] as String,
                '--apply',
                '--yes',
                '--format',
                'json',
              ]),
            ),
            code: 'TARGET_OCCUPIED',
            verb: 'create',
          );
        });

        test('rejects a stale plan id and requires approval', () async {
          final plan = successJson(
            await exec(
              command('create', [
                'alpha',
                '--body-text',
                'first',
                '--format',
                'json',
              ]),
            ),
          );
          expectFailure(
            await exec(
              command('create', [
                'alpha',
                '--body-text',
                'second',
                '--plan-id',
                plan['data']['planId'] as String,
                '--apply',
                '--yes',
                '--format',
                'json',
              ]),
            ),
            code: 'STALE_PLAN',
            verb: 'create',
          );
          expectFailure(
            await exec(
              command('create', [
                'alpha',
                '--body-text',
                'first',
                '--apply',
                '--format',
                'json',
              ]),
            ),
            code: 'MISSING_APPROVAL',
            verb: 'create',
          );
          expect(fs.file('$templateDir/alpha.md').existsSync(), isFalse);
        });

        test(
          'editor-led creation cleans up the owned draft on apply',
          () async {
            final result = await exec(
              command('create', ['alpha', '--interactive', '--apply']),
              authoring: authoring(terminal: true, confirm: (_) async => true),
            );

            expect(
              result,
              isA<MambaSuccessResult>().having(
                (value) => value.output,
                'output',
                allOf(
                  contains('context create: published'),
                  contains('draftId: drf_'),
                  contains('draftCleaned: true'),
                ),
              ),
            );
            expect(
              fs.file('$templateDir/alpha.md').readAsStringSync(),
              equals('Edited.\n'),
            );
            expect(
              !fs.directory(draftsDir).existsSync() ||
                  fs.directory(draftsDir).listSync().isEmpty,
              isTrue,
            );
          },
        );

        test(
          'a declined interactive confirmation cancels with exit 7',
          () async {
            expectFailure(
              await exec(
                command('create', ['alpha', '--interactive', '--apply']),
                authoring: authoring(
                  terminal: true,
                  confirm: (_) async => false,
                ),
              ),
              code: 'PUBLICATION_CANCELLED',
              verb: 'create',
              exitCode: 7,
            );
            expect(fs.file('$templateDir/alpha.md').existsSync(), isFalse);
          },
        );

        test('a cancelled editor retains the draft and exits 7', () async {
          final service = authoring(
            terminal: true,
            recover: (request) async => const EditorRecoveryCancel(),
            processRunner: (request) async =>
                const EditorProcessOutcome.failed('editor closed'),
          );

          expectFailure(
            await exec(
              command('create', ['alpha', '--interactive']),
              authoring: service,
            ),
            code: 'draftId drf_',
            verb: 'create',
            exitCode: 7,
          );
          final failure = await exec(
            command('create', ['alpha', '--interactive']),
            authoring: service,
          );
          final message = (failure as MambaFailureResult).message;
          expect(message, contains('draftPath $draftsDir/'));
          expect(fs.directory(draftsDir).listSync(), isNotEmpty);
        });

        test('an empty editor save is refused with BODY_EMPTY', () async {
          final service = authoring(
            terminal: true,
            processRunner: (request) async {
              fs.file(request.arguments.last).writeAsStringSync('  \n');
              return const EditorProcessOutcome(started: true, exitCode: 0);
            },
          );

          expectFailure(
            await exec(
              command('create', ['alpha', '--interactive']),
              authoring: service,
            ),
            code: 'BODY_EMPTY',
            verb: 'create',
          );
          expect(fs.directory(draftsDir).listSync(), isNotEmpty);
          expect(fs.file('$templateDir/alpha.md').existsSync(), isFalse);
        });
      });

      group('edit', () {
        test('seeds and publishes an editor-led edit', () async {
          writeTemplate('alpha', 'before\n');

          final result = await exec(
            command('edit', ['alpha', '--interactive', '--apply']),
            authoring: authoring(terminal: true, confirm: (_) async => true),
          );

          expect(
            result,
            isA<MambaSuccessResult>().having(
              (value) => value.output,
              'output',
              allOf(
                contains('context edit: published'),
                contains('name: alpha'),
                contains('existingSha256:'),
                contains('recoveryPath:'),
              ),
            ),
          );
          final recovery = fs
              .directory('/sandbox/state/authoring-recovery')
              .listSync(recursive: true)
              .where((entity) => entity.path.endsWith('source.md'))
              .single;
          expect(fs.file(recovery.path).readAsStringSync(), equals('before\n'));
          expect(
            fs.file('$templateDir/alpha.md').readAsStringSync(),
            equals('Edited.\n'),
          );
          expect(
            !fs.directory(draftsDir).existsSync() ||
                fs.directory(draftsDir).listSync().isEmpty,
            isTrue,
          );
        });

        test('publishes body flags with a recovery copy and receipt', () async {
          writeTemplate('alpha', 'old body\n');

          final envelope = successJson(
            await exec(
              command('edit', [
                'alpha',
                '--body-text',
                'new body\n',
                '--apply',
                '--yes',
                '--format',
                'json',
              ]),
            ),
          );
          final data = envelope['data'] as Map<String, dynamic>;
          final planId = data['planId'] as String;
          final recovery =
              '/sandbox/state/authoring-recovery/$planId/source.md';

          expect(recovery, contains(planId));
          expect(planId, matches(planIdPattern));
          expect(fs.file(recovery).readAsStringSync(), equals('old body\n'));
          expect(data['recoveryPath'], equals(recovery));
          expect(data['receiptId'], startsWith('rcp_'));
          expect(
            fs.file('$templateDir/alpha.md').readAsStringSync(),
            equals('new body\n'),
          );
        });

        test('refuses editing a missing or linked template', () async {
          expectFailure(
            await exec(
              command('edit', [
                'absent',
                '--body-text',
                'body',
                '--format',
                'json',
              ]),
            ),
            code: 'TEMPLATE_NOT_FOUND',
            verb: 'edit',
          );
          writeTemplate('linked', 'outside');
          fs.file('/sandbox/home/outside.md').writeAsStringSync('outside');
          fs.file('$templateDir/linked.md').deleteSync();
          fs
              .link('$templateDir/linked.md')
              .createSync('/sandbox/home/outside.md');
          // The link replaces the regular file above.
          expectFailure(
            await exec(
              command('edit', [
                'linked',
                '--body-text',
                'body',
                '--format',
                'json',
              ]),
            ),
            code: 'SYMLINK_REFUSED',
            verb: 'edit',
          );
        });

        test('refuses drift between plan and apply', () async {
          writeTemplate('alpha', 'before\n');
          final plan = successJson(
            await exec(
              command('edit', [
                'alpha',
                '--body-text',
                'after\n',
                '--format',
                'json',
              ]),
            ),
          );
          writeTemplate('alpha', 'raced\n');
          final result = await exec(
            command('edit', [
              'alpha',
              '--body-text',
              'after\n',
              '--plan-id',
              plan['data']['planId'] as String,
              '--apply',
              '--yes',
              '--format',
              'json',
            ]),
          );
          expect(result, isA<MambaFailureResult>());
          final failure = result as MambaFailureResult;
          expect(failure.exitCode, equals(4));
          expect(
            failure.message,
            anyOf(contains('STALE_PLAN'), contains('TARGET_DRIFT')),
          );
          expect(
            fs.file('$templateDir/alpha.md').readAsStringSync(),
            equals('raced\n'),
          );
        });

        test(
          'selector cancellation exits 7 and empty inventory exits 4',
          () async {
            expectFailure(
              await exec(
                command('edit', ['--interactive', '--body-text', 'body']),
                authoring: authoring(terminal: true, select: (_) async => null),
              ),
              code: 'NO_TEMPLATES',
              verb: 'edit',
            );
            writeTemplate('alpha', 'one');
            writeTemplate('beta', 'two');
            final error = await exec(
              command('edit', ['--interactive', '--body-text', 'body']),
              authoring: authoring(terminal: true, select: (_) async => null),
            );
            expectFailure(
              error,
              code: 'TEMPLATE_SELECTION_CANCELLED',
              verb: 'edit',
              exitCode: 7,
            );

            final selected = <List<String>>[];
            final result = await exec(
              command('edit', ['--interactive', '--body-text', 'three']),
              authoring: authoring(
                terminal: true,
                select: (options) async {
                  selected.add(options);
                  return 'beta';
                },
              ),
            );
            expect(selected.single, equals(['alpha', 'beta']));
            expect(
              result,
              isA<MambaSuccessResult>().having(
                (value) => value.output,
                'output',
                contains('name: beta'),
              ),
            );
          },
        );

        test('--dry-run plans without drafts, recovery or a write', () async {
          writeTemplate('alpha', 'before\n');
          final envelope = successJson(
            await exec(
              command('edit', [
                'alpha',
                '--body-text',
                'after\n',
                '--apply',
                '--yes',
                '--dry-run',
                '--format',
                'json',
              ]),
            ),
          );
          expect(envelope['outcome'], equals('planned'));
          expect(
            fs.file('$templateDir/alpha.md').readAsStringSync(),
            equals('before\n'),
          );
          expect(fs.directory(draftsDir).existsSync(), isFalse);
          expect(
            fs.directory('/sandbox/state/authoring-recovery').existsSync(),
            isFalse,
          );
        });
      });

      group('publication failures', () {
        final planIdPattern = RegExp(r'pln_[a-f0-9]{64}');

        Future<String> editorLedPlanId(String verb, List<String> extra) async {
          final result = await exec(
            command(verb, <String>[...extra, '--interactive']),
            authoring: authoring(terminal: true, confirm: (_) async => true),
          );
          final output = (result as MambaSuccessResult).output!;
          return planIdPattern.firstMatch(output)!.group(0)!;
        }

        void expectRetainedDraftFailure(
          MambaExecutionResult result,
          String code, {
          String verb = 'edit',
        }) {
          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 6)
                .having(
                  (value) => value.message,
                  'message',
                  allOf(
                    contains(code),
                    contains('draftId drf_'),
                    contains('draftPath $draftsDir/'),
                  ),
                )
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.error.phase,
                  'phase',
                  MambaExecutionPhase.run,
                )
                .having(
                  (value) => value.error.commandPath,
                  'command path',
                  <String>['agent_resource', 'context', verb],
                ),
          );
        }

        test('reports the retained draft when recovery is occupied', () async {
          writeTemplate('alpha', 'before\n');
          final planId = await editorLedPlanId('edit', <String>['alpha']);
          final occupied =
              '/sandbox/state/authoring-recovery/$planId/source.md';
          fs.file(occupied)
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('already here');

          expectRetainedDraftFailure(
            await exec(
              command('edit', <String>[
                'alpha',
                '--interactive',
                '--apply',
                '--yes',
              ]),
              authoring: authoring(terminal: true, confirm: (_) async => true),
            ),
            'RECOVERY_OCCUPIED',
          );
          expect(fs.directory(draftsDir).listSync(), isNotEmpty);
        });

        test('reports the retained draft when staging is occupied', () async {
          final planId = await editorLedPlanId('create', <String>['alpha']);
          final occupied = '/sandbox/state/authoring-staging/$planId/candidate';
          fs.file(occupied)
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('already here');

          expectRetainedDraftFailure(
            await exec(
              command('create', <String>[
                'alpha',
                '--interactive',
                '--apply',
                '--yes',
              ]),
              authoring: authoring(terminal: true, confirm: (_) async => true),
            ),
            'STAGING_OCCUPIED',
            verb: 'create',
          );
          expect(fs.directory(draftsDir).listSync(), isNotEmpty);
        });

        for (final tamper in <String>['read', 'rename']) {
          test(
            'reports the retained draft when staged bytes drift on $tamper',
            () async {
              expectRetainedDraftFailure(
                await exec(
                  command('create', <String>[
                    'alpha',
                    '--interactive',
                    '--apply',
                    '--yes',
                  ]),
                  authoring: authoring(
                    terminal: true,
                    confirm: (_) async => true,
                    io: _TamperingIO(fs: fs, operation: tamper),
                  ),
                ),
                tamper == 'read' ? 'STAGING_DRIFT' : 'PUBLICATION_DRIFT',
                verb: 'create',
              );
              expect(fs.directory(draftsDir).listSync(), isNotEmpty);
            },
          );
        }
      });
    });
  });
}

/// Mutates the staged candidate at a chosen publication boundary.
final class _TamperingIO extends LifecycleIO {
  _TamperingIO({required super.fs, required this.operation});

  final String operation;

  @override
  void before(String operation, String path) {
    if (operation == this.operation && path.endsWith('/candidate')) {
      fs.file(path).writeAsStringSync('tampered');
    }
  }
}

/// A resolver that finds every editor program.
final class _FakeResolver implements EditorProgramResolver {
  const _FakeResolver();

  @override
  EditorExecutableResolution resolve(
    String executable, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) => EditorExecutableResolution(
    requested: executable,
    resolvedPath: '/programs/$executable',
    isBatchLauncher: false,
  );
}
