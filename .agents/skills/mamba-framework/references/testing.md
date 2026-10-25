# Testing

Test a Mamba application at its porcelain boundary: pass command-line tokens
to `Executor.fake().execute(...)`, then assert the complete structured result.
Use Git-shaped examples and organize the test suite like the command tree so a
failure immediately identifies the affected command path.

Import `package:mamba/mamba.dart` for commands, hook mixins, context types,
`ProcessedStandardInput`, and `MambaException`. Add
`package:mamba/executor.dart` for execution results and phase metadata.
Exception messages and fake results stay plain text; production execution
renders failure diagnostics to stderr in Chalk red when color is enabled.

## Mirror the command tree

Every `group()` must be affiliated with the executor or a command. Name groups
with command tokens rather than class names, implementation concepts, or broad
labels such as `success cases`.

```dart
void main() {
  group('git', () {
    group('commit', () {
      test('records staged changes', () async {});
    });

    group('remote', () {
      test('shows its child commands', () async {});

      group('add', () {
        test('adds a named remote', () async {});
      });

      group('remove', () {
        test('removes a named remote', () async {});
      });
    });
  });
}
```

The outer `git` group belongs to the executor. A root `Command` gets one group
inside it. A `GroupCommand` gets one group containing a nested group for every
child command, including when a child has only one test. Put a test directly
inside a group only when it exercises behavior owned by that exact command
path. Test descriptions state behavior without repeating the path:

```dart
group('commit', () {
  test('records the selected path', () async {});
  test('requires a message', () async {});
});
```

Create a fresh fake executor in each test unless the behavior under test is
executor reuse. This keeps command and context state local to the test that
creates it. Creating another adapter from the same configured executor does
not isolate its retained context or commands. For reuse/concurrency tests,
make state sharing explicit; otherwise construct fresh commands and contexts.

Fake execution does not intercept application-owned file/network calls,
prompts, or progress. Inject those services through command constructors or
callbacks, then assert the calls and returned result. `standardInput` only
supplies the selected command pre-hook's buffered input; it is not a terminal
prompt-answer mechanism.

## Assert the result contract

Every success assertion covers the result variant, zero exit code, and exact
output. Assert `null` explicitly when silence is the intended output.

```dart
expect(
  result,
  isA<MambaSuccessResult>()
      .having((value) => value.exitCode, 'exit code', 0)
      .having((value) => value.output, 'output', 'Committed README.md.'),
);
```

Every failure assertion covers the result variant, non-zero exit code,
surfaced message, output, error phase, and resolved command path. The
`message` assertion is mandatory: it proves the user receives the intended
diagnostic instead of only proving that an internal failure exists. An error's
`commandPath` is the full registry path, including the application name;
invocation tokens still exclude that name.

```dart
expect(
  result,
  isA<MambaFailureResult>()
      .having((value) => value.exitCode, 'exit code', 1)
      .having(
        (value) => value.message,
        'message',
        'Option --message is required.',
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
        ['git', 'commit'],
      ),
);
```

Use the exact message when it is part of the command's contract. Failures
expose one required `error`, not an errors list. An ordinary `postRun` exception
skips persistent post-hooks:

```dart
expect(failure.error.exception.message, 'failed to close transport');
expect(failure.error.phase, MambaExecutionPhase.postRun);
```

Persistent post-hooks run concurrently only after ordinary `postRun` succeeds.
If several fail, assert the first observed exception, not a tree-order list.
Failure returns immediately while siblings continue running. A first observed
Dart `Error` escapes immediately instead. Later failures are consumed and do
not replace the result; success still waits for every hook.

## Test a single command and its inputs

Exercise inputs through the command rather than calling `Parser` directly.
The command's output or injected dependency should expose the values it
received.

