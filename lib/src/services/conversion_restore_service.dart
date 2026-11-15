import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';

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
    if (_peerScope(context, evidence) case final peer?)
      _io.fs.path.join(
        _restoreRootOf(context.stateRoot(peer)),
        '${evidence.restoreId}.json',
      ),
  };

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
      return LifecycleResult(
        command: 'prompt conversion restore',
        outcome: 'cleaned',
        data: <String, Object?>{...data, 'cleanupStatus': 'cleaned'},
      );
    }

    if (context.dryRun) return run();
    return _state.runCoordinated(
      context: context,
      location: context.stateRoot(),
      body: run,
    );
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
    final attempt = _restoreAttempt(restoreRoot, transactionId);
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
    }
    return _RestoreOwnership(
      sourceRecord: sourceRecord,
      targetRecord: targetRecord,
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
        _io.fs.path.join(context.stateRoot(scope), 'installations.json'),
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
      final scopeContext = scope == context.scope
          ? context
          : LifecycleContext.resolve(
              context.options.copyWith(scope: scope),
              fileSystem: _io.fs,
            );
      records[scope] = _state.records(scopeContext);
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
    final sourceRecord = evidence.sourceRecord;
    if (sourceRecord != null) {
      final record = InstallationRecord.fromJson(sourceRecord);
      final scope = LifecycleScope.values.byName(record.scope.name);
      restored[scope] = record.copyWith(
        lifecycle: 'live',
        origin: <String, Object?>{
          ...record.origin,
          'restoredFromConversionTransaction': original.transactionId,
          'conversionRestoredBy': evidence.restoreId,
        },
      );
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
    final peer = _peerScope(context, evidence);
    if (peer == null) return;
    _state.writeProtectedDocument(
      _io.fs.path.join(
        _restoreRootOf(context.stateRoot(peer)),
        '${evidence.restoreId}.json',
      ),
      utf8.encode(evidence.copyWith(participantMarker: true).encode()),
    );
  }

  /// The scope that does not coordinate the inverse restore.
  LifecycleScope? _peerScope(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    for (final scope in <LifecycleScope>{
      LifecycleScope.values.byName(evidence.sourceScope),
      LifecycleScope.values.byName(evidence.targetScope),
    }) {
      if (scope != context.scope) return scope;
    }
    return null;
  }

  /// Verifies the participant marker of the other scope.
  ///
  /// A missing or changed marker is missing authority: the inverse restore is
  /// refused instead of continuing with a half reserved participant.
  void _verifyParticipantMarker(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    final peer = _peerScope(context, evidence);
    if (peer == null) return;
    final path = _io.fs.path.join(
      _restoreRootOf(context.stateRoot(peer)),
      '${evidence.restoreId}.json',
    );
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException(
        'The inverse restore participant authority is missing.',
        exitCode: 6,
      );
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
        marker.phase != expected.phase) {
      throw MambaException(
        'The inverse restore participant authority changed.',
        exitCode: 6,
      );
    }
  }

  void _markRecoveryRequired(
    LifecycleContext context,
    ConversionRestoreEvidence evidence,
  ) {
    try {
      _persist(
        context,
        evidence.copyWith(phase: ConversionRestorePhase.recoveryRequired),
      );
    } on Exception {
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
}

/// The ownership observations of one reviewed inverse restore.
final class _RestoreOwnership {
  const _RestoreOwnership({this.sourceRecord, this.targetRecord});

  final Map<String, Object?>? sourceRecord;
  final Map<String, Object?>? targetRecord;
}
