import 'package:agent_resource/agent_resource.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('context', () {
      List<String> ctx() => const <String>[
        '--cwd',
        '/sandbox/project/',
        '--home',
        '/sandbox/home/',
        '--state-dir',
        '/sandbox/state/',
      ];

      test('help shows the read commands and group description', () async {
        final result = await createExecutor().fake().execute([
          'context',
          '--help',
        ]);

        expect(
          result,
          isA<MambaSuccessResult>()
              .having((value) => value.exitCode, 'exit code', 0)
              .having(
                (value) => value.output,
                'output',
                allOf(
                  contains(
                    'Manage reusable context templates and inject context',
                  ),
                  contains('list'),
                  contains('inspect'),
                ),
              ),
        );
      });

      test('rejects an undeclared option on context list', () async {
        final result = await createExecutor().fake().execute([
          'context',
          'list',
          '--not-an-input',
          ...ctx(),
        ]);

        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', 1)
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
              .having((value) => value.error.commandPath, 'command path', [
                'agent_resource',
                'context',
                'list',
              ]),
        );
      });

      test(
        'routes a refusal through the full context inspect command path',
        () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          for (final directory in [
            '/sandbox/project',
            '/sandbox/home',
            '/sandbox/state',
          ]) {
            fs.directory(directory).createSync(recursive: true);
          }
          final result = await createExecutor(fileSystem: fs)
              .fake()
              .execute(['context', 'inspect', '--format', 'json', ...ctx()]);

          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 4)
                .having(
                  (value) => value.message,
                  'message',
                  contains('MISSING_TEMPLATE_NAME'),
                )
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.error.phase,
                  'phase',
                  MambaExecutionPhase.run,
                )
                .having((value) => value.error.commandPath, 'command path', [
                  'agent_resource',
                  'context',
                  'inspect',
                ]),
          );
        },
      );
    });
  });
}
