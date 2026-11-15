import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';

import '../authoring/authoring_receipt.dart';
import '../authoring/authoring_transaction.dart';
import '../conversion/conversion_evidence.dart';
import '../conversion/conversion_restore_evidence.dart';
import '../skill_files.dart';
import 'conversion_coordinator_service.dart';
import 'conversion_evidence_service.dart';
import 'lifecycle_state_service.dart';

/// The reviewed plan of one completed-conversion inverse restore.
final class ConversionRestorePlan {
  const ConversionRestorePlan({required this.evidence, required this.data});

  /// The durable evidence of the inverse restore.
  final ConversionRestoreEvidence evidence;

  /// The review data that carries the exact plan identity.
  final Map<String, Object?> data;
}

/// The inverse restore of one completed native conversion.
///
/// The restore is a fresh inverse transaction. It reinstates the original
/// source from the retained independent payload and the original ownership
/// identity, retires the converted target and preserves the outgoing target
/// as evidence. It is neither an unrestricted rollback of the original
/// transaction nor the ordinary managed-only backup restore.
///
/// Every live effect requires a fresh reviewed plan and explicit approval.
/// The restore refuses a changed source, a changed target, a new occupant, a
/// changed membership, a missing authority and corrupt or missing evidence.
final class ConversionRestoreService {
  ConversionRestoreService({
    required LifecycleIO io,
    required LifecycleStateService state,
    ConversionEvidenceService? evidence,
  }) : _io = io,
       _state = state,
       _evidence = evidence ?? ConversionEvidenceService(fileSystem: io.fs);

  final LifecycleIO _io;
  final LifecycleStateService _state;
  final ConversionEvidenceService _evidence;

  /// Reviews and, with explicit approval, applies the inverse restore of one
  /// completed conversion.
  ///
  /// A dry run writes nothing and returns the exact plan identity. An apply
  /// requires `--apply`, `--yes` and the exact fresh `--plan-id` of a review.
  Future<LifecycleResult> restoreReviewed(
    LifecycleOptions options,
    String transactionId, {
    String? planId,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _io.fs);
    Future<LifecycleResult> run() async {
      if (isAuthoringTransactionId(transactionId)) {
        return _restoreAuthoring(context, transactionId, planId);
      }
      final original = await _readOriginal(context, transactionId);
      final plan = await _plan(context, original, transactionId);
      if (context.dryRun) {
        return LifecycleResult(
          command: 'prompt conversion restore',
          outcome: 'planned',
          data: plan.data,
        );
      }
      _requireApproval(context, planId, plan.data['planId']);
      _requireNoPendingConflict(context, original, plan);
      final result = await _apply(context, original, plan);
      return LifecycleResult(
        command: 'prompt conversion restore',
        outcome: 'restored',
        data: <String, Object?>{...plan.data, ...result},
      );
    }

    if (context.dryRun) return run();
    return _state.runCoordinated(
      context: context,
      location: context.stateRoot(),
      body: run,
    );
  }

  void _requireApproval(
    LifecycleContext context,
    String? supplied,
    Object? current,
  ) {
    if (!context.approved || supplied == null || supplied != current) {
      throw MambaException(
        'Apply requires explicit approval and the exact fresh --plan-id.',
        exitCode: 4,
      );
    }
  }

  /// Refuses an inverse restore that conflicts with other pending work.
  ///
  /// The inverse restore owns its source, its target and the identities of
  /// both participants. A pending conversion, participant reference, ordinary
  /// transaction, authoring transaction or inverse restore of any scope keeps
  /// those reservations; the restore never overwrites other pending work.
  void _requireNoPendingConflict(
    LifecycleContext context,
    ConversionEvidence original,
    ConversionRestorePlan plan,
  ) {
    final evidence = plan.evidence;
    final locations = <String>[
      evidence.sourceLocation,
      evidence.targetLocation,
    ];
    final own = _ownEvidencePaths(context, evidence);
    _state.checkPendingConversions(
      context,
      locations: locations,
      installationIds: <String>{
        if (evidence.sourceInstallationId != null)
          evidence.sourceInstallationId!,
        if (evidence.targetInstallationId != null)
          evidence.targetInstallationId!,
      },
      validatedRecoveryPaths: own,
    );
    _state.checkPendingMutations(
      context,
      locations: locations,
      validatedPaths: own,
    );
  }

  /// The inverse restore evidence documents of this restore.
  Set<String> _ownEvidencePaths(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) => <String>{
    _io.fs.path.join(_restoreRoot(context), '${evidence.restoreId}.json'),
    if (_peerRoot(context, evidence) case final root?)
      _io.fs.path.join(_restoreRootOf(root), '${evidence.restoreId}.json'),
  };

