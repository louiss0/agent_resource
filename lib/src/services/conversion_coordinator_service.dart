import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';

import '../conversion/conversion_evidence.dart';
import 'conversion_evidence_service.dart';
import 'lifecycle_state_service.dart';

/// The largest source file that is read for a manifest.
const int maxConversionSourceFileBytes = 64 * 1024 * 1024;

/// The largest number of entries of a source manifest.
const int maxConversionSourceEntries = 10000;

/// The largest depth of a source manifest.
const int maxConversionSourceDepth = 32;

/// The requested coordinated transition of one conversion.
final class ConversionTransitionRequest {
  const ConversionTransitionRequest({
    required this.transactionId,
    required this.options,
    required this.source,
    required this.target,
    required this.targetFiles,
    this.approvals = const <String, bool>{},
    this.observations = const <String, Object?>{},
  });

  final String transactionId;
  final LifecycleOptions options;

  /// The intended source participant and its ownership before.
  final ConversionParticipant source;

  /// The intended target participant and its ownership after.
  final ConversionParticipant target;

  /// The proposed native target files, keyed by their relative path.
  final Map<String, List<int>> targetFiles;

  final Map<String, bool> approvals;
  final Map<String, Object?> observations;
}

/// The outcome of one coordinated transition.
final class ConversionTransitionOutcome {
  const ConversionTransitionOutcome({
    required this.transactionId,
    required this.phase,
    required this.succeeded,
    required this.committed,
    required this.reconciled,
    required this.sourceLocation,
    required this.targetLocation,
    required this.diagnostics,
    this.recoveryPayloadPath,
  });

  final String transactionId;
  final ConversionEvidencePhase phase;

  /// Whether the transition completed its target and records.
  final bool succeeded;

  final bool committed;
  final bool reconciled;
  final String? sourceLocation;
  final String? targetLocation;

  /// The retained independent recovery payload of the source.
  final String? recoveryPayloadPath;

  final List<Map<String, Object?>> diagnostics;
}

/// The coordinated transition engine of one conversion.
///
/// The engine runs the prepare, publish, commit, reconcile and cleanup phases
/// over an injected filesystem seam. It publishes a native target, retains an
/// independent recovery payload, records one protected commit decision and
/// materializes the coordinated ownership records.
///
/// The engine authorizes no public apply: it is an internal transition used by
/// the later publication and recovery frontends.
interface class ConversionCoordinator {
  ConversionCoordinator({
    required LifecycleIO io,
    required this.state,
    ConversionEvidenceService? evidence,
  }) : _io = io,
       _evidence = evidence ?? ConversionEvidenceService(fileSystem: io.fs);

  final LifecycleIO _io;

  /// The ownership authority of the transition.
  final LifecycleStateService state;

  final ConversionEvidenceService _evidence;

  /// Runs the coordinated transition.
  Future<ConversionTransitionOutcome> execute(
    ConversionTransitionRequest request,
  ) {
    final context = LifecycleContext.resolve(
      request.options,
      fileSystem: _io.fs,
    );
    return state.runCoordinated(
      context: context,
      location: request.target.location,
      body: () => _execute(context, request),
    );
  }

  /// Reconstructs and concludes a persisted coordinated transition.
  ///
  /// This is an internal recovery seam. Public recovery inspection and apply
  /// remain separate delivery work.
  Future<ConversionTransitionOutcome> resume({
    required LifecycleOptions options,
    required String transactionId,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _io.fs);
    final initial = await _evidence.readPersisted(
      context.stateRoot(),
      transactionId,
    );
    if (initial == null) {
      throw MambaException(
        'No conversion evidence exists for $transactionId.',
        exitCode: 4,
      );
    }
    return state.runCoordinated(
      context: context,
      location: initial.target.location,
      body: () => _resume(context, options, transactionId),
    );
  }

