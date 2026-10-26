import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

bool _containsToken(String text, String token) =>
    RegExp(r'(?<![A-Za-z0-9_-])' + RegExp.escape(token) + r'(?![A-Za-z0-9_-])')
        .hasMatch(text);

bool _containsCommandEntry(String help, String command) {
  final entry = RegExp('^${RegExp.escape(command)}(?:\\s|\$)');
  return help
      .split(RegExp(r'\r?\n'))
      .any((line) => entry.hasMatch(line.trim()));
}

MambaSuccessResult _expectSuccess(MambaExecutionResult result, Matcher output) {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', output),
  );
  return result as MambaSuccessResult;
}

MambaFailureResult _expectFailure(
  MambaExecutionResult result,
  String diagnosticToken, {
  List<String>? commandPath,
}) {
  expect(
    result,
    isA<MambaFailureResult>()
        .having((value) => value.exitCode, 'exit code', isNonZero)
        .having(
          (value) => _containsToken(value.message, diagnosticToken),
          'diagnostic token',
          isTrue,
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
          commandPath ?? ['agent_resource'],
        ),
  );
  return result as MambaFailureResult;
}

void main() {
  group('agent_resource', () {
    test('shows nonempty root help when no arguments are supplied', () async {
      final result = await createExecutor().fake().execute([]);

      _expectSuccess(result, isNotEmpty);
    });

    for (final control in ['--help', '-h']) {
      test('$control returns successful root help', () async {
        final result = await createExecutor().fake().execute([control]);

        _expectSuccess(result, isNotEmpty);
      });
    }

    test('all root help entry points produce equivalent content', () async {
      final noArguments = _expectSuccess(
        await createExecutor().fake().execute([]),
        isNotEmpty,
      );
      final longControl = _expectSuccess(
        await createExecutor().fake().execute(['--help']),
        isNotEmpty,
      );
      final shortControl = _expectSuccess(
        await createExecutor().fake().execute(['-h']),
        isNotEmpty,
      );

      expect(noArguments.output, equals(longControl.output));
      expect(shortControl.output, equals(longControl.output));
    });

    test('root help identifies the product and implemented controls', () async {
      final result = _expectSuccess(
        await createExecutor().fake().execute(['--help']),
        isNotEmpty,
      );
      final output = result.output!;

      expect(output, contains('agent_resource'));
      expect(
        output,
        contains('Manage resources consumed by AI coding harnesses.'),
      );
      expect(output, isNot(contains('This is a CLI app')));
      for (final control in ['--help', '-h', '--version', '-v']) {
        expect(_containsToken(output, control), isTrue, reason: control);
      }
      expect(_containsCommandEntry(output, 'skill'), isTrue);
      expect(_containsCommandEntry(output, 'agent'), isTrue);
      for (final command in [
        'discover',
        'inspect',
        'validate',
        'install',
        'adopt',
      ]) {
        expect(
          _containsCommandEntry(output, command),
          isFalse,
          reason: command,
        );
      }
    });

    group('skill', () {
      for (final arguments in [
        const <String>[],
        const ['--help'],
      ]) {
        test(
          '${arguments.isEmpty ? 'no arguments' : '--help'} lists the Skill command surface',
          () async {
            final result = _expectSuccess(
              await createExecutor().fake().execute(['skill', ...arguments]),
              isNotEmpty,
            );
            for (final command in [
              'list',
              'inspect',
              'validate',
              'install',
              'adopt',
              'replace',
              'remove',
              'backup',
              'recover',
            ]) {
              expect(
                _containsCommandEntry(result.output!, command),
                isTrue,
                reason: command,
              );
            }
            expect(_containsCommandEntry(result.output!, 'discover'), isFalse);
          },
        );
      }
    });

    group('agent', () {
      test('help lists native inspection commands', () async {
        final result = _expectSuccess(
          await createExecutor().fake().execute(['agent', '--help']),
          isNotEmpty,
        );
        for (final command in ['list', 'inspect', 'validate']) {
          expect(_containsCommandEntry(result.output!, command), isTrue);
        }
      });
    });

    for (final leaf in ['discover', 'inspect', 'validate']) {
      test('rejects root-level $leaf invocation', () async {
        _expectFailure(await createExecutor().fake().execute([leaf]), leaf);
      });
    }

    test('repeated root help requests remain equivalent', () async {
      final adapter = createExecutor().fake();
      final first = _expectSuccess(
        await adapter.execute(['--help']),
        isNotEmpty,
      );
      final second = _expectSuccess(
        await adapter.execute(['--help']),
        equals(first.output),
      );

      expect(second.output, equals(first.output));
    });

    for (final control in ['--version', '-v']) {
      test('$control reports version 0.0.0 successfully', () async {
        final result = _expectSuccess(
          await createExecutor().fake().execute([control]),
          allOf(isNotEmpty, contains('0.0.0')),
        );
        final output = result.output!;

        expect(
          RegExp(
            r'^\s*usage\s*:',
            caseSensitive: false,
            multiLine: true,
          ).hasMatch(output),
          isFalse,
        );
        expect(output, isNot(contains('This is a CLI app')));
      });
    }

    test('long and short version controls produce equivalent output', () async {
      final longControl = _expectSuccess(
        await createExecutor().fake().execute(['--version']),
        allOf(isNotEmpty, contains('0.0.0')),
      );
      final shortControl = _expectSuccess(
        await createExecutor().fake().execute(['-v']),
        equals(longControl.output),
      );

      expect(shortControl.output, equals(longControl.output));
    });

    test('successive version requests remain stable', () async {
      final adapter = createExecutor().fake();
      final first = _expectSuccess(
        await adapter.execute(['--version']),
        allOf(isNotEmpty, contains('0.0.0')),
      );
      final second = _expectSuccess(
        await adapter.execute(['--version']),
        equals(first.output),
      );

      expect(second.output, equals(first.output));
    });

    test(
      'help, rejection, version, and help sequences remain independent',
      () async {
        final adapter = createExecutor().fake();
        final firstHelp = _expectSuccess(
          await adapter.execute(['--help']),
          isNotEmpty,
        );
        final firstVersion = _expectSuccess(
          await adapter.execute(['--version']),
          allOf(isNotEmpty, contains('0.0.0')),
        );
        _expectFailure(
          await adapter.execute(['unsupported-command']),
          'unsupported-command',
        );
        final afterRejection = _expectSuccess(
          await adapter.execute(['--version']),
          equals(firstVersion.output),
        );
        final afterVersion = _expectSuccess(
          await adapter.execute(['--help']),
          equals(firstHelp.output),
        );

        expect(afterRejection.output, equals(firstVersion.output));
        expect(afterVersion.output, equals(firstHelp.output));
      },
    );

    test('fresh executors report the same version', () async {
      final first = _expectSuccess(
        await createExecutor().fake().execute(['--version']),
        allOf(isNotEmpty, contains('0.0.0')),
      );
      final second = _expectSuccess(
        await createExecutor().fake().execute(['--version']),
        equals(first.output),
      );

      expect(second.output, equals(first.output));
    });

    final rejectedInvocations = [
      (
        name: 'unknown command',
        arguments: ['unsupported-command'],
        diagnosticToken: 'unsupported-command',
      ),
      (
        name: 'unknown long option',
        arguments: ['--unsupported'],
        diagnosticToken: '--unsupported',
      ),
      (name: 'unknown short option', arguments: ['-x'], diagnosticToken: '-x'),
      (
        name: 'unknown option with attached value',
        arguments: ['--unsupported=value'],
        diagnosticToken: '--unsupported',
      ),
    ];
    for (final invocation in rejectedInvocations) {
      test(
        '${invocation.name} is rejected with its diagnostic token',
        () async {
          _expectFailure(
            await createExecutor().fake().execute(invocation.arguments),
            invocation.diagnosticToken,
          );
        },
      );
    }

    test('repeated rejected invocations remain equivalent failures', () async {
      final adapter = createExecutor().fake();
      final first = _expectFailure(
        await adapter.execute(['--unsupported']),
        '--unsupported',
      );
      final second = _expectFailure(
        await adapter.execute(['--unsupported']),
        '--unsupported',
      );

      expect(second.message, equals(first.message));
      expect(second.error.phase, equals(first.error.phase));
      expect(second.error.commandPath, equals(first.error.commandPath));
    });

    test(
      'a rejection followed by help returns root help successfully',
      () async {
        final adapter = createExecutor().fake();
        final failure = _expectFailure(
          await adapter.execute(['unsupported-command']),
          'unsupported-command',
        );
        final help = _expectSuccess(
          await adapter.execute(['--help']),
          isNotEmpty,
        );

        expect(failure.output, isNull);
        expect(help.output, contains('agent_resource'));
      },
    );
  });
}
