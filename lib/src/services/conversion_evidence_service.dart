import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../conversion/conversion_evidence.dart';
import '../conversion/conversion_identity.dart';

/// The directory that holds the conversion evidence of one state root.
const String conversionEvidenceDirectoryName = 'conversions';

/// Prepares, validates and reads the conversion evidence of a transaction.
///
/// The slice implements the evidence contract only. It publishes nothing,
/// mutates no installation record and starts no coordinator.
interface class ConversionEvidenceService {
  ConversionEvidenceService({this.fileSystem = const local.LocalFileSystem()});

  /// The filesystem the evidence is read from.
  final fslib.FileSystem fileSystem;

  /// The directory that holds the conversion evidence of [stateRoot].
  String evidenceDirectory(String stateRoot) =>
      fileSystem.path.join(stateRoot, conversionEvidenceDirectoryName);

  /// The path of the evidence document of one transaction.
  String evidencePath(String stateRoot, String transactionId) {
    if (!RegExp(r'^cvx_[a-f0-9]{32}$').hasMatch(transactionId)) {
      throw MambaException('Invalid conversion transaction ID.', exitCode: 4);
    }
    return fileSystem.path.join(
      evidenceDirectory(stateRoot),
      '$transactionId.json',
    );
  }

  /// A new conversion transaction identifier.
  String newTransactionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return 'cvx_${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
  }

  /// The identity effect between the intended participants.
  ConversionIdentityDecision decideIdentity({
    required ConversionParticipant source,
    required ConversionParticipant target,
  }) => ConversionIdentityTransition.decide(source: source, target: target);

  /// Prepares the validated evidence of one conversion.
  ///
  /// The identity transition is resolved here: the target identity, the
  /// ownership after, the membership transition and the retired source are
  /// recorded before anything is published.
  ConversionEvidence prepare({
    required String transactionId,
    required ConversionParticipant source,
    required ConversionParticipant target,
    String? allocatedInstallationId,
    String? receiptId,
    String? lineageId,
    ConversionEvidencePhase phase = ConversionEvidencePhase.prepared,
    Map<String, bool> approvals = const <String, bool>{},
    Map<String, Object?> observations = const <String, Object?>{},
  }) {
    if (!RegExp(r'^cvx_[a-f0-9]{32}$').hasMatch(transactionId)) {
      throw MambaException('Invalid conversion transaction ID.', exitCode: 4);
    }
    final decision = decideIdentity(source: source, target: target);
    if (!decision.allowed) {
      throw MambaException(decision.refusal!, exitCode: 4);
    }
    try {
      source.validate();
      target.validate();
    } on FormatException catch (error) {
      throw MambaException(
        'The conversion participant is not usable: ${error.message}',
        exitCode: 4,
      );
    }
    final targetIdentity = ConversionIdentityTransition.targetIdentity(
      source: source,
      target: target,
      decision: decision,
      allocatedInstallationId: allocatedInstallationId,
      receiptId: receiptId,
      lineageId: lineageId,
    );
    final targetMembership = ConversionIdentityTransition.targetMembership(
      source: source,
      decision: decision,
    );
    final resolvedTarget = target.copyWith(
      identity: targetIdentity,
      membershipAfter: targetMembership,
      ownershipAfter: _ownershipAfter(target, targetIdentity),
    );
    final resolvedSource = source.copyWith(
      intent: decision.retiresSource
          ? ConversionParticipantIntent.retired
          : source.intent,
      membershipAfter: decision.retiresSource
          ? _retiredMembership(source.membershipBefore)
          : source.membershipAfter,
    );
    final evidence = ConversionEvidence(
      transactionId: transactionId,
      operation: 'convert',
      phase: phase,
      createdScope: target.scope,
      source: resolvedSource,
      target: resolvedTarget,
      approvals: Map<String, bool>.unmodifiable(approvals),
      observations: Map<String, Object?>.unmodifiable(observations),
    );
    _verifyRoundTrip(evidence);
    return evidence;
  }

  /// Reads the persisted evidence of one transaction.
  ///
  /// The read is bounded and fail closed. A missing document is null; a
  /// corrupt, truncated or unknown document is an operational failure, never
  /// evidence of a free state.
  Future<ConversionEvidence?> readPersisted(
    String stateRoot,
    String transactionId,
  ) async {
    final path = evidencePath(stateRoot, transactionId);
    final type = fileSystem.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The conversion evidence path is not a regular file: $path',
        exitCode: 3,
      );
    }
    final bytes = fileSystem.file(path).readAsBytesSync();
    if (bytes.length > maxConversionEvidenceBytes) {
      throw MambaException(
        'The conversion evidence document exceeds its byte limit.',
        exitCode: 3,
      );
    }
    final String encoded;
    try {
      encoded = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw MambaException(
        'The conversion evidence document is not valid UTF-8.',
        exitCode: 3,
      );
    }
    try {
      return ConversionEvidence.decode(encoded);
    } on FormatException catch (error) {
      throw MambaException(
        'The conversion evidence document is not usable: ${error.message}',
        exitCode: 3,
      );
    }
  }

  void _verifyRoundTrip(ConversionEvidence evidence) {
    final ConversionEvidence decoded;
    try {
      decoded = ConversionEvidence.decode(evidence.encode());
    } on FormatException catch (error) {
      throw MambaException(
        'The prepared conversion evidence is not usable: ${error.message}',
        exitCode: 4,
      );
    }
    if (decoded.digest != evidence.digest) {
      throw MambaException(
        'The prepared conversion evidence does not bind.',
        exitCode: 4,
      );
    }
  }

  ConversionOwnership? _ownershipAfter(
    ConversionParticipant target,
    ConversionIdentity identity,
  ) {
    final after = target.ownershipAfter;
    if (after == null) return null;
    if (!after.managed) {
      return ConversionOwnership(
        managed: false,
        receiptId: identity.receiptId ?? after.receiptId,
        nativeForm: after.nativeForm,
        nativeProfile: after.nativeProfile,
        nativeDestination: after.nativeDestination,
        location: after.location,
        nativeRoot: after.nativeRoot,
        scope: after.scope,
        baselineDigest: after.baselineDigest,
        provenance: after.provenance,
      );
    }
    return ConversionOwnership(
      managed: true,
      installationId: identity.installationId ?? after.installationId,
      nativeForm: after.nativeForm,
      nativeProfile: after.nativeProfile,
      nativeDestination: after.nativeDestination,
      location: after.location,
      nativeRoot: after.nativeRoot,
      scope: after.scope,
      baselineDigest: after.baselineDigest,
      provenance: after.provenance,
    );
  }

  ConversionMembership? _retiredMembership(ConversionMembership? before) {
    if (before == null) return null;
    return ConversionMembership(
      kind: before.kind,
      state: 'retired',
      memberId: before.memberId,
      source: before.source,
    );
  }
}