  Future<ConversionTransitionOutcome> _resume(
    LifecycleContext context,
    LifecycleOptions options,
    String transactionId,
  ) async {
    final stateRoot = context.stateRoot();
    final evidence = await _evidence.readPersisted(stateRoot, transactionId);
    if (evidence == null) {
      throw MambaException(
        'No conversion evidence exists for $transactionId.',
        exitCode: 4,
      );
    }
    if (evidence.phase == ConversionEvidencePhase.completed ||
        evidence.phase == ConversionEvidencePhase.rolledBack) {
      throw MambaException(
        'The conversion transaction is already terminal.',
        exitCode: 4,
      );
    }
    final staging = _io.fs.path.join(
      _evidence.evidenceDirectory(stateRoot),
      transactionId,
    );
    final commitPath = _io.fs.path.join(staging, 'commit.json');
    final committed =
        _io.type(commitPath, followLinks: false) == FileSystemEntityType.file;
    try {
      if (!committed) {
        _rollbackPersisted(evidence, staging);
        final rolledBack = evidence.withPhase(
          ConversionEvidencePhase.rolledBack,
        );
        _persistEvidence(stateRoot, rolledBack);
        return _outcome(
          rolledBack,
          succeeded: false,
          committed: false,
          reconciled: false,
        );
      }

      _verifyCommitDecision(commitPath, evidence);
      final payload = evidence.source.payload;
      final publication = evidence.target.publication;
      if (payload == null || publication == null || !publication.verified) {
        throw MambaException(
          'Committed conversion evidence is incomplete.',
          exitCode: 6,
        );
      }
      if (_manifestDigest(payload.path) != payload.digest ||
          _manifestDigest(publication.path) != publication.digest) {
        throw MambaException(
          'Committed conversion recovery evidence changed.',
          exitCode: 6,
        );
      }
      final request = ConversionTransitionRequest(
        transactionId: transactionId,
        options: options,
        source: evidence.source,
        target: evidence.target,
        targetFiles: const <String, List<int>>{},
        approvals: evidence.approvals,
        observations: evidence.observations,
      );
      await _reconcile(context, request, evidence);
      var current = evidence.withPhase(ConversionEvidencePhase.reconciled);
      _persistEvidence(stateRoot, current);
      _cleanup(staging, keepPayload: true);
      current = current.withPhase(ConversionEvidencePhase.completed);
      _persistEvidence(stateRoot, current);
      return _outcome(
        current,
        succeeded: true,
        committed: true,
        reconciled: true,
      );
    } on Exception catch (error) {
      _markRecoveryRequired(stateRoot, transactionId);
      throw MambaException(
        'The conversion needs recovery: $error',
        exitCode: 6,
      );
    }
  }