  /// Verifies the authoring receipt of an ordinary conversion.
  ///
  /// The receipt is the commit point of the ordinary publication. The inverse
  /// restore binds the exact receipt of the reviewed plan and target and
  /// refuses a missing, substituted or foreign receipt.
  void _verifyAuthoringReceipt(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) {
    final receiptId = transaction.receiptId;
    if (receiptId == null || receiptId.isEmpty) {
      throw MambaException(
        'The ordinary conversion recorded no authoring receipt; the commit '
        'point of the publication is missing.',
        exitCode: 6,
      );
    }
    if (receiptId !=
        authoringReceiptId(transaction.planId, transaction.target)) {
      throw MambaException(
        'The authoring receipt does not bind the reviewed plan and target.',
        exitCode: 6,
      );
    }
    final path = _io.fs.path.join(
      context.stateRoot(),
      authoringReceiptDirectoryName,
      '$receiptId.json',
    );
    _requireUnlinked(path);
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException(
        'The authoring receipt of the ordinary conversion is missing; the '
        'commit point of the publication is missing.',
        exitCode: 6,
      );
    }
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The authoring receipt of the ordinary conversion is not a file.',
        exitCode: 6,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(_io.read(path, 1024 * 1024)));
    } on FormatException catch (error) {
      throw MambaException(
        'The authoring receipt of the ordinary conversion is corrupt: '
        '${error.message}',
        exitCode: 6,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw MambaException(
        'The authoring receipt of the ordinary conversion is not an object.',
        exitCode: 6,
      );
    }
    if (decoded['schemaVersion'] != 1 ||
        decoded['receiptId'] != receiptId ||
        decoded['planId'] != transaction.planId ||
        decoded['operation'] != transaction.operation ||
        decoded['target'] != transaction.target ||
        decoded['ownership'] != 'authorOnly' ||
        decoded['derivedFrom'] != transaction.source ||
        decoded['sourceInstallationId'] != null) {
      throw MambaException(
        'The authoring receipt does not bind the ordinary conversion.',
        exitCode: 6,
      );
    }
  }

  /// The recorded peer authority of an ordinary conversion.
  ///
  /// The peer realm is the recorded host authority that does not coordinate
  /// the publication. An unconfigured realm has no recorded root and is never
  /// invented.
  ({String? scope, String? root}) _recordedPeer(
    AuthoringTransaction transaction,
  ) {
    final authority = transaction.authority;
    final scope = authority['scope'];
    if (scope == 'project') {
      final userRoot = authority['userStateRoot'];
      if (userRoot is String && userRoot.isNotEmpty) {
        return (scope: 'user', root: userRoot);
      }
      return (scope: null, root: null);
    }
    if (scope == 'user') {
      final projectRoot = authority['projectRoot'];
      if (projectRoot is String && projectRoot.isNotEmpty) {
        return (
          scope: 'project',
          root: _io.fs.path.join(projectRoot, '.agent-resource'),
        );
      }
      return (scope: null, root: null);
    }
    return (scope: null, root: null);
  }

  /// Restores an ordinary completed conversion of the ordinary publisher.
  ///
  /// The ordinary publisher does not write conversion evidence: it retains
  /// the independent payload of the source, publishes the native target and
  /// records an authoring transaction, a receipt and the retained payload.
  /// That durable authority is the authority of the inverse restore. The
  /// restore reinstates the original source, retires the converted target and
  /// never adopts the source as an installation.
  Future<LifecycleResult> _restoreAuthoring(
    LifecycleContext context,
    String transactionId,
    String? planId,
  ) async {
    Future<LifecycleResult> run() async {
      final subject = _readAuthoringSubject(context, transactionId);
      final plan = await _planAuthoring(context, subject);
      if (context.dryRun) {
        return LifecycleResult(
          command: 'prompt conversion restore',
          outcome: 'planned',
          data: plan.data,
        );
      }
      _requireApproval(context, planId, plan.data['planId']);
      _requireNoPendingAuthoringConflict(context, subject, plan);
      final result = await _applyAuthoring(context, subject, plan);
      return LifecycleResult(
        command: 'prompt conversion restore',
        outcome: 'restored',
        data: <String, Object?>{...plan.data, ...result},
      );
    }

    if (context.dryRun) return run();
    return _state.runCoordinated(
      context: context,
      location: context.stateRoot(),
      body: run,
    );
  }

  /// Reads the durable authority of one ordinary completed conversion.
  _AuthoringSubject _readAuthoringSubject(
    LifecycleContext context,
    String transactionId,
  ) {
    final path = _io.fs.path.join(
      context.stateRoot(),
      authoringTransactionDirectoryName,
      '$transactionId.json',
    );
    _requireUnlinked(path);
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException(
        'No authoring evidence exists for $transactionId.',
        exitCode: 4,
      );
    }
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The authoring transaction path is not a regular file: $path',
        exitCode: 6,
      );
    }
    final AuthoringTransactionDocument document;
    try {
      document = decodeAuthoringTransactionDocument(
        utf8.decode(_io.read(path, maxAuthoringTransactionBytes)),
      );
    } on FormatException catch (error) {
      throw MambaException(
        'The authoring transaction document is not usable: ${error.message}',
        exitCode: 6,
      );
    }
    if (document is! CurrentAuthoringTransactionDocument) {
      throw MambaException(
        'The authoring transaction document is not actionable.',
        exitCode: 6,
      );
    }
    final transaction = document.transaction;
    if (transaction.transactionId != transactionId) {
      throw MambaException(
        'The authoring transaction document does not carry its own identity.',
        exitCode: 6,
      );
    }
    if (transaction.operation != 'convert') {
      throw MambaException(
        'The authoring transaction is not a conversion.',
        exitCode: 4,
      );
    }
    if (transaction.ownership != 'authorOnly') {
      throw MambaException(
        'A tracked conversion is restored from its conversion evidence.',
        exitCode: 4,
      );
    }
    if (transaction.phase != AuthoringTransactionPhase.completed) {
      throw MambaException(
        'Only a completed ordinary conversion can be restored.',
        exitCode: 4,
      );
    }
    final source = transaction.source;
    final recovery = transaction.recoveryPath;
    if (source == null || recovery == null) {
      throw MambaException(
        'The ordinary conversion retained no independent source payload.',
        exitCode: 6,
      );
    }
    final authority = transaction.authority;
    if (authority['scope'] != context.scope.name) {
      throw MambaException(
        'The ordinary conversion belongs to another scope.',
        exitCode: 4,
      );
    }
    final recordedRoot = authority['stateRoot'];
    if (recordedRoot is String &&
        !_io.fs.path.equals(recordedRoot, context.stateRoot())) {
      throw MambaException(
        'The recorded authority of the ordinary conversion changed.',
        exitCode: 6,
      );
    }
    _verifyAuthoringReceipt(context, transaction);
    final recordedPayload = transaction.evidence['payloadManifest'];
    final recordedTarget = transaction.evidence['publishedManifest'];
    if (recordedPayload is! List || recordedTarget is! List) {
      throw MambaException(
        'The ordinary conversion retained no content evidence.',
        exitCode: 6,
      );
    }
    final payloadEntries = recordedPayload.cast<Map<String, Object?>>();
    final targetEntries = recordedTarget.cast<Map<String, Object?>>();
    return _AuthoringSubject(
      transaction: transaction,
      sourceLocation: source,
      targetLocation: transaction.target,
      payloadPath: recovery,
      payloadEntries: payloadEntries,
      targetEntries: targetEntries,
      payloadIsFile:
          payloadEntries.length == 1 &&
          payloadEntries.single['path'] == 'source',
      inPlace: _io.fs.path.equals(source, transaction.target),
    );
  }

  /// Reviews the exact current observations of an ordinary conversion.
  Future<ConversionRestorePlan> _planAuthoring(
    LifecycleContext context,
    _AuthoringSubject subject,
  ) async {
    final restoreRoot = _restoreRoot(context);
    final retained = _readRetainedRestores(
      restoreRoot,
      subject.transaction.transactionId,
    );
    if (retained.any(
      (evidence) => evidence.phase == ConversionRestorePhase.completed,
    )) {
      throw MambaException(
        'The completed conversion was already restored.',
        exitCode: 4,
      );
    }
    final resumable = retained
        .where((evidence) => !evidence.completed)
        .toList(growable: false);
    if (resumable.length > 1) {
      throw MambaException(
        'More than one inverse restore is pending for this conversion.',
        exitCode: 6,
      );
    }
    if (resumable.isNotEmpty) {
      return _resumePlanAuthoring(context, subject, resumable.single);
    }
    return _freshPlanAuthoring(context, subject, restoreRoot);
  }

  /// Reviews the resume of an interrupted ordinary inverse restore.
  Future<ConversionRestorePlan> _resumePlanAuthoring(
    LifecycleContext context,
    _AuthoringSubject subject,
    ConversionRestoreEvidence evidence,
  ) async {
    // The original source location must still be free or reviewed. A new
    // occupant is refused; the resume never merges over it.
    _requireFreeOriginalSource(subject);
    final staging = _stagingPath(context, evidence.restoreId);
    final restored = _restoredPath(evidence, staging);
    if (_io.type(restored, followLinks: false) !=
            FileSystemEntityType.notFound &&
        !_sameAuthoringContent(
          subject.payloadEntries,
          _authoringEntries(restored),
        )) {
      throw MambaException(
        'The staged inverse restore payload changed.',
        exitCode: 6,
      );
    }
    final observations = await _authoringObservations(context, subject);
    final data = <String, Object?>{
      'transactionId': subject.transaction.transactionId,
      'restoreId': evidence.restoreId,
      'action': 'restore',
      'scope': context.scope.name,
      'phase': 'completed',
      'restorePhase': evidence.phase.name,
      'resume': true,
      'source': subject.sourceLocation,
      'target': subject.targetLocation,
      'inPlace': subject.inPlace,
      'sourceManaged': false,
      'observations': observations,
    };
    data['planId'] = _reviewDigest(data);
    return ConversionRestorePlan(evidence: evidence, data: data);
  }

  /// Reviews a fresh inverse restore of an ordinary conversion.
  Future<ConversionRestorePlan> _freshPlanAuthoring(
    LifecycleContext context,
    _AuthoringSubject subject,
    String restoreRoot,
  ) async {
    // The retained payload is the only authority of the original content.
    if (_io.type(subject.payloadPath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      throw MambaException(
        'The retained recovery payload was cleaned; the completed conversion '
        'can no longer be restored.',
        exitCode: 6,
      );
    }
    if (!_sameAuthoringContent(
      subject.payloadEntries,
      _authoringEntries(subject.payloadPath),
    )) {
      throw MambaException(
        'The retained recovery payload is missing or changed.',
        exitCode: 6,
      );
    }
    // The published target must still be the published target.
    if (_io.type(subject.targetLocation, followLinks: false) ==
        FileSystemEntityType.notFound) {
      throw MambaException(
        'The converted target is missing; the restore is refused.',
        exitCode: 6,
      );
    }
    if (!_sameAuthoringContent(
      subject.targetEntries,
      _authoringEntries(subject.targetLocation),
    )) {
      throw MambaException(
        'The converted target changed since the conversion; the restore is '
        'refused.',
        exitCode: 6,
      );
    }
    // The original source location must be free unless the conversion
    // replaced the source in place.
    _requireFreeOriginalSource(subject);
    final attempt = _restoreAttempt(
      restoreRoot,
      subject.transaction.transactionId,
    );
    final peer = _recordedPeer(subject.transaction);
    final evidence = ConversionRestoreEvidence(
      restoreId: _restoreId(subject.transaction.transactionId, attempt),
      transactionId: subject.transaction.transactionId,
      phase: ConversionRestorePhase.prepared,
      createdScope: context.scope.name,
      sourceLocation: subject.sourceLocation,
      targetLocation: subject.targetLocation,
      artifactKind: subject.transaction.kind,
      subjectKind: 'authoring',
      sourceScope: context.scope.name,
      targetScope: context.scope.name,
      peerScope: peer.scope,
      peerStateRoot: peer.root,
      inPlace: subject.inPlace,
      payloadPath: subject.payloadPath,
      payloadDigest: _authoringDigest(subject.payloadEntries),
      outgoingDigest: _authoringDigest(subject.targetEntries),
      observations: const <String, Object?>{},
      sourceManaged: false,
      approvals: const <String, bool>{'authoringRestore': true},
    );
    final observations = await _authoringObservations(context, subject);
    final current = evidence.copyWith(observations: observations);
    final data = <String, Object?>{
      'transactionId': subject.transaction.transactionId,
      'restoreId': current.restoreId,
      'action': 'restore',
      'scope': context.scope.name,
      'phase': 'completed',
      'restorePhase': current.phase.name,
      'resume': false,
      'source': subject.sourceLocation,
      'target': subject.targetLocation,
      'inPlace': subject.inPlace,
      'sourceManaged': false,
      'observations': observations,
    };
    data['planId'] = _reviewDigest(data);
    return ConversionRestorePlan(evidence: current, data: data);
  }

  /// Requires that the original source location is free or reviewed.
  ///
  /// The location may hold nothing, the reviewed original content of an
  /// already restored source, or the published target of an in place
  /// conversion. Every other occupant is refused: the restore never merges
  /// over a foreign member and never overwrites a new occupant.
  void _requireFreeOriginalSource(_AuthoringSubject subject) {
    final location = subject.sourceLocation;
    if (_io.type(location, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final occupied = _authoringEntries(location);
    if (_sameAuthoringContent(subject.payloadEntries, occupied)) return;
    if (subject.inPlace &&
        _sameAuthoringContent(subject.targetEntries, occupied)) {
      return;
    }
    throw MambaException(
      'A new occupant appeared at the original source location; the restore '
      'is refused.',
      exitCode: 6,
    );
  }

  /// The exact current observations of an ordinary conversion.
  Future<Map<String, Object?>> _authoringObservations(
    LifecycleContext context,
    _AuthoringSubject subject,
  ) async {
    final observations = <String, Object?>{};
    for (final path in <String>{
      subject.sourceLocation,
      subject.targetLocation,
      subject.payloadPath,
    }) {
      _requireUnlinked(path);
      observations[path] =
          _io.type(path, followLinks: false) == FileSystemEntityType.notFound
          ? null
          : _manifestDigest(path);
    }
    return observations;
  }

  /// Applies the reviewed inverse restore of an ordinary conversion.
  Future<Map<String, Object?>> _applyAuthoring(
    LifecycleContext context,
    _AuthoringSubject subject,
    ConversionRestorePlan plan,
  ) async {
    final evidence = plan.evidence;
    final staging = _stagingPath(context, evidence.restoreId);
    final restored = _restoredPath(evidence, staging);
    final outgoing = _outgoingPath(evidence, staging);
    final decision = _io.fs.path.join(staging, 'commit.json');
    try {
      _requireUnlinked(staging);
      final resuming = plan.data['resume'] == true;
      if (resuming &&
          _io.type(decision, followLinks: false) ==
              FileSystemEntityType.notFound) {
        _rollbackAuthoring(context, evidence, subject);
        return <String, Object?>{
          'restorePhase': ConversionRestorePhase.rolledBack.name,
          'rolledBack': true,
        };
      }
      if (_io.type(staging, followLinks: false) ==
          FileSystemEntityType.notFound) {
        _io.createDirectory(staging);
      }
      _state.protectDirectory(staging);
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.prepared),
      );

      // Stage the retained independent payload of the original source.
      if (_io.type(restored, followLinks: false) ==
          FileSystemEntityType.notFound) {
        _copyTree(evidence.payloadPath, restored);
      }
      if (!_sameAuthoringContent(
        subject.payloadEntries,
        _authoringEntries(restored),
      )) {
        throw MambaException(
          'The staged inverse restore payload does not match the retained '
          'recovery payload.',
          exitCode: 6,
        );
      }

      // Preserve the outgoing target as evidence before it is retired.
      final decided =
          _io.type(decision, followLinks: false) == FileSystemEntityType.file;
      if (_io.type(outgoing, followLinks: false) ==
          FileSystemEntityType.notFound) {
        if (decided) {
          throw MambaException(
            'The retained outgoing target evidence is missing; the inverse '
            'restore cannot be completed.',
            exitCode: 6,
          );
        }
        if (_io.type(subject.targetLocation, followLinks: false) ==
            FileSystemEntityType.notFound) {
          throw MambaException(
            'The converted target is missing; the outgoing target evidence '
            'cannot be preserved.',
            exitCode: 6,
          );
        }
        _copyTree(subject.targetLocation, outgoing);
      }
      if (!_sameAuthoringContent(
        subject.targetEntries,
        _authoringEntries(outgoing),
      )) {
        throw MambaException(
          'The retained outgoing target evidence changed.',
          exitCode: 6,
        );
      }
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.published),
      );

      // Publish the original source at its original location.
      if (subject.inPlace) {
        _io.delete(subject.sourceLocation);
      }
      _restoreAuthoringSource(subject, restored);
      if (!_sameAuthoringContent(
        subject.payloadEntries,
        _authoringEntries(subject.sourceLocation),
      )) {
        throw MambaException(
          'The restored source does not match the retained recovery payload.',
          exitCode: 6,
        );
      }

      // Commit the inverse decision.
      _writeRestoreDecision(staging, evidence);
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.committed),
      );

      // Retire the converted target. Its content is retained as evidence.
      if (!subject.inPlace &&
          _io.type(subject.targetLocation, followLinks: false) !=
              FileSystemEntityType.notFound) {
        if (!_sameAuthoringContent(
          subject.targetEntries,
          _authoringEntries(subject.targetLocation),
        )) {
          throw MambaException(
            'The converted target changed; the restore is refused.',
            exitCode: 6,
          );
        }
        _io.delete(subject.targetLocation);
      }
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.reconciled),
      );
      final completed = evidence.copyWith(
        phase: ConversionRestorePhase.completed,
      );
      _persist(context, completed);
      return <String, Object?>{
        'restorePhase': completed.phase.name,
        'outgoingTargetEvidence': outgoing,
        'restoredSource': subject.sourceLocation,
        'retiredTarget': subject.targetLocation,
        'receiptId': subject.transaction.receiptId,
      };
    } on MambaException catch (error) {
      _markRecoveryRequired(context, evidence);
      throw error;
    } catch (error) {
      _markRecoveryRequired(context, evidence);
      throw MambaException(
        'The inverse restore needs recovery: $error',
        exitCode: 6,
      );
    }
  }

  /// Restores the original source of an ordinary conversion.
  void _restoreAuthoringSource(_AuthoringSubject subject, String restored) {
    final location = subject.sourceLocation;
    final type = _io.type(location, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      final occupied = _authoringEntries(location);
      final matchesOriginal = _sameAuthoringContent(
        subject.payloadEntries,
        occupied,
      );
      final matchesPublished =
          subject.inPlace &&
          _sameAuthoringContent(subject.targetEntries, occupied);
      if (matchesOriginal) return;
      if (!matchesPublished) {
        throw MambaException(
          'A new occupant appeared at the original source location; the '
          'restore is refused.',
          exitCode: 6,
        );
      }
      // The published target occupies the original location of an in place
      // conversion. It is replaced by the reviewed original.
      _io.delete(location);
    }
    if (subject.payloadIsFile) {
      _io.createDirectory(_io.fs.path.dirname(location));
      _io.copyFile(_io.fs.path.join(restored, 'source'), location);
      return;
    }
    _copyTree(restored, location);
  }

  /// Rolls an interrupted ordinary inverse restore back.
  void _rollbackAuthoring(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
    _AuthoringSubject subject,
  ) {
    final staging = _stagingPath(context, evidence.restoreId);
    final outgoing = _outgoingPath(evidence, staging);
    if (subject.inPlace) {
      if (_io.type(outgoing, followLinks: false) ==
          FileSystemEntityType.notFound) {
        throw MambaException(
          'The retained outgoing target evidence is missing; the inverse '
          'restore cannot be rolled back safely.',
          exitCode: 6,
        );
      }
      if (_io.type(subject.sourceLocation, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _io.delete(subject.sourceLocation);
      }
      _copyTree(outgoing, subject.sourceLocation);
    } else if (_io.type(subject.sourceLocation, followLinks: false) !=
            FileSystemEntityType.notFound &&
        _sameAuthoringContent(
          subject.payloadEntries,
          _authoringEntries(subject.sourceLocation),
        )) {
      _io.delete(subject.sourceLocation);
    }
    _persist(
      context,
      evidence.copyWith(phase: ConversionRestorePhase.rolledBack),
    );
  }

  /// The content evidence of one location, bound like the publisher binds it.
  List<Map<String, Object?>> _authoringEntries(String path) =>
      authoringContentEvidence(_io.fs, path);

  /// Whether two content manifests describe the same content.
  ///
  /// The retained payload of a single file source holds the marker under its
  /// own name, while the restored source carries the original name. The
  /// content itself must still be identical.
  bool _sameAuthoringContent(
    List<Map<String, Object?>> recorded,
    List<Map<String, Object?>> current,
  ) {
    if (recorded.length == 1 &&
        current.length == 1 &&
        recorded.single['path'] == 'source') {
      return recorded.single['sha256'] == current.single['sha256'] &&
          recorded.single['length'] == current.single['length'] &&
          recorded.single['type'] == current.single['type'];
    }
    return jsonEncode(recorded) == jsonEncode(current);
  }

  /// The digest that binds a content manifest.
  String _authoringDigest(List<Map<String, Object?>> entries) =>
      sha256.convert(utf8.encode(jsonEncode(entries))).toString();

  /// The relevant pack authority of the restored participants.
  ///
  /// The authority is the current content of the pack groups of the shared
  /// state document: the packs, the snapshots, the approvals, the selections
  /// and the operations that mention the restored participants. The restore
  /// binds the exact observation, refuses a changed authority and never
  /// reinstates a retired upstream tracking.
  Map<String, Object?> _packAuthority(
    LifecycleContext context,
    Set<String> installationIds,
    Set<String> packKeys,
    Set<String> resourceNames,
  ) {
    final authority = <String, Object?>{};
    for (final scope in const [LifecycleScope.project, LifecycleScope.user]) {
      final root = _scopeStateRoot(context, scope);
      if (root == null) continue;
      final path = _io.fs.path.join(root, 'installations.json');
      final type = _io.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file) {
        throw MambaException(
          'The installation ledger is not a regular file: $path',
          exitCode: 6,
        );
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(_io.read(path, 8 * 1024 * 1024)));
      } on FormatException catch (error) {
        throw MambaException(
          'The installation ledger is not usable: ${error.message}',
          exitCode: 6,
        );
      }
      if (decoded is! Map<String, Object?>) {
        throw MambaException(
          'The installation ledger is not an object.',
          exitCode: 6,
        );
      }
      for (final group in const [
        'packs',
        'snapshots',
        'approvals',
        'selections',
        'operations',
      ]) {
        final entries = decoded[group];
        if (entries is! List) continue;
        final relevant = <Map<String, Object?>>[];
        for (final entry in entries) {
          if (entry is! Map) continue;
          final map = Map<String, Object?>.from(entry);
          if (_mentionsPack(map, installationIds, packKeys, resourceNames)) {
            relevant.add(map);
          }
        }
        if (relevant.isEmpty) continue;
        relevant.sort(
          (left, right) => jsonEncode(left).compareTo(jsonEncode(right)),
        );
        authority['$scope/$group'] = relevant;
      }
    }
    return authority;
  }

  /// Whether one pack record mentions the restored participants.
  bool _mentionsPack(
    Map<String, Object?> record,
    Set<String> installationIds,
    Set<String> packKeys,
    Set<String> resourceNames,
  ) {
    for (final value in record.values) {
      if (value is! String) continue;
      if (installationIds.contains(value) ||
          packKeys.contains(value) ||
          resourceNames.contains(value)) {
        return true;
      }
    }
    return false;
  }

  /// Whether the upstream pack membership of the source is still active.
  ///
  /// The membership is active only while the pack authority records an
  /// active approval or selection of the restored resource: a declined, an
  /// excluded or a removed membership is retired and is never resurrected by
  /// the restore. The pack catalog bounds the membership: a pack that the
  /// authority records as removed has no live membership.
  bool _packMembershipActive(
    Map<String, Object?> authority,
    String? resourceName,
  ) {
    if (resourceName == null) return false;
    var active = false;
    for (final entry in authority.entries) {
      final group = entry.key.split('/').last;
      final records = entry.value;
      if (records is! List) continue;
      if (group == 'packs') {
        for (final record in records.cast<Map<String, Object?>>()) {
          if (record['removed'] == true) return false;
        }
        continue;
      }
      if (group != 'approvals' && group != 'selections') continue;
      for (final record in records.cast<Map<String, Object?>>()) {
        if (record['resourceName'] != resourceName) continue;
        if (record['selected'] == false ||
            record['excluded'] == true ||
            record['membership'] == 'removed') {
          return false;
        }
        active = true;
      }
    }
    return active;
  }

  /// The upstream pack binding of the restored participants.
  ///
  /// The binding names the pack keys and the native resource names of the
  /// participants and observes the current pack authority that mentions them.
  _PackBinding _packBinding(
    LifecycleContext context,
    _RestoreOwnership ownership,
  ) {
    final packKeys = <String>{};
    final resourceNames = <String>{};
    final installationIds = <String>{};
    for (final record in <Map<String, Object?>?>[
      ownership.sourceRecord,
      ownership.targetRecord,
      ownership.retiredSourceRecord,
    ]) {
      if (record == null) continue;
      final origin = record['origin'];
      if (origin is! Map) continue;
      final packKey = origin['packKey'];
      if (packKey is String) packKeys.add(packKey);
      final resourceName = origin['resourceName'];
      if (resourceName is String) resourceNames.add(resourceName);
      final installationId = record['installationId'];
      if (installationId is String) installationIds.add(installationId);
    }
    final authority = _packAuthority(
      context,
      installationIds,
      packKeys,
      resourceNames,
    );
    return _PackBinding(
      packKeys: packKeys.toList()..sort(),
      resourceNames: resourceNames.toList()..sort(),
      authority: authority,
    );
  }

  /// Verifies that the observed pack authority did not change.
  void _verifyPackAuthority(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    final installationIds = <String>{
      if (evidence.sourceInstallationId != null) evidence.sourceInstallationId!,
      if (evidence.targetInstallationId != null) evidence.targetInstallationId!,
    };
    final current = _packAuthority(
      context,
      installationIds,
      evidence.packKeys.toSet(),
      evidence.resourceNames.toSet(),
    );
    if (jsonEncode(current) != jsonEncode(evidence.packAuthority)) {
      throw MambaException(
        'The upstream pack authority changed; the restore is refused.',
        exitCode: 6,
      );
    }
  }

  /// Reads the completed conversion that is restored.
  Future<ConversionEvidence> _readOriginal(
    LifecycleContext context,
    String transactionId,
  ) async {
    final ConversionEvidence evidence;
    try {
      final stored = await _evidence.readPersisted(
        context.stateRoot(),
        transactionId,
      );
      if (stored == null) {
        throw MambaException(
          'No conversion evidence exists for $transactionId.',
          exitCode: 4,
        );
      }
      evidence = stored;
    } on MambaException {
      rethrow;
    }
    if (evidence.phase != ConversionEvidencePhase.completed) {
      throw MambaException(
        'Only a completed conversion can be restored.',
        exitCode: 4,
      );
    }
    if (evidence.createdScope != context.scope.name) {
      throw MambaException(
        'The conversion belongs to another scope.',
        exitCode: 4,
      );
    }
    if (evidence.source.payload == null) {
      throw MambaException(
        'The conversion retained no independent source payload.',
        exitCode: 6,
      );
    }
    final publication = evidence.target.publication;
    if (publication == null || !publication.verified) {
      throw MambaException(
        'The conversion retained no verified target publication.',
        exitCode: 6,
      );
    }
    _verifyCommitDecision(context, evidence);
    return evidence;
  }

  /// Verifies the protected commit decision of the original conversion.
  void _verifyCommitDecision(
    LifecycleContext context,
    ConversionEvidence evidence,
  ) {
    final path = _io.fs.path.join(
      _evidence.evidenceDirectory(context.stateRoot()),
      evidence.transactionId,
      'commit.json',
    );
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException(
        'The completed conversion decision is missing.',
        exitCode: 6,
      );
    }
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The conversion commit marker is not a file.',
        exitCode: 6,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(_io.read(path, 1024 * 1024)));
    } on FormatException catch (error) {
      throw MambaException(
        'The conversion commit decision is corrupt: ${error.message}',
        exitCode: 6,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw MambaException(
        'The conversion commit decision is not an object.',
        exitCode: 6,
      );
    }
    final digest = decoded['digest'];
    final body = Map<String, Object?>.of(decoded)..remove('digest');
    final expected = sha256.convert(utf8.encode(jsonEncode(body))).toString();
    final committed = evidence
        .copyWith(
          phase: ConversionEvidencePhase.published,
          observations: <String, Object?>{
            ...evidence.observations,
            'coordinatorSourceRemoval': false,
          },
        )
        .digest;
    if (decoded['schemaVersion'] != 1 ||
        decoded['transactionId'] != evidence.transactionId ||
        decoded['decision'] != 'commit' ||
        digest != expected ||
        decoded['evidenceDigest'] != committed) {
      throw MambaException(
        'The conversion commit decision does not bind the evidence.',
        exitCode: 6,
      );
    }
  }

  /// Reviews and, with explicit approval, deletes the retained private copies
  /// of a terminal inverse restore.
  ///
  /// The cleanup is bounded and integrity checked: it removes the staged
  /// payload copy and the outgoing target evidence of a completed or rolled
  /// back inverse restore and retains the inverse evidence document as an
  /// audit tombstone. It refuses unfinished evidence, it never touches the
  /// retained payload of the original conversion and it does not promise
  /// secure erasure.
  Future<LifecycleResult> cleanupReviewed(
    LifecycleOptions options,
    String transactionId, {
    String? planId,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _io.fs);
    Future<LifecycleResult> run() async {
      final retained = _readRetainedRestores(
        _restoreRoot(context),
        transactionId,
      );
      final terminal = retained
          .where((evidence) => evidence.completed)
          .toList(growable: false);
      if (terminal.isEmpty) {
        throw MambaException(
          'No terminal inverse restore evidence exists for $transactionId.',
          exitCode: 4,
        );
      }
      if (terminal.length > 1) {
        throw MambaException(
          'More than one terminal inverse restore evidence exists for this '
          'conversion.',
          exitCode: 6,
        );
      }
      final evidence = terminal.single;
      final own = _ownEvidencePaths(context, evidence);
      // The cleanup honours the pending authority: a reservation of the
      // source, the target, the identities or the pack keys refuses it.
      _state.checkPendingConversions(
        context,
        locations: <String>[evidence.sourceLocation, evidence.targetLocation],
        installationIds: <String>{
          if (evidence.sourceInstallationId != null)
            evidence.sourceInstallationId!,
          if (evidence.targetInstallationId != null)
            evidence.targetInstallationId!,
        },
        packKeys: evidence.packKeys.toSet(),
        validatedRecoveryPaths: own,
      );
      final staging = _stagingPath(context, evidence.restoreId);
      final roots = _privateRoots(staging);
      final observations = <String, Object?>{};
      for (final path in roots) {
        _requireUnlinked(path);
        observations[path] =
            _io.type(path, followLinks: false) == FileSystemEntityType.notFound
            ? null
            : _manifestDigest(path);
      }
      final data = <String, Object?>{
        'transactionId': transactionId,
        'restoreId': evidence.restoreId,
        'action': 'cleanup',
        'scope': context.scope.name,
        'restorePhase': evidence.phase.name,
        'observations': observations,
        'retainsInverseEvidence': true,
      };
      data['planId'] = _reviewDigest(data);
      if (context.dryRun) {
        return LifecycleResult(
          command: 'prompt conversion restore',
          outcome: 'planned',
          data: data,
        );
      }
      _requireApproval(context, planId, data['planId']);
      for (final path in roots) {
        final type = _io.type(path, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        if (_manifestDigest(path) != observations[path]) {
          throw MambaException(
            'The retained inverse restore evidence changed; the cleanup is '
            'refused.',
            exitCode: 6,
          );
        }
        _io.delete(path);
      }
      _cleanupParticipantMarker(context, evidence);
      return LifecycleResult(
        command: 'prompt conversion restore',
        outcome: 'cleaned',
        data: <String, Object?>{
          ...data,
          'cleanupStatus': 'cleaned',
          'peerMarkerRemoved': _peerRoot(context, evidence) != null,
        },
      );
    }

    if (context.dryRun) return run();
    return _state.runCoordinated(
      context: context,
      location: context.stateRoot(),
      body: run,
    );
  }

  /// Removes the participant marker of the other scope.
  ///
  /// The marker is the reservation of the inverse restore in the scope that
  /// does not coordinate it. The cleanup removes it only when it carries the
  /// same inverse restore; the evidence document of the coordinator scope
  /// remains as the audit tombstone.
  void _cleanupParticipantMarker(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    final root = _peerRoot(context, evidence);
    if (root == null) return;
    final path = _io.fs.path.join(
      _restoreRootOf(root),
      '${evidence.restoreId}.json',
    );
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The inverse restore participant authority is not a file.',
        exitCode: 6,
      );
    }
    final ConversionRestoreEvidence marker;
    try {
      marker = ConversionRestoreEvidence.decode(
        utf8.decode(_io.read(path, maxConversionRestoreEvidenceBytes)),
      );
    } on FormatException catch (error) {
      throw MambaException(
        'The inverse restore participant authority is invalid: '
        '${error.message}',
        exitCode: 6,
      );
    }
    if (marker.restoreId != evidence.restoreId ||
        marker.transactionId != evidence.transactionId) {
      throw MambaException(
        'The inverse restore participant authority belongs to another '
        'restore; the cleanup is refused.',
        exitCode: 6,
      );
    }
    _io.delete(path);
  }

  /// The private staging roots of one inverse restore.
  List<String> _privateRoots(String staging) => <String>[
    _io.fs.path.join(staging, 'restored-source'),
    _io.fs.path.join(staging, 'outgoing-target'),
  ];

  /// Reviews the exact current observations of the inverse restore.
  Future<ConversionRestorePlan> _plan(
    LifecycleContext context,
    ConversionEvidence original,
    String transactionId,
  ) async {
    final restoreRoot = _restoreRoot(context);
    final retained = _readRetainedRestores(restoreRoot, transactionId);
    if (retained.any(
      (evidence) => evidence.phase == ConversionRestorePhase.completed,
    )) {
      throw MambaException(
        'The completed conversion was already restored.',
        exitCode: 4,
      );
    }
    final resumable = retained
        .where((evidence) => !evidence.completed)
        .toList(growable: false);
    if (resumable.length > 1) {
      throw MambaException(
        'More than one inverse restore is pending for this conversion.',
        exitCode: 6,
      );
    }
    if (resumable.isNotEmpty) {
      return _resumePlan(context, original, resumable.single);
    }
    return _freshPlan(context, original, transactionId, restoreRoot);
  }

  /// Reviews the resume of an interrupted inverse restore.
  Future<ConversionRestorePlan> _resumePlan(
    LifecycleContext context,
    ConversionEvidence original,
    ConversionRestoreEvidence evidence,
  ) async {
    _verifyParticipantMarker(context, evidence);
    final staging = _stagingPath(context, evidence.restoreId);
    final restored = _restoredPath(evidence, staging);
    final payload = original.source.payload!;
    final staged =
        _io.type(restored, followLinks: false) != FileSystemEntityType.notFound;
    if (staged) {
      if (_manifestDigest(restored) != evidence.payloadDigest) {
        throw MambaException(
          'The staged inverse restore payload changed.',
          exitCode: 6,
        );
      }
    } else if (_io.type(payload.path, followLinks: false) ==
            FileSystemEntityType.notFound ||
        _manifestDigest(payload.path) != evidence.payloadDigest) {
      throw MambaException(
        'The retained recovery payload is missing or changed.',
        exitCode: 6,
      );
    }
    final observations = await _observations(context, original, evidence);
    final data = <String, Object?>{
      'transactionId': original.transactionId,
      'restoreId': evidence.restoreId,
      'action': 'restore',
      'scope': context.scope.name,
      'phase': original.phase.name,
      'restorePhase': evidence.phase.name,
      'resume': true,
      'source': evidence.sourceLocation,
      'target': evidence.targetLocation,
      'inPlace': evidence.inPlace,
      'sourceManaged': evidence.sourceManaged,
      'observations': observations,
    };
    data['planId'] = _reviewDigest(data);
    return ConversionRestorePlan(evidence: evidence, data: data);
  }

  /// Reviews a fresh inverse restore of a completed conversion.
  Future<ConversionRestorePlan> _freshPlan(
    LifecycleContext context,
    ConversionEvidence original,
    String transactionId,
    String restoreRoot,
  ) async {
    final source = original.source;
    final target = original.target;
    final payload = source.payload!;
    final publication = target.publication!;
    final inPlace = _io.fs.path.equals(source.location, target.location);

    // The retained independent payload is the only authority of the original
    // source content. A cleaned payload forfeits the restore.
    final payloadType = _io.type(payload.path, followLinks: false);
    if (payloadType == FileSystemEntityType.notFound) {
      throw MambaException(
        'The retained recovery payload was cleaned; the completed conversion '
        'can no longer be restored.',
        exitCode: 6,
      );
    }
    if (_manifestDigest(payload.path) != payload.digest) {
      throw MambaException(
        'The retained recovery payload is missing or changed.',
        exitCode: 6,
      );
    }

    // The converted target must still be the published target. A later edit
    // or a new occupant is refused, never overwritten.
    if (_io.type(target.location, followLinks: false) ==
        FileSystemEntityType.notFound) {
      throw MambaException(
        'The converted target is missing; the restore is refused.',
        exitCode: 6,
      );
    }
    if (_manifestDigest(target.location) != publication.digest) {
      throw MambaException(
        'The converted target changed since the conversion; the restore is '
        'refused.',
        exitCode: 6,
      );
    }

    // The original source location must be free unless the conversion
    // replaced the source in place.
    if (!inPlace &&
        _io.type(source.location, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw MambaException(
        'A new occupant appeared at the original source location; the restore '
        'is refused.',
        exitCode: 6,
      );
    }

    final ownership = await _reviewOwnership(context, original);
    final pack = _packBinding(context, ownership);
    final attempt = _restoreAttempt(restoreRoot, transactionId);
    final peer = _coordinatedPeer(
      context,
      source.ownershipBefore?.scope ?? context.scope.name,
      target.ownershipAfter?.scope ?? context.scope.name,
    );
    final evidence = ConversionRestoreEvidence(
      restoreId: _restoreId(transactionId, attempt),
      transactionId: transactionId,
      phase: ConversionRestorePhase.prepared,
      createdScope: context.scope.name,
      sourceLocation: source.location,
      targetLocation: target.location,
      artifactKind: target.artifactKind,
      sourceScope: source.ownershipBefore?.scope ?? context.scope.name,
      targetScope: target.ownershipAfter?.scope ?? context.scope.name,
      peerScope: peer.scope?.name,
      peerStateRoot: peer.root,
      inPlace: inPlace,
      payloadPath: payload.path,
      payloadDigest: payload.digest,
      outgoingDigest: publication.digest,
      observations: const <String, Object?>{},
      sourceManaged: source.ownershipBefore?.managed == true,
      sourceInstallationId: source.ownershipBefore?.installationId,
      targetInstallationId: target.identity?.installationId,
      sourceRecord: ownership.sourceRecord,
      targetRecord: ownership.targetRecord,
      retiredSourceRecord: ownership.retiredSourceRecord,
      packKeys: pack.packKeys,
      resourceNames: pack.resourceNames,
      packAuthority: pack.authority,
      approvals: original.approvals,
    );
    final observations = await _observations(context, original, evidence);
    final current = evidence.copyWith(observations: observations);
    final data = <String, Object?>{
      'transactionId': transactionId,
      'restoreId': current.restoreId,
      'action': 'restore',
      'scope': context.scope.name,
      'phase': original.phase.name,
      'restorePhase': current.phase.name,
      'resume': false,
      'source': source.location,
      'target': target.location,
      'inPlace': inPlace,
      'sourceManaged': current.sourceManaged,
      'observations': observations,
    };
    data['planId'] = _reviewDigest(data);
    return ConversionRestorePlan(evidence: current, data: data);
  }

  /// Reviews the ownership and membership observations of the restore.
  Future<_RestoreOwnership> _reviewOwnership(
    LifecycleContext context,
    ConversionEvidence original,
  ) async {
    final source = original.source;
    final target = original.target;
    final sourceId = source.ownershipBefore?.installationId;
    final targetId = target.identity?.installationId;
    final records = await _records(context);

    Map<String, Object?>? sourceRecord;
    if (source.ownershipBefore?.managed == true) {
      final snapshot = original.observations['coordinatorSourceRecord'];
      if (snapshot == null) {
        throw MambaException(
          'The managed source record snapshot is missing or invalid.',
          exitCode: 6,
        );
      }
      final InstallationRecord record;
      try {
        record = InstallationRecord.fromJson(snapshot);
      } on FormatException catch (error) {
        throw MambaException(
          'The managed source record snapshot is missing or invalid: '
          '${error.message}',
          exitCode: 6,
        );
      }
      if (record.installationId != sourceId ||
          record.location != source.location ||
          record.scope.name != source.ownershipBefore!.scope ||
          record.lifecycle != 'live') {
        throw MambaException(
          'The managed source record snapshot does not bind the participant.',
          exitCode: 6,
        );
      }
      sourceRecord = record.toJson();
    }

    Map<String, Object?>? targetRecord;
    if (targetId != null) {
      InstallationRecord? found;
      for (final scope in records.keys) {
        for (final record in records[scope]!) {
          if (record.installationId == targetId) found = record;
        }
      }
      if (found == null) {
        throw MambaException(
          'The converted target ownership is missing; the restore is refused.',
          exitCode: 6,
        );
      }
      if (found.lifecycle != 'live' ||
          !_io.fs.path.equals(found.location, target.location) ||
          found.origin['conversionTransactionId'] != original.transactionId) {
        throw MambaException(
          'The converted target ownership changed; the restore is refused.',
          exitCode: 6,
        );
      }
      _verifyTargetRecord(original, found, sourceRecord);
      _verifyMembership(original, found);
      targetRecord = found.toJson();
    }

    // An unmanaged source is never adopted by the restore, and no other live
    // installation may own the original source location.
    for (final scope in records.keys) {
      for (final record in records[scope]!) {
        if (record.lifecycle != 'live') continue;
        if (record.installationId == targetId) continue;
        if (record.installationId == sourceId) {
          throw MambaException(
            'The original ownership changed; the restore is refused.',
            exitCode: 6,
          );
        }
        if (_io.fs.path.equals(record.location, source.location)) {
          throw MambaException(
            'The original source was adopted by another installation; the '
            'restore is refused.',
            exitCode: 6,
          );
        }
      }
    }
    Map<String, Object?>? retiredSourceRecord;
    if (sourceId != null && sourceId != targetId) {
      // The retired source record must still be retired by this conversion.
      // A later edit or a new installation of the same identity is refused.
      final retired = records.values
          .expand((scope) => scope)
          .where((record) => record.installationId == sourceId)
          .toList(growable: false);
      if (retired.isEmpty ||
          retired.any((record) => record.lifecycle != 'removed')) {
        throw MambaException(
          'The original ownership changed; the restore is refused.',
          exitCode: 6,
        );
      }
      if (sourceRecord != null) {
        _verifySourceRetirement(
          original,
          retired.single,
          InstallationRecord.fromJson(sourceRecord),
        );
      }
      retiredSourceRecord = retired.single.toJson();
    }
    return _RestoreOwnership(
      sourceRecord: sourceRecord,
      targetRecord: targetRecord,
      retiredSourceRecord: retiredSourceRecord,
    );
  }

  /// Verifies that the converted target ownership still binds the conversion.
  void _verifyTargetRecord(
    ConversionEvidence original,
    InstallationRecord record,
    Map<String, Object?>? sourceSnapshot,
  ) {
    final target = original.target;
    final ownership = target.ownershipAfter;
    final sameIdentity =
        target.identity?.installationId ==
        original.source.ownershipBefore?.installationId;
    final expectedDestination = sameIdentity && sourceSnapshot != null
        ? sourceSnapshot['nativeDestination']
        : (ownership?.nativeDestination ??
              ownership?.nativeProfile ??
              ownership?.nativeForm);
    final expectedProfile = ownership?.nativeProfile;
    final expectedRoot = ownership?.nativeRoot;
    final expectedScope = ownership?.scope ?? record.scope.name;
    if (record.kind.wireName != target.artifactKind ||
        record.nativeForm != ownership?.nativeForm ||
        record.nativeProfile != expectedProfile ||
        record.nativeDestination != expectedDestination ||
        (expectedRoot != null &&
            !_io.fs.path.equals(record.nativeRoot, expectedRoot)) ||
        record.scope.name != expectedScope ||
        record.transactionId != null) {
      throw MambaException(
        'The converted target ownership changed; the restore is refused.',
        exitCode: 6,
      );
    }
  }

  /// Verifies that the membership of the converted target did not change.
  ///
  /// The membership binding is required evidence. A record without the
  /// recorded binding is missing evidence, not a free state: the restore is
  /// refused.
  void _verifyMembership(
    ConversionEvidence original,
    InstallationRecord record,
  ) {
    final expected = original.target.membershipAfter;
    if (expected == null) return;
    final observed = record.origin['conversionMembership'];
    if (observed == null) {
      throw MambaException(
        'The membership binding of the converted target is missing; the '
        'restore is refused.',
        exitCode: 6,
      );
    }
    if (jsonEncode(observed) != jsonEncode(expected.toJson())) {
      throw MambaException(
        'The membership of the converted target changed; the restore is '
        'refused.',
        exitCode: 6,
      );
    }
  }

  /// Verifies the retirement of the original source.
  ///
  /// The restore reinstates the original identity only when the current
  /// record is still the record that this conversion retired. A later edit, a
  /// new installation of the same identity or a changed upstream membership
  /// is refused; the restore never resurrects a retired membership.
  void _verifySourceRetirement(
    ConversionEvidence original,
    InstallationRecord retired,
    InstallationRecord snapshot,
  ) {
    if (retired.lifecycle != 'removed' ||
        retired.origin['conversionTransactionId'] != original.transactionId) {
      throw MambaException(
        'The original ownership changed; the restore is refused.',
        exitCode: 6,
      );
    }
    final expected = original.source.membershipAfter;
    if (expected != null) {
      final observed = retired.origin['conversionMembership'];
      if (observed == null ||
          jsonEncode(observed) != jsonEncode(expected.toJson())) {
        throw MambaException(
          'The membership of the original source changed; the restore is '
          'refused.',
          exitCode: 6,
        );
      }
    }
    // The upstream pack membership of the original source must not have
    // changed. A restored record never reinstates a membership that the
    // current observations do not permit.
    final packKey = snapshot.origin['packKey'];
    if (packKey is String && retired.origin['packKey'] != packKey) {
      throw MambaException(
        'The upstream membership of the original source changed; the restore '
        'is refused.',
        exitCode: 6,
      );
    }
    final resourceType = snapshot.origin['resourceType'];
    if (resourceType is String &&
        retired.origin['resourceType'] != resourceType) {
      throw MambaException(
        'The upstream membership of the original source changed; the restore '
        'is refused.',
        exitCode: 6,
      );
    }
    // A later edit of the retired record is not silently dropped by the
    // restore. Only the recorded conversion markers may differ.
    const markers = <String>{'conversionTransactionId', 'conversionMembership'};
    for (final key in retired.origin.keys) {
      if (snapshot.origin.containsKey(key)) continue;
      if (markers.contains(key)) continue;
      throw MambaException(
        'The original ownership changed; the restore is refused.',
        exitCode: 6,
      );
    }
  }

  /// The exact current observations that the reviewed plan binds.
  Future<Map<String, Object?>> _observations(
    LifecycleContext context,
    ConversionEvidence original,
    ConversionRestoreEvidence evidence,
  ) async {
    final observations = <String, Object?>{};
    final paths = <String>{
      evidence.sourceLocation,
      evidence.targetLocation,
      evidence.payloadPath,
      _evidence.evidencePath(context.stateRoot(), original.transactionId),
      for (final scope in const [LifecycleScope.project, LifecycleScope.user])
        if (_scopeStateRoot(context, scope) case final root?)
          _io.fs.path.join(root, 'installations.json'),
    };
    for (final path in paths) {
      _requireUnlinked(path);
      observations[path] =
          _io.type(path, followLinks: false) == FileSystemEntityType.notFound
          ? null
          : _manifestDigest(path);
    }
    return observations;
  }

  /// The installation records of both scopes.
  Future<Map<LifecycleScope, List<InstallationRecord>>> _records(
    LifecycleContext context,
  ) async {
    final records = <LifecycleScope, List<InstallationRecord>>{};
    for (final scope in const [LifecycleScope.project, LifecycleScope.user]) {
      final root = _scopeStateRoot(context, scope);
      if (root == null) continue;
      final scopeContext = scope == context.scope
          ? context
          : LifecycleContext.resolve(
              context.options.copyWith(scope: scope),
              fileSystem: _io.fs,
            );
      try {
        records[scope] = _state.records(scopeContext);
      } on MambaException {
        // A realm that the host did not configure has no authority to
        // observe. The restore never treats the missing realm as a free
        // state of the participants it does observe.
        if (scope == context.scope) rethrow;
        records[scope] = const <InstallationRecord>[];
      }
    }
    return records;
  }

  /// Applies the reviewed inverse restore.
  Future<Map<String, Object?>> _apply(
    LifecycleContext context,
    ConversionEvidence original,
    ConversionRestorePlan plan,
  ) async {
    final evidence = plan.evidence;
    final staging = _stagingPath(context, evidence.restoreId);
    final restored = _restoredPath(evidence, staging);
    final outgoing = _outgoingPath(evidence, staging);
    final decision = _io.fs.path.join(staging, 'commit.json');
    try {
      _requireUnlinked(staging);
      // An interrupted inverse restore without a commit decision is rolled
      // back; an interrupted inverse restore after its decision finishes
      // forward.
      final resuming = plan.data['resume'] == true;
      if (resuming &&
          _io.type(decision, followLinks: false) ==
              FileSystemEntityType.notFound) {
        _rollback(context, evidence, original);
        return <String, Object?>{
          'restorePhase': ConversionRestorePhase.rolledBack.name,
          'rolledBack': true,
        };
      }
      if (_io.type(staging, followLinks: false) ==
          FileSystemEntityType.notFound) {
        _io.createDirectory(staging);
      }
      _state.protectDirectory(staging);
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.prepared),
      );
      // The upstream pack authority must still be the observed authority.
      _verifyPackAuthority(context, evidence);

      // Stage the retained independent payload of the original source.
      if (_io.type(restored, followLinks: false) ==
          FileSystemEntityType.notFound) {
        _copyTree(evidence.payloadPath, restored);
      }
      if (_manifestDigest(restored) != evidence.payloadDigest) {
        throw MambaException(
          'The staged inverse restore payload does not match the retained '
          'recovery payload.',
          exitCode: 6,
        );
      }

      // Preserve the outgoing target as evidence before it is retired.
      //
      // The evidence is captured once, before the inverse decision. After
      // the decision a missing evidence is missing recovery data: the restore
      // stops safely instead of recreating it from a retired target.
      final decided =
          _io.type(decision, followLinks: false) == FileSystemEntityType.file;
      if (_io.type(outgoing, followLinks: false) ==
          FileSystemEntityType.notFound) {
        if (decided) {
          throw MambaException(
            'The retained outgoing target evidence is missing; the inverse '
            'restore cannot be completed.',
            exitCode: 6,
          );
        }
        if (_io.type(evidence.targetLocation, followLinks: false) ==
            FileSystemEntityType.notFound) {
          throw MambaException(
            'The converted target is missing; the outgoing target evidence '
            'cannot be preserved.',
            exitCode: 6,
          );
        }
        _copyTree(evidence.targetLocation, outgoing);
      }
      if (_manifestDigest(outgoing) != evidence.outgoingDigest) {
        throw MambaException(
          'The retained outgoing target evidence changed.',
          exitCode: 6,
        );
      }
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.published),
      );

      // Publish the original source at its original location.
      if (evidence.inPlace) {
        _io.delete(evidence.sourceLocation);
        _copyTree(restored, evidence.sourceLocation);
      } else if (_io.type(evidence.sourceLocation, followLinks: false) ==
          FileSystemEntityType.notFound) {
        _copyTree(restored, evidence.sourceLocation);
      }
      if (_manifestDigest(evidence.sourceLocation) !=
          original.source.baseline!.digest) {
        throw MambaException(
          'The restored source does not match the reviewed original.',
          exitCode: 6,
        );
      }

      // Commit the inverse decision. Before this point the restore rolls
      // back; after it the restore finishes forward.
      _writeRestoreDecision(staging, evidence);
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.committed),
      );

      // Retire the converted target. Its content is retained as evidence.
      if (!evidence.inPlace &&
          _io.type(evidence.targetLocation, followLinks: false) !=
              FileSystemEntityType.notFound) {
        if (_manifestDigest(evidence.targetLocation) !=
            evidence.outgoingDigest) {
          throw MambaException(
            'The converted target changed; the restore is refused.',
            exitCode: 6,
          );
        }
        _io.delete(evidence.targetLocation);
      }

      // Reinstate the original ownership and retire the converted target.
      await _applyOwnership(context, original, evidence);
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.reconciled),
      );
      final completed = evidence.copyWith(
        phase: ConversionRestorePhase.completed,
      );
      _persist(context, completed);
      return <String, Object?>{
        'restorePhase': completed.phase.name,
        'outgoingTargetEvidence': outgoing,
        'restoredSource': evidence.sourceLocation,
        'retiredTarget': evidence.targetLocation,
      };
    } on MambaException catch (error) {
      _markRecoveryRequired(context, evidence);
      throw error;
    } catch (error) {
      _markRecoveryRequired(context, evidence);
      throw MambaException(
        'The inverse restore needs recovery: $error',
        exitCode: 6,
      );
    }
  }

  /// Reinstates the original ownership and retires the converted target.
  Future<void> _applyOwnership(
    LifecycleContext context,
    ConversionEvidence original,
    ConversionRestoreEvidence evidence,
  ) async {
    final restored = <LifecycleScope, InstallationRecord>{};
    final retired = <LifecycleScope, InstallationRecord>{};
    final previous = <LifecycleScope, InstallationRecord>{};
    final sourceRecord = evidence.sourceRecord;
    if (sourceRecord != null) {
      final record = InstallationRecord.fromJson(sourceRecord);
      final scope = LifecycleScope.values.byName(record.scope.name);
      final origin = <String, Object?>{
        ...record.origin,
        'restoredFromConversionTransaction': original.transactionId,
        'conversionRestoredBy': evidence.restoreId,
      };
      // The upstream tracking is reinstated only while the pack authority
      // still records the membership of the resource. A retired membership is
      // never resurrected implicitly.
      final resourceName = record.origin['resourceName'];
      if (!_packMembershipActive(
        evidence.packAuthority,
        resourceName is String ? resourceName : null,
      )) {
        origin.remove('track');
      }
      restored[scope] = record.copyWith(lifecycle: 'live', origin: origin);
      final retiredSource = evidence.retiredSourceRecord;
      if (retiredSource != null) {
        final before = InstallationRecord.fromJson(retiredSource);
        if (before.installationId != record.installationId) {
          throw MambaException(
            'The original ownership changed; the restore is refused.',
            exitCode: 6,
          );
        }
        previous[scope] = before;
      }
    }
    final targetRecord = evidence.targetRecord;
    if (targetRecord != null) {
      final record = InstallationRecord.fromJson(targetRecord);
      final scope = LifecycleScope.values.byName(record.scope.name);
      retired[scope] = record;
    }
    await _state.applyConversionRestore(
      context: context,
      restored: restored,
      retiredTargets: retired,
      previous: previous,
      restoreId: evidence.restoreId,
    );
  }

  /// Rolls an interrupted inverse restore back before its commit decision.
  void _rollback(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
    ConversionEvidence original,
  ) {
    final staging = _stagingPath(context, evidence.restoreId);
    final outgoing = _outgoingPath(evidence, staging);
    if (evidence.inPlace &&
        _io.type(outgoing, followLinks: false) !=
            FileSystemEntityType.notFound) {
      // The converted target occupied the original location; put it back.
      if (_io.type(evidence.sourceLocation, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _io.delete(evidence.sourceLocation);
      }
      _copyTree(outgoing, evidence.sourceLocation);
    } else if (evidence.inPlace) {
      throw MambaException(
        'The retained outgoing target evidence is missing; the inverse '
        'restore cannot be rolled back safely.',
        exitCode: 6,
      );
    } else if (_io.type(evidence.sourceLocation, followLinks: false) !=
            FileSystemEntityType.notFound &&
        original.source.baseline != null &&
        _manifestDigest(evidence.sourceLocation) ==
            original.source.baseline!.digest) {
      // The restored source is transaction owned; remove it again.
      _io.delete(evidence.sourceLocation);
    }
    _persist(
      context,
      evidence.copyWith(phase: ConversionRestorePhase.rolledBack),
    );
  }

  /// The retained inverse restore evidence of one state root.
  List<ConversionRestoreEvidence> _readRetainedRestores(
    String restoreRoot,
    String transactionId,
  ) {
    if (_io.type(restoreRoot, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return const <ConversionRestoreEvidence>[];
    }
    final retained = <ConversionRestoreEvidence>[];
    for (final entry in _io.list(restoreRoot)) {
      final name = _io.fs.path.basename(entry.path);
      if (!name.endsWith('.json')) continue;
      if (_io.type(entry.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw MambaException(
          'The retained inverse restore evidence is not a file: ${entry.path}',
          exitCode: 6,
        );
      }
      final ConversionRestoreEvidence evidence;
      try {
        evidence = ConversionRestoreEvidence.decode(
          utf8.decode(_io.read(entry.path, maxConversionRestoreEvidenceBytes)),
        );
      } on FormatException catch (error) {
        throw MambaException(
          'The retained inverse restore evidence is corrupt: ${error.message}',
          exitCode: 6,
        );
      }
      if (evidence.transactionId == transactionId) retained.add(evidence);
    }
    return retained;
  }

  /// The number of inverse restores that were already attempted.
  int _restoreAttempt(String restoreRoot, String transactionId) =>
      _readRetainedRestores(restoreRoot, transactionId).length;

  /// The identifier of one inverse restore transaction.
  String _restoreId(String transactionId, int attempt) {
    final digest = sha256.convert(
      utf8.encode('restore:$transactionId:$attempt'),
    );
    return 'rsv_${digest.toString().substring(0, 32)}';
  }

  String _restoreRoot(LifecycleContext context) =>
      _restoreRootOf(context.stateRoot());

  String _restoreRootOf(String stateRoot) =>
      _io.fs.path.join(stateRoot, conversionRestoreDirectoryName);

  String _stagingPath(LifecycleContext context, String restoreId) =>
      _io.fs.path.join(_restoreRoot(context), restoreId);

  /// The staged copy of the retained original source.
  String _restoredPath(ConversionRestoreEvidence evidence, String staging) {
    final payloadType = _io.type(evidence.payloadPath, followLinks: false);
    final root = _io.fs.path.join(staging, 'restored-source');
    return payloadType == FileSystemEntityType.file
        ? _io.fs.path.join(root, _io.fs.path.basename(evidence.payloadPath))
        : root;
  }

  /// The preserved evidence of the outgoing converted target.
  String _outgoingPath(ConversionRestoreEvidence evidence, String staging) {
    final root = _io.fs.path.join(staging, 'outgoing-target');
    return _isDirectoryTarget(evidence.artifactKind)
        ? root
        : _io.fs.path.join(root, _io.fs.path.basename(evidence.targetLocation));
  }

  /// Whether the artifact kind is a native directory of files.
  bool _isDirectoryTarget(String artifactKind) =>
      artifactKind == 'skill-copy' || artifactKind == 'skill-canonical';

  void _persist(LifecycleContext context, ConversionRestoreEvidence evidence) {
    _state.writeProtectedDocument(
      _io.fs.path.join(_restoreRoot(context), '${evidence.restoreId}.json'),
      utf8.encode(evidence.encode()),
    );
    _writeParticipantMarker(context, evidence);
  }

  /// Writes the protected participant marker of the other scope.
  ///
  /// The marker reserves the inverse restore in the scope that does not
  /// coordinate it, so an old mutator of that scope cannot change the
  /// source, the target or the identities while the inverse restore is
  /// pending. The marker is written before any live effect.
  void _writeParticipantMarker(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    final root = _peerRoot(context, evidence);
    if (root == null) return;
    _state.writeProtectedDocument(
      _io.fs.path.join(_restoreRootOf(root), '${evidence.restoreId}.json'),
      utf8.encode(evidence.copyWith(participantMarker: true).encode()),
    );
  }

  /// The scope that does not coordinate the inverse restore.
  ///
  /// The peer scope is the recorded authority of the realm that does not
  /// coordinate the restore. An unconfigured realm has no peer scope.
  LifecycleScope? _peerScope(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    final scope = evidence.peerScope;
    if (scope == null) return null;
    return LifecycleScope.values.byName(scope);
  }

  /// The recorded state root of the peer scope.
  String? _peerRoot(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    final recorded = evidence.peerStateRoot;
    if (recorded != null) return recorded;
    final peer = _peerScope(context, evidence);
    if (peer == null) return null;
    return _scopeStateRoot(context, peer);
  }

  /// The state root of one scope, when the host configured it.
  ///
  /// The selected scope always resolves. Another scope resolves only when the
  /// host configured its realm: an unconfigured realm is not a free state and
  /// it is not an invented authority either. The restore observes and
  /// reserves only the realms that exist.
  String? _scopeStateRoot(LifecycleContext context, LifecycleScope scope) {
    if (scope == context.scope) return context.stateRoot(scope);
    try {
      return context.stateRoot(scope);
    } on MambaException {
      return null;
    }
  }

  /// The peer scope and root of a coordinated restore.
  ///
  /// The managed conversion coordinates in the scope of its target. The peer
  /// is the other realm, when the host configured it.
  ({LifecycleScope? scope, String? root}) _coordinatedPeer(
    LifecycleContext context,
    String sourceScope,
    String targetScope,
  ) {
    for (final scope in <LifecycleScope>{
      LifecycleScope.values.byName(sourceScope),
      LifecycleScope.values.byName(targetScope),
    }) {
      if (scope == context.scope) continue;
      final root = _scopeStateRoot(context, scope);
      if (root == null) continue;
      return (scope: scope, root: root);
    }
    return (scope: null, root: null);
  }

  /// Verifies the participant marker of the other scope.
  ///
  /// A missing marker is recoverable: the apply re-establishes the
  /// reservation before any live effect. A marker that carries another
  /// document is a substituted reservation and is refused.
  ///
  /// A marker of an earlier phase of the same inverse restore is stale after
  /// a crash between the coordinator write and the peer write. It is accepted
  /// and re-established. A marker that claims a later phase than the
  /// coordinator, another identity, another scope or another schema is an
  /// unauthorized state and is refused.
  void _verifyParticipantMarker(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    final root = _peerRoot(context, evidence);
    if (root == null) return;
    final path = _io.fs.path.join(
      _restoreRootOf(root),
      '${evidence.restoreId}.json',
    );
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      // The reservation is re-established by the apply before it publishes
      // anything. The reservation is never silently lost.
      return;
    }
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The inverse restore participant authority is not a file.',
        exitCode: 6,
      );
    }
    final ConversionRestoreEvidence marker;
    try {
      marker = ConversionRestoreEvidence.decode(
        utf8.decode(_io.read(path, maxConversionRestoreEvidenceBytes)),
      );
    } on FormatException catch (error) {
      throw MambaException(
        'The inverse restore participant authority is invalid: '
        '${error.message}',
        exitCode: 6,
      );
    }
    final expected = evidence.copyWith(participantMarker: true);
    if (marker.restoreId != expected.restoreId ||
        marker.transactionId != expected.transactionId ||
        marker.sourceLocation != expected.sourceLocation ||
        marker.targetLocation != expected.targetLocation ||
        marker.payloadDigest != expected.payloadDigest ||
        marker.outgoingDigest != expected.outgoingDigest ||
        marker.createdScope != expected.createdScope) {
      throw MambaException(
        'The inverse restore participant authority changed.',
        exitCode: 6,
      );
    }
    final markerOrder = _phaseOrder(marker.phase);
    final expectedOrder = _phaseOrder(expected.phase);
    if (markerOrder >= 0 && expectedOrder >= 0 && markerOrder > expectedOrder) {
      throw MambaException(
        'The inverse restore participant authority claims an unauthorized '
        'state.',
        exitCode: 6,
      );
    }
  }

  /// The order of the forward phases of an inverse restore.
  ///
  /// A rolled back or a recovery required inverse restore is not a forward
  /// phase: it carries no order and never outranks another phase.
  int _phaseOrder(ConversionRestorePhase phase) => switch (phase) {
    ConversionRestorePhase.prepared => 0,
    ConversionRestorePhase.published => 1,
    ConversionRestorePhase.committed => 2,
    ConversionRestorePhase.reconciled => 3,
    ConversionRestorePhase.completed => 4,
    ConversionRestorePhase.rolledBack => -1,
    ConversionRestorePhase.recoveryRequired => -1,
  };

  void _markRecoveryRequired(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    try {
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.recoveryRequired),
      );
    } catch (error) {
      // The retained evidence stays as it is; the refusal is reported to the
      // caller and the pending restore remains guarded.
    }
  }

  /// Writes the protected decision of the inverse restore.
  void _writeRestoreDecision(
    String staging,
    ConversionRestoreEvidence evidence,
  ) {
    final body = <String, Object?>{
      'schemaVersion': 1,
      'restoreId': evidence.restoreId,
      'transactionId': evidence.transactionId,
      'decision': 'restore',
      'evidenceDigest': evidence.digest,
    };
    final decision = <String, Object?>{
      ...body,
      'digest': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
    };
    _state.writeProtectedDocument(
      _io.fs.path.join(staging, 'commit.json'),
      utf8.encode(jsonEncode(decision)),
    );
  }

  void _requireUnlinked(String path) {
    final absolute = _io.fs.path.normalize(path);
    final root = _io.fs.path.rootPrefix(absolute);
    for (final component in skillPathComponents(
      absolute,
      base: root,
      fs: _io.fs,
    )) {
      if (_io.type(component, followLinks: false) ==
          FileSystemEntityType.link) {
        throw MambaException(
          'Linked inverse restore authority is unsupported: $component',
          exitCode: 6,
        );
      }
    }
  }

  /// Copies a file or a directory tree into a private staging path.
  void _copyTree(String source, String destination) {
    final type = _io.type(source, followLinks: false);
    if (type == FileSystemEntityType.file) {
      _io.createDirectory(_io.fs.path.dirname(destination));
      _io.copyFile(source, destination);
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw MambaException(
        'The retained evidence is not a regular file or directory.',
        exitCode: 6,
      );
    }
    void copy(String from, String to) {
      _io.createDirectory(to);
      for (final entry in _io.list(from)) {
        final name = _io.fs.path.basename(entry.path);
        final childType = _io.type(entry.path, followLinks: false);
        if (childType == FileSystemEntityType.directory) {
          copy(entry.path, _io.fs.path.join(to, name));
        } else if (childType == FileSystemEntityType.file) {
          _io.copyFile(entry.path, _io.fs.path.join(to, name));
        } else {
          throw MambaException(
            'The retained evidence contains an unsupported entry: ${entry.path}',
            exitCode: 6,
          );
        }
      }
    }

    copy(source, destination);
  }

  String _manifestDigest(String path) =>
      conversionManifestDigest(conversionManifestEntries(_io, path));

  String _reviewDigest(Map<String, Object?> data) =>
      sha256.convert(utf8.encode(jsonEncode(data))).toString();

  /// Refuses an ordinary inverse restore that conflicts with other pending
  /// work.
  void _requireNoPendingAuthoringConflict(
    LifecycleContext context,
    _AuthoringSubject subject,
    ConversionRestorePlan plan,
  ) {
    final own = _ownEvidencePaths(context, plan.evidence);
    _state.checkPendingConversions(
      context,
      locations: <String>[subject.sourceLocation, subject.targetLocation],
      validatedRecoveryPaths: own,
    );
    _state.checkPendingMutations(
      context,
      locations: <String>[subject.sourceLocation, subject.targetLocation],
      validatedPaths: own,
    );
  }
}

