import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/src/conversion/conversion_evidence.dart';
import 'package:agent_resource/src/services/conversion_coordinator_service.dart';
import 'package:agent_resource/src/services/conversion_evidence_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

/// One durable boundary of the coordinated transition.
class _Boundary {
  const _Boundary(
    this.operation,
    this.path,
    this.expectRecovery, {
    this.afterCommit = false,
  });

  final String operation;
  final String? path;

  /// Whether the boundary leaves the transaction in recovery.
  final bool expectRecovery;

  /// Whether the boundary is reached after the commit decision.
  final bool afterCommit;
}

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
  late ConversionCoordinator coordinator;
  late LifecycleOptions options;

  const sourceInstallationId = 'ins_0123456789abcdef0123456789abcdef';

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
  }) {
    final record = InstallationRecord(
      installationId: sourceInstallationId,
      kind: kind,
      scope: LifecycleScope.project,
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
    final stateRoot = '/work/project/.agent-resource';
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
      scope: 'project',
      ownershipBefore: ConversionOwnership(
        managed: true,
        installationId: sourceInstallationId,
        nativeForm: nativeForm,
        nativeProfile: 'claude',
        location: location,
        nativeRoot: nativeRoot,
        scope: 'project',
      ),
      baseline: baseline,
    );
  }

  ConversionParticipant targetParticipant({
    required String location,
    required String nativeRoot,
    required String artifactKind,
    required String nativeForm,
    String installationId = sourceInstallationId,
  }) => ConversionParticipant(
    role: ConversionParticipantRole.target,
    intent: ConversionParticipantIntent.created,
    artifactKind: artifactKind,
    nativeForm: nativeForm,
    nativeProfile: 'claude',
    location: location,
    nativeRoot: nativeRoot,
    scope: 'project',
    ownershipAfter: ConversionOwnership(
      managed: true,
      installationId: installationId,
      nativeForm: nativeForm,
      nativeProfile: 'claude',
      location: location,
      nativeRoot: nativeRoot,
      scope: 'project',
    ),
  );

  group('ConversionCoordinator', () {
    test('every durable boundary is exercised', () async {
      const boundaries = <_Boundary>[
        _Boundary(
          'createDirectory',
          'conversions/cvx_0123456789abcdef0123456789abcdef/',
          false,
        ),
        _Boundary('copy', null, false),
        _Boundary('write', '/target/', false),
        _Boundary(
          'write',
          'conversions/cvx_0123456789abcdef0123456789abcdef.json',
          true,
        ),
        _Boundary('write', 'commit.json', false),
        _Boundary('write', 'installations.json', true, afterCommit: true),
        _Boundary('delete', '/target', true, afterCommit: true),
      ];
      for (final boundary in boundaries) {
        fs.directory('/work/project').createSync(recursive: true);
        fs.directory('/home/user').createSync(recursive: true);
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
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .createSync(recursive: true);
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .writeAsStringSync('Original agent instructions');
        seedLedger(
          location: '/work/project/.claude/agents/reviewer.md',
          nativeRoot: '/work/project/.claude/agents',
        );
        io.failingOperation = boundary.operation;
        io.failingPath = boundary.path;
        final request = ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/reviewer.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            installationId: 'ins_fedcba9876543210fedcba9876543210',
          ),
          targetFiles: <String, List<int>>{
            'reviewer.md': utf8.encode('Review.'),
          },
        );
        if (boundary.expectRecovery) {
          await expectLater(
            coordinator.execute(request),
            throwsA(
              isA<MambaException>().having(
                (error) => error.message,
                'message',
                contains('needs recovery'),
              ),
            ),
          );
          expect(
            fs.file('/work/project/.pi/prompts/reviewer.md').existsSync(),
            boundary.afterCommit,
            reason:
                'the published target follows the commit decision: '
                '${boundary.operation} ${boundary.path}',
          );
        } else {
          final outcome = await coordinator.execute(request);
          expect(
            outcome.phase,
            ConversionEvidencePhase.rolledBack,
            reason: 'a failure before the commit rolls back',
          );
          expect(outcome.succeeded, isFalse);
          expect(
            fs.file('/work/project/.pi/prompts/reviewer.md').existsSync(),
            isFalse,
          );
          expect(
            fs
                .file('/work/project/.claude/agents/reviewer.md')
                .readAsStringSync(),
            'Original agent instructions',
          );
        }
      }
    });

    test('a cross scope conversion reconciles both roots', () async {
      fs
          .file('/work/project/.claude/skills/demo/SKILL.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/skills/demo/SKILL.md')
          .writeAsStringSync('Skill instructions');
      final projectState = '/work/project/.agent-resource';
      fs.directory(projectState).createSync(recursive: true);
      fs
          .file('$projectState/installations.json')
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'installations': <Object?>[
                InstallationRecord(
                  installationId: sourceInstallationId,
                  kind: ArtifactKind.skillCopy,
                  scope: LifecycleScope.project,
                  nativeDestination: 'claude',
                  nativeForm: 'claude-skill',
                  location: '/work/project/.claude/skills/demo',
                  nativeRoot: '/work/project/.claude/skills',
                  name: 'demo',
                  nativeProfile: 'claude',
                  validatedProfiles: const <String>['claude'],
                  knownConsumers: const <String>['claude'],
                  baseline: const ArtifactBaseline(<BaselineEntry>[]),
                  lifecycle: 'live',
                  origin: const <String, Object?>{'status': 'unknown'},
                  backupIds: const <String>[],
                  transactionId: null,
                ).toJson(),
              ],
            }),
          );
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options.copyWith(scope: LifecycleScope.user),
          source:
              sourceParticipant(
                location: '/work/project/.claude/skills/demo',
                nativeRoot: '/work/project/.claude/skills',
                artifactKind: 'skill-copy',
                nativeForm: 'claude-skill',
              ).copyWith(
                ownershipBefore: ConversionOwnership(
                  managed: true,
                  installationId: sourceInstallationId,
                  nativeForm: 'claude-skill',
                  nativeProfile: 'claude',
                  location: '/work/project/.claude/skills/demo',
                  nativeRoot: '/work/project/.claude/skills',
                  scope: 'project',
                ),
              ),
          target:
              targetParticipant(
                location: '/home/user/.claude/skills/demo',
                nativeRoot: '/home/user/.claude/skills',
                artifactKind: 'skill-copy',
                nativeForm: 'claude-skill',
                installationId: 'ins_fedcba9876543210fedcba9876543210',
              ).copyWith(
                ownershipAfter: ConversionOwnership(
                  managed: true,
                  installationId: 'ins_fedcba9876543210fedcba9876543210',
                  nativeForm: 'claude-skill',
                  nativeProfile: 'claude',
                  location: '/home/user/.claude/skills/demo',
                  nativeRoot: '/home/user/.claude/skills',
                  scope: 'user',
                ),
              ),
          targetFiles: <String, List<int>>{
            'SKILL.md': utf8.encode('---\nname: demo\n---\nDemo.'),
          },
        ),
      );
      expect(outcome.succeeded, isTrue);
      final projectLedger = jsonDecode(
        fs.file('$projectState/installations.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final projectRecords = projectLedger['installations']! as List<Object?>;
      expect(projectRecords.length, 1);
      expect(
        (projectRecords.single! as Map<String, Object?>)['lifecycle'],
        'removed',
      );
      final userLedger = jsonDecode(
        fs.file('/work/state/installations.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final userRecords = userLedger['installations']! as List<Object?>;
      expect(userRecords.length, 1);
      expect(
        (userRecords.single! as Map<String, Object?>)['lifecycle'],
        'live',
      );
    });

    test(
      'a file to file conversion publishes, commits and reconciles',
      () async {
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .createSync(recursive: true);
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .writeAsStringSync('Original agent instructions');
        seedLedger(
          location: '/work/project/.claude/agents/reviewer.md',
          nativeRoot: '/work/project/.claude/agents',
        );
        final outcome = await coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source:
                sourceParticipant(
                  location: '/work/project/.claude/agents/reviewer.md',
                  nativeRoot: '/work/project/.claude/agents',
                  artifactKind: 'agent-file',
                  nativeForm: 'claude-agent-file',
                ).copyWith(
                  membershipBefore: const ConversionMembership(
                    kind: 'pack',
                    state: 'active',
                    memberId: 'mem_reviewer',
                    source: 'pack_demo',
                  ),
                ),
            target: targetParticipant(
              location: '/work/project/.pi/prompts/reviewer.md',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'prompt-template',
              nativeForm: 'pi-prompt-template',
              installationId: 'ins_fedcba9876543210fedcba9876543210',
            ),
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode(
                '---\ndescription: Review\n---\nReview.',
              ),
            },
          ),
        );
        expect(outcome.succeeded, isTrue);
        expect(outcome.phase, ConversionEvidencePhase.completed);
        expect(outcome.committed, isTrue);
        expect(outcome.reconciled, isTrue);
        expect(
          fs.file('/work/project/.pi/prompts/reviewer.md').readAsStringSync(),
          contains('description: Review'),
        );
        expect(
          fs.file('/work/project/.claude/agents/reviewer.md').existsSync(),
          isTrue,
        );
        final ledger = jsonDecode(
          fs
              .file('/work/project/.agent-resource/installations.json')
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final records = ledger['installations']! as List<Object?>;
        expect(records.length, 2);
        final live = records.cast<Map<String, Object?>>().where(
          (record) => record['lifecycle'] == 'live',
        );
        expect(live.length, 1);
        expect(
          live.single['location'],
          '/work/project/.pi/prompts/reviewer.md',
        );
        final liveOrigin = live.single['origin']! as Map<String, Object?>;
        expect(
          (liveOrigin['conversionMembership']!
              as Map<String, Object?>)['state'],
          'detached',
        );
        final removed = records.cast<Map<String, Object?>>().singleWhere(
          (record) => record['lifecycle'] == 'removed',
        );
        final removedOrigin = removed['origin']! as Map<String, Object?>;
        expect(
          (removedOrigin['conversionMembership']!
              as Map<String, Object?>)['state'],
          'retired',
        );
        expect(
          fs.file(outcome.recoveryPayloadPath!).readAsStringSync(),
          'Original agent instructions',
        );
      },
    );

    test('a directory to file conversion publishes the template', () async {
      fs
          .file('/work/project/.claude/skills/demo/SKILL.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/skills/demo/SKILL.md')
          .writeAsStringSync('Skill instructions');
      seedLedger(
        location: '/work/project/.claude/skills/demo',
        nativeRoot: '/work/project/.claude/skills',
        kind: ArtifactKind.skillCopy,
        nativeForm: 'claude-skill',
      );
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/skills/demo',
            nativeRoot: '/work/project/.claude/skills',
            artifactKind: 'skill-copy',
            nativeForm: 'claude-skill',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/demo.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            installationId: 'ins_fedcba9876543210fedcba9876543210',
          ),
          targetFiles: <String, List<int>>{
            'demo.md': utf8.encode('---\ndescription: Demo\n---\nDemo.'),
          },
        ),
      );
      expect(outcome.succeeded, isTrue);
      expect(fs.file('/work/project/.pi/prompts/demo.md').existsSync(), isTrue);
      expect(
        fs.directory('/work/project/.claude/skills/demo').existsSync(),
        isTrue,
      );
    });

    test('an in place conversion keeps the installation identity', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          targetFiles: <String, List<int>>{
            'reviewer.md': utf8.encode('Converted agent instructions'),
          },
        ),
      );
      expect(outcome.succeeded, isTrue);
      expect(
        fs.file('/work/project/.claude/agents/reviewer.md').readAsStringSync(),
        'Converted agent instructions',
      );
      final ledger = jsonDecode(
        fs
            .file('/work/project/.agent-resource/installations.json')
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final records = ledger['installations']! as List<Object?>;
      expect(records.length, 1);
      final record = records.single! as Map<String, Object?>;
      expect(record['installationId'], sourceInstallationId);
      expect(record['lifecycle'], 'live');
    });

    test('a changed source is refused before any live effect', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      final source = sourceParticipant(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
        artifactKind: 'agent-file',
        nativeForm: 'claude-agent-file',
      );
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Changed instructions');
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: source,
            target: targetParticipant(
              location: '/work/project/.pi/prompts/reviewer.md',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'prompt-template',
              nativeForm: 'pi-prompt-template',
              installationId: 'ins_fedcba9876543210fedcba9876543210',
            ),
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Review.'),
            },
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('changed since the reviewed plan'),
          ),
        ),
      );
      expect(
        fs.file('/work/project/.pi/prompts/reviewer.md').existsSync(),
        isFalse,
      );
    });

    test('a failure before the commit rolls the transition back', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      io.failingOperation = 'write';
      io.failingPath = '/work/project/.pi/prompts/reviewer.md';
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/reviewer.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            installationId: 'ins_fedcba9876543210fedcba9876543210',
          ),
          targetFiles: <String, List<int>>{
            'reviewer.md': utf8.encode('Review.'),
          },
        ),
      );
      expect(outcome.succeeded, isFalse);
      expect(outcome.phase, ConversionEvidencePhase.rolledBack);
      expect(
        fs.file('/work/project/.pi/prompts/reviewer.md').existsSync(),
        isFalse,
      );
      expect(
        fs.file('/work/project/.claude/agents/reviewer.md').readAsStringSync(),
        'Original agent instructions',
      );
    });

    test(
      'a reconstructed service finishes a committed transition forward',
      () async {
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .createSync(recursive: true);
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .writeAsStringSync('Original agent instructions');
        seedLedger(
          location: '/work/project/.claude/agents/reviewer.md',
          nativeRoot: '/work/project/.claude/agents',
        );
        io.failingOperation = 'write';
        io.failingPath = 'installations.json';
        await expectLater(
          coordinator.execute(
            ConversionTransitionRequest(
              transactionId: 'cvx_0123456789abcdef0123456789abcdef',
              options: options,
              source: sourceParticipant(
                location: '/work/project/.claude/agents/reviewer.md',
                nativeRoot: '/work/project/.claude/agents',
                artifactKind: 'agent-file',
                nativeForm: 'claude-agent-file',
              ),
              target: targetParticipant(
                location: '/work/project/.pi/prompts/reviewer.md',
                nativeRoot: '/work/project/.pi/prompts',
                artifactKind: 'prompt-template',
                nativeForm: 'pi-prompt-template',
                installationId: 'ins_fedcba9876543210fedcba9876543210',
              ),
              targetFiles: <String, List<int>>{
                'reviewer.md': utf8.encode('Review.'),
              },
            ),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'exit code',
              6,
            ),
          ),
        );
        io.failingOperation = null;
        io.failingPath = null;
        final reconstructed = ConversionCoordinator(
          io: io,
          state: LifecycleStateService(io: io),
          evidence: ConversionEvidenceService(fileSystem: fs),
        );
        final outcome = await reconstructed.resume(
          options: options,
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
        );
        expect(outcome.succeeded, isTrue);
        expect(outcome.committed, isTrue);
        expect(outcome.phase, ConversionEvidencePhase.completed);
      },
    );

    test('completed evidence and ledgers remain readable', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/reviewer.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            installationId: 'ins_fedcba9876543210fedcba9876543210',
          ),
          targetFiles: <String, List<int>>{
            'reviewer.md': utf8.encode('Review.'),
          },
        ),
      );
      final evidence = await ConversionEvidenceService(
        fileSystem: fs,
      ).readPersisted('/work/project/.agent-resource', outcome.transactionId);
      expect(evidence!.phase, ConversionEvidencePhase.completed);
      expect(evidence.source.payload!.digest, evidence.source.baseline!.digest);
      expect(evidence.target.publication!.verified, isTrue);
      expect(
        state.records(LifecycleContext.resolve(options, fileSystem: fs)),
        hasLength(2),
      );
    });

    test('an occupied target is refused before staging', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      fs.file('/work/project/.pi/prompts/reviewer.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing target');
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
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
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Review.'),
            },
          ),
        ),
        throwsA(isA<MambaException>()),
      );
      expect(
        fs.file('/work/project/.pi/prompts/reviewer.md').readAsStringSync(),
        'Existing target',
      );
      expect(
        fs.directory('/work/project/.agent-resource/conversions').existsSync(),
        isFalse,
      );
    });

    test('unsafe proposed target paths are refused before staging', () async {
      fs.file('/work/project/.claude/skills/demo/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Skill instructions');
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/skills/demo',
              nativeRoot: '/work/project/.claude/skills',
              artifactKind: 'skill-copy',
              nativeForm: 'claude-skill',
            ),
            target: targetParticipant(
              location: '/work/project/.codex/skills/demo',
              nativeRoot: '/work/project/.codex/skills',
              artifactKind: 'skill-copy',
              nativeForm: 'codex-skill',
              installationId: 'ins_fedcba9876543210fedcba9876543210',
            ),
            targetFiles: <String, List<int>>{
              '../escape': utf8.encode('escape'),
            },
          ),
        ),
        throwsA(isA<MambaException>()),
      );
      expect(
        fs.file('/work/project/.codex/skills/escape').existsSync(),
        isFalse,
      );
    });

    test(
      'an in-place quarantine failure rolls back without live change',
      () async {
        fs.file('/work/project/.claude/agents/reviewer.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('Original agent instructions');
        seedLedger(
          location: '/work/project/.claude/agents/reviewer.md',
          nativeRoot: '/work/project/.claude/agents',
        );
        io.failingOperation = 'rename';
        io.failingPath = '/work/project/.claude/agents/reviewer.md';
        final outcome = await coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
              nativeRoot: '/work/project/.claude/agents',
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
            ),
            target: targetParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
              nativeRoot: '/work/project/.claude/agents',
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
            ),
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Converted instructions'),
            },
          ),
        );
        expect(outcome.phase, ConversionEvidencePhase.rolledBack);
        expect(
          fs
              .file('/work/project/.claude/agents/reviewer.md')
              .readAsStringSync(),
          'Original agent instructions',
        );
      },
    );

    test('source ownership must match the reviewed ledger record', () async {
      fs.file('/work/project/.claude/agents/reviewer.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/other.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
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
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Review.'),
            },
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('does not match the installation ledger'),
          ),
        ),
      );
    });

    test('cross-scope target ownership is refused', () async {
      fs.file('/work/project/.claude/agents/reviewer.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      fs.directory('/work/state').createSync(recursive: true);
      fs
          .file('/work/state/installations.json')
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'installations': <Object?>[
                InstallationRecord(
                  installationId: 'ins_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                  kind: ArtifactKind.promptTemplate,
                  scope: LifecycleScope.user,
                  nativeDestination: 'pi',
                  nativeForm: 'pi-prompt-template',
                  location: '/work/project/.pi/prompts/reviewer.md',
                  nativeRoot: '/work/project/.pi/prompts',
                  name: 'reviewer.md',
                  nativeProfile: 'pi',
                  validatedProfiles: const <String>['pi'],
                  knownConsumers: const <String>['pi'],
                  baseline: const ArtifactBaseline(<BaselineEntry>[]),
                  lifecycle: 'live',
                  origin: const <String, Object?>{'status': 'unknown'},
                  backupIds: const <String>[],
                  transactionId: null,
                ).toJson(),
              ],
            }),
          );
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
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
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Review.'),
            },
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('Another scope already owns'),
          ),
        ),
      );
    });

    test('unsupported linked target publication is refused', () async {
      fs.file('/work/project/.claude/skills/demo/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Skill instructions');
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/skills/demo',
              nativeRoot: '/work/project/.claude/skills',
              artifactKind: 'skill-copy',
              nativeForm: 'claude-skill',
            ),
            target: targetParticipant(
              location: '/work/project/.codex/skills/demo',
              nativeRoot: '/work/project/.codex/skills',
              artifactKind: 'skill-link',
              nativeForm: 'codex-skill-link',
            ),
            targetFiles: <String, List<int>>{'SKILL.md': utf8.encode('Demo.')},
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('not supported'),
          ),
        ),
      );
    });
  });
}
