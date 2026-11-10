import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/authoring_publication_service.dart';
import 'package:agent_resource/src/services/authoring_recovery_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
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
  late AuthoringPlanService plans;
  late AuthoringPublicationService publication;
  late AuthoringRecoveryService recovery;
  late LifecycleOptions options;

  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/work/project').createSync(recursive: true);
    fs.directory('/home/user').createSync(recursive: true);
    io = _FaultyIO(fs);
    state = LifecycleStateService(io: io);
    plans = AuthoringPlanService(fileSystem: fs, state: state);
    publication = AuthoringPublicationService(
      fileSystem: fs,
      state: state,
      recovery: AuthoringRecoveryService(fileSystem: fs, state: state),
    );
    recovery = AuthoringRecoveryService(fileSystem: fs, state: state);
    options = LifecycleOptions(
      processWorkingDirectory: '/work/project',
      environment: const <String, String>{},
      scope: LifecycleScope.project,
      cwd: '/work/project',
      projectRoot: '/work/project',
      home: '/home/user',
      stateDir: '/work/state',
    );
  });

  /// The skill package of one source directory.
  void seedSkill(
    String directory, {
    String name = 'demo',
    String body = 'Original instructions.',
  }) {
    fs.directory(directory).createSync(recursive: true);
    fs
        .file('$directory/SKILL.md')
        .writeAsStringSync(
          '---\nname: $name\ndescription: Demonstrates the publication.\n---\n$body',
        );
  }

  /// The recorded authoring transactions of the selected scope.
  List<Map<String, Object?>> transactions() {
    final directory = fs.directory(
      '/work/project/.agent-resource/authoring-transactions',
    );
    if (!directory.existsSync()) return const <Map<String, Object?>>[];
    return [
      for (final entry in directory.listSync())
        if (RegExp(r'aut_[a-f0-9]{32}\.json$').hasMatch(entry.path))
          Map<String, Object?>.from(
            jsonDecode(fs.file(entry.path).readAsStringSync())
                as Map<String, Object?>,
          ),
    ];
  }

  /// The reviewed plan of one ordinary edit.
  Future<AuthoringPlan> editPlan() async {
    seedSkill('/work/source/demo');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.edit,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      scope: LifecycleScope.project,
      sourcePath: '/work/source/demo',
      bodyText: 'Updated instructions.',
    );
    final plan = await plans.plan(inputs, options);
    expect(plan.ready, isTrue, reason: '${plan.diagnostics}');
    return plan;
  }

  /// Publishes the reviewed plan and stops at the selected failure.
  Future<void> publish(AuthoringPlan plan, {String? failingPath}) async {
    io.failingOperation = 'write';
    io.failingPath = failingPath;
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
  }

  group('authoring recovery', () {
    test('an ordinary publication records a committed transaction', () async {
      final plan = await editPlan();
      final outcome = await publication.publish(
        AuthoringPublicationRequest(
          plan: plan,
          options: options,
          planId: plan.planId,
          approved: true,
        ),
      );

      final records = transactions();
      expect(records, hasLength(1));
      expect(records.single['phase'], 'completed');
      expect(records.single['operation'], 'edit');
      expect(records.single['ownership'], 'authorOnly');
      expect(records.single['receiptId'], outcome.receiptId);
    });

    test('the inventory lists the recorded transactions', () async {
      final plan = await editPlan();
      await publication.publish(
        AuthoringPublicationRequest(
          plan: plan,
          options: options,
          planId: plan.planId,
          approved: true,
        ),
      );

      final result = await recovery.inventory(options);

      expect(result.outcome, 'listed');
      final listed = result.data['transactions']! as List<Object?>;
      expect(listed, hasLength(1));
      expect((listed.single! as Map<String, Object?>)['phase'], 'completed');
    });

    test(
      'an interrupted publication stays reviewable and rolls back',
      () async {
        final plan = await editPlan();
        await publish(plan, failingPath: 'authoring-receipts');

        final records = transactions();
        expect(records, hasLength(1));
        expect(records.single['phase'], 'published');

        final review = await recovery.inspect(
          options,
          records.single['transactionId']! as String,
        );
        expect(review.data['permittedAction'], 'rollback');
        expect(review.data['writes'], isFalse);

        final applied = await recovery.recoverReviewed(
          options.copyWith(approved: true),
          records.single['transactionId']! as String,
          planId: review.data['reviewId']! as String,
        );

        expect(applied.outcome, 'rolledBack');
        expect(
          fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
          contains('Original instructions.'),
        );
        expect(transactions().single['phase'], 'rolledBack');
      },
    );

    test(
      'a stale review identity and a missing approval are refused',
      () async {
        final plan = await editPlan();
        await publish(plan, failingPath: 'authoring-receipts');
        final transactionId = transactions().single['transactionId']! as String;

        await expectLater(
          recovery.recoverReviewed(
            options.copyWith(approved: true),
            transactionId,
            planId: 'stale-review',
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'diagnostic',
              contains('current review identity'),
            ),
          ),
        );
        await expectLater(
          recovery.recoverReviewed(
            options,
            transactionId,
            planId: 'stale-review',
          ),
          throwsA(isA<MambaException>()),
        );
      },
    );

    test('a changed target refuses the rollback', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      fs
          .file('/work/source/demo/SKILL.md')
          .writeAsStringSync(
            '---\nname: demo\ndescription: Changed.\n---\nOther.',
          );
      final review = await recovery.inspect(options, transactionId);

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Other.'),
      );
    });

    test('a terminal transaction refuses a repeated recovery', () async {
      final plan = await editPlan();
      await publication.publish(
        AuthoringPublicationRequest(
          plan: plan,
          options: options,
          planId: plan.planId,
          approved: true,
        ),
      );
      final transactionId = transactions().single['transactionId']! as String;

      final review = await recovery.inspect(options, transactionId);
      expect(review.data['permittedAction'], isNull);
      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('terminal'),
          ),
        ),
      );
    });

    test('the cleanup removes the retained payload and keeps the receipt', () async {
      final plan = await editPlan();
      final outcome = await publication.publish(
        AuthoringPublicationRequest(
          plan: plan,
          options: options,
          planId: plan.planId,
          approved: true,
        ),
      );
      final transactionId = transactions().single['transactionId']! as String;
      expect(
        fs
            .directory(
              '/work/project/.agent-resource/authoring-recovery/${plan.planId}',
            )
            .existsSync(),
        isTrue,
      );

      final review = await recovery.cleanupReviewed(options, transactionId);
      expect(review.outcome, 'planned');
      final applied = await recovery.cleanupReviewed(
        options.copyWith(approved: true),
        transactionId,
        planId: review.data['reviewId']! as String,
      );

      expect(applied.outcome, 'cleaned');
      expect(
        fs
            .directory(
              '/work/project/.agent-resource/authoring-recovery/${plan.planId}',
            )
            .existsSync(),
        isFalse,
      );
      expect(transactions(), hasLength(1));
      expect(
        fs
            .file(
              '/work/project/.agent-resource/authoring-receipts/'
              '${outcome.receiptId}.json',
            )
            .existsSync(),
        isTrue,
      );
    });

    test('an unfinished transaction refuses the cleanup', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      final review = await recovery.cleanupReviewed(options, transactionId);

      await expectLater(
        recovery.cleanupReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('not terminal'),
          ),
        ),
      );
    });

    test('a reconstructed service reads the persisted transaction', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;

      final reconstructed = AuthoringRecoveryService(
        fileSystem: fs,
        state: LifecycleStateService(io: LifecycleIO(fs: fs)),
      );
      final review = await reconstructed.inspect(options, transactionId);

      expect(review.data['transactionId'], transactionId);
      expect(review.data['permittedAction'], 'rollback');
    });

    test(
      'an interrupted Agent file publication restores the source file',
      () async {
        fs
            .file('/project/agents/reviewer.md')
            .parent
            .createSync(recursive: true);
        fs
            .file('/project/agents/reviewer.md')
            .writeAsStringSync(
              '---\nname: reviewer\ndescription: Reviews the change.\n---\n'
              'Original instructions.',
            );
        final plans = AuthoringPlanService(fileSystem: fs, state: state);
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.edit,
          kind: AuthoringKind.agent,
          profile: AuthoringProfile.claude,
          scope: LifecycleScope.project,
          sourcePath: '/project/agents/reviewer.md',
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
        final transactionId = transactions().single['transactionId']! as String;
        final review = await recovery.inspect(options, transactionId);
        expect(review.data['permittedAction'], 'rollback');

        final applied = await recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        );

        expect(applied.outcome, 'rolledBack');
        expect(
          fs.file('/project/agents/reviewer.md').readAsStringSync(),
          contains('Original instructions.'),
        );
      },
    );

    test(
      'a corrupt transaction stays visible as unresolved evidence',
      () async {
        final plan = await editPlan();
        await publish(plan, failingPath: 'authoring-receipts');
        final transactionId = transactions().single['transactionId']! as String;
        fs
            .file(
              '/work/project/.agent-resource/authoring-transactions/'
              '$transactionId.json',
            )
            .writeAsStringSync('{corrupt');

        final result = await recovery.inventory(options);

        expect(result.diagnostics, isNotEmpty);
        expect(result.diagnostics.first['code'], 'EVIDENCE_UNRESOLVED');
        await expectLater(
          recovery.inspect(options, transactionId),
          throwsA(isA<MambaException>()),
        );
      },
    );

    test('a committed receipt refuses the rollback', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      // The receipt is the commit point: a publication that committed it is
      // never rolled back.
      final receipt = transactions().single['receiptId']! as String;
      fs
          .file(
            '/work/project/.agent-resource/authoring-receipts/$receipt.json',
          )
          .writeAsStringSync('{"receiptId": "$receipt"}');
      final review = await recovery.inspect(options, transactionId);

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
    });

    test('a repeated cleanup is refused', () async {
      final plan = await editPlan();
      await publication.publish(
        AuthoringPublicationRequest(
          plan: plan,
          options: options,
          planId: plan.planId,
          approved: true,
        ),
      );
      final transactionId = transactions().single['transactionId']! as String;
      final review = await recovery.cleanupReviewed(options, transactionId);
      await recovery.cleanupReviewed(
        options.copyWith(approved: true),
        transactionId,
        planId: review.data['reviewId']! as String,
      );

      final repeated = await recovery.cleanupReviewed(options, transactionId);
      await expectLater(
        recovery.cleanupReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: repeated.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('already removed'),
          ),
        ),
      );
    });

    test('the inventory surfaces an orphan private payload', () async {
      fs
          .directory(
            '/work/project/.agent-resource/authoring-recovery/orphan-plan',
          )
          .createSync(recursive: true);

      final result = await recovery.inventory(options);

      final orphans = result.data['orphans']! as List<Object?>;
      expect(orphans, isNotEmpty);
      expect(
        (orphans.first! as Map<String, Object?>)['kind'],
        'authoring-recovery',
      );
    });

    test('an unknown transaction is refused', () async {
      await expectLater(
        recovery.inspect(options, 'aut_0123456789abcdef0123456789abcdef'),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 4),
        ),
      );
    });
  });
}
