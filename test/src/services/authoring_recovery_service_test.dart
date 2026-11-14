import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/authoring/authoring_transaction.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/authoring_publication_service.dart';
import 'package:agent_resource/src/services/authoring_recovery_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:crypto/crypto.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

/// An IO seam that fails one selected durable operation.
class _FaultyIO extends LifecycleIO {
  _FaultyIO(this.memory) : super(fs: memory);

  final MemoryFileSystem memory;
  String? failingOperation;
  String? failingPath;
  int matchingOperationsToSkip = 0;
  bool failAfterWrite = false;

  @override
  void write(String path, List<int> bytes) {
    if (failAfterWrite &&
        failingOperation == 'write' &&
        (failingPath == null || path.contains(failingPath!))) {
      failingOperation = null;
      super.write(path, bytes);
      failingOperation = 'write';
      throw FileSystemException('Injected post-write failure', path);
    }
    super.write(path, bytes);
  }

  @override
  void before(String operation, String path) {
    if (failingOperation != operation) return;
    if (failingPath != null && !path.contains(failingPath!)) return;
    if (matchingOperationsToSkip > 0) {
      matchingOperationsToSkip--;
      return;
    }
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
      throwsA(
        isA<MambaException>().having((error) => error.exitCode, 'status', 6),
      ),
    );
    io.failingOperation = null;
    io.failingPath = null;
    io.matchingOperationsToSkip = 0;
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

