import 'package:agent_resource/skills.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

// A floor, not coverage: these two tests hold for any command. Add a
// valid invocation with observable output or effects, and a case for
// each way this command is meant to reject an invocation.
void main() {
  group('test', () {
    group('skills', () {
      test('shows help', () async {
        final result = await Executor('test', 'Test.', '1.0.0', [
          SkillsCommand(),
        ]).fake().execute(['skills', '--help']);

        expect(
          result,
          isA<MambaSuccessResult>()
              .having((value) => value.exitCode, 'exit code', 0)
              .having(
                (value) => value.output?.contains('skills'),
                'help includes command',
                true,
              ),
        );
      });

      test('rejects an input it does not declare', () async {
        final result = await Executor('test', 'Test.', '1.0.0', [
          SkillsCommand(),
        ]).fake().execute(['skills', '--not-an-input']);

        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', 1)
              .having(
                (value) => value.message.contains('--not-an-input'),
                'diagnostic names rejected input',
                true,
              )
              .having((value) => value.output, 'output', null)
              .having(
                (value) => value.error.phase,
                'phase',
                MambaExecutionPhase.parse,
              )
              .having((value) => value.error.commandPath, 'command path', [
                'test',
                'skills',
              ]),
        );
      });
    });
  });
}
