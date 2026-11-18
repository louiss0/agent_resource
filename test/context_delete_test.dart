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
