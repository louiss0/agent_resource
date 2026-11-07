import 'conversion_evidence.dart';

/// The identity effect of one conversion.
///
/// The decision never adopts an unmanaged source and never reuses an
/// installation identifier for a relocated or reclassified target.
final class ConversionIdentityDecision {
  const ConversionIdentityDecision({
    required this.retainsIdentity,
    required this.allocatesTargetId,
    required this.retiresSource,
    required this.adoptsSource,
    required this.membershipTransition,
    this.refusal,
  });

  /// The target keeps the installation identifier of the source.
  final bool retainsIdentity;

  /// The target receives a new linked installation identifier.
  final bool allocatesTargetId;

  /// The source participant is retired by the conversion.
  final bool retiresSource;

  /// Whether the conversion adopts the source as a managed installation.
  ///
  /// An authoring receipt never adopts a source or an output.
  final bool adoptsSource;

  /// The upstream membership transition of the derived target.
  ///
  /// A derived target keeps its provenance but does not inherit the automatic
  /// upstream tracking of its source.
  final String membershipTransition;

  /// The reason the conversion is refused, when it is.
  final String? refusal;

  /// Whether the conversion may proceed.
  bool get allowed => refusal == null;
}

/// The identity rules of a conversion.
///
/// The same location and native form keep the installation identity. A
/// relocated or reclassified managed target receives a new linked identifier
/// and the source is retired. An unmanaged source produces an unmanaged
/// target: a receipt is evidence of authoring, not ongoing ownership.
final class ConversionIdentityTransition {
  const ConversionIdentityTransition._();

  /// Decides the identity effect between the intended participants.
  static ConversionIdentityDecision decide({
    required ConversionParticipant source,
    required ConversionParticipant target,
  }) {
    final sourceOwnership = source.ownershipBefore ?? source.ownershipAfter;
    final targetOwnership = target.ownershipAfter ?? target.ownershipBefore;
    final sourceManaged = sourceOwnership?.managed == true;
    final targetManaged = targetOwnership?.managed == true;

    if (!sourceManaged) {
      if (targetManaged) {
        return const ConversionIdentityDecision(
          retainsIdentity: false,
          allocatesTargetId: false,
          retiresSource: false,
          adoptsSource: false,
          membershipTransition: 'unchanged',
          refusal:
              'An unmanaged authoring source cannot become a managed '
              'installation.',
        );
      }
      return const ConversionIdentityDecision(
        retainsIdentity: false,
        allocatesTargetId: false,
        retiresSource: false,
        adoptsSource: false,
        membershipTransition: 'unchanged',
      );
    }

    final sameLocation = source.location == target.location;
    final sameForm =
        source.nativeForm != null && source.nativeForm == target.nativeForm;
    if (sameLocation && sameForm) {
      return const ConversionIdentityDecision(
        retainsIdentity: true,
        allocatesTargetId: false,
        retiresSource: false,
        adoptsSource: false,
        membershipTransition: 'unchanged',
      );
    }
    return const ConversionIdentityDecision(
      retainsIdentity: false,
      allocatesTargetId: true,
      retiresSource: true,
      adoptsSource: false,
      membershipTransition: 'detached',
    );
  }

  /// The identity that the target participant carries after the decision.
  ///
  /// A retained identity keeps the installation identifier of the source. An
  /// allocated identity links the new identifier to the retired source.
  static ConversionIdentity targetIdentity({
    required ConversionParticipant source,
    required ConversionParticipant target,
    required ConversionIdentityDecision decision,
    String? allocatedInstallationId,
    String? receiptId,
    String? lineageId,
  }) {
    final sourceOwnership = source.ownershipBefore ?? source.ownershipAfter;
    final sourceId = sourceOwnership?.installationId;
    if (decision.allocatesTargetId) {
      if (allocatedInstallationId == null) {
        throw StateError('A relocated target requires a new installation ID.');
      }
      return ConversionIdentity(
        installationId: allocatedInstallationId,
        receiptId: receiptId,
        lineageId: lineageId,
        predecessorId: sourceId,
        convertedFromId: sourceId,
      );
    }
    if (decision.retainsIdentity) {
      return ConversionIdentity(
        installationId: sourceId,
        receiptId: receiptId,
        lineageId: lineageId,
        convertedFromId: sourceId,
      );
    }
    return ConversionIdentity(
      receiptId: receiptId,
      lineageId: lineageId,
      convertedFromId: sourceId,
    );
  }

  /// The membership observation of the derived target.
  ///
  /// The upstream tracking of the source is detached: a derived target keeps
  /// its provenance, and the source updates must not resurrect it implicitly.
  static ConversionMembership? targetMembership({
    required ConversionParticipant source,
    required ConversionIdentityDecision decision,
    String kind = 'pack',
    String? memberId,
    String? membershipSource,
  }) {
    final before = source.membershipBefore;
    if (before == null) return null;
    return ConversionMembership(
      kind: kind,
      state: decision.membershipTransition == 'detached'
          ? 'detached'
          : before.state,
      memberId: memberId ?? before.memberId,
      source: membershipSource ?? before.source,
    );
  }
}
