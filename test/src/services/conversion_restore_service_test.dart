import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/conversion/conversion_evidence.dart';
import 'package:agent_resource/src/conversion/conversion_restore_evidence.dart';
import 'package:agent_resource/src/services/conversion_coordinator_service.dart';
import 'package:agent_resource/src/services/conversion_evidence_service.dart';
import 'package:agent_resource/src/services/conversion_restore_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

const _sourceInstallationId = 'ins_0123456789abcdef0123456789abcdef';
const _transactionId = 'cvx_0123456789abcdef0123456789abcdef';

/// An IO seam that fails one selected durable operation.
class _FaultyIO extends LifecycleIO {
  _FaultyIO(this.memory) : super(fs: memory);

  final MemoryFileSystem memory;
  String? failingOperation;
  String? failingPath;
  bool Function(String path)? failBeforeWrite;
  void Function(String operation, String path)? after;

  @override
  void write(String path, List<int> bytes) {
    if (failBeforeWrite != null && failBeforeWrite!(path)) {
      throw StateError('Simulated process interruption');
    }
    super.write(path, bytes);
    after?.call('write', path);
  }

  @override
  void delete(String path) {
    super.delete(path);
    after?.call('delete', path);
  }

  @override
  void rename(String source, String destination) {
    super.rename(source, destination);
    after?.call('rename', source);
  }

  @override
  void before(String operation, String path) {
    if (failingOperation != operation) return;
    if (failingPath != null && !path.contains(failingPath!)) return;
    throw StateError('Simulated process interruption');
  }
}