  Future<ConversionTransitionOutcome> _execute(
    LifecycleContext context,
    ConversionTransitionRequest request,
  ) async {
    final source = request.source;
    final target = request.target;
    final inPlace = source.location == target.location;
    final stateRoot = context.stateRoot();
    final staging = _io.fs.path.join(
      _evidence.evidenceDirectory(stateRoot),
      request.transactionId,
    );
    final payloadRoot = _io.fs.path.join(staging, 'source-payload');
    final payloadPath = _payloadPath(source, payloadRoot);
    final stagedTargetRoot = _io.fs.path.join(staging, 'target');
    final stagedTargetPath = _stagedTargetPath(target, stagedTargetRoot);
    final quarantinePath = _io.fs.path.join(staging, 'quarantine');
    final commitPath = _io.fs.path.join(staging, 'commit.json');
    final diagnostics = <Map<String, Object?>>[];

    // The review of the proposal happens before any durable effect, so a
    // refusal never leaves a staged artifact behind.
    _verifySourceUnchanged(source);
    _verifyTargetAvailable(source, target);
    final decision = _evidence.decideIdentity(source: source, target: target);
    if (!decision.allowed) {
      throw MambaException(decision.refusal!, exitCode: 4);
    }
    _verifyTargetFiles(target, request.targetFiles);
    _verifyOwnership(context, request);

    var committed = false;
    var reconciled = false;
    var quarantined = false;
    var published = false;
    ConversionEvidence? currentEvidence;

    try {
      // Prepare: stage and independently verify both payloads before an intent
      // document can authorize publication.
      _io.createDirectory(staging);
      state.protectDirectory(staging);
      _copySource(source.location, payloadPath);
      final payloadDigest = _manifestDigest(payloadPath);
      if (payloadDigest != source.baseline!.digest) {
        throw MambaException(
          'The independent source payload does not match the reviewed source.',
          exitCode: 4,
        );
      }
      _writeTargetFiles(stagedTargetRoot, request.targetFiles);
      final targetDigest = _targetDigest(request.targetFiles);
      if (_manifestDigest(stagedTargetPath) != targetDigest) {
        throw MambaException(
          'The staged target does not match the reviewed proposal.',
          exitCode: 4,
        );
      }
      final preparedSource = source.copyWith(
        payload: ConversionPayloadReference(
          path: payloadPath,
          digest: payloadDigest,
          length: _payloadLength(payloadPath),
        ),
      );
      final preparedTarget = target.copyWith(
        staging: ConversionPublicationEvidence(
          path: stagedTargetPath,
          digest: targetDigest,
          verified: true,
        ),
      );
      currentEvidence = _evidence.prepare(
        transactionId: request.transactionId,
        source: preparedSource,
        target: preparedTarget,
        allocatedInstallationId: decision.allocatesTargetId
            ? state.newInstallationId()
            : null,
        approvals: request.approvals,
        observations: request.observations,
      );
      _persistEvidence(stateRoot, currentEvidence);

      // Recheck the reviewed observations at the live-mutation boundary.
      _verifySourceUnchanged(source);
      _verifyTargetAvailable(source, target);

      // Publish: a same-location replacement quarantines the source instead
      // of deleting it. A moved output keeps the source live.
      if (inPlace) {
        _io.rename(source.location, quarantinePath);
        quarantined = true;
      }
      _publishTarget(target, request.targetFiles);
      published = true;
      _verifyPublishedTarget(target, request.targetFiles);
      currentEvidence = currentEvidence.copyWith(
        phase: ConversionEvidencePhase.published,
        target: currentEvidence.target.copyWith(
          publication: ConversionPublicationEvidence(
            path: target.location,
            digest: targetDigest,
            verified: true,
          ),
        ),
      );
      _persistEvidence(stateRoot, currentEvidence);

      // Commit: one protected decision binds the reviewed source, independent
      // payload, verified target and resolved participants.
      _writeCommitDecision(
        commitPath,
        request: request,
        sourceDigest: source.baseline!.digest,
        targetDigest: targetDigest,
        payloadDigest: payloadDigest,
      );
      committed = true;
      currentEvidence = currentEvidence.withPhase(
        ConversionEvidencePhase.committed,
      );
      _persistEvidence(stateRoot, currentEvidence);

      // Reconcile: materialize the target record and retire the source.
      await _reconcile(context, request, currentEvidence);
      reconciled = true;
      currentEvidence = currentEvidence.withPhase(
        ConversionEvidencePhase.reconciled,
      );
      _persistEvidence(stateRoot, currentEvidence);

      // Cleanup retains the independent source payload as completed recovery
      // evidence and removes only private staging/quarantine entries.
      _cleanup(staging, keepPayload: true);
      currentEvidence = currentEvidence.withPhase(
        ConversionEvidencePhase.completed,
      );
      _persistEvidence(stateRoot, currentEvidence);
      return ConversionTransitionOutcome(
        transactionId: request.transactionId,
        phase: ConversionEvidencePhase.completed,
        succeeded: true,
        committed: true,
        reconciled: true,
        sourceLocation: source.location,
        targetLocation: target.location,
        recoveryPayloadPath: payloadPath,
        diagnostics: List<Map<String, Object?>>.unmodifiable(diagnostics),
      );
    } on Exception catch (error) {
      if (committed) {
        try {
          if (!reconciled) {
            await _reconcile(context, request, currentEvidence!);
            reconciled = true;
          }
          currentEvidence = currentEvidence!.withPhase(
            ConversionEvidencePhase.reconciled,
          );
          _persistEvidence(stateRoot, currentEvidence);
          _cleanup(staging, keepPayload: true);
          currentEvidence = currentEvidence.withPhase(
            ConversionEvidencePhase.completed,
          );
          _persistEvidence(stateRoot, currentEvidence);
          return ConversionTransitionOutcome(
            transactionId: request.transactionId,
            phase: ConversionEvidencePhase.completed,
            succeeded: true,
            committed: true,
            reconciled: true,
            sourceLocation: source.location,
            targetLocation: target.location,
            recoveryPayloadPath: payloadPath,
            diagnostics: List<Map<String, Object?>>.unmodifiable(diagnostics),
          );
        } on Exception catch (forwardError) {
          _markRecoveryRequired(stateRoot, request.transactionId);
          throw MambaException(
            'The conversion is committed and needs recovery: $forwardError',
            exitCode: 6,
          );
        }
      }
      try {
        if (published && !inPlace) {
          _removePublishedTarget(target, request.targetFiles);
        }
        if (quarantined) {
          _io.rename(quarantinePath, source.location);
        }
        _cleanup(staging, keepPayload: false);
        if (currentEvidence != null) {
          currentEvidence = currentEvidence.withPhase(
            ConversionEvidencePhase.rolledBack,
          );
          _persistEvidence(stateRoot, currentEvidence);
        }
        return ConversionTransitionOutcome(
          transactionId: request.transactionId,
          phase: ConversionEvidencePhase.rolledBack,
          succeeded: false,
          committed: false,
          reconciled: false,
          sourceLocation: source.location,
          targetLocation: target.location,
          diagnostics: List<Map<String, Object?>>.unmodifiable(diagnostics),
        );
      } on Exception catch (rollbackError) {
        _markRecoveryRequired(stateRoot, request.transactionId);
        throw MambaException(
          'The conversion failed and needs recovery: $error; '
          'the rollback failed: $rollbackError',
          exitCode: 6,
        );
      }
    }
  }

