import 'package:agent_resource/src/conversion/conversion_evidence.dart';
import 'package:agent_resource/src/services/conversion_evidence_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late ConversionEvidenceService service;

  setUp(() {
    fs = MemoryFileSystem();
    service = ConversionEvidenceService(fileSystem: fs);
  });

  ConversionOwnership managedOwnership({
    required String location,
    String installationId = 'ins_0123456789abcdef0123456789abcdef',
  }) => ConversionOwnership(
    managed: true,
    installationId: installationId,
    nativeForm: 'claude-skill',
    location: location,
    scope: 'project',
    nativeRoot: location.substring(0, location.lastIndexOf('/')),
    provenance: const <String, Object?>{'origin': 'pack'},
  );

  ConversionParticipant participant({
    required ConversionParticipantRole role,
    required String location,
    ConversionOwnership? ownershipBefore,
    ConversionOwnership? ownershipAfter,
    ConversionMembership? membershipBefore,
  }) => ConversionParticipant(
    role: role,
    intent: role == ConversionParticipantRole.source
        ? ConversionParticipantIntent.retired
        : ConversionParticipantIntent.created,
    artifactKind: 'skill-copy',
    nativeForm: 'claude-skill',
    nativeProfile: 'claude',
    location: location,
    nativeRoot: location.substring(0, location.lastIndexOf('/')),
    scope: 'project',
    ownershipBefore: ownershipBefore,
    ownershipAfter: ownershipAfter,
    membershipBefore: membershipBefore,
  );

  test('the prepared evidence records the identity transition', () {
    const source = '/work/project/.claude/skills/demo';
    const target = '/work/project/.codex/skills/demo';
    final evidence = service.prepare(
      transactionId: 'cvx_0123456789abcdef0123456789abcdef',
      source: participant(
        role: ConversionParticipantRole.source,
        location: source,
        ownershipBefore: managedOwnership(location: source),
        membershipBefore: const ConversionMembership(
          kind: 'pack',
          state: 'active',
          memberId: 'mem_1',
        ),
      ),
      target: participant(
        role: ConversionParticipantRole.target,
        location: target,
        ownershipAfter: managedOwnership(location: target),
      ),
      allocatedInstallationId: 'ins_fedcba9876543210fedcba9876543210',
      lineageId: 'ln_1',
    );
    expect(evidence.source.intent, ConversionParticipantIntent.retired);
    expect(evidence.source.membershipAfter?.state, 'retired');
    expect(
      evidence.target.identity?.installationId,
      'ins_fedcba9876543210fedcba9876543210',
    );
    expect(
      evidence.target.identity?.convertedFromId,
      'ins_0123456789abcdef0123456789abcdef',
    );
    expect(evidence.target.membershipAfter?.state, 'detached');
    expect(evidence.phase, ConversionEvidencePhase.prepared);
    expect(evidence.encode(), contains('cvx_0123456789abcdef0123456789abcdef'));
  });

  test('a relocated target requires an allocated installation identifier', () {
    const source = '/work/project/.claude/skills/demo';
    const target = '/work/project/.codex/skills/demo';
    expect(
      () => service.prepare(
        transactionId: 'cvx_0123456789abcdef0123456789abcdef',
        source: participant(
          role: ConversionParticipantRole.source,
          location: source,
          ownershipBefore: managedOwnership(location: source),
        ),
        target: participant(
          role: ConversionParticipantRole.target,
          location: target,
          ownershipAfter: managedOwnership(location: target),
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('an adoption of an unmanaged source is refused', () {
    const location = '/work/project/source/demo';
    expect(
      () => service.prepare(
        transactionId: 'cvx_0123456789abcdef0123456789abcdef',
        source: participant(
          role: ConversionParticipantRole.source,
          location: location,
          ownershipBefore: ConversionOwnership(
            managed: false,
            receiptId: 'rcp_0123456789abcdef0123456789abcdef',
            nativeForm: 'claude-skill',
            location: location,
            scope: 'project',
            nativeRoot: location.substring(0, location.lastIndexOf('/')),
          ),
        ),
        target: participant(
          role: ConversionParticipantRole.target,
          location: location,
          ownershipAfter: managedOwnership(location: location),
        ),
      ),
      throwsA(
        isA<MambaException>().having(
          (error) => error.message,
          'message',
          contains('cannot become a managed'),
        ),
      ),
    );
  });

  test('an invalid transaction identifier is refused', () {
    expect(
      () => service.prepare(
        transactionId: 'txn_1',
        source: participant(
          role: ConversionParticipantRole.source,
          location: '/work/project/.claude/skills/demo',
        ),
        target: participant(
          role: ConversionParticipantRole.target,
          location: '/work/project/.claude/skills/demo',
        ),
      ),
      throwsA(isA<MambaException>()),
    );
  });

  test('the evidence path stays inside the state root', () {
    final path = service.evidencePath(
      '/work/project/.agent-resource',
      'cvx_0123456789abcdef0123456789abcdef',
    );
    expect(
      path,
      '/work/project/.agent-resource/conversions/'
      'cvx_0123456789abcdef0123456789abcdef.json',
    );
    expect(
      () => service.evidencePath('/work/project/.agent-resource', '../escape'),
      throwsA(isA<MambaException>()),
    );
  });

  test('a persisted evidence document is read and validated', () async {
    final evidence = service.prepare(
      transactionId: 'cvx_0123456789abcdef0123456789abcdef',
      source: participant(
        role: ConversionParticipantRole.source,
        location: '/work/project/.claude/skills/demo',
        ownershipBefore: managedOwnership(
          location: '/work/project/.claude/skills/demo',
        ),
      ),
      target: participant(
        role: ConversionParticipantRole.target,
        location: '/work/project/.claude/skills/demo',
        ownershipAfter: managedOwnership(
          location: '/work/project/.claude/skills/demo',
        ),
      ),
    );
    final directory = service.evidenceDirectory('/work/state');
    fs.directory(directory).createSync(recursive: true);
    fs
        .file('$directory/cvx_0123456789abcdef0123456789abcdef.json')
        .writeAsStringSync(evidence.encode());
    final read = await service.readPersisted(
      '/work/state',
      'cvx_0123456789abcdef0123456789abcdef',
    );
    expect(read, isNotNull);
    expect(read!.digest, evidence.digest);
  });

  test('a missing evidence document is not an error', () async {
    expect(
      await service.readPersisted(
        '/work/state',
        'cvx_0123456789abcdef0123456789abcdef',
      ),
      isNull,
    );
  });

  test('a corrupt evidence document fails closed', () async {
    final directory = service.evidenceDirectory('/work/state');
    fs.directory(directory).createSync(recursive: true);
    fs
        .file('$directory/cvx_0123456789abcdef0123456789abcdef.json')
        .writeAsStringSync('{"schemaVersion": 1}');
    expect(
      () => service.readPersisted(
        '/work/state',
        'cvx_0123456789abcdef0123456789abcdef',
      ),
      throwsA(isA<MambaException>()),
    );
  });

  test('a legacy installation record stays readable', () {
    final record = InstallationRecord.fromJson(<String, Object?>{
      'installationId': 'ins_0123456789abcdef0123456789abcdef',
      'artifactKind': 'skill-copy',
      'scope': 'project',
      'nativeDestination': 'claude',
      'nativeForm': 'claude-skill',
      'location': '/work/project/.claude/skills/demo',
      'nativeRoot': '/work/project/.claude/skills',
      'name': 'demo',
      'nativeProfile': 'claude',
      'validatedProfiles': <String>['claude'],
      'knownConsumers': <String>['claude'],
      'baseline': <Object?>[],
      'origin': <String, Object?>{'status': 'unknown'},
      'lifecycle': 'live',
      'backupIds': <String>[],
      'transactionId': null,
    });
    expect(record.kind, ArtifactKind.skillCopy);
    expect(record.installationId, 'ins_0123456789abcdef0123456789abcdef');
  });

  test('a tracked Pi template record uses the native artifact kind', () {
    final record = InstallationRecord.fromJson(<String, Object?>{
      'installationId': 'ins_fedcba9876543210fedcba9876543210',
      'artifactKind': 'prompt-template',
      'scope': 'project',
      'nativeDestination': 'pi',
      'nativeForm': 'pi-prompt-template',
      'location': '/work/project/.pi/prompts/demo.md',
      'nativeRoot': '/work/project/.pi/prompts',
      'name': 'demo',
      'nativeProfile': 'pi',
      'validatedProfiles': <String>['pi'],
      'knownConsumers': <String>['pi'],
      'baseline': <Object?>[],
      'origin': <String, Object?>{'status': 'unknown'},
      'lifecycle': 'live',
      'backupIds': <String>[],
      'transactionId': null,
    });
    expect(record.kind, ArtifactKind.promptTemplate);
    expect(record.kind.wireName, 'prompt-template');
  });
}