```dart
final class CommitCommand extends Command {
  new({this.hasStagedChanges = true})
    : super(
        mandatoryPositionals: [_path],
        flags: [_amend],
        options: [_message],
      );

  static final _path = NormalPositional('path');
  static final _amend = BooleanFlag('amend');
  static final _message = StringOption.required(
    'message',
    short: 'm',
    regex: RegExp(r'.+'),
  );

  final bool hasStagedChanges;

  @override
  String get name => 'commit';

  @override
  String get shortDescription => 'Record changes.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    if (!hasStagedChanges) {
      throw MambaException('nothing to commit, working tree clean');
    }
    final path = valueOf(_path);
    final message = valueOf(_message);
    final amend = valueOf(_amend);
    final action = amend ? 'Amended' : 'Committed';
    return '$action $path with message: $message';
  }
}
```

Place parameterized cases inside the command's group. Keep one record per
behavior and create the executor inside each generated test. The case name
describes the behavior; the surrounding groups supply the `git commit` path.
Use separate case tables when success and failure require different expected
fields, but keep both loops directly inside the `commit` group:

```dart
group('git', () {
  group('commit', () {
    final successCases = [
      (
        name: 'records a path with a message',
        command: CommitCommand(),
        arguments: ['commit', 'README.md', '-m', 'Document testing'],
        output: 'Committed README.md with message: Document testing',
      ),
      (
        name: 'amends the previous commit',
        command: CommitCommand(),
        arguments: [
          'commit',
          'README.md',
          '--message',
          'Clarify testing',
          '--amend',
        ],
        output: 'Amended README.md with message: Clarify testing',
      ),
    ];

    for (final testCase in successCases) {
      test(testCase.name, () async {
        final result = await Executor(
          'git',
          'Track source changes.',
          '1.0.0',
          [testCase.command],
        ).fake().execute(testCase.arguments);

        expect(
          result,
          isA<MambaSuccessResult>()
              .having((value) => value.exitCode, 'exit code', 0)
              .having((value) => value.output, 'output', testCase.output),
        );
      });
    }

    final failureCases = [
      (
        name: 'requires a message',
        command: CommitCommand(),
        arguments: ['commit', 'README.md'],
        message: 'Option --message is required.',
        phase: MambaExecutionPhase.parse,
      ),
      (
        name: 'surfaces a clean working tree',
        command: CommitCommand(hasStagedChanges: false),
        arguments: ['commit', 'README.md', '-m', 'Document testing'],
        message: 'nothing to commit, working tree clean',
        phase: MambaExecutionPhase.run,
      ),
    ];

    for (final testCase in failureCases) {
      test(testCase.name, () async {
        final result = await Executor(
          'git',
          'Track source changes.',
          '1.0.0',
          [testCase.command],
        ).fake().execute(testCase.arguments);

        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', 1)
              .having(
                (value) => value.message,
                'message',
                testCase.message,
              )
              .having((value) => value.output, 'output', isNull)
              .having(
                (value) => value.error.phase,
                'phase',
                testCase.phase,
              )
              .having(
                (value) => value.error.commandPath,
                'command path',
                ['git', 'commit'],
              ),
        );
      });
    }
  });
});
```

For optional and defaulted inputs, test both omission and explicit input. For
repeatable, paired, selected, accessor, conflicting, and variadic inputs, test
one accepted shape and every user-visible rejection rule configured by the
command. For typed file/folder/URL inputs, cover the relevant lexical rejection
rules, exact-text preservation, nullable/defaulted reads, and repeated capacity,
uniqueness, order, and default replacement. Path parsing must not require a
real file or folder. Suffixes filter completions only: include an otherwise
valid different-extension value when this distinction matters. Use real
`UrlValue.parse` values for defaults and assert intentional safe output rather
than accidentally publishing raw credentials or query secrets.

## Test group commands

Build the production command hierarchy and invoke children through their full
path. The test hierarchy must match it.