  ConversionTransitionOutcome _outcome(
    ConversionEvidence evidence, {
    required bool succeeded,
    required bool committed,
    required bool reconciled,
  }) => ConversionTransitionOutcome(
    transactionId: evidence.transactionId,
    phase: evidence.phase,
    succeeded: succeeded,
    committed: committed,
    reconciled: reconciled,
    sourceLocation: evidence.source.location,
    targetLocation: evidence.target.location,
    recoveryPayloadPath: succeeded ? evidence.source.payload?.path : null,
    diagnostics: const <Map<String, Object?>>[],
  );

  void _rollbackPersisted(ConversionEvidence evidence, String staging) {
    final target = evidence.target;
    final publication = target.publication;
    final inPlace = evidence.source.location == target.location;
    final quarantine = _io.fs.path.join(staging, 'quarantine');
    final quarantineExists =
        _io.type(quarantine, followLinks: false) !=
        FileSystemEntityType.notFound;
    final targetType = _io.type(target.location, followLinks: false);
    final publicationAttempted =
        publication != null ||
        (!inPlace && targetType != FileSystemEntityType.notFound) ||
        (inPlace && quarantineExists);
    if (publicationAttempted && targetType != FileSystemEntityType.notFound) {
      final expectedDigest = publication?.digest ?? target.staging?.digest;
      if (expectedDigest == null ||
          _manifestDigest(target.location) != expectedDigest) {
        throw MambaException(
          'The uncommitted published target cannot be safely removed.',
          exitCode: 6,
        );
      }
      _io.delete(target.location);
    } else if (publicationAttempted && !inPlace) {
      throw MambaException(
        'The uncommitted published target is missing.',
        exitCode: 6,
      );
    }
    if (inPlace) {
      if (_io.type(quarantine, followLinks: false) !=
          FileSystemEntityType.notFound) {
        if (_io.type(evidence.source.location, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw MambaException(
            'The original conversion location is occupied.',
            exitCode: 6,
          );
        }
        _io.rename(quarantine, evidence.source.location);
      }
    }
    _cleanup(staging, keepPayload: false);
  }

  void _verifyCommitDecision(String path, ConversionEvidence evidence) {
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
    final source = decoded['source'];
    final target = decoded['target'];
    final payload = decoded['payload'];
    if (decoded['schemaVersion'] != 1 ||
        decoded['transactionId'] != evidence.transactionId ||
        decoded['decision'] != 'commit' ||
        digest != expected ||
        source is! Map<String, Object?> ||
        target is! Map<String, Object?> ||
        payload is! Map<String, Object?> ||
        source['location'] != evidence.source.location ||
        source['digest'] != evidence.source.baseline?.digest ||
        target['location'] != evidence.target.location ||
        target['digest'] != evidence.target.publication?.digest ||
        payload['digest'] != evidence.source.payload?.digest) {
      throw MambaException(
        'The conversion commit decision does not bind the evidence.',
        exitCode: 6,
      );
    }
  }

  /// Reconciles the ownership records of the transition.
  Future<void> _reconcile(
    LifecycleContext context,
    ConversionTransitionRequest request,
    ConversionEvidence evidence,
  ) async {
    final target = evidence.target;
    final source = evidence.source;
    final targetOwnership = target.ownershipAfter;
    final sourceOwnership = source.ownershipBefore;
    if (targetOwnership == null || !targetOwnership.managed) {
      // An unmanaged authoring output owns no installation record.
      return;
    }
    if (targetOwnership.scope != context.scope.name) {
      throw MambaException(
        'The target scope does not agree with the selected scope.',
        exitCode: 4,
      );
    }
    final installationId = target.identity?.installationId;
    if (installationId == null) {
      throw MambaException(
        'The reconciled target requires an installation identifier.',
        exitCode: 4,
      );
    }
    final record = InstallationRecord(
      installationId: installationId,
      kind: ArtifactKind.values.firstWhere(
        (kind) => kind.wireName == target.artifactKind,
      ),
      scope: LifecycleScope.values.firstWhere(
        (scope) => scope.name == targetOwnership.scope,
      ),
      nativeDestination: targetOwnership.nativeForm,
      nativeForm: targetOwnership.nativeForm,
      location: target.location,
      nativeRoot: targetOwnership.nativeRoot ?? target.location,
      name: _io.fs.path.basename(target.location),
      nativeProfile: targetOwnership.nativeProfile,
      validatedProfiles: <String>[
        if (targetOwnership.nativeProfile != null)
          targetOwnership.nativeProfile!,
      ],
      knownConsumers: <String>[
        if (targetOwnership.nativeProfile != null)
          targetOwnership.nativeProfile!,
      ],
      baseline: state.baselineFor(
        target.location,
        ArtifactKind.values.firstWhere(
          (kind) => kind.wireName == target.artifactKind,
        ),
      ),
      lifecycle: 'live',
      origin: <String, Object?>{
        'status': 'unknown',
        'conversionTransactionId': request.transactionId,
        if (target.identity?.convertedFromId != null)
          'convertedFromInstallationId': target.identity!.convertedFromId,
        if (target.identity?.lineageId != null)
          'conversionLineageId': target.identity!.lineageId,
        if (target.membershipAfter != null)
          'conversionMembership': target.membershipAfter!.toJson(),
      },
      backupIds: const <String>[],
      transactionId: null,
    );
    InstallationRecord? retired;
    LifecycleScope? retiredScope;
    if (sourceOwnership != null && sourceOwnership.managed) {
      final sourceScope = LifecycleScope.values.firstWhere(
        (scope) => scope.name == sourceOwnership.scope,
      );
      final sourceContext = sourceScope == context.scope
          ? context
          : LifecycleContext.resolve(
              request.options.copyWith(scope: sourceScope),
              fileSystem: _io.fs,
            );
      final existing = state.recordById(
        sourceContext,
        sourceOwnership.installationId!,
      );
      retired = existing.copyWith(
        lifecycle: 'removed',
        origin: <String, Object?>{
          ...existing.origin,
          'conversionTransactionId': request.transactionId,
          if (source.membershipAfter != null)
            'conversionMembership': source.membershipAfter!.toJson(),
        },
      );
      retiredScope = sourceScope;
    }
    await state.applyCoordinatedTransition(
      context: context,
      target: record,
      retiredSource: retired,
      retiredSourceScope: retiredScope,
    );
  }

  void _verifyOwnership(
    LifecycleContext context,
    ConversionTransitionRequest request,
  ) {
    final source = request.source;
    final sourceOwnership = source.ownershipBefore;
    if (sourceOwnership?.managed == true) {
      final sourceScope = LifecycleScope.values.firstWhere(
        (scope) => scope.name == sourceOwnership!.scope,
      );
      final sourceContext = sourceScope == context.scope
          ? context
          : LifecycleContext.resolve(
              request.options.copyWith(scope: sourceScope),
              fileSystem: _io.fs,
            );
      final record = state.recordById(
        sourceContext,
        sourceOwnership!.installationId!,
      );
      final expectedKind = ArtifactKind.values.firstWhere(
        (kind) => kind.wireName == source.artifactKind,
      );
      final expectedRoot = sourceOwnership.nativeRoot;
      if (record.lifecycle != 'live' ||
          expectedRoot == null ||
          !_io.fs.path.equals(record.location, source.location) ||
          !_io.fs.path.equals(record.nativeRoot, expectedRoot) ||
          record.kind != expectedKind ||
          record.nativeForm != sourceOwnership.nativeForm ||
          record.scope != sourceScope) {
        throw MambaException(
          'The reviewed source ownership does not match the installation ledger.',
          exitCode: 4,
        );
      }
    }

    for (final scope in const <LifecycleScope>[
      LifecycleScope.project,
      LifecycleScope.user,
    ]) {
      final LifecycleContext scopeContext;
      try {
        scopeContext = scope == context.scope
            ? context
            : LifecycleContext.resolve(
                request.options.copyWith(scope: scope),
                fileSystem: _io.fs,
              );
      } on MambaException {
        continue;
      }
      for (final record in state.records(scopeContext)) {
        if (record.lifecycle != 'live' ||
            !_io.fs.path.equals(record.location, request.target.location)) {
          continue;
        }
        final sourceId = sourceOwnership?.installationId;
        final sameInPlaceSource =
            _io.fs.path.equals(source.location, request.target.location) &&
            record.installationId == sourceId;
        if (!sameInPlaceSource) {
          throw MambaException(
            'Another scope already owns the conversion target location.',
            exitCode: 4,
          );
        }
      }
    }
  }

  void _verifySourceUnchanged(ConversionParticipant source) {
    final baseline = source.baseline;
    if (baseline == null) {
      throw MambaException(
        'The conversion source requires a reviewed baseline.',
        exitCode: 4,
      );
    }
    final digest = _manifestDigest(source.location);
    if (digest != baseline.digest) {
      throw MambaException(
        'The source changed since the reviewed plan.',
        exitCode: 4,
      );
    }
  }

  void _verifyTargetAvailable(
    ConversionParticipant source,
    ConversionParticipant target,
  ) {
    if (_io.fs.path.equals(source.location, target.location)) return;
    if (_io.type(target.location, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw MambaException(
        'The conversion target location is already occupied.',
        exitCode: 4,
      );
    }
  }

  void _verifyPublishedTarget(
    ConversionParticipant target,
    Map<String, List<int>> files,
  ) {
    final digest = _targetDigest(files);
    final published = _manifestDigest(target.location);
    if (digest != published) {
      throw MambaException(
        'The published target does not match the reviewed proposal.',
        exitCode: 4,
      );
    }
  }

  void _writeTargetFiles(String root, Map<String, List<int>> files) {
    for (final entry in files.entries) {
      final path = _io.fs.path.join(root, entry.key);
      final directory = _io.fs.path.dirname(path);
      _io.createDirectory(directory);
      _io.write(path, entry.value);
    }
  }

  String _payloadPath(ConversionParticipant source, String payloadRoot) {
    final type = _io.type(source.location, followLinks: false);
    return type == FileSystemEntityType.file
        ? _io.fs.path.join(payloadRoot, _io.fs.path.basename(source.location))
        : payloadRoot;
  }

  String _stagedTargetPath(
    ConversionParticipant target,
    String stagedTargetRoot,
  ) => _isDirectoryTarget(target)
      ? stagedTargetRoot
      : _io.fs.path.join(
          stagedTargetRoot,
          _io.fs.path.basename(target.location),
        );

  int _payloadLength(String path) {
    final entries = conversionManifestEntries(_io, path);
    return entries.fold<int>(
      0,
      (total, entry) => total + (entry['length']! as int),
    );
  }

  void _persistEvidence(String stateRoot, ConversionEvidence evidence) {
    state.writeProtectedDocument(
      _evidence.evidencePath(stateRoot, evidence.transactionId),
      utf8.encode(evidence.encode()),
    );
  }

  /// Whether the target location holds a directory of native files.
  bool _isDirectoryTarget(ConversionParticipant target) =>
      target.artifactKind == 'skill-copy' ||
      target.artifactKind == 'skill-canonical';

  /// Checks that the proposed files match the native form of the target.
  void _verifyTargetFiles(
    ConversionParticipant target,
    Map<String, List<int>> files,
  ) {
    if (files.isEmpty) {
      throw MambaException(
        'The conversion requires a proposed native target.',
        exitCode: 4,
      );
    }
    _targetManifestEntries(files);
    if (target.artifactKind == 'skill-link') {
      throw MambaException(
        'Linked Skill conversion publication is not supported by this coordinator.',
        exitCode: 4,
      );
    }
    if (_isDirectoryTarget(target)) return;
    if (files.length != 1) {
      throw MambaException(
        'The native target form accepts exactly one file.',
        exitCode: 4,
      );
    }
    final name = _io.fs.path.basename(target.location);
    if (files.keys.single != name) {
      throw MambaException(
        'The proposed file name must match the native target location.',
        exitCode: 4,
      );
    }
  }

  /// Publishes the proposed native target at its location.
  void _publishTarget(
    ConversionParticipant target,
    Map<String, List<int>> files,
  ) {
    if (_isDirectoryTarget(target)) {
      _writeTargetFiles(target.location, files);
      return;
    }
    final entry = files.entries.single;
    _io.createDirectory(_io.fs.path.dirname(target.location));
    _io.write(target.location, entry.value);
  }

  void _copySource(String source, String destination) {
    final type = _io.type(source, followLinks: false);
    if (type == FileSystemEntityType.file) {
      _io.createDirectory(_io.fs.path.dirname(destination));
      _io.copyFile(source, destination);
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw MambaException(
        'The source is not a regular file or directory.',
        exitCode: 4,
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
            'The source contains an unsupported entry: ${entry.path}',
            exitCode: 4,
          );
        }
      }
    }

    copy(source, destination);
  }