    test('an unreviewed target member refuses the rollback', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      fs
          .file('/work/source/demo/unreviewed.txt')
          .writeAsStringSync('Preserve the new member.');
      final review = await recovery.inspect(options, transactionId);

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('published target changed'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/unreviewed.txt').readAsStringSync(),
        'Preserve the new member.',
      );
      expect(transactions().single['phase'], 'published');
    });

    test('a changed retained payload refuses the rollback', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      final payload = fs.file(
        '/work/project/.agent-resource/authoring-recovery/'
        '${plan.planId}/SKILL.md',
      );
      payload.writeAsStringSync('Damaged recovery bytes.');
      final review = await recovery.inspect(options, transactionId);

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('retained recovery payload'),
              ),
        ),
      );
      expect(payload.readAsStringSync(), 'Damaged recovery bytes.');
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
      expect(transactions().single['phase'], 'published');
    });

    test(
      'a relocated conversion rollback restores the retired source',
      () async {
        seedSkill('/work/source/demo');
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.convert,
          kind: AuthoringKind.prompt,
          profile: AuthoringProfile.pi,
          scope: LifecycleScope.project,
          sourcePath: '/work/source/demo',
          conversion: ConversionDirection.skillToPrompt,
        );
        final plan = await plans.plan(inputs, options);
        expect(plan.ready, isTrue, reason: '${plan.diagnostics}');
        await publish(plan, failingPath: 'authoring-receipts');
        final transactionId = transactions().single['transactionId']! as String;
        expect(fs.directory('/work/source/demo').existsSync(), isFalse);
        expect(
          fs.file('/work/project/.pi/prompts/demo.md').existsSync(),
          isTrue,
        );
        final review = await recovery.inspect(options, transactionId);

        final applied = await recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        );

        expect(applied.outcome, 'rolledBack');
        expect(applied.data['sourceRestored'], isTrue);
        expect(
          fs.file('/work/project/.pi/prompts/demo.md').existsSync(),
          isFalse,
        );
        expect(
          fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
          contains('Original instructions.'),
        );
        expect(transactions().single['phase'], 'rolledBack');
      },
    );

    test('an unreviewed source member refuses a conversion rollback', () async {
      seedSkill('/work/source/demo');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        conversion: ConversionDirection.skillToPrompt,
      );
      final plan = await plans.plan(inputs, options);
      expect(plan.ready, isTrue, reason: '${plan.diagnostics}');
      io.failingOperation = 'write';
      io.failingPath = 'authoring-transactions';
      io.matchingOperationsToSkip = 1;
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
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      io.failingOperation = null;
      io.failingPath = null;
      io.matchingOperationsToSkip = 0;
      final transactionId = transactions().single['transactionId']! as String;
      expect(transactions().single['phase'], 'prepared');
      expect(fs.directory('/work/source/demo').existsSync(), isTrue);
      fs
          .file('/work/source/demo/unreviewed.txt')
          .writeAsStringSync('Preserve the new source member.');
      final review = await recovery.inspect(options, transactionId);

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('source changed'),
              ),
        ),
      );
      expect(fs.file('/work/project/.pi/prompts/demo.md').existsSync(), isTrue);
      expect(
        fs.file('/work/source/demo/unreviewed.txt').readAsStringSync(),
        'Preserve the new source member.',
      );
      expect(transactions().single['phase'], 'prepared');
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
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              6,
            ),
          ),
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

    test(
      'a valid receipt completes forward after a commit-journal fault',
      () async {
        final plan = await editPlan();
        io.failingOperation = 'write';
        io.failingPath = 'authoring-receipts';
        io.failAfterWrite = true;
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
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              6,
            ),
          ),
        );
        io.failingOperation = null;
        io.failingPath = null;
        io.failAfterWrite = false;
        final transactionId = transactions().single['transactionId']! as String;
        expect(transactions().single['phase'], 'published');
        final reconstructed = AuthoringRecoveryService(
          fileSystem: fs,
          state: LifecycleStateService(io: LifecycleIO(fs: fs)),
        );

        final review = await reconstructed.inspect(options, transactionId);
        expect(review.data['permittedAction'], 'complete');
        final applied = await reconstructed.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        );

        expect(applied.outcome, 'completed');
        expect(transactions().single['phase'], 'completed');
        expect(
          fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
          contains('Updated instructions.'),
        );
      },
    );

    test('a committed journal without its receipt is inconsistent', () async {
      final plan = await editPlan();
      final outcome = await publication.publish(
        AuthoringPublicationRequest(
          plan: plan,
          options: options,
          planId: plan.planId,
          approved: true,
        ),
      );
      final record = transactions().single;
      final transactionId = record['transactionId']! as String;
      final body = <String, Object?>{...record, 'phase': 'committed'}
        ..remove('digest');
      final digest = sha256
          .convert(utf8.encode(jsonEncode(canonicalAuthoringJson(body))))
          .toString();
      fs
          .file(
            '/work/project/.agent-resource/authoring-transactions/'
            '$transactionId.json',
          )
          .writeAsStringSync(
            jsonEncode(<String, Object?>{...body, 'digest': digest}),
          );
      fs
          .file(
            '/work/project/.agent-resource/authoring-receipts/'
            '${outcome.receiptId}.json',
          )
          .deleteSync();

      await expectLater(
        recovery.inspect(options, transactionId),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('without its receipt'),
              ),
        ),
      );
      expect(transactions().single['phase'], 'committed');
    });

    test('a malformed receipt refuses the inspection', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      // A receipt that does not match the reviewed publication is not a
      // commit point: it is substituted evidence, and the recovery is
      // refused before any direction is offered.
      final receipt = transactions().single['receiptId']! as String;
      fs
          .file(
            '/work/project/.agent-resource/authoring-receipts/$receipt.json',
          )
          .writeAsStringSync('{"receiptId": "$receipt"}');

      await expectLater(
        recovery.inspect(options, transactionId),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('receipt does not match'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
      expect(transactions().single['phase'], 'published');
    });

    test('a validated receipt refuses a rollback', () async {
      final plan = await editPlan();
      io.failingOperation = 'write';
      io.failingPath = 'authoring-receipts';
      io.failAfterWrite = true;
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
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      io.failingOperation = null;
      io.failingPath = null;
      io.failAfterWrite = false;
      final transactionId = transactions().single['transactionId']! as String;
      final review = await recovery.inspect(options, transactionId);
      expect(review.data['permittedAction'], 'complete');

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
          action: 'rollback',
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 4)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('permitted direction'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
      expect(transactions().single['phase'], 'published');
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

    test('the inventory does not call a recorded payload an orphan', () async {
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

      expect(result.data['transactions']! as List<Object?>, hasLength(1));
      expect(result.data['orphans'], isEmpty);
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

    test('a legacy transaction stays visible but read-only', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final record = transactions().single;
      final transactionId = record['transactionId']! as String;
      final legacyBody = <String, Object?>{...record, 'schemaVersion': 1}
        ..removeWhere(
          (key, value) =>
              key == 'digest' ||
              key == 'evidence' ||
              key == 'authority' ||
              key == 'nativeName',
        );
      final legacyDigest = sha256
          .convert(utf8.encode(jsonEncode(canonicalAuthoringJson(legacyBody))))
          .toString();
      final path =
          '/work/project/.agent-resource/authoring-transactions/'
          '$transactionId.json';
      fs
          .file(path)
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              ...legacyBody,
              'digest': legacyDigest,
            }),
          );
      final originalBytes = fs.file(path).readAsBytesSync();

      final inventory = await recovery.inventory(options);
      final listed = inventory.data['transactions']! as List<Object?>;
      expect(listed, hasLength(1));
      final legacy = listed.single! as Map<String, Object?>;
      expect(legacy['legacyReadOnly'], isTrue);
      expect(legacy['blockedReason'], contains('no content evidence'));
      expect(inventory.diagnostics, isEmpty);

      final inspected = await recovery.inspect(options, transactionId);
      expect(inspected.data['legacyReadOnly'], isTrue);
      expect(inspected.data['permittedAction'], isNull);
      expect(inspected.data['writes'], isFalse);
      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: inspected.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('no content evidence'),
          ),
        ),
      );
      await expectLater(
        recovery.cleanupReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: inspected.data['reviewId']! as String,
        ),
        throwsA(isA<MambaException>()),
      );
      expect(fs.file(path).readAsBytesSync(), originalBytes);
      expect(
        fs
            .directory(
              '/work/project/.agent-resource/authoring-recovery/${plan.planId}',
            )
            .existsSync(),
        isTrue,
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

    test(
      'a pending authoring transaction blocks an ordinary mutation',
      () async {
        final plan = await editPlan();
        await publish(plan, failingPath: 'authoring-receipts');
        final transactionId = transactions().single['transactionId']! as String;
        final context = LifecycleContext.resolve(options, fileSystem: fs);

        await expectLater(
          state.runMutation(
            context: context,
            locations: <String>['/work/source/demo'],
            body: () async => 'mutated',
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 6)
                .having(
                  (error) => error.message,
                  'diagnostic',
                  contains('pending authoring transaction'),
                ),
          ),
        );
        expect(transactions().single['transactionId'], transactionId);
      },
    );

    test('a pending authoring transaction reserves its native name', () async {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        fields: <String, Object?>{
          'name': 'demo',
          'description': 'Demonstrates the publication.',
        },
        bodyText: 'Created instructions.',
      );
      final plan = await plans.plan(inputs, options);
      expect(plan.ready, isTrue, reason: '${plan.diagnostics}');
      await publish(plan, failingPath: 'authoring-receipts');
      final record = transactions().single;
      final root = record['root']! as String;
      final nativeName = record['nativeName']! as String;
      final context = LifecycleContext.resolve(options, fileSystem: fs);

      expect(
        () => state.checkPendingConversions(
          context,
          uniqueness: (
            kind: ArtifactKind.skillCopy,
            name: nativeName,
            roots: <String>[root],
            nativeProfile: record['profile'] as String,
          ),
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('reserves the native name'),
              ),
        ),
      );
    });

    test(
      'the recovery of a pending transaction is not blocked by itself',
      () async {
        final plan = await editPlan();
        await publish(plan, failingPath: 'authoring-receipts');
        final transactionId = transactions().single['transactionId']! as String;
        final review = await recovery.inspect(options, transactionId);

        final applied = await recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        );

        expect(applied.outcome, 'rolledBack');
        expect(transactions().single['phase'], 'rolledBack');
      },
    );

    test(
      'the cleanup review identity is distinct from the recovery one',
      () async {
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

        final recoveryReview = await recovery.inspect(options, transactionId);
        final cleanupReview = await recovery.cleanupReviewed(
          options,
          transactionId,
        );

        expect(
          cleanupReview.data['reviewId'],
          isNot(recoveryReview.data['reviewId']),
        );
        expect(cleanupReview.data['purpose'], 'cleanup');
        expect(cleanupReview.data['forfeitedRestore'], isTrue);
        expect(cleanupReview.data['cleanupStatus'], 'available');
      },
    );

    test('the inventory reports an interrupted cleanup', () async {
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
      final record = transactions().single;
      fs
          .file(
            '/work/project/.agent-resource/authoring-transactions/'
            '$transactionId.cleanup.json',
          )
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'transactionId': transactionId,
              'decision': 'cleanup',
              'digest': record['digest'],
              'payload':
                  (record['evidence']! as Map<String, Object?>)['payloadPath'],
              'status': 'prepared',
            }),
          );

      final result = await recovery.inventory(options);

      final cleanups = result.data['cleanups']! as List<Object?>;
      expect(cleanups, hasLength(1));
      final cleanup = cleanups.single! as Map<String, Object?>;
      expect(cleanup['status'], 'interrupted');
      expect(cleanup['transactionId'], transactionId);
      expect(result.diagnostics, isEmpty);
    });

    test(
      'a transaction document without its own identity is unresolved',
      () async {
        final plan = await editPlan();
        await publish(plan, failingPath: 'authoring-receipts');
        final transactionId = transactions().single['transactionId']! as String;
        final path =
            '/work/project/.agent-resource/authoring-transactions/'
            '$transactionId.json';
        fs
            .file(path)
            .renameSync(
              '/work/project/.agent-resource/authoring-transactions/'
              'aut_ffffffffffffffffffffffffffffffff.json',
            );

        final result = await recovery.inventory(options);

        expect(result.diagnostics, isNotEmpty);
        expect(result.diagnostics.first['code'], 'EVIDENCE_UNRESOLVED');
        expect(result.data['transactions'], isEmpty);
      },
    );

    test('the rollback restores exactly the retained payload', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      final payload =
          (transactions().single['evidence']!
                  as Map<String, Object?>)['payloadPath']!
              as String;
      final expected = authoringContentEvidence(fs, payload);
      final review = await recovery.inspect(options, transactionId);

      final applied = await recovery.recoverReviewed(
        options.copyWith(approved: true),
        transactionId,
        planId: review.data['reviewId']! as String,
      );

      expect(applied.outcome, 'rolledBack');
      expect(authoringContentEvidence(fs, '/work/source/demo'), expected);
    });

    test('an interrupted cleanup is reported as interrupted', () async {
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
      expect(review.data['cleanupStatus'], 'available');

      // The deletion of the retained payload fails after the intent was
      // written: the cleanup stays interrupted and distinguishable.
      io.failingOperation = 'delete';
      io.failingPath = 'authoring-recovery';
      await expectLater(
        recovery.cleanupReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('cleanup stays interrupted'),
              ),
        ),
      );
      io.failingOperation = null;
      io.failingPath = null;
      expect(
        fs
            .directory(
              '/work/project/.agent-resource/authoring-recovery/${plan.planId}',
            )
            .existsSync(),
        isTrue,
      );

      final reconstructed = AuthoringRecoveryService(
        fileSystem: fs,
        state: LifecycleStateService(io: LifecycleIO(fs: fs)),
      );
      final inventory = await reconstructed.inventory(options);
      final cleanups = inventory.data['cleanups']! as List<Object?>;
      expect(cleanups, hasLength(1));
      expect(
        (cleanups.single! as Map<String, Object?>)['status'],
        'interrupted',
      );
      final reviewed = await reconstructed.cleanupReviewed(
        options,
        transactionId,
      );
      expect(reviewed.data['cleanupStatus'], 'interrupted');
      expect(reviewed.data['forfeitedRestore'], isTrue);
    });

    test('a partially deleted cleanup is reported as partial', () async {
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
      final record = transactions().single;
      fs
          .file(
            '/work/project/.agent-resource/authoring-transactions/'
            '$transactionId.cleanup.json',
          )
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'transactionId': transactionId,
              'decision': 'cleanup',
              'digest': record['digest'],
              'payload':
                  (record['evidence']! as Map<String, Object?>)['payloadPath'],
              'status': 'cleaned',
            }),
          );

      final inventory = await recovery.inventory(options);
      final cleanups = inventory.data['cleanups']! as List<Object?>;
      expect((cleanups.single! as Map<String, Object?>)['status'], 'partial');
      final reviewed = await recovery.cleanupReviewed(options, transactionId);
      expect(reviewed.data['cleanupStatus'], 'partial');
    });

    test('a copied transaction never authorizes another scope', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      // The same evidence and payload are copied into another scope: the
      // recorded authority context does not match the reviewing one.
      fs
          .directory('/work/state/authoring-transactions')
          .createSync(recursive: true);
      fs
          .file('/work/state/authoring-transactions/$transactionId.json')
          .writeAsStringSync(
            fs
                .file(
                  '/work/project/.agent-resource/authoring-transactions/'
                  '$transactionId.json',
                )
                .readAsStringSync(),
          );
      final userOptions = options.copyWith(scope: LifecycleScope.user);

      await expectLater(
        recovery.inspect(userOptions, transactionId),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('another authority context'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
    });

    test('an adopted location refuses the rollback', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      // An installation of the other scope adopted the reviewed source
      // after the interruption.
      fs.directory('/work/state').createSync(recursive: true);
      fs
          .file('/work/state/installations.json')
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'installations': <Object?>[
                <String, Object?>{
                  'installationId': 'ins_00000000000000000000000000000001',
                  'artifactKind': 'skill-copy',
                  'scope': 'user',
                  'nativeDestination': 'claude',
                  'nativeForm': 'skill-copy',
                  'location': '/work/source/demo',
                  'nativeRoot': '/work/source',
                  'name': 'demo',
                  'nativeProfile': 'claude',
                  'validatedProfiles': <String>['claude'],
                  'knownConsumers': <String>[],
                  'baseline': <Object?>[],
                  'lifecycle': 'live',
                  'origin': <String, Object?>{},
                  'backupIds': <String>[],
                  'transactionId': 'trx_00000000000000000000000000000001',
                },
              ],
            }),
          );
      final review = await recovery.inspect(options, transactionId);

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('owned by the installation'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
      expect(transactions().single['phase'], 'published');
    });

    test(
      'a missing payload without a recorded cleanup is unresolved',
      () async {
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
        final payload = transactions().single['recoveryPath']! as String;
        fs.directory(payload).deleteSync(recursive: true);
        final review = await recovery.cleanupReviewed(options, transactionId);
        expect(review.data['cleanupStatus'], 'unresolved');

        await expectLater(
          recovery.cleanupReviewed(
            options.copyWith(approved: true),
            transactionId,
            planId: review.data['reviewId']! as String,
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 6)
                .having(
                  (error) => error.message,
                  'diagnostic',
                  contains('evidence is unresolved'),
                ),
          ),
        );
      },
    );

    test('a partially deleted cleanup is completed by a new service', () async {
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
      final record = transactions().single;
      final payload = record['recoveryPath']! as String;
      // An interrupted cleanup removed one member of the retained payload.
      fs.file('$payload/SKILL.md').deleteSync();
      fs
          .file(
            '/work/project/.agent-resource/authoring-transactions/'
            '$transactionId.cleanup.json',
          )
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'transactionId': transactionId,
              'decision': 'cleanup',
              'digest': record['digest'],
              'payload': payload,
              'status': 'interrupted',
            }),
          );
      final reconstructed = AuthoringRecoveryService(
        fileSystem: fs,
        state: LifecycleStateService(io: LifecycleIO(fs: fs)),
      );
      final review = await reconstructed.cleanupReviewed(
        options,
        transactionId,
      );
      expect(review.data['cleanupStatus'], 'partial');

      final applied = await reconstructed.cleanupReviewed(
        options.copyWith(approved: true),
        transactionId,
        planId: review.data['reviewId']! as String,
      );

      expect(applied.outcome, 'cleaned');
      expect(fs.directory(payload).existsSync(), isFalse);
    });

    test('a large package stays reconstructable', () async {
      seedSkill('/work/source/demo');
      for (var index = 0; index < 120; index++) {
        fs
            .directory('/work/source/demo/references')
            .createSync(recursive: true);
        fs
            .file('/work/source/demo/references/note-$index.md')
            .writeAsStringSync('Reference $index.');
      }
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
      await publish(plan, failingPath: 'authoring-receipts');
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
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Original instructions.'),
      );
      expect(
        fs.file('/work/source/demo/references/note-119.md').existsSync(),
        isTrue,
      );
    });

    test('an interrupted restore is completed by the next rollback', () async {
      seedSkill('/work/source/demo');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        conversion: ConversionDirection.skillToPrompt,
      );
      final plan = await plans.plan(inputs, options);
      expect(plan.ready, isTrue, reason: '${plan.diagnostics}');
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      // The relocation retired the source: the rollback has to restore it
      // from the retained payload.
      expect(fs.directory('/work/source/demo').existsSync(), isFalse);
      final review = await recovery.inspect(options, transactionId);

      // The restore of the source fails after the intent was recorded.
      io.failingOperation = 'copy';
      io.failingPath = 'authoring-recovery';
      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 4)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('coordination'),
              ),
        ),
      );
      io.failingOperation = null;
      io.failingPath = null;

      // The published target survives the interrupted restore.
      expect(fs.file('/work/project/.pi/prompts/demo.md').existsSync(), isTrue);
      final retry = await recovery.inspect(options, transactionId);
      expect(retry.data['permittedAction'], 'rollback');
      final applied = await recovery.recoverReviewed(
        options.copyWith(approved: true),
        transactionId,
        planId: retry.data['reviewId']! as String,
      );

      expect(applied.outcome, 'rolledBack');
      expect(
        fs.file('/work/project/.pi/prompts/demo.md').existsSync(),
        isFalse,
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Original instructions.'),
      );
      expect(transactions().single['phase'], 'rolledBack');
    });

    test('a changed survivor refuses the rollback', () async {
      seedSkill('/work/source/demo');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        conversion: ConversionDirection.skillToPrompt,
      );
      final plan = await plans.plan(inputs, options);
      expect(plan.ready, isTrue, reason: '${plan.diagnostics}');
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      // An interrupted rollback recorded its intent and restored a changed
      // survivor: the changed bytes are not proven by the transaction.
      fs.directory('/work/source/demo').createSync(recursive: true);
      fs
          .file('/work/source/demo/SKILL.md')
          .writeAsStringSync('Changed survivor.');
      fs
          .file(
            '/work/project/.agent-resource/authoring-transactions/'
            '$transactionId.rollback.json',
          )
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'transactionId': transactionId,
              'decision': 'rollback',
              'digest': transactions().single['digest'],
              'payload': transactions().single['recoveryPath'],
              'status': 'prepared',
            }),
          );
      final review = await recovery.inspect(options, transactionId);

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('source changed'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        'Changed survivor.',
      );
      expect(fs.file('/work/project/.pi/prompts/demo.md').existsSync(), isTrue);
    });

    test('a nested source member is restored as a directory tree', () async {
      seedSkill('/work/source/demo');
      fs.directory('/work/source/demo/assets').createSync(recursive: true);
      fs
          .file('/work/source/demo/assets/source')
          .writeAsStringSync('Nested member.');
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
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      final review = await recovery.inspect(options, transactionId);

      final applied = await recovery.recoverReviewed(
        options.copyWith(approved: true),
        transactionId,
        planId: review.data['reviewId']! as String,
      );

      expect(applied.outcome, 'rolledBack');
      expect(fs.directory('/work/source/demo/assets').existsSync(), isTrue);
      expect(
        fs.file('/work/source/demo/assets/source').readAsStringSync(),
        'Nested member.',
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Original instructions.'),
      );
    });

    test('a changed user state root refuses the recovery', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      final changed = LifecycleOptions(
        processWorkingDirectory: options.processWorkingDirectory,
        environment: options.environment,
        scope: options.scope,
        cwd: options.cwd,
        projectRoot: options.projectRoot,
        home: options.home,
        stateDir: '/other/state',
      );

      // Another user ledger would hide an original user owned location.
      await expectLater(
        recovery.inspect(changed, transactionId),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('another user state root'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
    });

    test('an unavailable user authority refuses the recovery', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      final unavailable = LifecycleOptions(
        processWorkingDirectory: options.processWorkingDirectory,
        environment: options.environment,
        scope: options.scope,
        cwd: options.cwd,
        projectRoot: options.projectRoot,
        home: options.home,
      );

      // The original user scope authority cannot be resolved any more.
      await expectLater(
        recovery.inspect(unavailable, transactionId),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('user scope authority is unavailable'),
              ),
        ),
      );
    });

    test('a changed home refuses the recovery', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      fs.directory('/other/home').createSync(recursive: true);
      final changed = LifecycleOptions(
        processWorkingDirectory: options.processWorkingDirectory,
        environment: options.environment,
        scope: options.scope,
        cwd: options.cwd,
        projectRoot: options.projectRoot,
        home: '/other/home',
        stateDir: options.stateDir,
      );

      await expectLater(
        recovery.inspect(changed, transactionId),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('another home'),
              ),
        ),
      );
    });

    test('an exposure of an installation refuses the rollback', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      // A canonical installation of the other scope exposes the reviewed
      // source without owning its location.
      fs.directory('/work/state').createSync(recursive: true);
      fs
          .file('/work/state/installations.json')
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'installations': <Object?>[
                <String, Object?>{
                  'installationId': 'ins_00000000000000000000000000000002',
                  'recordSchemaVersion': 2,
                  'artifactKind': 'skill-canonical',
                  'scope': 'user',
                  'nativeDestination': 'claude',
                  'nativeForm': 'skill-canonical',
                  'location': '/work/other/demo',
                  'nativeRoot': '/work/other',
                  'name': 'demo',
                  'nativeProfile': 'claude',
                  'validatedProfiles': <String>['claude'],
                  'knownConsumers': <String>[],
                  'baseline': <Object?>[],
                  'lifecycle': 'live',
                  'origin': <String, Object?>{},
                  'backupIds': <String>[],
                  'transactionId': 'trx_00000000000000000000000000000002',
                  'exposures': <Object?>[
                    <String, Object?>{
                      'path': '/work/source/demo',
                      'target': 'claude',
                      'nativeKind': 'skill',
                      'baseline': <Object?>[],
                    },
                  ],
                },
              ],
            }),
          );
      final review = await recovery.inspect(options, transactionId);

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('owned by the installation'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
    });

    test('a rolled back transaction stays inspectable', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      final review = await recovery.inspect(options, transactionId);
      await recovery.recoverReviewed(
        options.copyWith(approved: true),
        transactionId,
        planId: review.data['reviewId']! as String,
      );

      final inventory = await recovery.inventory(options);
      expect(inventory.diagnostics, isEmpty);
      final rollbacks = inventory.data['rollbacks']! as List<Object?>;
      expect(rollbacks, hasLength(1));
      expect(
        (rollbacks.single! as Map<String, Object?>)['status'],
        'completed',
      );
      final inspected = await recovery.inspect(options, transactionId);
      expect(inspected.data['legacyReadOnly'], isFalse);
      final cleanup = await recovery.cleanupReviewed(options, transactionId);
      expect(cleanup.data['cleanupStatus'], 'available');
    });

    test('a user scope transaction reads the project ledger', () async {
      seedSkill('/work/source/demo');
      final userOptions = LifecycleOptions(
        processWorkingDirectory: options.processWorkingDirectory,
        environment: options.environment,
        scope: LifecycleScope.user,
        cwd: options.cwd,
        projectRoot: options.projectRoot,
        home: options.home,
        stateDir: options.stateDir,
      );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.user,
        sourcePath: '/work/source/demo',
        bodyText: 'Updated instructions.',
      );
      final plan = await plans.plan(inputs, userOptions);
      expect(plan.ready, isTrue, reason: '${plan.diagnostics}');
      io.failingOperation = 'write';
      io.failingPath = 'authoring-receipts';
      await expectLater(
        publication.publish(
          AuthoringPublicationRequest(
            plan: plan,
            options: userOptions,
            planId: plan.planId,
            approved: true,
          ),
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      io.failingOperation = null;
      io.failingPath = null;
      final transactionId = fs
          .directory('/work/state/authoring-transactions')
          .listSync()
          .map((entry) => entry.path)
          .first
          .split(RegExp(r'[/\\]'))
          .last
          .replaceAll('.json', '');
      // The project ledger owns the reviewed source of the user scope
      // transaction: the rollback must refuse before it writes.
      fs
          .file('/work/project/.agent-resource/installations.json')
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'installations': <Object?>[
                <String, Object?>{
                  'installationId': 'ins_00000000000000000000000000000003',
                  'artifactKind': 'skill-copy',
                  'scope': 'project',
                  'nativeDestination': 'claude',
                  'nativeForm': 'skill-copy',
                  'location': '/work/source/demo',
                  'nativeRoot': '/work/source',
                  'name': 'demo',
                  'nativeProfile': 'claude',
                  'validatedProfiles': <String>['claude'],
                  'knownConsumers': <String>[],
                  'baseline': <Object?>[],
                  'lifecycle': 'live',
                  'origin': <String, Object?>{},
                  'backupIds': <String>[],
                  'transactionId': 'trx_00000000000000000000000000000003',
                },
              ],
            }),
          );
      final review = await recovery.inspect(userOptions, transactionId);

      await expectLater(
        recovery.recoverReviewed(
          userOptions.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('owned by the installation'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
    });

    test('a newly resolvable authority refuses the recovery', () async {
      final unconfigured = LifecycleOptions(
        processWorkingDirectory: options.processWorkingDirectory,
        environment: options.environment,
        scope: options.scope,
        cwd: options.cwd,
        projectRoot: options.projectRoot,
        home: options.home,
      );
      final plan = await editPlan();
      io.failingOperation = 'write';
      io.failingPath = 'authoring-receipts';
      await expectLater(
        publication.publish(
          AuthoringPublicationRequest(
            plan: plan,
            options: unconfigured,
            planId: plan.planId,
            approved: true,
          ),
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      io.failingOperation = null;
      io.failingPath = null;
      final transactionId = transactions().single['transactionId']! as String;
      // The host now offers a home and a user ledger that the recorded
      // context never bound: the authority is never rebaselined.
      final configured = LifecycleOptions(
        processWorkingDirectory: options.processWorkingDirectory,
        environment: options.environment,
        scope: options.scope,
        cwd: options.cwd,
        projectRoot: options.projectRoot,
        home: options.home,
        stateDir: options.stateDir,
      );

      await expectLater(
        recovery.inspect(configured, transactionId),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('recorded without'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
    });

    test('an observed change refuses the approved recovery', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      final review = await recovery.inspect(options, transactionId);
      // The published target changes after the review: the approval covers
      // one exact observed state, not a boolean summary of it.
      fs
          .file('/work/source/demo/SKILL.md')
          .writeAsStringSync(
            '---\nname: demo\ndescription: Changed after the review.\n---\n'
            'Other.',
          );

      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 4)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('current review identity'),
              ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Changed after the review.'),
      );
      expect(transactions().single['phase'], 'published');
    });

    test('an interrupted rollback is retried from a fresh review', () async {
      final plan = await editPlan();
      await publish(plan, failingPath: 'authoring-receipts');
      final transactionId = transactions().single['transactionId']! as String;
      final review = await recovery.inspect(options, transactionId);

      // The journal write of the rollback fails after the live change.
      io.failingOperation = 'write';
      io.failingPath = 'authoring-transactions';
      await expectLater(
        recovery.recoverReviewed(
          options.copyWith(approved: true),
          transactionId,
          planId: review.data['reviewId']! as String,
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 4),
        ),
      );
      io.failingOperation = null;
      io.failingPath = null;
      expect(transactions().single['phase'], 'published');
      // The intent is written before the live change: the refused rollback
      // left the published content in place.
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );

      final retry = await recovery.inspect(options, transactionId);
      expect(retry.data['permittedAction'], 'rollback');
      final applied = await recovery.recoverReviewed(
        options.copyWith(approved: true),
        transactionId,
        planId: retry.data['reviewId']! as String,
      );

      expect(applied.outcome, 'rolledBack');
      expect(transactions().single['phase'], 'rolledBack');
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Original instructions.'),
      );
    });

    test('a prepared transaction rolls back a published target', () async {
      seedSkill('/work/source/demo');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        conversion: ConversionDirection.skillToPrompt,
      );
      final plan = await plans.plan(inputs, options);
      expect(plan.ready, isTrue, reason: '${plan.diagnostics}');
      io.failingOperation = 'write';
      io.failingPath = 'authoring-transactions';
      io.matchingOperationsToSkip = 1;
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
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      io.failingOperation = null;
      io.failingPath = null;
      io.matchingOperationsToSkip = 0;
      final transactionId = transactions().single['transactionId']! as String;
      expect(transactions().single['phase'], 'prepared');
      expect(fs.file('/work/project/.pi/prompts/demo.md').existsSync(), isTrue);
      final review = await recovery.inspect(options, transactionId);
      expect(review.data['permittedAction'], 'rollback');

      final applied = await recovery.recoverReviewed(
        options.copyWith(approved: true),
        transactionId,
        planId: review.data['reviewId']! as String,
      );

      expect(applied.outcome, 'rolledBack');
      expect(
        fs.file('/work/project/.pi/prompts/demo.md').existsSync(),
        isFalse,
      );
      expect(fs.directory('/work/source/demo').existsSync(), isTrue);
      expect(transactions().single['phase'], 'rolledBack');
    });
  });
}