```dart
final class RemoteCommand extends GroupCommand {
  new() : super([RemoteAddCommand(), RemoteRemoveCommand()]);

  @override
  String get name => 'remote';

  @override
  String get shortDescription => 'Manage remotes.';
}

final class RemoteAddCommand extends Command {
  new() : super(mandatoryPositionals: [_name, _url]);

  static final _name = NormalPositional('name');
  static final _url = NormalPositional('url');

  @override
  String get name => 'add';

  @override
  String get shortDescription => 'Add a remote.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final name = valueOf(_name);
    final url = valueOf(_url);
    return 'Added remote $name at $url.';
  }
}

final class RemoteRemoveCommand extends Command {
  new() : super(mandatoryPositionals: [_name]);

  static final _name = NormalPositional('name');

  @override
  String get name => 'remove';

  @override
  String get shortDescription => 'Remove a remote.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final name = valueOf(_name);
    return 'Removed remote $name.';
  }
}
```

```dart
group('git', () {
  group('remote', () {
    test('shows its child commands', () async {
      final result = await Executor(
        'git',
        'Track source changes.',
        '1.0.0',
        [RemoteCommand()],
      ).fake().execute(['remote', '--help']);

      expect(
        result,
        isA<MambaSuccessResult>()
            .having((value) => value.exitCode, 'exit code', 0)
            .having(
              (value) => value.output,
              'output',
              allOf(contains('add'), contains('remove')),
            ),
      );
    });

    group('add', () {
      test('adds a named remote', () async {
        final result = await Executor(
          'git',
          'Track source changes.',
          '1.0.0',
          [RemoteCommand()],
        ).fake().execute([
          'remote',
          'add',
          'origin',
          'git@example.com:team/project.git',
        ]);

        expect(
          result,
          isA<MambaSuccessResult>()
              .having((value) => value.exitCode, 'exit code', 0)
              .having(
                (value) => value.output,
                'output',
                'Added remote origin at '
                    'git@example.com:team/project.git.',
              ),
        );
      });

      test('requires a remote URL', () async {
        final result = await Executor(
          'git',
          'Track source changes.',
          '1.0.0',
          [RemoteCommand()],
        ).fake().execute(['remote', 'add', 'origin']);

        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', 1)
              .having(
                (value) => value.message,
                'message',
                'The url is required at 1 after this command',
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
                ['git', 'remote', 'add'],
              ),
        );
      });
    });

    group('remove', () {
      test('removes a named remote', () async {
        final result = await Executor(
          'git',
          'Track source changes.',
          '1.0.0',
          [RemoteCommand()],
        ).fake().execute(['remote', 'remove', 'upstream']);

        expect(
          result,
          isA<MambaSuccessResult>()
              .having((value) => value.exitCode, 'exit code', 0)
              .having(
                (value) => value.output,
                'output',
                'Removed remote upstream.',
              ),
        );
      });
    });
  });
});
```

The remote URL in this Git-shaped example deliberately uses `NormalPositional`:
Git accepts SCP-style addresses such as `git@example.com:team/project.git`,
which are not Mamba's explicit-scheme, host-bearing `UrlPositional` values.
Choose a declaration by the application's accepted syntax, not just its name.

Test group-owned help, propagated inputs, default subcommands, and persistent
hooks directly inside the parent command's group. Test child behavior only
inside that child's nested group.

## Test command hooks

Record observable lifecycle events in a list owned by the test. Assert the
result contract and the event order. This proves both user-facing behavior and
the hook lifecycle.

```dart
final class PushCommand extends Command with HookRunner {
  new(this.events, {this.rejectAuthentication = false});

  final List<String> events;
  final bool rejectAuthentication;

  @override
  String get name => 'push';

  @override
  String get shortDescription => 'Update a remote.';

  @override
  void preRun(
    ValueOf valueOf,
    MambaReadContext context,
    ProcessedStandardInput? input,
  ) {
    events.add('authenticate');
    if (rejectAuthentication) {
      throw MambaException('fatal: authentication failed', exitCode: 128);
    }
  }

  @override
  String run(ValueOf valueOf, List<String> args) {
    events.add('push');
    return 'Pushed to origin.';
  }

  @override
  void postRun(ValueOf valueOf, MambaReadContext context) {
    events.add('close transport');
  }
}
```

