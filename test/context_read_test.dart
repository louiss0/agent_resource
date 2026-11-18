import 'package:agent_resource/agent_resource.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

import 'support/context_test_support.dart';

void main() {
  group('agent_resource', () {
    group('context', () {
      late fslib.FileSystem fs;

      const templateDir = '/sandbox/state/context-templates';
      const alphaDigest =
          '4f76f12a140a02006bff5b0a8c0bcdf5344d89a6773c0b312b5e459709f59e18';
      const betaDigest =
          '7345f88948ef27749a784d2bc88df8d9c3f17cd59775000c8892f630240ffeef';
      const emptyDigest =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

      List<String> command(String verb, List<String> extra) =>
          contextCommandArgs(verb, extra);

      Future<MambaExecutionResult> exec(List<String> tokens) =>
          createExecutor(fileSystem: fs).fake().execute(tokens);

      Map<String, dynamic> successJson(
        MambaExecutionResult result, {
        required String command,
        required String outcome,
        required Map<String, Object?> data,
      }) => expectContextJsonSuccess(
        result,
        command: command,
        outcome: outcome,
        data: data,
      );

      void expectFailure(
        MambaExecutionResult result, {
        required String code,
        String verb = 'inspect',
        int exitCode = 4,
      }) => expectContextFailure(
        result,
        verb: verb,
        code: code,
        exitCode: exitCode,
      );

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

      group('list', () {
        test(
          'reports an empty inventory when the directory is absent',
          () async {
            successJson(
              await exec(command('list', ['--format', 'json'])),
              command: 'context list',
              outcome: 'listed',
              data: <String, Object?>{'templates': <Object?>[]},
            );

            expect(fs.directory(templateDir).existsSync(), isFalse);
          },
        );

        test(
          'sorts templates and reports metadata with byte digests',
          () async {
            writeTemplate('zebra', 'beta instructions');
            writeTemplate('blank', '');
            writeTemplate('alpha', 'alpha rules\n');

            final envelope = successJson(
              await exec(command('list', ['--format', 'json'])),
              command: 'context list',
              outcome: 'listed',
              data: <String, Object?>{
                'templates': <Object?>[
                  contextTemplateData(
                    'alpha',
                    byteLength: 12,
                    isEmpty: false,
                    sha256: alphaDigest,
                  ),
                  contextTemplateData(
                    'blank',
                    byteLength: 0,
                    isEmpty: true,
                    sha256: emptyDigest,
                  ),
                  contextTemplateData(
                    'zebra',
                    byteLength: 17,
                    isEmpty: false,
                    sha256: betaDigest,
                  ),
                ],
              },
            );
            final templates =
                (envelope['data'] as Map<String, dynamic>)['templates']
                    as List<dynamic>;
            expect(
              templates.map((entry) => entry['name']).toList(),
              equals(['alpha', 'blank', 'zebra']),
            );
          },
        );

        test('refuses a symlinked template directory', () async {
          fs.directory('/sandbox/home/templates').createSync(recursive: true);
          fs.link(templateDir).createSync('/sandbox/home/templates');

          expectFailure(
            await exec(command('list', ['--format', 'json'])),
            code: 'SYMLINK_REFUSED',
            verb: 'list',
          );
        });

        test('refuses a symlinked template entry', () async {
          writeTemplate('alpha', 'alpha rules\n');
          fs.file('/sandbox/home/outside.md').writeAsStringSync('outside');
          fs
              .link('$templateDir/linked.md')
              .createSync('/sandbox/home/outside.md');

          expectFailure(
            await exec(command('list', ['--format', 'json'])),
            code: 'SYMLINK_REFUSED',
            verb: 'list',
          );
        });

        test('refuses a non-regular template entry', () async {
          fs.directory('$templateDir/subdir').createSync(recursive: true);

          expectFailure(
            await exec(command('list', ['--format', 'json'])),
            code: 'NON_REGULAR_TEMPLATE_REFUSED',
            verb: 'list',
          );
        });

        test('refuses a stored template with a non-portable name', () async {
          writeTemplate('BAD', 'bad');

          expectFailure(
            await exec(command('list', ['--format', 'json'])),
            code: 'INVALID_TEMPLATE_NAME',
            verb: 'list',
          );
        });
      });

      group('inspect', () {
        late List<List<String>> selectedNames;

        setUp(() {
          selectedNames = <List<String>>[];
        });

        Future<MambaExecutionResult> execSelecting(
          String? answer,
          List<String> extra, {
          bool terminal = true,
        }) => createExecutor(
          fileSystem: fs,
          contextHasTerminal: () => terminal,
          contextTemplateSelection: (names) async {
            selectedNames.add(names);
            return answer;
          },
        ).fake().execute(command('inspect', extra));

        test('selects a stored template on a usable terminal', () async {
          writeTemplate('alpha', 'one');
          writeTemplate('beta', 'beta rules\n');

          final result = await execSelecting('beta', <String>['--interactive']);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  allOf(
                    contains('context inspect: inspected'),
                    contains('name: beta'),
                    contains('content: beta rules'),
                  ),
                ),
          );
          expect(selectedNames.single, equals(['alpha', 'beta']));
        });

        test('refuses selection when no templates are stored', () async {
          expectFailure(
            await execSelecting('beta', <String>['--interactive']),
            code: 'NO_CONTEXT_TEMPLATES',
          );
          expect(selectedNames, isEmpty);
        });

        test('cancels with exit 7 when the selector is dismissed', () async {
          writeTemplate('alpha', 'one');

          expectFailure(
            await execSelecting(null, <String>['--interactive']),
            code: 'TEMPLATE_SELECTION_CANCELLED',
            exitCode: 7,
          );
        });

        test('refuses an omitted name in unattended mode', () async {
          writeTemplate('alpha', 'one');

          expectFailure(
            await execSelecting('alpha', <String>[
              '--unattended',
            ], terminal: false),
            code: 'MISSING_TEMPLATE_NAME',
          );
          expect(selectedNames, isEmpty);
        });

        test(
          'returns full content and metadata for a positional name',
          () async {
            writeTemplate('alpha', 'alpha rules\n');

            successJson(
              await exec(command('inspect', ['alpha', '--format', 'json'])),
              command: 'context inspect',
              outcome: 'inspected',
              data: contextTemplateData(
                'alpha',
                byteLength: 12,
                isEmpty: false,
                sha256: alphaDigest,
                content: 'alpha rules\n',
              ),
            );

            expect(
              fs.file('$templateDir/alpha.md').readAsStringSync(),
              equals('alpha rules\n'),
            );
          },
        );

        test(
          'accepts an explicit --name without --show-instructions',
          () async {
            writeTemplate('zebra', 'beta instructions');

            final envelope = successJson(
              await exec(
                command('inspect', ['--name', 'zebra', '--format', 'json']),
              ),
              command: 'context inspect',
              outcome: 'inspected',
              data: contextTemplateData(
                'zebra',
                byteLength: 17,
                isEmpty: false,
                sha256: betaDigest,
                content: 'beta instructions',
              ),
            );

            expect(
              (envelope['data'] as Map<String, dynamic>)['content'],
              equals('beta instructions'),
            );
          },
        );

        test('returns empty content for a zero-byte template', () async {
          writeTemplate('blank', '');

          final envelope = successJson(
            await exec(
              command('inspect', ['--name', 'blank', '--format', 'json']),
            ),
            command: 'context inspect',
            outcome: 'inspected',
            data: contextTemplateData(
              'blank',
              byteLength: 0,
              isEmpty: true,
              sha256: emptyDigest,
              content: '',
            ),
          );

          final data = envelope['data'] as Map<String, dynamic>;
          expect(data['content'], equals(''));
        });

        test('renders the standard text envelope with full content', () async {
          writeTemplate('alpha', 'alpha rules\n');

          final result = await exec(command('inspect', ['alpha']));

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  allOf(
                    contains('context inspect: inspected'),
                    contains('content: alpha rules'),
                    contains('sha256: $alphaDigest'),
                    contains('diagnostics:'),
                  ),
                ),
          );
        });

        test('refuses both positional and --name', () async {
          writeTemplate('alpha', 'alpha rules\n');

          expectFailure(
            await exec(
              command('inspect', [
                'alpha',
                '--name',
                'alpha',
                '--format',
                'json',
              ]),
            ),
            code: 'AMBIGUOUS_TEMPLATE_NAME',
          );
        });

        test('refuses a missing name', () async {
          expectFailure(
            await exec(command('inspect', ['--format', 'json'])),
            code: 'MISSING_TEMPLATE_NAME',
          );
        });

        test('refuses an invalid template name', () async {
          expectFailure(
            await exec(command('inspect', ['../escape', '--format', 'json'])),
            code: 'INVALID_TEMPLATE_NAME',
          );
        });

        test('refuses an absent template', () async {
          expectFailure(
            await exec(command('inspect', ['absent', '--format', 'json'])),
            code: 'TEMPLATE_NOT_FOUND',
          );
        });

        test('refuses a symlinked template', () async {
          writeTemplate('alpha', 'alpha rules\n');
          fs.file('/sandbox/home/outside.md').writeAsStringSync('outside');
          fs
              .link('$templateDir/linked.md')
              .createSync('/sandbox/home/outside.md');

          expectFailure(
            await exec(command('inspect', ['linked', '--format', 'json'])),
            code: 'SYMLINK_REFUSED',
          );
        });

        test('refuses a template larger than the bounded body limit', () async {
          writeTemplate('huge', 'x' * ((1024 * 1024) + 1));

          expectFailure(
            await exec(command('inspect', ['huge', '--format', 'json'])),
            code: 'TEMPLATE_TOO_LARGE',
          );
        });
      });
    });
  });
}
