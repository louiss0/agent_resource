import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('context', () {
      group('delete', () {
        late fslib.FileSystem fs;

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
            createExecutor(fileSystem: fs).fake().execute(tokens);

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