```dart
group('git', () {
  group('push', () {
    test('runs hooks around the command', () async {
      final events = <String>[];
      final result = await Executor(
        'git',
        'Track source changes.',
        '1.0.0',
        [PushCommand(events)],
      ).fake().execute(['push']);

      expect(
        result,
        isA<MambaSuccessResult>()
            .having((value) => value.exitCode, 'exit code', 0)
            .having((value) => value.output, 'output', 'Pushed to origin.'),
      );
      expect(events, ['authenticate', 'push', 'close transport']);
    });

    test('surfaces a pre-hook failure', () async {
      final events = <String>[];
      final result = await Executor(
        'git',
        'Track source changes.',
        '1.0.0',
        [PushCommand(events, rejectAuthentication: true)],
      ).fake().execute(['push']);

      expect(
        result,
        isA<MambaFailureResult>()
            .having((value) => value.exitCode, 'exit code', 128)
            .having(
              (value) => value.message,
              'message',
              'fatal: authentication failed',
            )
            .having((value) => value.output, 'output', isNull)
            .having(
              (value) => value.error.phase,
              'phase',
              MambaExecutionPhase.preRun,
            )
            .having(
              (value) => value.error.commandPath,
              'command path',
              ['git', 'push'],
            ),
      );
      expect(events, ['authenticate']);
    });
  });
});
```

Test a `PersistentHookRunner` through a selected child path and assert outer
pre-hook, child hooks and run, then outer post-hook in order. For each hook
that can fail, assert its exact surfaced message, exit code, phase, command
path, and retained output. Pre-hook and `run` exceptions must skip every
post-hook; an ordinary `postRun` exception must skip persistent post-hooks.
Use `Completer`s to prove that persistent post-hooks overlap and that success
awaits every hook. Pause an outer post-hook, fail an inner one, and assert that
execution returns the inner failure before releasing the outer hook. Verify
the owning group's path, original trace, and retained output. Release the
sibling and verify that its later `Exception` or `Error` does not replace the
first failure. A first observed Dart `Error` must escape while siblings remain
paused.

Pass `ProcessedStandardInput` to `fake()` when `preRun` reads piped input:

```dart
import 'dart:convert';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  test('apply reads standard input', () async {
    final input = ProcessedStandardInput(utf8.encode('ref=main\n'));
    final result = await Executor(
      'git',
      'Track source changes.',
      '1.0.0',
      [ApplyCommand()],
    ).fake(standardInput: input).execute(['apply']);

    expect(result, isA<MambaSuccessResult>());
  });
}
```

Assert what the hook observed in addition to the complete execution result.

## Completion checklist

Before finishing a command test suite, verify:

- the `group()` hierarchy mirrors every tested command path;
- every child of a tested `GroupCommand` has a nested group;
- parameterized case loops stay inside the group for their command path;
- every success asserts its variant, exit code, and exact or intentionally
  matched output;
- every failure asserts its variant, exit code, surfaced message, output,
  error phase and command path;
- every registered input has meaningful accepted and rejected coverage;
- command-domain failures are distinct from parse failures;
- hook tests assert sequential setup, fail-fast phases, and concurrent
  persistent post-hook completion;
- standard input and context are asserted when a hook consumes them;
- fake execution is not mistaken for mocking application-owned effects; and
- typed path/URL cases cover the configured validation, repetition, defaults,
  and safe-display behavior.

When changing global inputs, defaults, propagation, or help rendering, also
check root and nested help, intrinsic help/version bypasses, canonical paths
when aliases are invoked, and the affected completion artifacts. Keep these
cases in the group that owns the behavior.

The suite is complete only when every tested command and every expected user
diagnostic can be located from the command-group tree alone.
