import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/conversion/conversion_evidence.dart';
import 'package:agent_resource/src/conversion/conversion_restore_evidence.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/authoring_publication_service.dart';
import 'package:agent_resource/src/services/conversion_coordinator_service.dart';
import 'package:agent_resource/src/services/conversion_evidence_service.dart';
import 'package:agent_resource/src/services/conversion_restore_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/file.dart' as fslib;
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
  bool Function(String path)? failAfterRename;

  /// The evidence document of the coordinating scope.
  String? coordinatorEvidencePath;

  /// The participant marker of the other scope.
  String? peerMarkerPath;

  /// The number of coordinator writes after which the peer marker fails.
  int? failPeerMarkerAfter;
  int coordinatorWrites = 0;
  void Function(String operation, String path)? after;

  @override
  void write(String path, List<int> bytes) {
    if (failBeforeWrite != null && failBeforeWrite!(path)) {
      throw StateError('Simulated process interruption');
    }
    if (failPeerMarkerAfter != null &&
        path == peerMarkerPath &&
        coordinatorWrites >= failPeerMarkerAfter!) {
      throw StateError('Simulated crash before the peer marker');
    }
    super.write(path, bytes);
    if (path == coordinatorEvidencePath) coordinatorWrites++;
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
    if (failAfterRename != null && failAfterRename!(destination)) {
      throw StateError('Simulated crash after a durable write');
    }
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

  void reset() {
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
  }

  setUp(reset);

  void seedLedger({
    required String location,
    required String nativeRoot,
    ArtifactKind kind = ArtifactKind.agentFile,
    String nativeForm = 'claude-agent-file',
    String scope = 'project',
    String nativeDestination = 'claude',
    Map<String, Object?> origin = const <String, Object?>{'status': 'unknown'},
  }) {
    final record = InstallationRecord(
      installationId: _sourceInstallationId,
      kind: kind,
      scope: LifecycleScope.values.byName(scope),
      nativeDestination: nativeDestination,
      nativeForm: nativeForm,
      location: location,
      nativeRoot: nativeRoot,
      name: location.split('/').last,
      nativeProfile: 'claude',
      validatedProfiles: const <String>['claude'],
      knownConsumers: const <String>['claude'],
      baseline: const ArtifactBaseline(<BaselineEntry>[]),
      lifecycle: 'live',
      origin: origin,
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
    String? nativeDestination,
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
      nativeDestination: nativeDestination,
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

  /// Writes a synthetic pending inverse restore evidence document.
  void writePendingInverseEvidence({
    required String restoreId,
    required String sourceLocation,
    required String targetLocation,
    String transactionId = _transactionId,
    String scope = 'project',
  }) {
    final root = scope == 'project'
        ? '/work/project/.agent-resource/conversion-restores'
        : '/work/state/conversion-restores';
    final evidence = ConversionRestoreEvidence(
      restoreId: restoreId,
      transactionId: transactionId,
      phase: ConversionRestorePhase.prepared,
      createdScope: scope,
      sourceLocation: sourceLocation,
      targetLocation: targetLocation,
      artifactKind: 'agent-file',
      sourceScope: scope,
      targetScope: scope,
      inPlace: false,
      payloadPath: '/work/project/.agent-resource/conversions/source-payload/reviewer.md',
      payloadDigest: 'a' * 64,
      outgoingDigest: 'b' * 64,
      observations: const <String, Object?>{},
    );
    fs.file('$root/$restoreId.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(evidence.encode());
  }

  /// The installation records of the project ledger.
  List<Map<String, Object?>> ledgerRecords() {
    final file = fs.file('/work/project/.agent-resource/installations.json');
    if (!file.existsSync()) return const <Map<String, Object?>>[];
    final document =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    return (document['installations'] as List).cast<Map<String, Object?>>();
  }

  /// Writes the pack groups of the shared state document.
  void seedPackGroups({
    String scope = 'project',
    List<Map<String, Object?>> packs = const <Map<String, Object?>>[],
    List<Map<String, Object?>> selections = const <Map<String, Object?>>[],
    List<Map<String, Object?>> approvals = const <Map<String, Object?>>[],
    List<Map<String, Object?>> snapshots = const <Map<String, Object?>>[],
  }) {
    final stateRoot = scope == 'project'
        ? '/work/project/.agent-resource'
        : '/work/state';
    final file = fs.file('$stateRoot/installations.json');
    final document = file.existsSync()
        ? jsonDecode(file.readAsStringSync()) as Map<String, Object?>
        : <String, Object?>{'schemaVersion': 1, 'installations': <Object?>[]};
    document['packs'] = packs;
    document['selections'] = selections;
    document['approvals'] = approvals;
    document['snapshots'] = snapshots;
    fs.directory(stateRoot).createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(document));
  }

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

    test(
      'leaves an unmanaged source of the conversion evidence unadopted',
      () async {
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
      },
    );

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

    test(
      'resumes after a crash between the ledger write and the journal',
      () async {
        await completeConversion();
        final source = '/work/project/.claude/agents/reviewer.md';
        final target = '/work/project/.pi/prompts/reviewer.md';
        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        // The durable ledger write lands and the process stops before the
        // inverse restore persists its next phase.
        io.failAfterRename = (path) => path.endsWith('installations.json');
        await expectLater(
          restore.restoreReviewed(
            approved(),
            _transactionId,
            planId: review.data['planId']! as String,
          ),
          throwsA(isA<MambaException>()),
        );
        io.failAfterRename = null;

        // The resumed restore accepts its own applied state and completes.
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
        final records = ledgerRecords();
        final reinstated = records.singleWhere(
          (record) => record['installationId'] == _sourceInstallationId,
        );
        expect(reinstated['lifecycle'], 'live');
        expect(reinstated['location'], source);
        final retired = records.singleWhere(
          (record) => record['installationId'] != _sourceInstallationId,
        );
        expect(retired['lifecycle'], 'removed');
      },
    );

    test(
      'resumes a cross scope restore after the first ledger write',
      () async {
        const source = '/work/project/.claude/agents/reviewer.md';
        const target = '/home/user/.pi/prompts/reviewer.md';
        fs.file(source)
          ..createSync(recursive: true)
          ..writeAsStringSync('original');
        seedLedger(
          location: source,
          nativeRoot: '/work/project/.claude/agents',
        );
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
        final review = await restore.restoreReviewed(
          userOptions.copyWith(approved: true, dryRun: true),
          _transactionId,
        );
        io.failAfterRename = (path) => path.endsWith('installations.json');
        await expectLater(
          restore.restoreReviewed(
            userOptions.copyWith(approved: true),
            _transactionId,
            planId: review.data['planId']! as String,
          ),
          throwsA(isA<MambaException>()),
        );
        io.failAfterRename = null;

        final resumed = await restore.restoreReviewed(
          userOptions.copyWith(approved: true, dryRun: true),
          _transactionId,
        );
        expect(resumed.data['resume'], isTrue);
        final result = await restore.restoreReviewed(
          userOptions.copyWith(approved: true),
          _transactionId,
          planId: resumed.data['planId']! as String,
        );
        expect(result.outcome, 'restored');
        expect(fs.file(source).readAsStringSync(), 'original');
        expect(fs.file(target).existsSync(), isFalse);

        final project = jsonDecode(
          fs
              .file('/work/project/.agent-resource/installations.json')
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final projectRecords = (project['installations'] as List).cast<Map>();
        final reinstated = projectRecords.singleWhere(
          (record) => record['installationId'] == _sourceInstallationId,
        );
        expect(reinstated['lifecycle'], 'live');
        final user = jsonDecode(
          fs.file('/work/state/installations.json').readAsStringSync(),
        ) as Map<String, Object?>;
        final userRecords = (user['installations'] as List).cast<Map>();
        final retired = userRecords.singleWhere(
          (record) => record['installationId'] != _sourceInstallationId,
        );
        expect(retired['lifecycle'], 'removed');
      },
    );

    test(
      'recreates a lost participant marker before any live effect',
      () async {
        const source = '/work/project/.claude/agents/reviewer.md';
        const target = '/home/user/.pi/prompts/reviewer.md';
        fs.file(source)
          ..createSync(recursive: true)
          ..writeAsStringSync('original');
        seedLedger(
          location: source,
          nativeRoot: '/work/project/.claude/agents',
        );
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
        final review = await restore.restoreReviewed(
          userOptions.copyWith(approved: true, dryRun: true),
          _transactionId,
        );
        // The inverse restore is interrupted before its decision.
        io.failBeforeWrite = (path) => path.endsWith('commit.json');
        await expectLater(
          restore.restoreReviewed(
            userOptions.copyWith(approved: true),
            _transactionId,
            planId: review.data['planId']! as String,
          ),
          throwsA(isA<MambaException>()),
        );
        io.failBeforeWrite = null;
        // The participant marker of the other scope is lost.
        final markers = fs.directory(
          '/work/project/.agent-resource/conversion-restores',
        );
        for (final file in markers.listSync().whereType<fslib.File>()) {
          file.deleteSync();
        }
        // The reservation is re-established before the resume continues.
        final resumed = await restore.restoreReviewed(
          userOptions.copyWith(approved: true, dryRun: true),
          _transactionId,
        );
        expect(resumed.data['resume'], isTrue);
        // The review writes nothing.
        expect(
          fs
              .directory('/work/project/.agent-resource/conversion-restores')
              .listSync()
              .whereType<fslib.File>(),
          isEmpty,
        );
        final result = await restore.restoreReviewed(
          userOptions.copyWith(approved: true),
          _transactionId,
          planId: resumed.data['planId']! as String,
        );
        expect(result.data['rolledBack'], isTrue);
        expect(
          fs
              .directory('/work/project/.agent-resource/conversion-restores')
              .listSync()
              .whereType<fslib.File>(),
          isNotEmpty,
        );
      },
    );

    test(
      'refuses a restore when the upstream pack authority changed',
      () async {
        const source = '/work/project/.claude/skills/demo';
        fs.directory(source).createSync(recursive: true);
        fs.file('$source/SKILL.md').writeAsStringSync('original');
        seedLedger(
          location: source,
          nativeRoot: '/work/project/.claude/skills',
          kind: ArtifactKind.skillCopy,
          nativeForm: 'claude-skill-directory',
          origin: const <String, Object?>{
            'status': 'evidenced',
            'packKey': 'pack-one',
            'resourceType': 'skill',
            'resourceName': 'demo',
            'track': <String, Object?>{'kind': 'exact'},
          },
        );
        seedPackGroups(
          selections: const <Map<String, Object?>>[
            <String, Object?>{
              'packKey': 'pack-one',
              'resourceType': 'skill',
              'resourceName': 'demo',
              'scope': 'project',
            },
          ],
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
              location: '/work/project/.pi/prompts/demo',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'skill-copy',
              nativeForm: 'claude-skill-directory',
            ),
            targetFiles: {'SKILL.md': utf8.encode('converted')},
          ),
        );
        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        // The upstream pack authority changes after the review.
        seedPackGroups(
          selections: const <Map<String, Object?>>[
            <String, Object?>{
              'packKey': 'pack-one',
              'resourceType': 'skill',
              'resourceName': 'demo',
              'scope': 'user',
            },
          ],
        );
        await expectLater(
          restore.restoreReviewed(
            approved(),
            _transactionId,
            planId: review.data['planId']! as String,
          ),
          throwsA(isA<MambaException>()),
        );
        expect(fs.directory(source).existsSync(), isFalse);
      },
    );

    test(
      'refuses a resumed restore when the upstream pack authority changed',
      () async {
        const source = '/work/project/.claude/skills/demo';
        fs.directory(source).createSync(recursive: true);
        fs.file('$source/SKILL.md').writeAsStringSync('original');
        seedLedger(
          location: source,
          nativeRoot: '/work/project/.claude/skills',
          kind: ArtifactKind.skillCopy,
          nativeForm: 'claude-skill-directory',
          origin: const <String, Object?>{
            'status': 'evidenced',
            'packKey': 'pack-one',
            'resourceType': 'skill',
            'resourceName': 'demo',
          },
        );
        seedPackGroups(
          selections: const <Map<String, Object?>>[
            <String, Object?>{
              'packKey': 'pack-one',
              'resourceType': 'skill',
              'resourceName': 'demo',
              'scope': 'project',
            },
          ],
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
              location: '/work/project/.pi/prompts/demo',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'skill-copy',
              nativeForm: 'claude-skill-directory',
            ),
            targetFiles: {'SKILL.md': utf8.encode('converted')},
          ),
        );
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
        // The upstream pack authority changes while the inverse restore is
        // pending.
        seedPackGroups(
          selections: const <Map<String, Object?>>[
            <String, Object?>{
              'packKey': 'pack-one',
              'resourceType': 'skill',
              'resourceName': 'demo',
              'scope': 'user',
            },
          ],
        );
        final resumed = await restore.restoreReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        expect(resumed.data['resume'], isTrue);
        await expectLater(
          restore.restoreReviewed(
            approved(),
            _transactionId,
            planId: resumed.data['planId']! as String,
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('upstream pack authority changed'),
            ),
          ),
        );
        // The ownership was not changed by the refused resume.
        final retired = ledgerRecords().singleWhere(
          (record) => record['installationId'] == _sourceInstallationId,
        );
        expect(retired['lifecycle'], 'removed');
      },
    );

    test('does not reinstate a retired upstream tracking', () async {
      const source = '/work/project/.claude/skills/demo';
      fs.directory(source).createSync(recursive: true);
      fs.file('$source/SKILL.md').writeAsStringSync('original');
      seedLedger(
        location: source,
        nativeRoot: '/work/project/.claude/skills',
        kind: ArtifactKind.skillCopy,
        nativeForm: 'claude-skill-directory',
        origin: const <String, Object?>{
          'status': 'evidenced',
          'packKey': 'pack-one',
          'resourceType': 'skill',
          'resourceName': 'demo',
          'track': <String, Object?>{'kind': 'exact'},
        },
      );
      // The pack authority records no membership of the resource any more.
      seedPackGroups();
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
            location: '/work/project/.pi/prompts/demo',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'skill-copy',
            nativeForm: 'claude-skill-directory',
          ),
          targetFiles: {'SKILL.md': utf8.encode('converted')},
        ),
      );
      final review = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      await restore.restoreReviewed(
        approved(),
        _transactionId,
        planId: review.data['planId']! as String,
      );
      final reinstated = ledgerRecords().singleWhere(
        (record) => record['installationId'] == _sourceInstallationId,
      );
      final origin = reinstated['origin'] as Map<String, Object?>;
      expect(origin.containsKey('track'), isFalse);
      expect(origin['packKey'], 'pack-one');
      expect(origin['resourceName'], 'demo');
    });

    test(
      'reserves the upstream pack key while the inverse restore is pending',
      () async {
        const source = '/work/project/.claude/skills/demo';
        fs.directory(source).createSync(recursive: true);
        fs.file('$source/SKILL.md').writeAsStringSync('original');
        seedLedger(
          location: source,
          nativeRoot: '/work/project/.claude/skills',
          kind: ArtifactKind.skillCopy,
          nativeForm: 'claude-skill-directory',
          origin: const <String, Object?>{
            'status': 'evidenced',
            'packKey': 'pack-one',
            'resourceType': 'skill',
            'resourceName': 'demo',
          },
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
              location: '/work/project/.pi/prompts/demo',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'skill-copy',
              nativeForm: 'claude-skill-directory',
            ),
            targetFiles: {'SKILL.md': utf8.encode('converted')},
          ),
        );
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
        // A pack mutation of the reserved pack key is refused.
        expect(
          () => state.checkPendingConversions(
            LifecycleContext.resolve(options, fileSystem: fs),
            packKeys: const <String>{'pack-one'},
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('pending inverse restore'),
            ),
          ),
        );
      },
    );

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

    test(
      'cleans the retained inverse evidence through the registered command',
      () async {
        await completeConversion();
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
        final planId =
            ((jsonDecode((review as MambaSuccessResult).output!) as Map)['data']
                    as Map)['planId']!
                as String;
        await executor.execute(<String>[
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
        final cleanup = await executor.execute(<String>[
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
          '--cleanup',
          '--format',
          'json',
        ]);
        expect(cleanup, isA<MambaSuccessResult>());
        final data = jsonDecode((cleanup as MambaSuccessResult).output!) as Map;
        expect(data['outcome'], 'planned');
        final cleanupPlanId = (data['data'] as Map)['planId']! as String;
        final cleaned = await executor.execute(<String>[
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
          '--cleanup',
          '--plan-id',
          cleanupPlanId,
          '--apply',
          '--yes',
          '--format',
          'json',
        ]);
        expect(cleaned, isA<MambaSuccessResult>());
        expect(
          (jsonDecode((cleaned as MambaSuccessResult).output!)
              as Map)['outcome'],
          'cleaned',
        );
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

  group('durable boundaries and recorded authority', () {
    /// Publishes an ordinary conversion through the real publisher.
    Future<({String transactionId, String planId})> publishOrdinary({
      String source = '/work/source/demo',
      LifecycleScope scope = LifecycleScope.project,
      LifecycleOptions? selected,
    }) async {
      final plans = AuthoringPlanService(fileSystem: fs, state: state);
      final publication = AuthoringPublicationService(
        fileSystem: fs,
        state: state,
      );
      fs.directory(source).createSync(recursive: true);
      fs
          .file('$source/SKILL.md')
          .writeAsStringSync(
            '---\nname: demo\ndescription: Demonstrates the authoring.\n'
            '---\nOriginal instructions.',
          );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        scope: scope,
        sourcePath: source,
        conversion: ConversionDirection.skillToPrompt,
      );
      final reviewed = await plans.plan(inputs, selected ?? options);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');
      await publication.publish(
        AuthoringPublicationRequest(
          plan: reviewed,
          options: selected ?? options,
          planId: reviewed.planId,
          approved: true,
        ),
      );
      final transactionId = fs
          .directory('/work/project/.agent-resource/authoring-transactions')
          .listSync()
          .whereType<fslib.File>()
          .single
          .basename
          .replaceAll('.json', '');
      return (transactionId: transactionId, planId: reviewed.planId);
    }

    test(
      'refuses an ordinary resume that would overwrite a new occupant',
      () async {
        final published = await publishOrdinary();
        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          published.transactionId,
        );
        io.failBeforeWrite = (path) => path.endsWith('commit.json');
        await expectLater(
          restore.restoreReviewed(
            approved(),
            published.transactionId,
            planId: review.data['planId']! as String,
          ),
          throwsA(isA<MambaException>()),
        );
        io.failBeforeWrite = null;
        // A new occupant appears at the original source location.
        fs.file('/work/source/demo/foreign.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('foreign');
        await expectLater(
          restore.restoreReviewed(
            approved(dryRun: true),
            published.transactionId,
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('new occupant'),
            ),
          ),
        );
        expect(
          fs.file('/work/source/demo/foreign.md').readAsStringSync(),
          'foreign',
        );
      },
    );

    test(
      'refuses an ordinary apply that would overwrite a new occupant',
      () async {
        final published = await publishOrdinary();
        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          published.transactionId,
        );
        fs.file('/work/source/demo/foreign.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('foreign');
        await expectLater(
          restore.restoreReviewed(
            approved(),
            published.transactionId,
            planId: review.data['planId']! as String,
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('new occupant'),
            ),
          ),
        );
        expect(
          fs.file('/work/source/demo/foreign.md').readAsStringSync(),
          'foreign',
        );
      },
    );

    test(
      'refuses an ordinary conversion whose authoring receipt is missing',
      () async {
        final published = await publishOrdinary();
        final receipt = fs
            .directory('/work/project/.agent-resource/authoring-receipts')
            .listSync()
            .whereType<fslib.File>()
            .single;
        receipt.deleteSync();
        await expectLater(
          restore.restoreReviewed(
            approved(dryRun: true),
            published.transactionId,
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('authoring receipt'),
            ),
          ),
        );
      },
    );

    test(
      'refuses an ordinary conversion whose receipt was substituted',
      () async {
        final published = await publishOrdinary();
        final receipt = fs
            .directory('/work/project/.agent-resource/authoring-receipts')
            .listSync()
            .whereType<fslib.File>()
            .single;
        final document =
            jsonDecode(receipt.readAsStringSync()) as Map<String, Object?>;
        document['planId'] = 'authoring-plan-${'0' * 64}';
        receipt.writeAsStringSync(jsonEncode(document));
        await expectLater(
          restore.restoreReviewed(
            approved(dryRun: true),
            published.transactionId,
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('authoring receipt'),
            ),
          ),
        );
      },
    );

    test(
      'reserves the recorded peer realm of an ordinary conversion',
      () async {
        const source = '/home/user/.claude/skills/demo';
        final published = await publishOrdinary(source: source);
        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          published.transactionId,
        );
        final restoreId = review.data['restoreId']! as String;
        // The inverse restore is interrupted before its decision, so the
        // reservation of the peer realm is live.
        io.failBeforeWrite = (path) => path.endsWith('commit.json');
        await expectLater(
          restore.restoreReviewed(
            approved(),
            published.transactionId,
            planId: review.data['planId']! as String,
          ),
          throwsA(isA<MambaException>()),
        );
        io.failBeforeWrite = null;
        // The participant marker reserves the recorded peer realm.
        expect(
          fs
              .file('/work/state/conversion-restores/$restoreId.json')
              .existsSync(),
          isTrue,
        );
        // A mutator of the peer realm is refused while the inverse restore is
        // pending.
        final userContext = LifecycleContext.resolve(
          options.copyWith(scope: LifecycleScope.user),
          fileSystem: fs,
        );
        expect(
          () => state.checkPendingConversions(
            userContext,
            locations: const <String>[source],
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('pending inverse restore'),
            ),
          ),
        );
      },
    );

    test(
      'restores a project conversion without a configured user realm',
      () async {
        final local = LifecycleOptions(
          processWorkingDirectory: '/work/project',
          environment: const <String, String>{},
          scope: LifecycleScope.project,
          cwd: '/work/project',
          projectRoot: '/work/project',
          home: '/home/user',
        );
        final published = await publishOrdinary(selected: local);
        final review = await restore.restoreReviewed(
          local.copyWith(approved: true, dryRun: true),
          published.transactionId,
        );
        expect(review.outcome, 'planned');
        final result = await restore.restoreReviewed(
          local.copyWith(approved: true),
          published.transactionId,
          planId: review.data['planId']! as String,
        );
        expect(result.outcome, 'restored');
        expect(
          fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
          contains('Original instructions.'),
        );
        // The managed conversion is restored in the same host without a
        // configured user realm.
        await completeConversion();
        final managed = await restore.restoreReviewed(
          local.copyWith(approved: true, dryRun: true),
          _transactionId,
        );
        expect(managed.outcome, 'planned');
        final managedResult = await restore.restoreReviewed(
          local.copyWith(approved: true),
          _transactionId,
          planId: managed.data['planId']! as String,
        );
        expect(managedResult.outcome, 'restored');
        expect(
          fs
              .file('/work/project/.claude/agents/reviewer.md')
              .readAsStringSync(),
          'original',
        );
      },
    );

    test(
      'resumes after a crash between the coordinator and the peer marker',
      () async {
        const source = '/work/project/.claude/agents/reviewer.md';
        const target = '/home/user/.pi/prompts/reviewer.md';
        // The crash lands in every durable phase of the inverse restore.
        for (var phase = 1; phase <= 5; phase++) {
          reset();
          fs.file(source)
            ..createSync(recursive: true)
            ..writeAsStringSync('original');
          seedLedger(
            location: source,
            nativeRoot: '/work/project/.claude/agents',
          );
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
          final review = await restore.restoreReviewed(
            userOptions.copyWith(approved: true, dryRun: true),
            _transactionId,
          );
          final restoreId = review.data['restoreId']! as String;
          io.coordinatorEvidencePath =
              '/work/state/conversion-restores/$restoreId.json';
          io.peerMarkerPath =
              '/work/project/.agent-resource/conversion-restores/'
              '$restoreId.json';
          io.coordinatorWrites = 0;
          io.failPeerMarkerAfter = phase;
          await expectLater(
            restore.restoreReviewed(
              userOptions.copyWith(approved: true),
              _transactionId,
              planId: review.data['planId']! as String,
            ),
            throwsA(isA<MambaException>()),
            reason: 'phase $phase',
          );
          io.failPeerMarkerAfter = null;
          // The stale peer marker never wedges the restore.
          final resumed = await restore.restoreReviewed(
            userOptions.copyWith(approved: true, dryRun: true),
            _transactionId,
          );
          expect(resumed.data['resume'], isTrue, reason: 'phase $phase');
          final result = await restore.restoreReviewed(
            userOptions.copyWith(approved: true),
            _transactionId,
            planId: resumed.data['planId']! as String,
          );
          expect(result.outcome, 'restored', reason: 'phase $phase');
          // The reservation is re-established in the other realm.
          expect(
            fs
                .file(
                  '/work/project/.agent-resource/conversion-restores/'
                  '$restoreId.json',
                )
                .existsSync(),
            isTrue,
            reason: 'phase $phase',
          );
          if (result.data['rolledBack'] == true) {
            // The inverse restore rolled back before its decision. A fresh
            // attempt restores the source.
            final fresh = await restore.restoreReviewed(
              userOptions.copyWith(approved: true, dryRun: true),
              _transactionId,
            );
            expect(fresh.data['resume'], isFalse, reason: 'phase $phase');
            await restore.restoreReviewed(
              userOptions.copyWith(approved: true),
              _transactionId,
              planId: fresh.data['planId']! as String,
            );
          }
          expect(
            fs.file(source).readAsStringSync(),
            'original',
            reason: 'phase $phase',
          );
          expect(fs.file(target).existsSync(), isFalse, reason: 'phase $phase');
        }
      },
    );

    test('does not reinstate a declined pack membership', () async {
      const source = '/work/project/.claude/skills/demo';
      fs.directory(source).createSync(recursive: true);
      fs.file('$source/SKILL.md').writeAsStringSync('original');
      seedLedger(
        location: source,
        nativeRoot: '/work/project/.claude/skills',
        kind: ArtifactKind.skillCopy,
        nativeForm: 'claude-skill-directory',
        origin: const <String, Object?>{
          'status': 'evidenced',
          'packKey': 'pack-one',
          'resourceType': 'skill',
          'resourceName': 'demo',
          'track': <String, Object?>{'kind': 'exact'},
        },
      );
      seedPackGroups(
        selections: const <Map<String, Object?>>[
          <String, Object?>{
            'packKey': 'pack-one',
            'resourceType': 'skill',
            'resourceName': 'demo',
            'scope': 'project',
            'selected': false,
            'excluded': true,
            'membership': 'group',
            'reason': 'declined',
          },
        ],
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
            location: '/work/project/.pi/prompts/demo',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'skill-copy',
            nativeForm: 'claude-skill-directory',
          ),
          targetFiles: {'SKILL.md': utf8.encode('converted')},
        ),
      );
      final review = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      await restore.restoreReviewed(
        approved(),
        _transactionId,
        planId: review.data['planId']! as String,
      );
      final reinstated = ledgerRecords().singleWhere(
        (record) => record['installationId'] == _sourceInstallationId,
      );
      final origin = reinstated['origin'] as Map<String, Object?>;
      expect(origin.containsKey('track'), isFalse);
      expect(origin['packKey'], 'pack-one');
    });
  });

  group('ordinary publisher conversions', () {
    test(
      'restores an ordinary conversion published by the real publisher',
      () async {
        final plans = AuthoringPlanService(fileSystem: fs, state: state);
        final publication = AuthoringPublicationService(
          fileSystem: fs,
          state: state,
        );
        fs.directory('/work/source/demo').createSync(recursive: true);
        fs
            .file('/work/source/demo/SKILL.md')
            .writeAsStringSync(
              '---\nname: demo\ndescription: Demonstrates the authoring.\n'
              '---\nOriginal instructions.',
            );
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.convert,
          kind: AuthoringKind.prompt,
          profile: AuthoringProfile.pi,
          scope: LifecycleScope.project,
          sourcePath: '/work/source/demo',
          conversion: ConversionDirection.skillToPrompt,
        );
        final reviewed = await plans.plan(inputs, options);
        expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');
        final outcome = await publication.publish(
          AuthoringPublicationRequest(
            plan: reviewed,
            options: options,
            planId: reviewed.planId,
            approved: true,
          ),
        );
        expect(outcome.ownership, PublicationOwnership.authorOnly);
        expect(fs.directory('/work/source/demo').existsSync(), isFalse);
        expect(
          fs.file('/work/project/.pi/prompts/demo.md').existsSync(),
          isTrue,
        );

        // The ordinary publisher records an authoring transaction, a receipt
        // and the retained payload. The inverse restore uses that authority.
        final transactions = fs
            .directory('/work/project/.agent-resource/authoring-transactions')
            .listSync()
            .whereType<fslib.File>()
            .toList();
        expect(transactions, hasLength(1));
        final transactionId = transactions.single.basename.replaceAll(
          '.json',
          '',
        );

        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          transactionId,
        );
        expect(review.outcome, 'planned');
        expect(review.data['sourceManaged'], isFalse);
        final result = await restore.restoreReviewed(
          approved(),
          transactionId,
          planId: review.data['planId']! as String,
        );
        expect(result.outcome, 'restored');

        // The original source is restored with its content.
        expect(
          fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
          contains('Original instructions.'),
        );
        // The converted target is retired.
        expect(
          fs.file('/work/project/.pi/prompts/demo.md').existsSync(),
          isFalse,
        );
        // The restored source is not adopted as an installation.
        expect(ledgerRecords(), isEmpty);
      },
    );

    test('refuses an ordinary conversion whose target changed', () async {
      final plans = AuthoringPlanService(fileSystem: fs, state: state);
      final publication = AuthoringPublicationService(
        fileSystem: fs,
        state: state,
      );
      fs.directory('/work/source/demo').createSync(recursive: true);
      fs
          .file('/work/source/demo/SKILL.md')
          .writeAsStringSync(
            '---\nname: demo\ndescription: Demonstrates the authoring.\n'
            '---\nOriginal instructions.',
          );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        conversion: ConversionDirection.skillToPrompt,
      );
      final reviewed = await plans.plan(inputs, options);
      final outcome = await publication.publish(
        AuthoringPublicationRequest(
          plan: reviewed,
          options: options,
          planId: reviewed.planId,
          approved: true,
        ),
      );
      final transactionId = fs
          .directory('/work/project/.agent-resource/authoring-transactions')
          .listSync()
          .whereType<fslib.File>()
          .single
          .basename
          .replaceAll('.json', '');
      expect(outcome.receiptId, isNotNull);
      fs
          .file('/work/project/.pi/prompts/demo.md')
          .writeAsStringSync('edited after the conversion');
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('converted target changed'),
          ),
        ),
      );
    });

    test('refuses an ordinary conversion whose retained payload was cleaned', () async {
      final plans = AuthoringPlanService(fileSystem: fs, state: state);
      final publication = AuthoringPublicationService(
        fileSystem: fs,
        state: state,
      );
      fs.directory('/work/source/demo').createSync(recursive: true);
      fs
          .file('/work/source/demo/SKILL.md')
          .writeAsStringSync(
            '---\nname: demo\ndescription: Demonstrates the authoring.\n'
            '---\nOriginal instructions.',
          );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        conversion: ConversionDirection.skillToPrompt,
      );
      final reviewed = await plans.plan(inputs, options);
      await publication.publish(
        AuthoringPublicationRequest(
          plan: reviewed,
          options: options,
          planId: reviewed.planId,
          approved: true,
        ),
      );
      final transactionId = fs
          .directory('/work/project/.agent-resource/authoring-transactions')
          .listSync()
          .whereType<fslib.File>()
          .single
          .basename
          .replaceAll('.json', '');
      fs
          .directory(
            '/work/project/.agent-resource/authoring-recovery/${reviewed.planId}',
          )
          .deleteSync(recursive: true);
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('retained recovery payload'),
          ),
        ),
      );
    });
  });

  group('pending inverse restore authority', () {
    test('refuses an old mutator of the reserved source and target', () async {
      const source = '/work/project/.claude/agents/reviewer.md';
      const target = '/work/project/.claude/agents/converted.md';
      fs.file(source)
        ..createSync(recursive: true)
        ..writeAsStringSync('original');
      seedLedger(
        location: source,
        nativeRoot: '/work/project/.claude/agents',
        nativeDestination: 'native',
      );
      await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: _transactionId,
          options: options,
          source: sourceParticipant(
            location: source,
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: target,
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
            nativeDestination: 'native',
          ),
          targetFiles: {'converted.md': utf8.encode('converted')},
        ),
      );
      final targetId =
          ledgerRecords().singleWhere(
                (record) => record['lifecycle'] == 'live',
              )['installationId']!
              as String;
      // The inverse restore is interrupted before its decision and stays
      // pending with its reservation.
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

      // The old removal path of the converted target is refused.
      final removed = await createExecutor(fileSystem: fs)
          .fake()
          .execute(<String>[
            'agent',
            'remove',
            targetId,
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
            '--yes',
          ]);
      expect(removed, isA<MambaFailureResult>());
      expect(
        (removed as MambaFailureResult).message,
        contains('pending inverse restore'),
      );
      expect(fs.file(target).readAsStringSync(), 'converted');
    });

    test(
      'refuses a restore while another inverse restore is pending',
      () async {
        await completeConversion();
        writePendingInverseEvidence(
          restoreId: 'rsv_0123456789abcdef0123456789abcdef',
          transactionId: 'cvx_fedcba9876543210fedcba9876543210',
          sourceLocation: '/work/project/.claude/agents/reviewer.md',
          targetLocation: '/work/project/.pi/prompts/reviewer.md',
        );
        final review = await restore.restoreReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        await expectLater(
          restore.restoreReviewed(
            approved(),
            _transactionId,
            planId: review.data['planId']! as String,
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('pending inverse restore'),
            ),
          ),
        );
        expect(
          fs.file('/work/project/.pi/prompts/reviewer.md').readAsStringSync(),
          'converted',
        );
      },
    );

    test(
      'refuses an old mutator when the inverse evidence is corrupt',
      () async {
        await completeConversion();
        writePendingInverseEvidence(
          restoreId: 'rsv_0123456789abcdef0123456789abcdef',
          sourceLocation: '/work/project/.claude/agents/reviewer.md',
          targetLocation: '/work/project/.pi/prompts/reviewer.md',
        );
        fs
            .file(
              '/work/project/.agent-resource/conversion-restores/'
              'rsv_0123456789abcdef0123456789abcdef.json',
            )
            .writeAsStringSync('{corrupt');
        expect(
          () => state.checkPendingConversions(
            LifecycleContext.resolve(options, fileSystem: fs),
            locations: const <String>['/work/project/.pi/prompts/reviewer.md'],
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('authority is unavailable'),
            ),
          ),
        );
      },
    );

    test('refuses an unknown schema version of the inverse evidence', () async {
      await completeConversion();
      writePendingInverseEvidence(
        restoreId: 'rsv_0123456789abcdef0123456789abcdef',
        sourceLocation: '/work/project/.claude/agents/reviewer.md',
        targetLocation: '/work/project/.pi/prompts/reviewer.md',
      );
      final path =
          '/work/project/.agent-resource/conversion-restores/'
          'rsv_0123456789abcdef0123456789abcdef.json';
      final document = jsonDecode(fs.file(path).readAsStringSync()) as Map;
      document['schemaVersion'] = 999;
      fs.file(path).writeAsStringSync(jsonEncode(document));
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('corrupt'),
          ),
        ),
      );
    });

    test('refuses a damaged retained payload', () async {
      await completeConversion();
      final payload =
          '/work/project/.agent-resource/conversions/$_transactionId/'
          'source-payload/reviewer.md';
      fs.file(payload).writeAsStringSync('damaged');
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('payload is missing or changed'),
          ),
        ),
      );
    });

    test('recovers a lost participant authority of the other scope', () async {
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
      final review = await restore.restoreReviewed(
        userOptions.copyWith(approved: true, dryRun: true),
        _transactionId,
      );
      io.failBeforeWrite = (path) => path.contains('installations.json');
      await expectLater(
        restore.restoreReviewed(
          userOptions.copyWith(approved: true),
          _transactionId,
          planId: review.data['planId']! as String,
        ),
        throwsA(isA<MambaException>()),
      );
      io.failBeforeWrite = null;
      // The participant marker of the other scope reserves the inverse
      // restore there.
      final markers = fs.directory(
        '/work/project/.agent-resource/conversion-restores',
      );
      expect(markers.listSync().whereType<fslib.File>(), isNotEmpty);
      markers.listSync().whereType<fslib.File>().forEach((file) {
        file.deleteSync();
      });
      // The lost reservation is re-established before the resume
      // continues; the inverse restore never proceeds without it.
      final resumed = await restore.restoreReviewed(
        userOptions.copyWith(approved: true, dryRun: true),
        _transactionId,
      );
      expect(resumed.data['resume'], isTrue);
      final result = await restore.restoreReviewed(
        userOptions.copyWith(approved: true),
        _transactionId,
        planId: resumed.data['planId']! as String,
      );
      expect(result.outcome, 'restored');
      expect(fs.file(source).readAsStringSync(), 'original');
      expect(
        fs
            .directory('/work/project/.agent-resource/conversion-restores')
            .listSync()
            .whereType<fslib.File>(),
        isNotEmpty,
      );
    });

    test('refuses to complete when the outgoing evidence is lost', () async {
      await completeConversion();
      final source = '/work/project/.claude/agents/reviewer.md';
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
      // The outgoing target evidence of the decided inverse restore is
      // removed. The restore stops safely instead of recreating it.
      final restoreId = review.data['restoreId']! as String;
      final outgoing =
          '/work/project/.agent-resource/conversion-restores/$restoreId/'
          'outgoing-target';
      fs.directory(outgoing).deleteSync(recursive: true);
      final resumed = await restore.restoreReviewed(
        approved(dryRun: true),
        _transactionId,
      );
      expect(resumed.data['resume'], isTrue);
      await expectLater(
        restore.restoreReviewed(
          approved(),
          _transactionId,
          planId: resumed.data['planId']! as String,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('outgoing target evidence is missing'),
          ),
        ),
      );
      expect(fs.file(source).readAsStringSync(), 'original');
    });

    test(
      'cleans the retained private copies of a terminal inverse restore',
      () async {
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
        final restoreId = review.data['restoreId']! as String;
        final staging =
            '/work/project/.agent-resource/conversion-restores/$restoreId';
        expect(fs.directory('$staging/outgoing-target').existsSync(), isTrue);

        final cleanup = await restore.cleanupReviewed(
          approved(dryRun: true),
          _transactionId,
        );
        expect(cleanup.data['action'], 'cleanup');
        final cleaned = await restore.cleanupReviewed(
          approved(),
          _transactionId,
          planId: cleanup.data['planId']! as String,
        );
        expect(cleaned.outcome, 'cleaned');
        expect(fs.directory('$staging/outgoing-target').existsSync(), isFalse);
        expect(fs.directory('$staging/restored-source').existsSync(), isFalse);
        // The inverse evidence document is retained as an audit tombstone.
        expect(
          fs
              .file(
                '/work/project/.agent-resource/conversion-restores/'
                '$restoreId.json',
              )
              .existsSync(),
          isTrue,
        );
      },
    );

    test(
      'refuses the cleanup while another authority reserves the source',
      () async {
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
        // Another pending inverse restore reserves the same target.
        writePendingInverseEvidence(
          restoreId: 'rsv_0123456789abcdef0123456789abcdef',
          transactionId: 'cvx_fedcba9876543210fedcba9876543210',
          sourceLocation: '/work/project/.claude/agents/reviewer.md',
          targetLocation: '/work/project/.pi/prompts/reviewer.md',
        );
        await expectLater(
          restore.cleanupReviewed(approved(dryRun: true), _transactionId),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('pending inverse restore'),
            ),
          ),
        );
      },
    );

    test(
      'removes the participant marker of the other scope on cleanup',
      () async {
        const source = '/work/project/.claude/agents/reviewer.md';
        const target = '/home/user/.pi/prompts/reviewer.md';
        fs.file(source)
          ..createSync(recursive: true)
          ..writeAsStringSync('original');
        seedLedger(
          location: source,
          nativeRoot: '/work/project/.claude/agents',
        );
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
        final review = await restore.restoreReviewed(
          userOptions.copyWith(approved: true, dryRun: true),
          _transactionId,
        );
        await restore.restoreReviewed(
          userOptions.copyWith(approved: true),
          _transactionId,
          planId: review.data['planId']! as String,
        );
        final markers = fs.directory(
          '/work/project/.agent-resource/conversion-restores',
        );
        expect(markers.listSync().whereType<fslib.File>(), isNotEmpty);
        final cleanup = await restore.cleanupReviewed(
          userOptions.copyWith(approved: true, dryRun: true),
          _transactionId,
        );
        await restore.cleanupReviewed(
          userOptions.copyWith(approved: true),
          _transactionId,
          planId: cleanup.data['planId']! as String,
        );
        expect(markers.listSync().whereType<fslib.File>(), isEmpty);
        // The evidence of the coordinator scope remains as the tombstone.
        expect(
          fs
              .directory('/work/state/conversion-restores')
              .listSync()
              .whereType<fslib.File>(),
          isNotEmpty,
        );
      },
    );

    test('refuses the cleanup of an unfinished inverse restore', () async {
      await completeConversion();
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
      await expectLater(
        restore.cleanupReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('No terminal inverse restore evidence'),
          ),
        ),
      );
    });

    test(
      'refuses a restore when the upstream membership of the source changed',
      () async {
        const source = '/work/project/.claude/agents/reviewer.md';
        fs.file(source)
          ..createSync(recursive: true)
          ..writeAsStringSync('original');
        seedLedger(
          location: source,
          nativeRoot: '/work/project/.claude/agents',
          origin: const <String, Object?>{
            'status': 'unknown',
            'packKey': 'pack-one',
            'resourceType': 'skill',
          },
        );
        await coordinator.execute(
          ConversionTransitionRequest(
            transactionId: _transactionId,
            options: options,
            source: sourceParticipant(
              location: source,
              nativeRoot: '/work/project/.claude/agents',
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
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
        // The upstream membership of the retired source changed.
        final ledger = fs.file(
          '/work/project/.agent-resource/installations.json',
        );
        final document = jsonDecode(ledger.readAsStringSync()) as Map;
        for (final record in (document['installations'] as List).cast<Map>()) {
          if (record['lifecycle'] != 'removed') continue;
          (record['origin'] as Map)['packKey'] = 'pack-two';
        }
        ledger.writeAsStringSync(jsonEncode(document));
        await expectLater(
          restore.restoreReviewed(approved(dryRun: true), _transactionId),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('upstream membership'),
            ),
          ),
        );
      },
    );

    test('refuses a restore when the membership binding is missing', () async {
      const source = '/work/project/.claude/agents/reviewer.md';
      fs.file(source)
        ..createSync(recursive: true)
        ..writeAsStringSync('original');
      seedLedger(location: source, nativeRoot: '/work/project/.claude/agents');
      await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: _transactionId,
          options: options,
          source: sourceParticipant(
            location: source,
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
        (record['origin'] as Map).remove('conversionMembership');
      }
      ledger.writeAsStringSync(jsonEncode(document));
      await expectLater(
        restore.restoreReviewed(approved(dryRun: true), _transactionId),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('membership binding'),
          ),
        ),
      );
    });
  });
}
