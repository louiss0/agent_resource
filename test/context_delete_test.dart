import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/components/installation_approval.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('context', () {
      test('group help lists the delete child', () async {
        final helpFs = MemoryFileSystem(style: FileSystemStyle.posix);
        final result = await createExecutor(fileSystem: helpFs)
            .fake()
            .execute(['context', '--help']);

        expect(
          result,
          isA<MambaSuccessResult>()
              .having((value) => value.exitCode, 'exit code', 0)
              .having((value) => value.output, 'output', contains('delete')),
        );
      });

      group('delete', () {
        late fslib.FileSystem fs;
        late InstallationApprovalComponent approval;

        const templateDir = '/sandbox/state/context-templates';
        const alphaDigest =
            '4f76f12a140a02006bff5b0a8c0bcdf5344d89a6773c0b312b5e459709f59e18';

        List<String> ctx() => const <String>[
          '--cwd',
          '/sandbox/project/',
          '--home',
          '/sandbox/home/',
          '--state-dir',
          '/sandbox/state/',
        ];

        List<String> deleteCommand(List<String> extra) => <String>[
          'context',
          'delete',
          ...extra,
          ...ctx(),
        ];

        Future<MambaExecutionResult> exec(List<String> tokens) =>
            createExecutor(
              fileSystem: fs,
              contextDeleteApproval: approval,
            ).fake().execute(tokens);

        late List<List<String>> selectedNames;

        Future<MambaExecutionResult> execSelecting(
          String? answer,
          List<String> extra,
        ) => createExecutor(
          fileSystem: fs,
          contextDeleteApproval: approval,
          contextHasTerminal: () => true,
          contextTemplateSelection: (names) async {
            selectedNames.add(names);
            return answer;
          },
        ).fake().execute(deleteCommand(extra));

        setUp(() {
          selectedNames = <List<String>>[];
        });

        void expectFailure(
          MambaExecutionResult result, {
          required int exitCode,
          required String code,
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
                  <String>['agent_resource', 'context', 'delete'],
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
          approval = InstallationApprovalComponent(
            hasTerminal: () => false,
            confirm: (_) => false,
          );
          for (final directory in [
            '/sandbox/project',
            '/sandbox/home',
            '/sandbox/state',
          ]) {
            fs.directory(directory).createSync(recursive: true);
          }
        });

        test('selects and deletes a stored template interactively', () async {
          writeTemplate('alpha', 'one');
          writeTemplate('beta', 'beta rules\n');
          approval = InstallationApprovalComponent(
            hasTerminal: () => true,
            confirm: (_) => true,
          );

          final result = await execSelecting('beta', <String>['--interactive']);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  allOf(
                    contains('context delete: deleted'),
                    contains('name: beta'),
                  ),
                ),
          );
          expect(selectedNames.single, equals(['alpha', 'beta']));
          expect(fs.file('$templateDir/beta.md').existsSync(), isFalse);
          expect(
            fs.file('$templateDir/alpha.md').readAsStringSync(),
            equals('one'),
          );
        });

        test('refuses selection when no templates are stored', () async {
          approval = InstallationApprovalComponent(
            hasTerminal: () => true,
            confirm: (_) => true,
          );

          expectFailure(
            await execSelecting('alpha', <String>['--interactive']),
            exitCode: 4,
            code: 'NO_CONTEXT_TEMPLATES',
          );
          expect(selectedNames, isEmpty);
        });

        test('cancels with exit 7 when the selector is dismissed', () async {
          writeTemplate('alpha', 'one');
          approval = InstallationApprovalComponent(
            hasTerminal: () => true,
            confirm: (_) => true,
          );

          expectFailure(
            await execSelecting(null, <String>['--interactive']),
            exitCode: 7,
            code: 'TEMPLATE_SELECTION_CANCELLED',
          );
          expect(fs.file('$templateDir/alpha.md').existsSync(), isTrue);
        });

        test('refuses an omitted name in unattended mode', () async {
          writeTemplate('alpha', 'one');
          approval = InstallationApprovalComponent(
            hasTerminal: () => true,
            confirm: (_) => true,
          );

          expectFailure(
            await execSelecting('alpha', <String>[
              '--unattended',
              '--format',
              'json',
            ]),
            exitCode: 4,
            code: 'MISSING_TEMPLATE_NAME',
          );
          expect(selectedNames, isEmpty);
        });

        test(
          'confirmed interactive deletion removes only the named template',
          () async {
            writeTemplate('alpha', 'alpha rules\n');
            writeTemplate('beta', 'beta rules\n');
            approval = InstallationApprovalComponent(
              hasTerminal: () => true,
              confirm: (_) => true,
            );

            final result = await exec(deleteCommand(['alpha']));

            expect(
              result,
              isA<MambaSuccessResult>()
                  .having((value) => value.exitCode, 'exit code', 0)
                  .having(
                    (value) => value.output,
                    'output',
                    allOf(
                      contains('context delete: deleted'),
                      contains('name: alpha'),
                      contains('deleted: true'),
                      contains('diagnostics:'),
                    ),
                  ),
            );
            expect(fs.file('$templateDir/alpha.md').existsSync(), isFalse);
            expect(
              fs.file('$templateDir/beta.md').readAsStringSync(),
              equals('beta rules\n'),
            );
          },
        );

        test(
          'declining interactive confirmation cancels with exit 7',
          () async {
            writeTemplate('alpha', 'alpha rules\n');
            approval = InstallationApprovalComponent(
              hasTerminal: () => true,
              confirm: (_) => false,
            );

            expectFailure(
              await exec(deleteCommand(['alpha'])),
              exitCode: 7,
              code: 'DELETION_CANCELLED',
            );
            expect(
              fs.file('$templateDir/alpha.md').readAsStringSync(),
              equals('alpha rules\n'),
            );
          },
        );

        test(
          'unattended --yes deletes and reports the JSON envelope',
          () async {
            writeTemplate('alpha', 'alpha rules\n');
            writeTemplate('beta', 'beta rules\n');

            final result = await exec(
              deleteCommand([
                '--name',
                'alpha',
                '--unattended',
                '--yes',
                '--format',
                'json',
              ]),
            );

            expect(
              result,
              isA<MambaSuccessResult>()
                  .having((value) => value.exitCode, 'exit code', 0)
                  .having((value) => value.output, 'output', isNotNull),
            );
            final envelope = jsonDecode(
              (result as MambaSuccessResult).output!,
            ) as Map<String, dynamic>;
            expect(envelope['schemaVersion'], equals(1));
            expect(envelope['command'], equals('context delete'));
            expect(envelope['outcome'], equals('deleted'));
            expect(
              envelope['data'],
              equals(<String, Object?>{
                'name': 'alpha',
                'path': '$templateDir/alpha.md',
                'byteLength': 12,
                'isEmpty': false,
                'sha256': alphaDigest,
                'deleted': true,
                'dryRun': false,
              }),
            );
            final diagnostics = envelope['diagnostics'] as List<dynamic>;
            expect(diagnostics, hasLength(1));
            expect(
              diagnostics.first,
              equals(<String, Object?>{
                'code': 'TEMPLATE_DELETED',
                'category': 'operation',
                'severity': 'info',
                'field': 'deleted',
                'message': 'Removed context template "alpha".',
              }),
            );
            expect(fs.file('$templateDir/alpha.md').existsSync(), isFalse);
            expect(
              fs.file('$templateDir/beta.md').readAsStringSync(),
              equals('beta rules\n'),
            );
          },
        );

        test('unattended deletion without --yes is refused', () async {
          writeTemplate('alpha', 'alpha rules\n');

          expectFailure(
            await exec(
              deleteCommand(['alpha', '--unattended', '--format', 'json']),
            ),
            exitCode: 4,
            code: 'CONFIRMATION_REQUIRED',
          );
          expect(fs.file('$templateDir/alpha.md').existsSync(), isTrue);
        });

        test('JSON output implies unattended confirmation', () async {
          writeTemplate('alpha', 'alpha rules\n');

          expectFailure(
            await exec(deleteCommand(['--name', 'alpha', '--format', 'json'])),
            exitCode: 4,
            code: 'CONFIRMATION_REQUIRED',
          );
          expect(fs.file('$templateDir/alpha.md').existsSync(), isTrue);
        });

        test('no usable terminal implies unattended confirmation', () async {
          writeTemplate('alpha', 'alpha rules\n');

          expectFailure(
            await exec(deleteCommand(['alpha'])),
            exitCode: 4,
            code: 'CONFIRMATION_REQUIRED',
          );
          expect(fs.file('$templateDir/alpha.md').existsSync(), isTrue);
        });

        test('help describes the delete surface', () async {
          final result = await exec(deleteCommand(['--help']));

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  allOf(
                    contains('--dry-run'),
                    contains('--yes'),
                    contains('--interactive'),
                    contains('--unattended'),
                    contains('--format'),
                  ),
                ),
          );
        });

        test('rejects an undeclared input during parsing', () async {
          final result = await exec(deleteCommand(['alpha', '--not-an-input']));

          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', isNonZero)
                .having(
                  (value) => value.message,
                  'message',
                  contains('--not-an-input'),
                )
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.error.phase,
                  'phase',
                  MambaExecutionPhase.parse,
                )
                .having(
                  (value) => value.error.commandPath,
                  'command path',
                  <String>['agent_resource', 'context', 'delete'],
                ),
          );
        });

        test('rejects both positional and --name', () async {
          writeTemplate('alpha', 'alpha rules\n');

          expectFailure(
            await exec(
              deleteCommand(['alpha', '--name', 'alpha', '--format', 'json']),
            ),
            exitCode: 4,
            code: 'AMBIGUOUS_TEMPLATE_NAME',
          );
        });

        test('requires an explicit name even on a usable terminal', () async {
          approval = InstallationApprovalComponent(
            hasTerminal: () => true,
            confirm: (_) => true,
          );

          expectFailure(
            await exec(deleteCommand(['--format', 'json'])),
            exitCode: 4,
            code: 'MISSING_TEMPLATE_NAME',
          );
        });

        test('refuses a non-portable name', () async {
          expectFailure(
            await exec(deleteCommand(['../escape', '--format', 'json'])),
            exitCode: 4,
            code: 'INVALID_TEMPLATE_NAME',
          );
        });

        test('refuses an absent template', () async {
          expectFailure(
            await exec(deleteCommand(['absent', '--format', 'json'])),
            exitCode: 4,
            code: 'TEMPLATE_NOT_FOUND',
          );
        });

        test(
          'refuses a symlinked template without unlinking its target',
          () async {
            fs.directory(templateDir).createSync(recursive: true);
            fs.file('/sandbox/home/outside.md').writeAsStringSync('outside');
            fs
                .link('$templateDir/linked.md')
                .createSync('/sandbox/home/outside.md');

            expectFailure(
              await exec(
                deleteCommand([
                  'linked',
                  '--unattended',
                  '--yes',
                  '--format',
                  'json',
                ]),
              ),
              exitCode: 4,
              code: 'SYMLINK_REFUSED',
            );
            expect(
              fs.file('/sandbox/home/outside.md').readAsStringSync(),
              equals('outside'),
            );
          },
        );

        test('refuses a non-regular template entry', () async {
          fs.directory('$templateDir/folder.md').createSync(recursive: true);

          expectFailure(
            await exec(
              deleteCommand([
                'folder',
                '--unattended',
                '--yes',
                '--format',
                'json',
              ]),
            ),
            exitCode: 4,
            code: 'NON_REGULAR_TEMPLATE_REFUSED',
          );
          expect(fs.directory('$templateDir/folder.md').existsSync(), isTrue);
        });

        test('dry run reports a plan without touching templates', () async {
          writeTemplate('alpha', 'alpha rules\n');
          writeTemplate('beta', 'beta rules\n');

          final result = await exec(
            deleteCommand(['alpha', '--dry-run', '--format', 'json']),
          );

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having((value) => value.output, 'output', isNotNull),
          );
          final envelope = jsonDecode(
            (result as MambaSuccessResult).output!,
          ) as Map<String, dynamic>;
          expect(envelope['schemaVersion'], equals(1));
          expect(envelope['command'], equals('context delete'));
          expect(envelope['outcome'], equals('planned'));
          expect(
            envelope['data'],
            equals(<String, Object?>{
              'name': 'alpha',
              'path': '$templateDir/alpha.md',
              'byteLength': 12,
              'isEmpty': false,
              'sha256': alphaDigest,
              'deleted': false,
              'dryRun': true,
            }),
          );
          expect(
            envelope['diagnostics'],
            everyElement(
              isA<Map<String, dynamic>>()
                  .having((value) => value['code'], 'code', isA<String>())
                  .having(
                    (value) => value['category'],
                    'category',
                    isA<String>(),
                  )
                  .having(
                    (value) => value['severity'],
                    'severity',
                    isA<String>(),
                  )
                  .having((value) => value['field'], 'field', isA<String>())
                  .having(
                    (value) => value['message'],
                    'message',
                    isA<String>(),
                  ),
            ),
          );
          expect(
            fs.file('$templateDir/alpha.md').readAsStringSync(),
            equals('alpha rules\n'),
          );
          expect(
            fs.file('$templateDir/beta.md').readAsStringSync(),
            equals('beta rules\n'),
          );
        });
      });
    });
  });
}
