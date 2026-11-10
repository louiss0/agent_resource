import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/authoring_publication_service.dart';
import 'package:agent_resource/src/services/authoring_recovery_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
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
      throwsA(isA<FileSystemException>()),
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

  Future<MambaExecutionResult> invoke(
    String action, {
    String? id,
    List<String> extra = const [],
  }) => createExecutor(fileSystem: fs, authoringRecovery: recovery)
      .fake()
      .execute([
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

  Map<String, dynamic> envelope(MambaExecutionResult result) {
    if (result is MambaFailureResult) fail(result.message);
    final output = (result as MambaSuccessResult).output;
    return jsonDecode(output!) as Map<String, dynamic>;
  }

  group('agent_resource', () {
    group('authoring', () {
      test('help lists the recovery actions', () async {
        final result = await invoke('list');

        expect(result, isA<MambaSuccessResult>());
        expect(envelope(result)['data'], isNotNull);
      });

      test('list reports the recorded transactions', () async {
        final id = await interruptedPublication();

        final result = await invoke('list');

        final data = envelope(result)['data']! as Map<String, dynamic>;
        final transactions = data['transactions']! as List<dynamic>;
        expect(transactions, hasLength(1));
        expect(
          (transactions.single! as Map<String, dynamic>)['transactionId'],
          id,
        );
      });

      test('inspect reports the permitted recovery without writing', () async {
        final id = await interruptedPublication();

        final result = await invoke('inspect', id: id);

        final data = envelope(result)['data']! as Map<String, dynamic>;
        expect(data['permittedAction'], 'rollback');
        expect(data['writes'], isFalse);
      });

      test('an unknown transaction is refused', () async {
        final result = await invoke(
          'inspect',
          id: 'aut_0123456789abcdef0123456789abcdef',
        );

        expect(result, isA<MambaFailureResult>());
        expect((result as MambaFailureResult).exitCode, 4);
      });

      test('a stale review identity is refused', () async {
        final id = await interruptedPublication();

        final result = await invoke(
          'recover',
          id: id,
          extra: ['--apply', '--yes', '--plan-id', 'stale-review'],
        );

        expect(result, isA<MambaFailureResult>());
        expect((result as MambaFailureResult).exitCode, 4);
      });

      test('a reviewed recovery restores the source', () async {
        final id = await interruptedPublication();
        final review = envelope(await invoke('inspect', id: id));
        final data = review['data']! as Map<String, dynamic>;

        final result = await invoke(
          'recover',
          id: id,
          extra: ['--apply', '--yes', '--plan-id', data['reviewId']! as String],
        );

        expect(envelope(result)['outcome'], 'rolledBack');
        expect(
          fs.file('/project/source/demo/SKILL.md').readAsStringSync(),
          contains('Original instructions.'),
        );
      });

      test('a cleanup without the review identity stays a review', () async {
        final id = await interruptedPublication();

        final result = await invoke('cleanup', id: id);

        expect(envelope(result)['outcome'], 'planned');
      });

      test('a review without --apply publishes nothing', () async {
        final id = await interruptedPublication();
        final review = envelope(await invoke('inspect', id: id));
        final data = review['data']! as Map<String, dynamic>;

        final result = await invoke(
          'recover',
          id: id,
          extra: ['--yes', '--plan-id', data['reviewId']! as String],
        );

        expect(envelope(result)['outcome'], 'planned');
        expect(
          fs.file('/project/source/demo/SKILL.md').readAsStringSync(),
          contains('Updated instructions.'),
        );
      });
    });
  });
}
