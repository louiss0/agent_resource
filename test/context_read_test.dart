import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

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

      Future<MambaExecutionResult> exec(List<String> tokens) =>
          createExecutor(fileSystem: fs).fake().execute(tokens);

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
        String verb = 'inspect',
      }) {
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
                <String>['agent_resource', 'context', verb],
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

      group('list', () {
        test(
          'reports an empty inventory when the directory is absent',
          () async {
            final envelope = successJson(
              await exec(command('list', ['--format', 'json'])),
            );

            expect(envelope['schemaVersion'], equals(1));
            expect(envelope['command'], equals('context list'));
            expect(envelope['outcome'], equals('listed'));
            expect(envelope['data'], isA<Map<String, dynamic>>());
            expect(
              (envelope['data'] as Map<String, dynamic>)['templates'],
              isEmpty,
            );
            expect(envelope['diagnostics'], isEmpty);
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
            );
            final templates =
                (envelope['data'] as Map<String, dynamic>)['templates']
                    as List<dynamic>;

            expect(
              templates.map((entry) => entry['name']).toList(),
              equals(['alpha', 'blank', 'zebra']),
            );
            expect(
              templates.first,
              equals(<String, Object?>{
                'name': 'alpha',
                'path': '$templateDir/alpha.md',
                'byteLength': 12,
                'isEmpty': false,
                'sha256': alphaDigest,
              }),
            );
            expect(
              templates[1],
              equals(<String, Object?>{
                'name': 'blank',
                'path': '$templateDir/blank.md',
                'byteLength': 0,
                'isEmpty': true,
                'sha256': emptyDigest,
              }),
            );
            expect(
              templates[2],
              equals(<String, Object?>{
                'name': 'zebra',
                'path': '$templateDir/zebra.md',
                'byteLength': 17,
                'isEmpty': false,
                'sha256': betaDigest,
              }),
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
        test(
          'returns full content and metadata for a positional name',
          () async {
            writeTemplate('alpha', 'alpha rules\n');

            final envelope = successJson(
              await exec(command('inspect', ['alpha', '--format', 'json'])),
            );

            expect(envelope['schemaVersion'], equals(1));
            expect(envelope['command'], equals('context inspect'));
            expect(envelope['outcome'], equals('inspected'));
            expect(
              envelope['data'],
              equals(<String, Object?>{
                'name': 'alpha',
                'path': '$templateDir/alpha.md',
                'byteLength': 12,
                'isEmpty': false,
                'sha256': alphaDigest,
                'content': 'alpha rules\n',
              }),
            );
            expect(envelope['diagnostics'], isEmpty);
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
          );

          final data = envelope['data'] as Map<String, dynamic>;
          expect(data['isEmpty'], isTrue);
          expect(data['byteLength'], equals(0));
          expect(data['sha256'], equals(emptyDigest));
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
