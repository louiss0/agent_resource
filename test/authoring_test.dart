import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/authoring_publication_service.dart';
import 'package:agent_resource/src/services/authoring_recovery_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

/// An IO seam that fails one selected durable operation.
class _FaultyIO extends LifecycleIO {
  _FaultyIO(this.memory) : super(fs: memory);

  final MemoryFileSystem memory;
  String? failingOperation;
  String? failingPath;

  @override
  void before(String operation, String path) {
    if (failingOperation != operation) return;
    if (failingPath != null && !path.contains(failingPath!)) return;
    throw FileSystemException('Injected failure', path);
  }
}

void main() {
  late MemoryFileSystem fs;
  late _FaultyIO io;
  late LifecycleStateService state;
  late AuthoringRecoveryService recovery;
  late LifecycleOptions options;

  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/project').createSync(recursive: true);
    fs.directory('/home').createSync(recursive: true);
    fs.currentDirectory = '/project';
    io = _FaultyIO(fs);
    state = LifecycleStateService(io: io);
    recovery = AuthoringRecoveryService(fileSystem: fs, state: state);
    options = LifecycleOptions(
      processWorkingDirectory: '/project',
      environment: const <String, String>{},
      scope: LifecycleScope.project,
      cwd: '/project',
      projectRoot: '/project',
      home: '/home',
      stateDir: '/state',
    );
  });

  /// Publishes an ordinary edit that stops before its receipt.
  ///
  /// The interruption is produced by the real publisher through the injected
  /// [LifecycleIO]: the durable receipt write fails, so the transaction stays
  /// unresolved and a recovery can be reviewed against it.
  Future<String> interruptedPublication() async {
    fs.directory('/project/source/demo').createSync(recursive: true);
    fs
        .file('/project/source/demo/SKILL.md')
        .writeAsStringSync(
          '---\nname: demo\ndescription: Demonstrates the publication.\n---\n'
          'Original instructions.',
        );
    final plans = AuthoringPlanService(fileSystem: fs, state: state);
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.edit,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      scope: LifecycleScope.project,
      sourcePath: '/project/source/demo',
      bodyText: 'Updated instructions.',
    );
    final plan = await plans.plan(inputs, options);
    expect(plan.ready, isTrue, reason: '${plan.diagnostics}');
    final publication = AuthoringPublicationService(
      fileSystem: fs,
      state: state,
      recovery: recovery,
    );
    io.failingOperation = 'write';
    io.failingPath = 'authoring-receipts';
    await expectLater(
      publication.publish(
        AuthoringPublicationRequest(
          plan: plan,
          options: options,
          planId: plan.planId,
          approved: true,
        ),
      ),
      throwsA(
        isA<MambaException>()
            .having(
              (error) => error.message,
              'message',
              'The authoring publication failed: Injected failure',
            )
            .having((error) => error.exitCode, 'exit code', 6),
      ),
    );
    io.failingOperation = null;
    io.failingPath = null;
    final directory = fs
        .directory('/project/.agent-resource/authoring-transactions')
        .listSync();
    expect(directory, hasLength(1));
    final document = jsonDecode(
      fs.file(directory.single.path).readAsStringSync(),
    ) as Map<String, Object?>;
    return document['transactionId']! as String;
  }

  /// Invokes the application with the given tokens.
  Future<MambaExecutionResult> invoke(List<String> arguments) => createExecutor(
    fileSystem: fs,
    authoringRecovery: recovery,
  ).fake().execute(arguments);

  /// Invokes one authoring action with the shared lifecycle locations.
  Future<MambaExecutionResult> invokeAction(
    String action, {
    String? id,
    List<String> extra = const [],
  }) => invoke([
    'authoring',
    action,
    ?id,
    '--format',
    'json',
    '--home',
    '/home/',
    '--project-root',
    '/project/',
    '--state-dir',
    '/state/',
    '--scope',
    'project',
    ...extra,
  ]);

  /// The observed state of every durable location of the fixture.
  Map<String, String> snapshot() {
    final entries = <String, String>{};
    for (final root in const ['/project', '/state', '/home']) {
      if (!fs.directory(root).existsSync()) continue;
      for (final entity in fs.directory(root).listSync(recursive: true)) {
        if (entity is fslib.Directory) {
          entries[entity.path] = '<directory>';
        } else {
          entries[entity.path] = fs.file(entity.path).readAsStringSync();
        }
      }
    }
    return entries;
  }

  /// Asserts the complete success contract and returns the JSON envelope.
  Map<String, dynamic> expectJsonSuccess(
    MambaExecutionResult result, {
    required String command,
    required String outcome,
  }) {
    expect(
      result,
      isA<MambaSuccessResult>()
          .having((value) => value.exitCode, 'exit code', 0)
          .having((value) => value.output, 'output', isNotNull),
    );
    final output = (result as MambaSuccessResult).output!;
    final envelope = jsonDecode(output) as Map<String, dynamic>;
    expect(envelope['schemaVersion'], 1);
    expect(envelope['command'], command);
    expect(envelope['outcome'], outcome);
    expect(envelope['diagnostics'], isEmpty);
    return envelope;
  }

  /// Asserts the complete failure contract.
  void expectFailure(
    MambaExecutionResult result, {
    required int exitCode,
    required String message,
    required MambaExecutionPhase phase,
    required List<String> commandPath,
  }) {
    expect(
      result,
      isA<MambaFailureResult>()
          .having((value) => value.exitCode, 'exit code', exitCode)
          .having((value) => value.message, 'message', message)
          .having((value) => value.output, 'output', isNull)
          .having((value) => value.error.phase, 'phase', phase)
          .having(
            (value) => value.error.commandPath,
            'command path',
            commandPath,
          ),
    );
  }

  group('agent_resource', () {
    group('authoring', () {
      test('lists its recovery actions in the group help', () async {
        final result = await invoke(['authoring', '--help']);

        expect(
          result,
          isA<MambaSuccessResult>()
              .having((value) => value.exitCode, 'exit code', 0)
              .having(
                (value) => value.output,
                'output',
                allOf(
                  contains('list'),
                  contains('inspect'),
                  contains('recover'),
                  contains('cleanup'),
                ),
              ),
        );
      });

      group('list', () {
        test('reports the recorded transactions', () async {
          final id = await interruptedPublication();

          final result = await invokeAction('list');

          final envelope = expectJsonSuccess(
            result,
            command: 'authoring list',
            outcome: 'listed',
          );
          final data = envelope['data']! as Map<String, dynamic>;
          expect(data['count'], 1);
          final transactions = data['transactions']! as List<dynamic>;
          expect(transactions, hasLength(1));
          final transaction = transactions.single! as Map<String, dynamic>;
          expect(transaction['transactionId'], id);
          expect(transaction['scope'], 'project');
          expect(transaction['legacyReadOnly'], isFalse);
        });

        test('reads the evidence without changing it', () async {
          await interruptedPublication();
          final before = snapshot();

          final result = await invokeAction('list');

          expectJsonSuccess(
            result,
            command: 'authoring list',
            outcome: 'listed',
          );
          expect(snapshot(), before);
        });
      });

      group('inspect', () {
        test('reports the permitted recovery without writing', () async {
          final id = await interruptedPublication();
          final before = snapshot();

          final result = await invokeAction('inspect', id: id);

          final envelope = expectJsonSuccess(
            result,
            command: 'authoring inspect',
            outcome: 'inspected',
          );
          final data = envelope['data']! as Map<String, dynamic>;
          expect(data['transactionId'], id);
          expect(data['permittedAction'], 'rollback');
          expect(data['writes'], isFalse);
          expect(data['purpose'], 'recover');
          expect(snapshot(), before);
        });

        test('refuses an unknown transaction', () async {
          final result = await invokeAction(
            'inspect',
            id: 'aut_0123456789abcdef0123456789abcdef',
          );

          expectFailure(
            result,
            exitCode: 4,
            message:
                'No authoring transaction exists for '
                'aut_0123456789abcdef0123456789abcdef.',
            phase: MambaExecutionPhase.run,
            commandPath: ['agent_resource', 'authoring', 'inspect'],
          );
        });

        test('requires a transaction id', () async {
          final result = await invokeAction('inspect');

          expectFailure(
            result,
            exitCode: 1,
            message: 'The transaction-id is required at 0 after this command',
            phase: MambaExecutionPhase.parse,
            commandPath: ['agent_resource', 'authoring', 'inspect'],
          );
        });
      });

      group('recover', () {
        test('describes its guarded inputs in the leaf help', () async {
          final result = await invoke(['authoring', 'recover', '--help']);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  allOf(
                    contains('transaction-id'),
                    contains('--apply'),
                    contains('--yes'),
                    contains('--dry-run'),
                    contains('--plan-id'),
                  ),
                ),
          );
        });

        test('refuses --apply together with --dry-run', () async {
          final id = await interruptedPublication();

          final result = await invokeAction(
            'recover',
            id: id,
            extra: ['--apply', '--dry-run'],
          );

          expectFailure(
            result,
            exitCode: 1,
            message: 'Input --apply conflicts with --dry-run.',
            phase: MambaExecutionPhase.parse,
            commandPath: ['agent_resource', 'authoring', 'recover'],
          );
        });

        test('requires a transaction id', () async {
          final result = await invokeAction('recover', extra: ['--apply']);

          expectFailure(
            result,
            exitCode: 1,
            message: 'The transaction-id is required at 0 after this command',
            phase: MambaExecutionPhase.parse,
            commandPath: ['agent_resource', 'authoring', 'recover'],
          );
        });

        test('refuses a stale review identity', () async {
          final id = await interruptedPublication();

          final result = await invokeAction(
            'recover',
            id: id,
            extra: ['--apply', '--yes', '--plan-id', 'stale-review'],
          );

          expectFailure(
            result,
            exitCode: 4,
            message:
                'Recovery requires the current review identity; stale approval '
                'is refused.',
            phase: MambaExecutionPhase.run,
            commandPath: ['agent_resource', 'authoring', 'recover'],
          );
        });

        test('refuses an apply that is not approved', () async {
          final id = await interruptedPublication();
          final review = expectJsonSuccess(
            await invokeAction('inspect', id: id),
            command: 'authoring inspect',
            outcome: 'inspected',
          );
          final reviewId =
              (review['data']! as Map<String, dynamic>)['reviewId']! as String;
          final before = snapshot();

          final result = await invokeAction(
            'recover',
            id: id,
            extra: ['--apply', '--plan-id', reviewId],
          );

          expectFailure(
            result,
            exitCode: 4,
            message: 'Recovery requires --yes.',
            phase: MambaExecutionPhase.run,
            commandPath: ['agent_resource', 'authoring', 'recover'],
          );
          expect(snapshot(), before);
        });

        test('restores the source when the review is fresh', () async {
          final id = await interruptedPublication();
          final review = expectJsonSuccess(
            await invokeAction('inspect', id: id),
            command: 'authoring inspect',
            outcome: 'inspected',
          );
          final reviewId =
              (review['data']! as Map<String, dynamic>)['reviewId']! as String;

          final result = await invokeAction(
            'recover',
            id: id,
            extra: ['--apply', '--yes', '--plan-id', reviewId],
          );

          final envelope = expectJsonSuccess(
            result,
            command: 'authoring recover',
            outcome: 'rolledBack',
          );
          final data = envelope['data']! as Map<String, dynamic>;
          expect(data['transactionId'], id);
          expect(data['phase'], 'rolledBack');
          expect(data['sourceRestored'], isTrue);
          expect(
            fs.file('/project/source/demo/SKILL.md').readAsStringSync(),
            contains('Original instructions.'),
          );
        });

        test('publishes nothing without --apply', () async {
          final id = await interruptedPublication();
          final review = expectJsonSuccess(
            await invokeAction('inspect', id: id),
            command: 'authoring inspect',
            outcome: 'inspected',
          );
          final reviewId =
              (review['data']! as Map<String, dynamic>)['reviewId']! as String;
          final before = snapshot();

          final result = await invokeAction(
            'recover',
            id: id,
            extra: ['--yes', '--plan-id', reviewId],
          );

          final envelope = expectJsonSuccess(
            result,
            command: 'authoring recover',
            outcome: 'planned',
          );
          final data = envelope['data']! as Map<String, dynamic>;
          expect(data['permittedAction'], 'rollback');
          expect(data['writes'], isFalse);
          expect(
            fs.file('/project/source/demo/SKILL.md').readAsStringSync(),
            contains('Updated instructions.'),
          );
          expect(snapshot(), before);
        });
      });

      group('cleanup', () {
        test('stays a review without the cleanup identity', () async {
          final id = await interruptedPublication();
          final before = snapshot();

          final result = await invokeAction('cleanup', id: id);

          final envelope = expectJsonSuccess(
            result,
            command: 'authoring cleanup',
            outcome: 'planned',
          );
          final data = envelope['data']! as Map<String, dynamic>;
          expect(data['transactionId'], id);
          expect(data['purpose'], 'cleanup');
          expect(data['writes'], isFalse);
          expect(snapshot(), before);
        });

        test('requires a transaction id', () async {
          final result = await invokeAction('cleanup');

          expectFailure(
            result,
            exitCode: 1,
            message: 'The transaction-id is required at 0 after this command',
            phase: MambaExecutionPhase.parse,
            commandPath: ['agent_resource', 'authoring', 'cleanup'],
          );
        });

        test('refuses the recovery review identity', () async {
          final id = await interruptedPublication();
          final review = expectJsonSuccess(
            await invokeAction('inspect', id: id),
            command: 'authoring inspect',
            outcome: 'inspected',
          );
          final reviewId =
              (review['data']! as Map<String, dynamic>)['reviewId']! as String;

          final result = await invokeAction(
            'cleanup',
            id: id,
            extra: ['--apply', '--yes', '--plan-id', reviewId],
          );

          expectFailure(
            result,
            exitCode: 4,
            message:
                'Cleanup requires the current review identity; stale approval '
                'is refused.',
            phase: MambaExecutionPhase.run,
            commandPath: ['agent_resource', 'authoring', 'cleanup'],
          );
        });

        test('refuses to clean an unfinished transaction', () async {
          final id = await interruptedPublication();
          final cleanup = expectJsonSuccess(
            await invokeAction('cleanup', id: id),
            command: 'authoring cleanup',
            outcome: 'planned',
          );
          final reviewId =
              (cleanup['data']! as Map<String, dynamic>)['reviewId']! as String;
          final before = snapshot();

          final result = await invokeAction(
            'cleanup',
            id: id,
            extra: ['--apply', '--yes', '--plan-id', reviewId],
          );

          expectFailure(
            result,
            exitCode: 4,
            message:
                'The authoring transaction is not terminal; an unfinished '
                'transaction is never cleaned up.',
            phase: MambaExecutionPhase.run,
            commandPath: ['agent_resource', 'authoring', 'cleanup'],
          );
          expect(snapshot(), before);
        });
      });
    });
  });
}
