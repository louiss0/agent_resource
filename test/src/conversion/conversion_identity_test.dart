import 'package:agent_resource/src/conversion/conversion_evidence.dart';
import 'package:agent_resource/src/conversion/conversion_identity.dart';
import 'package:test/test.dart';

void main() {
  group('ConversionIdentityTransition', () {
    ConversionOwnership managedOwnership({
      required String location,
      String installationId = 'ins_0123456789abcdef0123456789abcdef',
      String nativeForm = 'claude-skill',
    }) => ConversionOwnership(
      managed: true,
      installationId: installationId,
      nativeForm: nativeForm,
      location: location,
      scope: 'project',
      nativeRoot: location.substring(0, location.lastIndexOf('/')),
      provenance: const <String, Object?>{'origin': 'pack'},
    );

    ConversionOwnership receiptOwnership({
      required String location,
      String receiptId = 'rcp_0123456789abcdef0123456789abcdef',
    }) => ConversionOwnership(
      managed: false,
      receiptId: receiptId,
      nativeForm: 'claude-skill',
      location: location,
      scope: 'project',
      nativeRoot: location.substring(0, location.lastIndexOf('/')),
      provenance: const <String, Object?>{'origin': 'authoring'},
    );

    ConversionParticipant participant({
      required ConversionParticipantRole role,
      required String location,
      String nativeForm = 'claude-skill',
      ConversionOwnership? ownershipBefore,
      ConversionOwnership? ownershipAfter,
      ConversionMembership? membershipBefore,
      String artifactKind = 'skill-copy',
    }) => ConversionParticipant(
      role: role,
      intent: role == ConversionParticipantRole.source
          ? ConversionParticipantIntent.retired
          : ConversionParticipantIntent.created,
      artifactKind: artifactKind,
      nativeForm: nativeForm,
      nativeProfile: 'claude',
      location: location,
      nativeRoot: location.substring(0, location.lastIndexOf('/')),
      scope: 'project',
      ownershipBefore: ownershipBefore,
      ownershipAfter: ownershipAfter,
      membershipBefore: membershipBefore,
    );

    test('the same location and form keep the installation identity', () {
      const location = '/work/project/.claude/skills/demo';
      final decision = ConversionIdentityTransition.decide(
        source: participant(
          role: ConversionParticipantRole.source,
          location: location,
          ownershipBefore: managedOwnership(location: location),
        ),
        target: participant(
          role: ConversionParticipantRole.target,
          location: location,
          ownershipAfter: managedOwnership(location: location),
        ),
      );
      expect(decision.allowed, isTrue);
      expect(decision.retainsIdentity, isTrue);
      expect(decision.allocatesTargetId, isFalse);
      expect(decision.retiresSource, isFalse);
      expect(decision.adoptsSource, isFalse);
      expect(decision.membershipTransition, 'unchanged');
    });

    test('a relocated target receives a new linked identity', () {
      const source = '/work/project/.claude/skills/demo';
      const target = '/work/project/.codex/skills/demo';
      final decision = ConversionIdentityTransition.decide(
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
      );
      expect(decision.retainsIdentity, isFalse);
      expect(decision.allocatesTargetId, isTrue);
      expect(decision.retiresSource, isTrue);
      expect(decision.membershipTransition, 'detached');
      final identity = ConversionIdentityTransition.targetIdentity(
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
        decision: decision,
        allocatedInstallationId: 'ins_fedcba9876543210fedcba9876543210',
      );
      expect(identity.installationId, 'ins_fedcba9876543210fedcba9876543210');
      expect(identity.convertedFromId, 'ins_0123456789abcdef0123456789abcdef');
      expect(identity.predecessorId, isNotNull);
    });

    test('a changed native form receives a new linked identity', () {
      const location = '/work/project/.claude/skills/demo';
      final decision = ConversionIdentityTransition.decide(
        source: participant(
          role: ConversionParticipantRole.source,
          location: location,
          nativeForm: 'claude-skill',
          ownershipBefore: managedOwnership(location: location),
        ),
        target: participant(
          role: ConversionParticipantRole.target,
          location: location,
          nativeForm: 'codex-skill',
          ownershipAfter: managedOwnership(
            location: location,
            nativeForm: 'codex-skill',
          ),
        ),
      );
      expect(decision.allocatesTargetId, isTrue);
      expect(decision.retainsIdentity, isFalse);
    });

    test('an unmanaged source is never adopted', () {
      const location = '/work/project/source/demo';
      final decision = ConversionIdentityTransition.decide(
        source: participant(
          role: ConversionParticipantRole.source,
          location: location,
          ownershipBefore: receiptOwnership(location: location),
        ),
        target: participant(
          role: ConversionParticipantRole.target,
          location: location,
          ownershipAfter: receiptOwnership(location: location),
        ),
      );
      expect(decision.allowed, isTrue);
      expect(decision.adoptsSource, isFalse);
      expect(decision.allocatesTargetId, isFalse);
      expect(decision.retiresSource, isFalse);
    });

    test('a managed target for an unmanaged source is refused', () {
      const location = '/work/project/source/demo';
      final decision = ConversionIdentityTransition.decide(
        source: participant(
          role: ConversionParticipantRole.source,
          location: location,
          ownershipBefore: receiptOwnership(location: location),
        ),
        target: participant(
          role: ConversionParticipantRole.target,
          location: location,
          ownershipAfter: managedOwnership(location: location),
        ),
      );
      expect(decision.allowed, isFalse);
      expect(decision.refusal, contains('cannot become a managed'));
    });

    test('a derived target detaches the upstream membership', () {
      const source = '/work/project/.claude/skills/demo';
      const target = '/work/project/.codex/skills/demo';
      final sourceParticipant = participant(
        role: ConversionParticipantRole.source,
        location: source,
        ownershipBefore: managedOwnership(location: source),
        membershipBefore: const ConversionMembership(
          kind: 'pack',
          state: 'active',
          memberId: 'mem_1',
          source: 'pack_1',
        ),
      );
      final decision = ConversionIdentityTransition.decide(
        source: sourceParticipant,
        target: participant(
          role: ConversionParticipantRole.target,
          location: target,
          ownershipAfter: managedOwnership(location: target),
        ),
      );
      final membership = ConversionIdentityTransition.targetMembership(
        source: sourceParticipant,
        decision: decision,
      );
      expect(membership?.state, 'detached');
      expect(membership?.memberId, 'mem_1');
    });
  });
}