/// The upstream pack binding of one reviewed inverse restore.
final class _PackBinding {
  const _PackBinding({
    required this.packKeys,
    required this.resourceNames,
    required this.authority,
  });

  /// The reserved upstream pack keys.
  final List<String> packKeys;

  /// The observed native resource names.
  final List<String> resourceNames;

  /// The observed pack authority.
  final Map<String, Object?> authority;
}

/// The durable authority of one ordinary completed conversion.
final class _AuthoringSubject {
  const _AuthoringSubject({
    required this.transaction,
    required this.sourceLocation,
    required this.targetLocation,
    required this.payloadPath,
    required this.payloadEntries,
    required this.targetEntries,
    required this.payloadIsFile,
    required this.inPlace,
  });

  /// The completed authoring transaction of the ordinary conversion.
  final AuthoringTransaction transaction;

  /// The original location of the converted source.
  final String sourceLocation;

  /// The location of the converted target that the restore retires.
  final String targetLocation;

  /// The retained independent payload of the original source.
  final String payloadPath;

  /// The recorded content evidence of the retained payload.
  final List<Map<String, Object?>> payloadEntries;

  /// The recorded content evidence of the published target.
  final List<Map<String, Object?>> targetEntries;

  /// Whether the retained payload holds a single marker file.
  final bool payloadIsFile;

  /// Whether the conversion replaced the source in place.
  final bool inPlace;
}

/// The ownership observations of one reviewed inverse restore.
final class _RestoreOwnership {
  const _RestoreOwnership({
    this.sourceRecord,
    this.targetRecord,
    this.retiredSourceRecord,
  });

  final Map<String, Object?>? sourceRecord;
  final Map<String, Object?>? targetRecord;

  /// The retired record of the original source at review time.
  final Map<String, Object?>? retiredSourceRecord;
}
