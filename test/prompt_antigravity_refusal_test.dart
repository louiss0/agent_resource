import 'package:agent_resource/agent_resource.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('Antigravity Prompt refusal', () {
    late MemoryFileSystem fs;

    setUp(() {
      fs = MemoryFileSystem.test(style: FileSystemStyle.posix);
      fs.directory('/sandbox/prompt').createSync(recursive: true);
      fs
          .file('/sandbox/prompt/SKILL.md')
          .writeAsStringSync(
            '---\nname: prompt\ndescription: A manual prompt.\n'
            'disable-model-invocation: true\n---\nBody.\n',
          );
    });

    Future<MambaExecutionResult> run(List<String> args) =>
        createExecutor(fileSystem: fs).fake().execute(args);

    for (final command in const ['inspect', 'validate', 'list']) {
      test('$command refuses an explicit Antigravity Prompt target', () async {
        final result = await run(<String>[
          'prompt',
          command,
          if (command != 'list') ...<String>['--path', '/sandbox/prompt'],
          '--target',
          'antigravity',
        ]);
        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', 4)
              .having(
                (value) => value.message,
                'message',
                allOf(
                  contains('antigravity'),
                  contains('ordinary Skills'),
                  contains('.agents/skills'),
                ),
              )
              .having((value) => value.output, 'output', isNull),
        );
      });
    }

    test('create refuses the Antigravity Prompt profile', () async {
      final result = await run(<String>[
        'prompt',
        'create',
        '--profile',
        'antigravity',
        '--name',
        'prompt',
        '--description',
        'A manual prompt.',
        '--body-text',
        'Body.',
      ]);
      expect(
        result,
        isA<MambaFailureResult>()
            .having((value) => value.exitCode, 'exit code', 4)
            .having(
              (value) => value.message,
              'message',
              contains('ordinary Skills'),
            ),
      );
    });
  });
}