void main() {
  late MemoryFileSystem fs;
  late _FaultyIO io;
  late LifecycleStateService state;
  late ConversionCoordinator coordinator;
  late ConversionRestoreService restore;
  late LifecycleOptions options;

  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/work/project').createSync(recursive: true);
    fs.directory('/home/user').createSync(recursive: true);
    io = _FaultyIO(fs);
    state = LifecycleStateService(io: io);
    coordinator = ConversionCoordinator(
      io: io,
      state: state,
      evidence: ConversionEvidenceService(fileSystem: fs),
    );
    restore = ConversionRestoreService(
      io: io,
      state: state,
      evidence: ConversionEvidenceService(fileSystem: fs),
    );
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

  void seedLedger({
    required String location,
    required String nativeRoot,
    ArtifactKind kind = ArtifactKind.agentFile,
    String nativeForm = 'claude-agent-file',
    String scope = 'project',
  }) {
    final record = InstallationRecord(
      installationId: _sourceInstallationId,
      kind: kind,
      scope: LifecycleScope.values.byName(scope),
      nativeDestination: 'claude',
      nativeForm: nativeForm,
      location: location,
      nativeRoot: nativeRoot,
      name: location.split('/').last,
      nativeProfile: 'claude',
      validatedProfiles: const <String>['claude'],
      knownConsumers: const <String>['claude'],
      baseline: const ArtifactBaseline(<BaselineEntry>[]),
      lifecycle: 'live',
      origin: const <String, Object?>{'status': 'unknown'},
      backupIds: const <String>[],
      transactionId: null,
    );
    final stateRoot = scope == 'project'
        ? '/work/project/.agent-resource'
        : '/work/state';
    fs.directory(stateRoot).createSync(recursive: true);
    fs
        .file('$stateRoot/installations.json')
        .writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 1,
            'installations': <Object?>[record.toJson()],
          }),
        );
  }

  ConversionParticipant sourceParticipant({
    required String location,
    required String nativeRoot,
    required String artifactKind,
    required String nativeForm,
    bool managed = true,
    String scope = 'project',
    bool membership = false,
  }) {
    final baseline = ConversionBaseline(
      entries: conversionManifestEntries(io, location),
    );
    return ConversionParticipant(
      role: ConversionParticipantRole.source,
      intent: ConversionParticipantIntent.retired,
      artifactKind: artifactKind,
      nativeForm: nativeForm,
      nativeProfile: 'claude',
      location: location,
      nativeRoot: nativeRoot,
      scope: scope,
      ownershipBefore: ConversionOwnership(
        managed: managed,
        installationId: managed ? _sourceInstallationId : null,
        receiptId: managed ? null : 'rcp_0123456789abcdef0123456789abcdef',
        nativeForm: nativeForm,
        nativeProfile: 'claude',
        location: location,
        nativeRoot: nativeRoot,
        scope: scope,
      ),
      membershipBefore: membership
          ? const ConversionMembership(
              kind: 'pack',
              state: 'active',
              memberId: 'mem_0123456789abcdef0123456789abcdef',
              source: 'pack-source',
            )
          : null,
      baseline: baseline,
    );
  }

  ConversionParticipant targetParticipant({
    required String location,
    required String nativeRoot,
    required String artifactKind,
    required String nativeForm,
    String scope = 'project',
    bool managed = true,
  }) => ConversionParticipant(
    role: ConversionParticipantRole.target,
    intent: ConversionParticipantIntent.created,
    artifactKind: artifactKind,
    nativeForm: nativeForm,
    nativeProfile: 'claude',
    location: location,
    nativeRoot: nativeRoot,
    scope: scope,
    ownershipAfter: ConversionOwnership(
      managed: managed,
      installationId: managed ? _sourceInstallationId : null,
      receiptId: managed ? null : 'rcp_0123456789abcdef0123456789abcdef',
      nativeForm: nativeForm,
      nativeProfile: 'claude',
      location: location,
      nativeRoot: nativeRoot,
      scope: scope,
    ),
  );

  /// Creates a completed conversion through the internal coordinator seam.
  Future<ConversionTransitionOutcome> completeConversion({
    bool inPlace = false,
    bool managed = true,
    String sourceLocation = '/work/project/.claude/agents/reviewer.md',
    String targetLocation = '/work/project/.pi/prompts/reviewer.md',
    String sourceRoot = '/work/project/.claude/agents',
    String targetRoot = '/work/project/.pi/prompts',
    String targetKind = 'prompt-template',
    String targetForm = 'pi-prompt-template',
  }) async {
    fs.file(sourceLocation)
      ..createSync(recursive: true)
      ..writeAsStringSync('original');
    if (managed) {
      seedLedger(location: sourceLocation, nativeRoot: sourceRoot);
    }
    final request = ConversionTransitionRequest(
      transactionId: _transactionId,
      options: options,
      source: sourceParticipant(
        location: sourceLocation,
        nativeRoot: sourceRoot,
        artifactKind: 'agent-file',
        nativeForm: 'claude-agent-file',
        managed: managed,
      ),
      target: targetParticipant(
        location: inPlace ? sourceLocation : targetLocation,
        nativeRoot: inPlace ? sourceRoot : targetRoot,
        artifactKind: inPlace
            ? 'agent-file'
            : (managed ? targetKind : 'agent-file'),
        nativeForm: inPlace
            ? 'claude-agent-file'
            : (managed ? targetForm : 'claude-agent-file'),
        managed: managed,
      ),
      targetFiles: {'reviewer.md': utf8.encode('converted')},
    );
    return coordinator.execute(request);
  }

  LifecycleOptions approved({bool dryRun = false}) =>
      options.copyWith(approved: true, dryRun: dryRun);

  group('ConversionRestoreService', () {
    test(
      'restores the original source and retires the converted target',
      () async {
        await completeConversion();
        final source = '/work/project/.claude/agents/reviewer.md';
        final target = '/work/project/.pi/prompts/reviewer.md';
        expect(fs.file(target).existsSync(), isTrue);
        expect(fs.file(source).existsSync(), isFalse);

        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        expect(review.outcome, 'planned');
        final planId = review.data['planId']! as String;
        expect(review.data['action'], 'restore');
        expect(review.data['inPlace'], isFalse);
        // A review writes nothing.
        expect(fs.file(source).existsSync(), isFalse);
        expect(fs.file(target).existsSync(), isTrue);

        final result = await restore.restoreReviewed(
          approved(),
          _transactionId,
          planId: planId,
        );
        expect(result.outcome, 'restored');
        expect(fs.file(source).readAsStringSync(), 'original');
        expect(fs.file(target).existsSync(), isFalse);

        final ledger = jsonDecode(
          fs
              .file('/work/project/.agent-resource/installations.json')
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final records = (ledger['installations'] as List).cast<Map>();
        final restored = records.singleWhere(
          (record) => record['installationId'] == _sourceInstallationId,
        );
        expect(restored['location'], source);
        expect(restored['lifecycle'], 'live');
        expect(
          (restored['origin'] as Map)['restoredFromConversionTransaction'],
          _transactionId,
        );
        // The converted target is retired, not deleted from the history.
        final retired = records.singleWhere(
          (record) => record['installationId'] != _sourceInstallationId,
        );
        expect(retired['lifecycle'], 'removed');
        expect(retired['location'], target);

        // The outgoing target is preserved as private evidence.
        final outgoing = result.data['outgoingTargetEvidence']! as String;
        expect(fs.file(outgoing).readAsStringSync(), 'converted');
      },
    );

    test(
      'restores an in place conversion under its original identity',
      () async {
        await completeConversion(inPlace: true);
        final source = '/work/project/.claude/agents/reviewer.md';
        expect(fs.file(source).readAsStringSync(), 'converted');

        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        expect(review.data['inPlace'], isTrue);
        final result = await restore.restoreReviewed(
          approved(),
          _transactionId,
          planId: review.data['planId']! as String,
        );
        expect(result.outcome, 'restored');
        expect(fs.file(source).readAsStringSync(), 'original');

        final ledger = jsonDecode(
          fs
              .file('/work/project/.agent-resource/installations.json')
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final records = (ledger['installations'] as List).cast<Map>();
        expect(records.length, 1);
        expect(records.single['installationId'], _sourceInstallationId);
        expect(records.single['location'], source);
        expect(records.single['lifecycle'], 'live');
      },
    );

    test('leaves an unmanaged source unadopted', () async {
      await completeConversion(managed: false);
      final source = '/work/project/.claude/agents/reviewer.md';
      final target = '/work/project/.pi/prompts/reviewer.md';

      final review = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      expect(review.data['sourceManaged'], isFalse);
      await restore.restoreReviewed(
        approved(),
        _transactionId,
        planId: review.data['planId']! as String,
      );
      expect(fs.file(source).readAsStringSync(), 'original');
      expect(fs.file(target).existsSync(), isFalse);
      // The restored source is not adopted as an installation.
      expect(
        fs
            .file('/work/project/.agent-resource/installations.json')
            .existsSync(),
        isFalse,
      );
    });

    test('refuses an apply without the exact fresh plan', () async {
      await completeConversion();
      await expectLater(
        restore.restoreReviewed(approved(), _transactionId, planId: 'stale'),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('exact fresh --plan-id'),
          ),
        ),
      );
      await expectLater(
        restore.restoreReviewed(options, _transactionId, planId: 'stale'),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('exact fresh --plan-id'),
          ),
        ),
      );
    });

    test('refuses a changed converted target', () async {
      await completeConversion();
      fs
          .file('/work/project/.pi/prompts/reviewer.md')
          .writeAsStringSync('edited');
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('converted target changed'),
          ),
        ),
      );
    });

    test('refuses a new occupant at the original source location', () async {
      await completeConversion();
      fs.file('/work/project/.claude/agents/reviewer.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('occupant');
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('new occupant'),
          ),
        ),
      );
    });

    test('refuses a changed target ownership', () async {
      await completeConversion();
      final ledger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final document = jsonDecode(ledger.readAsStringSync()) as Map;
      final records = document['installations'] as List;
      for (final record in records.cast<Map>()) {
        if (record['lifecycle'] != 'live') continue;
        record['nativeDestination'] = 'native';
      }
      ledger.writeAsStringSync(jsonEncode(document));
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('ownership changed'),
          ),
        ),
      );
    });

    test('refuses a repeated restore of the same conversion', () async {
      await completeConversion();
      final review = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      await restore.restoreReviewed(
        approved(),
        _transactionId,
        planId: review.data['planId']! as String,
      );
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('already restored'),
          ),
        ),
      );
    });

    test(
      'refuses the restore after the retained payload was cleaned',
      () async {
        await completeConversion();
        final cleanup = await coordinator.cleanupReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        await coordinator.cleanupReviewed(
          approved(),
          _transactionId,
          planId: cleanup.data['planId']! as String,
        );
        await expectLater(
          restore.restoreReviewed(approved(dryRun: true), _transactionId),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('cleaned'),
            ),
          ),
        );
      },
    );

    test('refuses a transaction that is not a completed conversion', () async {
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('No conversion evidence'),
          ),
        ),
      );
    });

    test('rolls an interrupted inverse restore back before its decision', () async {
      await completeConversion();
      final source = '/work/project/.claude/agents/reviewer.md';
      final target = '/work/project/.pi/prompts/reviewer.md';
      final review = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      io.failBeforeWrite = (path) => path.endsWith('commit.json');
      await expectLater(
        restore.restoreReviewed(
          approved(),
          _transactionId,
          planId: review.data['planId']! as String,
        ),
        throwsA(isA<MambaException>()),
      );
      io.failBeforeWrite = null;
      // The interrupted inverse restore stays pending and is guarded.
      expect(fs.file(source).readAsStringSync(), 'original');
      expect(fs.file(target).readAsStringSync(), 'converted');

      // A fresh review resumes the interrupted inverse restore. Without a
      // commit decision the inverse restore is rolled back.
      final resumed = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      expect(resumed.data['resume'], isTrue);
      final rolledBack = await restore.restoreReviewed(
        approved(),
        _transactionId,
        planId: resumed.data['planId']! as String,
      );
      expect(rolledBack.data['rolledBack'], isTrue);
      expect(fs.file(target).readAsStringSync(), 'converted');
      expect(fs.file(source).existsSync(), isFalse);

      // The rolled back inverse restore does not block a new reviewed restore.
      final retry = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      expect(retry.data['resume'], isFalse);
      final applied = await restore.restoreReviewed(
        approved(),
        _transactionId,
        planId: retry.data['planId']! as String,
      );
      expect(applied.outcome, 'restored');
      expect(fs.file(source).readAsStringSync(), 'original');
      expect(fs.file(target).existsSync(), isFalse);
    });

    test(
      'finishes an interrupted inverse restore forward after its decision',
      () async {
        await completeConversion();
        final source = '/work/project/.claude/agents/reviewer.md';
        final target = '/work/project/.pi/prompts/reviewer.md';
        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        io.failBeforeWrite = (path) => path.contains('installations.json');
        await expectLater(
          restore.restoreReviewed(
            approved(),
            _transactionId,
            planId: review.data['planId']! as String,
          ),
          throwsA(isA<MambaException>()),
        );
        io.failBeforeWrite = null;
        expect(fs.file(source).readAsStringSync(), 'original');

        // The interrupted inverse restore is recoverable: a fresh review
        // resumes it and completes the ownership transition.
        final resumed = await restore.restoreReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        expect(resumed.data['resume'], isTrue);
        final result = await restore.restoreReviewed(
          approved(),
          _transactionId,
          planId: resumed.data['planId']! as String,
        );
        expect(result.outcome, 'restored');
        expect(fs.file(source).readAsStringSync(), 'original');
        expect(fs.file(target).existsSync(), isFalse);
        final ledger = jsonDecode(
          fs
              .file('/work/project/.agent-resource/installations.json')
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final records = (ledger['installations'] as List).cast<Map>();
        final restored = records.singleWhere(
          (record) => record['installationId'] == _sourceInstallationId,
        );
        expect(restored['lifecycle'], 'live');
      },
    );

    test('refuses a changed membership of the converted target', () async {
      fs.file('/work/project/.claude/agents/reviewer.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('original');
      seedLedger(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: _transactionId,
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
            membership: true,
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/reviewer.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
          ),
          targetFiles: {'reviewer.md': utf8.encode('converted')},
        ),
      );
      final ledger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final document = jsonDecode(ledger.readAsStringSync()) as Map;
      for (final record in (document['installations'] as List).cast<Map>()) {
        if (record['lifecycle'] != 'live') continue;
        final origin = record['origin'] as Map;
        expect(origin['conversionMembership'], isNotNull);
        (origin['conversionMembership'] as Map)['state'] = 'active';
      }
      ledger.writeAsStringSync(jsonEncode(document));
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('membership'),
          ),
        ),
      );
    });

    test('restores a cross scope conversion in both ledgers', () async {
      const source = '/work/project/.claude/agents/reviewer.md';
      const target = '/home/user/.pi/prompts/reviewer.md';
      fs.file(source)
        ..createSync(recursive: true)
        ..writeAsStringSync('original');
      seedLedger(location: source, nativeRoot: '/work/project/.claude/agents');
      final userOptions = options.copyWith(scope: LifecycleScope.user);
      await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: _transactionId,
          options: userOptions,
          source: sourceParticipant(
            location: source,
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: target,
            nativeRoot: '/home/user/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            scope: 'user',
          ),
          targetFiles: {'reviewer.md': utf8.encode('converted')},
        ),
      );
      expect(fs.file(target).existsSync(), isTrue);

      final review = await restore.restoreReviewed(
        userOptions.copyWith(approved: true, dryRun: true),
        _transactionId,
      );
      expect(review.data['scope'], 'user');
      await restore.restoreReviewed(
        userOptions.copyWith(approved: true),
        _transactionId,
        planId: review.data['planId']! as String,
      );
      expect(fs.file(source).readAsStringSync(), 'original');
      expect(fs.file(target).existsSync(), isFalse);

      final project = jsonDecode(
        fs
            .file('/work/project/.agent-resource/installations.json')
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final projectRecords = (project['installations'] as List).cast<Map>();
      final restored = projectRecords.singleWhere(
        (record) => record['installationId'] == _sourceInstallationId,
      );
      expect(restored['lifecycle'], 'live');
      expect(restored['location'], source);

      final user = jsonDecode(
        fs.file('/work/state/installations.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final userRecords = (user['installations'] as List).cast<Map>();
      final retired = userRecords.singleWhere(
        (record) => record['installationId'] != _sourceInstallationId,
      );
      expect(retired['lifecycle'], 'removed');
    });

    test('restores a directory conversion from the retained payload', () async {
      const source = '/work/project/.claude/skills/reviewer';
      const target = '/work/project/.pi/prompts/reviewer';
      fs.directory(source).createSync(recursive: true);
      fs.file('$source/SKILL.md').writeAsStringSync('original skill');
      seedLedger(
        location: source,
        nativeRoot: '/work/project/.claude/skills',
        kind: ArtifactKind.skillCopy,
        nativeForm: 'claude-skill-directory',
      );
      await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: _transactionId,
          options: options,
          source: sourceParticipant(
            location: source,
            nativeRoot: '/work/project/.claude/skills',
            artifactKind: 'skill-copy',
            nativeForm: 'claude-skill-directory',
          ),
          target: targetParticipant(
            location: target,
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'skill-copy',
            nativeForm: 'claude-skill-directory',
          ),
          targetFiles: {'SKILL.md': utf8.encode('converted skill')},
        ),
      );
      expect(fs.file('$target/SKILL.md').readAsStringSync(), 'converted skill');

      final review = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      await restore.restoreReviewed(
        approved(),
        _transactionId,
        planId: review.data['planId']! as String,
      );
      expect(fs.file('$source/SKILL.md').readAsStringSync(), 'original skill');
      expect(fs.directory(target).existsSync(), isFalse);
    });

    test('binds the inverse restore evidence to its reviewed plan', () async {
      await completeConversion();
      final review = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      final restoreId = review.data['restoreId']! as String;
      expect(restoreId, startsWith('rsv_'));
      // The review itself writes nothing.
      expect(
        fs
            .file(
              '/work/project/.agent-resource/conversion-restores/'
              '$restoreId.json',
            )
            .existsSync(),
        isFalse,
      );
      await restore.restoreReviewed(
        approved(),
        _transactionId,
        planId: review.data['planId']! as String,
      );
      final path =
          '/work/project/.agent-resource/conversion-restores/$restoreId.json';
      final evidence = ConversionRestoreEvidence.decode(
        fs.file(path).readAsStringSync(),
      );
      expect(evidence.transactionId, _transactionId);
      expect(evidence.phase, ConversionRestorePhase.completed);
      expect(evidence.payloadDigest, isNotEmpty);
      expect(evidence.outgoingDigest, isNotEmpty);
    });
  });

  group('prompt conversion restore', () {
    test(
      'reviews and applies the inverse restore of a completed conversion',
      () async {
        await completeConversion();
        final source = '/work/project/.claude/agents/reviewer.md';
        final target = '/work/project/.pi/prompts/reviewer.md';
        final executor = createExecutor(fileSystem: fs).fake();
        final review = await executor.execute(<String>[
          'prompt',
          'conversion',
          'restore',
          _transactionId,
          '--scope',
          'project',
          '--cwd',
          '/work/project/',
          '--project-root',
          '/work/project/',
          '--home',
          '/home/user/',
          '--state-dir',
          '/work/state/',
          '--format',
          'json',
        ]);
        expect(review, isA<MambaSuccessResult>());
        final data = jsonDecode((review as MambaSuccessResult).output!) as Map;
        expect(data['outcome'], 'planned');
        final planId = (data['data'] as Map)['planId']! as String;

        final applied = await executor.execute(<String>[
          'prompt',
          'conversion',
          'restore',
          _transactionId,
          '--scope',
          'project',
          '--cwd',
          '/work/project/',
          '--project-root',
          '/work/project/',
          '--home',
          '/home/user/',
          '--state-dir',
          '/work/state/',
          '--plan-id',
          planId,
          '--apply',
          '--yes',
          '--format',
          'json',
        ]);
        expect(applied, isA<MambaSuccessResult>());
        expect(fs.file(source).readAsStringSync(), 'original');
        expect(fs.file(target).existsSync(), isFalse);
      },
    );

    test('refuses an apply without the reviewed plan identity', () async {
      await completeConversion();
      final result = await createExecutor(fileSystem: fs)
          .fake()
          .execute(<String>[
            'prompt',
            'conversion',
            'restore',
            _transactionId,
            '--scope',
            'project',
            '--cwd',
            '/work/project/',
            '--project-root',
            '/work/project/',
            '--home',
            '/home/user/',
            '--state-dir',
            '/work/state/',
            '--apply',
            '--yes',
          ]);
      expect(result, isA<MambaFailureResult>());
      expect(
        (result as MambaFailureResult).message,
        contains('exact fresh --plan-id'),
      );
    });
  });
}