  void _removePublishedTarget(
    ConversionParticipant target,
    Map<String, List<int>> files,
  ) {
    if (_io.type(target.location, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    _verifyPublishedTarget(target, files);
    _io.delete(target.location);
  }

  void _cleanup(String staging, {required bool keepPayload}) {
    final payloadRoot = _io.fs.path.join(staging, 'source-payload');
    if (!keepPayload &&
        _io.type(payloadRoot, followLinks: false) !=
            FileSystemEntityType.notFound) {
      _io.delete(payloadRoot);
    }
    final target = _io.fs.path.join(staging, 'target');
    if (_io.type(target, followLinks: false) != FileSystemEntityType.notFound) {
      _io.delete(target);
    }
    final quarantine = _io.fs.path.join(staging, 'quarantine');
    if (_io.type(quarantine, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _io.delete(quarantine);
    }
  }

  void _writeCommitDecision(
    String path, {
    required ConversionTransitionRequest request,
    required String sourceDigest,
    required String targetDigest,
    required String payloadDigest,
  }) {
    final body = <String, Object?>{
      'schemaVersion': 1,
      'transactionId': request.transactionId,
      'decision': 'commit',
      'source': <String, Object?>{
        'location': request.source.location,
        'digest': sourceDigest,
      },
      'target': <String, Object?>{
        'location': request.target.location,
        'digest': targetDigest,
      },
      'payload': <String, Object?>{'digest': payloadDigest},
    };
    final decision = <String, Object?>{
      ...body,
      'digest': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
    };
    state.writeProtectedDocument(path, utf8.encode(jsonEncode(decision)));
  }

  void _markRecoveryRequired(String stateRoot, String transactionId) {
    try {
      final path = _evidence.evidencePath(stateRoot, transactionId);
      final type = _io.type(path, followLinks: false);
      if (type != FileSystemEntityType.file) return;
      final bytes = _io.read(path, maxConversionEvidenceBytes);
      final evidence = ConversionEvidence.decode(utf8.decode(bytes));
      _persistEvidence(
        stateRoot,
        evidence.withPhase(ConversionEvidencePhase.recoveryRequired),
      );
    } on Exception {
      // The recovery evidence stays as it is; the refusal is reported by the
      // caller and the pending operation remains guarded.
    }
  }

  String _targetDigest(Map<String, List<int>> files) =>
      conversionManifestDigest(_targetManifestEntries(files));

  List<Map<String, Object?>> _targetManifestEntries(
    Map<String, List<int>> files,
  ) {
    final entries = <Map<String, Object?>>[];
    final directories = <String>{};
    for (final entry in files.entries) {
      final normalized = entry.key.replaceAll('\\', '/');
      final segments = normalized.split('/');
      if (normalized.isEmpty ||
          normalized.startsWith('/') ||
          RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
          segments.any(
            (segment) => segment.isEmpty || segment == '.' || segment == '..',
          )) {
        throw MambaException(
          'A proposed target file must use a safe relative path.',
          exitCode: 4,
        );
      }
      for (var index = 1; index < segments.length; index++) {
        directories.add(segments.take(index).join('/'));
      }
      entries.add(<String, Object?>{
        'path': normalized,
        'type': 'file',
        'length': entry.value.length,
        'sha256': sha256.convert(entry.value).toString(),
      });
    }
    entries.addAll(<Map<String, Object?>>[
      for (final directory in directories)
        <String, Object?>{
          'path': directory,
          'type': 'directory',
          'length': 0,
          'sha256': null,
        },
    ]);
    entries.sort(
      (left, right) =>
          (left['path']! as String).compareTo(right['path']! as String),
    );
    return entries;
  }

  String _manifestDigest(String path) =>
      conversionManifestDigest(conversionManifestEntries(_io, path));
}

/// The verified manifest entries of one source artifact.
///
/// The entries bind the relative path, the type, the length and the content
/// digest of every entry. The listing is bounded and never follows a link.
List<Map<String, Object?>> conversionManifestEntries(
  LifecycleIO io,
  String path,
) {
  final type = io.type(path, followLinks: false);
  if (type == FileSystemEntityType.file) {
    final bytes = io.read(path, maxConversionSourceFileBytes);
    return <Map<String, Object?>>[
      <String, Object?>{
        'path': io.fs.path.basename(path),
        'type': 'file',
        'length': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      },
    ];
  }
  if (type != FileSystemEntityType.directory) {
    throw MambaException(
      'The source is not a regular file or directory.',
      exitCode: 4,
    );
  }
  final entries = <Map<String, Object?>>[];
  void walk(String directory, String prefix, int depth) {
    if (depth > maxConversionSourceDepth) {
      throw MambaException(
        'The source exceeds the manifest depth limit.',
        exitCode: 3,
      );
    }
    for (final entry in io.list(directory)) {
      if (entries.length >= maxConversionSourceEntries) {
        throw MambaException(
          'The source exceeds the manifest entry limit.',
          exitCode: 3,
        );
      }
      final name = io.fs.path.basename(entry.path);
      final relative = prefix.isEmpty ? name : '$prefix/$name';
      final childType = io.type(entry.path, followLinks: false);
      if (childType == FileSystemEntityType.directory) {
        entries.add(<String, Object?>{
          'path': relative,
          'type': 'directory',
          'length': 0,
          'sha256': null,
        });
        walk(entry.path, relative, depth + 1);
      } else if (childType == FileSystemEntityType.file) {
        final bytes = io.read(entry.path, maxConversionSourceFileBytes);
        entries.add(<String, Object?>{
          'path': relative,
          'type': 'file',
          'length': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        });
      } else {
        throw MambaException(
          'The source contains an unsupported entry: ${entry.path}',
          exitCode: 4,
        );
      }
    }
  }

  walk(path, '', 0);
  entries.sort(
    (left, right) =>
        (left['path']! as String).compareTo(right['path']! as String),
  );
  return entries;
}

/// The digest that binds the manifest entries of one artifact.
String conversionManifestDigest(List<Map<String, Object?>> entries) =>
    sha256.convert(utf8.encode(jsonEncode(entries))).toString();
