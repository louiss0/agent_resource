import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';

import '../agent_inspection.dart';
import '../conversion/conversion_evidence.dart';
import '../skill_files.dart';
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
/// New publication remains an internal seam. The public recovery operations
/// require an exact current plan and explicit approval; they cannot authorize
/// new authoring/conversion publication or completed inverse restore.
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

  /// Inventories local authority and participant references without taking locks
  /// or creating state. Unreadable entries remain visible as unresolved.
  Future<LifecycleResult> inventory(LifecycleOptions options) async {
    final transactions = <Map<String, Object?>>[];
    for (final scope
        in options.scope == LifecycleScope.all
            ? const [LifecycleScope.project, LifecycleScope.user]
            : [options.scope]) {
      final context = LifecycleContext.resolve(
        options.copyWith(scope: scope),
        fileSystem: _io.fs,
      );
      for (final directory in [
        _evidence.evidenceDirectory(context.stateRoot()),
        _io.fs.path.join(context.stateRoot(), 'conversion-participants'),
      ]) {
        try {
          _verifyUnlinkedPath(directory);
          if (_io.type(directory, followLinks: false) ==
              FileSystemEntityType.notFound) {
            continue;
          }
          final ids = <String>{};
          final entries = _io.list(directory);
          if (entries.length > maxConversionSourceEntries) {
            throw MambaException(
              'Conversion inventory exceeds its entry limit.',
              exitCode: 3,
            );
          }
          for (final entry in entries) {
            final name = _io.fs.path.basename(entry.path);
            ids.add(
              name.endsWith('.json')
                  ? name.substring(0, name.length - 5)
                  : name,
            );
          }
          for (final id in ids.toList()..sort()) {
            try {
              _evidence.evidencePath(context.stateRoot(), id);
              final participant =
                  _io.fs.path.basename(directory) == 'conversion-participants';
              final evidence = participant
                  ? null
                  : await _readEvidence(context.stateRoot(), id);
              // Participant markers are discovery hints, never permission to
              // follow an arbitrary coordinator path or act in another project.
              if (participant) {
                final path = _io.fs.path.join(directory, '$id.json');
                _verifyUnlinkedPath(path);
                final marker = ConversionEvidence.decode(
                  utf8.decode(_io.read(path, maxConversionEvidenceBytes)),
                );
                if (marker.transactionId != id) {
                  throw const FormatException('Participant identity mismatch.');
                }
                transactions.add({
                  'transactionId': id,
                  'scope': scope.name,
                  'status': 'participant-reference',
                  'coordinatorScope': marker.createdScope,
                  'requiresCoordinatorContext': true,
                });
              } else {
                if (evidence == null) {
                  throw const FormatException('Missing coordinator evidence.');
                }
                final (_, review) = await _reviewRecovery(context, id);
                transactions.add({
                  'transactionId': id,
                  'scope': scope.name,
                  'status': evidence.phase.name,
                  'operation': evidence.operation,
                  'terminal': _terminal(evidence),
                  'cleanupStatus': review['cleanupStatus'],
                });
              }
            } on Exception catch (error) {
              transactions.add({
                'transactionId': id,
                'scope': scope.name,
                'status': 'unresolved',
                'reason': '$error',
              });
            }
          }
        } on Exception catch (error) {
          transactions.add({
            'scope': scope.name,
            'status': 'unresolved',
            'reason': '$error',
          });
        }
      }
    }
    return LifecycleResult(
      command: 'prompt conversion list',
      outcome: 'listed',
      data: {'transactions': transactions},
    );
  }

  /// Reviews exact current observations; it never resumes an operation.
  Future<LifecycleResult> inspectRecovery(
    LifecycleOptions options,
    String id,
  ) async {
    final context = LifecycleContext.resolve(options, fileSystem: _io.fs);
    final (_, data) = await _reviewRecovery(context, id);
    return LifecycleResult(
      command: 'prompt conversion inspect',
      outcome: 'reviewed',
      data: data,
    );
  }

  /// Requires a fresh read-only plan and explicit approval under coordination.
  Future<LifecycleResult> recoverReviewed(
    LifecycleOptions options,
    String id, {
    String? planId,
    String? action,
    Set<ArtifactKind>? editKinds,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _io.fs);
    Future<LifecycleResult> run() async {
      final (evidence, data) = await _reviewRecovery(context, id);
      if (editKinds != null &&
          (!editKinds.any(
                (kind) => kind.wireName == evidence.source.artifactKind,
              ) ||
              evidence.source.artifactKind != evidence.target.artifactKind ||
              evidence.source.nativeForm != evidence.target.nativeForm ||
              !_io.fs.path.equals(
                evidence.source.location,
                evidence.target.location,
              ))) {
        throw MambaException(
          'Use prompt conversion recover for a native conversion, not resource edit recovery.',
          exitCode: 4,
        );
      }
      if (action != null && action != data['action']) {
        throw MambaException(
          'Recovery direction is fixed by the protected coordinator decision.',
          exitCode: 4,
        );
      }
      if (_terminal(evidence)) {
        throw MambaException(
          'The conversion transaction is already terminal.',
          exitCode: 4,
        );
      }
      if (context.dryRun) {
        return LifecycleResult(
          command: 'prompt conversion recover',
          outcome: 'planned',
          data: data,
        );
      }
      _requireReview(context, planId, data['planId']);
      final outcome = await _resume(context, options, id);
      return LifecycleResult(
        command: 'prompt conversion recover',
        outcome: 'recovered',
        data: {
          ...data,
          'phase': outcome.phase.name,
          'originalOperationSucceeded': outcome.succeeded,
        },
      );
    }

    if (context.dryRun) return run();
    return state.runCoordinated(
      context: context,
      location: context.stateRoot(),
      body: run,
    );
  }

  /// Deletes only the verified private payload of a terminal transaction.
  /// The coordinator evidence and decision remain as audit/tombstone records.
  Future<LifecycleResult> cleanupReviewed(
    LifecycleOptions options,
    String id, {
    String? planId,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _io.fs);
    Future<LifecycleResult> run() async {
      final (evidence, data) = await _reviewRecovery(context, id);
      if (!_terminal(evidence)) {
        throw MambaException(
          'Unfinished conversion evidence cannot be cleaned.',
          exitCode: 6,
        );
      }
      final staging = _io.fs.path.join(
        _evidence.evidenceDirectory(context.stateRoot()),
        id,
      );
      final receipt = _io.fs.path.join(staging, 'cleanup.json');
      if (data['cleanupStatus'] == 'cleaned') {
        throw MambaException(
          'Conversion payloads are already cleaned.',
          exitCode: 4,
        );
      }
      state.checkPendingConversions(
        context,
        locations: [evidence.source.location, evidence.target.location],
        installationIds: {
          if (evidence.source.ownershipBefore?.installationId
              case final String id)
            id,
          if (evidence.target.identity?.installationId case final String id) id,
        },
      );
      final cleanupData = {
        ...data,
        'action': 'cleanup',
        'forfeitsPayloadRestore': evidence.source.payload != null,
      };
      cleanupData['planId'] = _reviewDigest(cleanupData);
      if (context.dryRun) {
        return LifecycleResult(
          command: 'prompt conversion cleanup',
          outcome: 'planned',
          data: cleanupData,
        );
      }
      _requireReview(context, planId, cleanupData['planId']);
      // Persist intent first. An interrupted cleanup can be reviewed again;
      // missing payload is authorized only by this bound receipt.
      _writeCleanupIntent(receipt, evidence);
      final payloadRoot = _io.fs.path.join(staging, 'source-payload');
      if (_io.type(payloadRoot, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _io.delete(payloadRoot);
      }
      return LifecycleResult(
        command: 'prompt conversion cleanup',
        outcome: 'cleaned',
        data: {...cleanupData, 'cleanupStatus': 'cleaned'},
      );
    }

    if (context.dryRun) return run();
    return state.runCoordinated(
      context: context,
      location: context.stateRoot(),
      body: run,
    );
  }

  void _requireReview(
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

  bool _terminal(ConversionEvidence evidence) =>
      evidence.phase == ConversionEvidencePhase.completed ||
      evidence.phase == ConversionEvidencePhase.rolledBack;

  void _writeCleanupIntent(String path, ConversionEvidence evidence) {
    state.writeProtectedDocument(
      path,
      utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'transactionId': evidence.transactionId,
          'evidenceDigest': evidence.digest,
          'decision': 'cleanup',
        }),
      ),
    );
  }

  String _reviewDigest(Map<String, Object?> data) =>
      sha256.convert(utf8.encode(jsonEncode(data))).toString();

  Future<(ConversionEvidence, Map<String, Object?>)> _reviewRecovery(
    LifecycleContext context,
    String id,
  ) async {
    final evidence = await _readEvidence(context.stateRoot(), id);
    if (evidence == null) {
      throw MambaException(
        'No conversion evidence exists for $id.',
        exitCode: 4,
      );
    }
    _verifyRecoveryAuthority(context, evidence, id);
    _checkPendingRecoveryConflicts(context, evidence, id);
    final staging = _io.fs.path.join(
      _evidence.evidenceDirectory(context.stateRoot()),
      id,
    );
    final commit = _io.fs.path.join(staging, 'commit.json');
    final cleanup = _io.fs.path.join(staging, 'cleanup.json');
    final hasCleanup =
        _io.type(cleanup, followLinks: false) != FileSystemEntityType.notFound;
    if (hasCleanup) {
      final receipt = jsonDecode(
        utf8.decode(_io.read(cleanup, maxConversionEvidenceBytes)),
      );
      if (!_terminal(evidence) ||
          receipt is! Map ||
          receipt['schemaVersion'] != 1 ||
          receipt['transactionId'] != id ||
          receipt['decision'] != 'cleanup' ||
          receipt['evidenceDigest'] != evidence.digest) {
        throw MambaException(
          'The cleanup receipt does not bind terminal evidence.',
          exitCode: 6,
        );
      }
    }
    final hasPayload =
        evidence.source.payload != null &&
        _io.type(evidence.source.payload!.path, followLinks: false) !=
            FileSystemEntityType.notFound;
    if (evidence.source.payload case final payload?) {
      final remaining = hasCleanup && hasPayload
          ? conversionManifestEntries(_io, payload.path)
          : null;
      final baseline = evidence.source.baseline;
      // The terminal receipt authorizes removal of the original manifest's
      // members. A recursive delete may stop between any two members. Missing
      // members are then permitted, but changed or added survivors never are.
      final validRemainder =
          remaining != null &&
          baseline?.digest == payload.digest &&
          remaining.every(
            (entry) => baseline!.entries.any(
              (original) => jsonEncode(entry) == jsonEncode(original),
            ),
          ) &&
          _io.type(payload.path, followLinks: false) ==
              (_isDirectoryTarget(evidence.source)
                  ? FileSystemEntityType.directory
                  : FileSystemEntityType.file);
      if ((!hasPayload &&
              !hasCleanup &&
              evidence.phase != ConversionEvidencePhase.rolledBack) ||
          (hasPayload &&
              (hasCleanup
                  ? !validRemainder
                  : _manifestDigest(payload.path) != payload.digest))) {
        throw MambaException(
          'The retained recovery payload is missing or changed.',
          exitCode: 6,
        );
      }
    }
    final commitType = _io.type(commit, followLinks: false);
    if (commitType != FileSystemEntityType.notFound &&
        commitType != FileSystemEntityType.file) {
      throw MambaException(
        'The conversion commit marker is not a file.',
        exitCode: 6,
      );
    }
    final committed = commitType == FileSystemEntityType.file;
    if (committed) _verifyCommitDecision(commit, evidence);
    if (evidence.phase == ConversionEvidencePhase.completed && !committed) {
      throw MambaException(
        'The completed conversion decision is missing.',
        exitCode: 6,
      );
    }
    if (evidence.phase == ConversionEvidencePhase.rolledBack && committed) {
      throw MambaException(
        'Rolled-back evidence contradicts the commit decision.',
        exitCode: 6,
      );
    }
    if (!_terminal(evidence) ||
        ((hasPayload || hasCleanup) &&
            evidence.phase == ConversionEvidencePhase.completed)) {
      if (committed) {
        await _reconcile(
          context,
          ConversionTransitionRequest(
            transactionId: id,
            options: context.options,
            source: evidence.source,
            target: evidence.target,
            targetFiles: const {},
          ),
          evidence,
          dryRun: true,
          verifyPayload: !hasCleanup,
        );
        final original =
            _io.fs.path.equals(
              evidence.source.location,
              evidence.target.location,
            )
            ? _io.fs.path.join(staging, 'quarantine')
            : evidence.source.location;
        if (_io.type(original, followLinks: false) !=
            FileSystemEntityType.notFound) {
          _verifyOriginalAt(evidence.source, original);
        } else if (evidence.observations['coordinatorSourceRemoval'] != true) {
          throw MambaException(
            'The original conversion source is missing.',
            exitCode: 6,
          );
        }
      } else {
        _verifyRollbackAuthority(context, evidence);
        _rollbackPersisted(evidence, staging, dryRun: true);
      }
    }
    final observations = <String, Object?>{};
    for (final path in <String>{
      evidence.source.location,
      evidence.target.location,
      staging,
      _evidence.evidencePath(context.stateRoot(), id),
      for (final scope in const [
        LifecycleScope.project,
        LifecycleScope.user,
      ]) ...[
        _io.fs.path.join(context.stateRoot(scope), 'installations.json'),
        _io.fs.path.join(
          context.stateRoot(scope),
          'conversion-participants',
          '$id.json',
        ),
      ],
    }) {
      _verifyUnlinkedPath(path);
      observations[path] =
          _io.type(path, followLinks: false) == FileSystemEntityType.notFound
          ? null
          : _manifestDigest(path);
    }
    final data = <String, Object?>{
      'transactionId': id,
      'scope': context.scope.name,
      'phase': evidence.phase.name,
      'operation': evidence.operation,
      'action': _terminal(evidence)
          ? null
          : (committed ? 'complete' : 'rollback'),
      'terminal': _terminal(evidence),
      'evidenceDigest': evidence.digest,
      'source': evidence.source.location,
      'target': evidence.target.location,
      'cleanupStatus': hasCleanup
          ? (_io.type(
                      _io.fs.path.join(staging, 'source-payload'),
                      followLinks: false,
                    ) !=
                    FileSystemEntityType.notFound
                ? 'pending'
                : 'cleaned')
          : 'retained',
      'observations': observations,
    };
    data['planId'] = _reviewDigest(data);
    return (evidence, data);
  }

  void _checkPendingRecoveryConflicts(
    LifecycleContext context,
    ConversionEvidence evidence,
    String id,
  ) {
    state.checkPendingConversions(
      context,
      locations: [evidence.source.location, evidence.target.location],
      validatedRecoveryPaths: {
        _evidence.evidencePath(context.stateRoot(), id),
        for (final scope in [LifecycleScope.project, LifecycleScope.user])
          if (!_io.fs.path.equals(
            context.stateRoot(scope),
            context.stateRoot(),
          ))
            _io.fs.path.join(
              context.stateRoot(scope),
              'conversion-participants',
              '$id.json',
            ),
      },
    );
  }

  List<String> _verifyRecoveryAuthority(
    LifecycleContext context,
    ConversionEvidence evidence,
    String id,
  ) {
    if (evidence.transactionId != id ||
        evidence.createdScope != context.scope.name ||
        jsonEncode(evidence.observations['coordinatorContext']) !=
            jsonEncode(_contextObservation(context))) {
      throw MambaException(
        'The conversion authority context or identity changed.',
        exitCode: 6,
      );
    }
    _verifyPaths(context, evidence.source, evidence.target);
    final staging = _io.fs.path.join(
      _evidence.evidenceDirectory(context.stateRoot()),
      id,
    );
    _verifyUnlinkedPath(staging);
    final expectedPayload = _isDirectoryTarget(evidence.source)
        ? _io.fs.path.join(staging, 'source-payload')
        : _io.fs.path.join(
            staging,
            'source-payload',
            _io.fs.path.basename(evidence.source.location),
          );
    final staged = _stagedTargetPath(
      evidence.target,
      _io.fs.path.join(staging, 'target'),
    );
    if ((evidence.source.payload != null &&
            !_io.fs.path.equals(
              evidence.source.payload!.path,
              expectedPayload,
            )) ||
        (evidence.target.staging != null &&
            !_io.fs.path.equals(evidence.target.staging!.path, staged)) ||
        (evidence.target.publication != null &&
            !_io.fs.path.equals(
              evidence.target.publication!.path,
              evidence.target.location,
            ))) {
      throw MambaException(
        'Conversion payload or publication paths were substituted.',
        exitCode: 6,
      );
    }
    if (_io.type(staging, followLinks: false) !=
        FileSystemEntityType.notFound) {
      // Reject links and unsupported entries before reading any private
      // decision, or recursively removing a payload directory.
      _manifestDigest(staging);
      for (final entry in _io.list(staging)) {
        final allowed = _terminal(evidence)
            ? {'source-payload', 'commit.json', 'cleanup.json'}
            : {
                'source-payload',
                'target',
                'quarantine',
                'commit.json',
                'initial-intent.json',
              };
        if (!allowed.contains(_io.fs.path.basename(entry.path))) {
          throw MambaException(
            'Unknown private conversion entry; cleanup is unsafe.',
            exitCode: 6,
          );
        }
      }
    }
    final payloadRoot = _io.fs.path.join(staging, 'source-payload');
    if (!_isDirectoryTarget(evidence.source) &&
        _io.type(payloadRoot, followLinks: false) !=
            FileSystemEntityType.notFound) {
      final entries = _io.list(payloadRoot);
      final cleaning =
          _terminal(evidence) &&
          _io.type(
                _io.fs.path.join(staging, 'cleanup.json'),
                followLinks: false,
              ) ==
              FileSystemEntityType.file;
      if ((entries.isEmpty && !cleaning && evidence.source.payload != null) ||
          entries.length > 1 ||
          (entries.isNotEmpty &&
              !_io.fs.path.equals(entries.single.path, expectedPayload))) {
        throw MambaException(
          'Unexpected recovery payload members; cleanup is unsafe.',
          exitCode: 6,
        );
      }
    }
    if (evidence.source.payload case final payload?) {
      if (!_terminal(evidence) &&
          _io.type(payload.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
        throw MambaException(
          'The retained recovery payload is missing or changed.',
          exitCode: 6,
        );
      }
    }
    return _verifyParticipantAuthority(context, evidence, id);
  }

  List<String> _verifyParticipantAuthority(
    LifecycleContext context,
    ConversionEvidence evidence,
    String id,
  ) {
    final staging = _io.fs.path.join(
      _evidence.evidenceDirectory(context.stateRoot()),
      id,
    );
    final expectedMarker = evidence.initialIntent;
    final missingMarkers = <String>[];
    for (final scope in const [LifecycleScope.project, LifecycleScope.user]) {
      final root = context.stateRoot(scope);
      final coordinatorScope = _io.fs.path.equals(root, context.stateRoot());
      final unexpected = coordinatorScope
          ? _io.fs.path.join(root, 'conversion-participants', '$id.json')
          : _evidence.evidencePath(root, id);
      _verifyUnlinkedPath(unexpected);
      if (_io.type(unexpected, followLinks: false) !=
              FileSystemEntityType.notFound ||
          (!coordinatorScope &&
              _io.type(
                    _io.fs.path.join(_evidence.evidenceDirectory(root), id),
                    followLinks: false,
                  ) !=
                  FileSystemEntityType.notFound)) {
        throw MambaException(
          'Unexpected duplicate conversion authority.',
          exitCode: 6,
        );
      }
      if (coordinatorScope) continue;
      final markerPath = _io.fs.path.join(
        root,
        'conversion-participants',
        '$id.json',
      );
      _verifyUnlinkedPath(markerPath);
      final markerType = _io.type(markerPath, followLinks: false);
      if (markerType == FileSystemEntityType.notFound &&
          context.scope == LifecycleScope.user &&
          evidence.digest == expectedMarker.digest &&
          _io.type(staging, followLinks: false) ==
              FileSystemEntityType.notFound) {
        // User authority is published first. Only pristine, unstaged intent
        // can precede its project marker; later missing authority stays blocked.
        missingMarkers.add(markerPath);
        continue;
      }
      if (markerType != FileSystemEntityType.file) {
        throw MambaException(
          'The conversion participant authority is missing.',
          exitCode: 6,
        );
      }
      late final ConversionEvidence marker;
      try {
        marker = ConversionEvidence.decode(
          utf8.decode(_io.read(markerPath, maxConversionEvidenceBytes)),
        );
      } on FormatException catch (error) {
        throw MambaException(
          'The conversion participant authority is invalid: $error',
          exitCode: 6,
        );
      }
      if (marker.digest != expectedMarker.digest) {
        throw MambaException(
          'The conversion participant authority changed.',
          exitCode: 6,
        );
      }
    }
    return missingMarkers;
  }

  /// Runs the coordinated transition.
  Future<ConversionTransitionOutcome> execute(
    ConversionTransitionRequest request,
  ) async {
    final context = LifecycleContext.resolve(
      request.options,
      fileSystem: _io.fs,
    );
    _verifyPaths(context, request.source, request.target);
    return state.runCoordinated(
      context: context,
      location: request.target.location,
      body: () => _execute(context, request),
    );
  }

  /// Reconstructs and concludes a persisted coordinated transition.
  ///
  /// This internal seam has no review UI. Public callers use [recoverReviewed].
  Future<ConversionTransitionOutcome> resume({
    required LifecycleOptions options,
    required String transactionId,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _io.fs);
    _verifyUnlinkedPath(context.stateRoot(LifecycleScope.project));
    _verifyUnlinkedPath(context.stateRoot(LifecycleScope.user));
    final initial = await _readEvidence(context.stateRoot(), transactionId);
    if (initial == null) {
      throw MambaException(
        'No conversion evidence exists for $transactionId.',
        exitCode: 4,
      );
    }
    _verifyPaths(context, initial.source, initial.target);
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
    final evidence = await _readEvidence(stateRoot, transactionId);
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
    final missingMarkers = _verifyRecoveryAuthority(
      context,
      evidence,
      transactionId,
    );
    _checkPendingRecoveryConflicts(context, evidence, transactionId);
    final staging = _io.fs.path.join(
      _evidence.evidenceDirectory(stateRoot),
      transactionId,
    );
    final commitPath = _io.fs.path.join(staging, 'commit.json');
    final commitType = _io.type(commitPath, followLinks: false);
    try {
      _verifyPaths(context, evidence.source, evidence.target);
      _verifyUnlinkedPath(staging);
      if (jsonEncode(evidence.observations['coordinatorContext']) !=
          jsonEncode(_contextObservation(context))) {
        throw MambaException(
          'The conversion authority context changed.',
          exitCode: 6,
        );
      }
      _verifyNoOtherOwners(
        context,
        evidence.source,
        evidence.target,
        allowTarget: true,
      );
      if (commitType != FileSystemEntityType.notFound &&
          commitType != FileSystemEntityType.file) {
        throw MambaException(
          'The conversion commit marker is not a file.',
          exitCode: 6,
        );
      }
      final committed = commitType == FileSystemEntityType.file;
      if (!committed) {
        _verifyRollbackAuthority(context, evidence);
        for (final marker in missingMarkers) {
          state.writeProtectedDocument(
            marker,
            utf8.encode(evidence.initialIntent.encode()),
          );
        }
        _rollbackPersisted(evidence, staging, keepPayload: true);
        _removeInitialFallback(staging);
        final rolledBack = evidence.withPhase(
          ConversionEvidencePhase.rolledBack,
        );
        _persistEvidence(stateRoot, rolledBack);
        _writeCleanupIntent(
          _io.fs.path.join(staging, 'cleanup.json'),
          rolledBack,
        );
        _cleanup(staging, keepPayload: false);
        return _outcome(
          rolledBack,
          succeeded: false,
          committed: false,
          reconciled: false,
        );
      }

      _verifyCommitDecision(commitPath, evidence);
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
      current = _finishCleanup(stateRoot, staging, current);
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
    final evidencePath = _evidence.evidencePath(
      stateRoot,
      request.transactionId,
    );
    if (_io.type(staging, followLinks: false) !=
            FileSystemEntityType.notFound ||
        _io.type(evidencePath, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw MambaException(
        'The conversion transaction ID is already in use.',
        exitCode: 4,
      );
    }

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
    var commitAttempted = false;
    // Resolve and persist the initial intent before creating any transaction
    // staging. A restart can distinguish preparation from publication by the
    // absence of verified staging evidence.
    final sourceOwnership = source.ownershipBefore;
    final sourceSnapshot = sourceOwnership?.managed == true
        ? state
              .recordById(
                sourceOwnership!.scope == context.scope.name
                    ? context
                    : LifecycleContext.resolve(
                        request.options.copyWith(
                          scope: LifecycleScope.values.byName(
                            sourceOwnership.scope,
                          ),
                        ),
                        fileSystem: _io.fs,
                      ),
                sourceOwnership.installationId!,
              )
              .toJson()
        : null;
    var currentEvidence = _evidence.prepare(
      transactionId: request.transactionId,
      source: source,
      target: target,
      allocatedInstallationId: decision.allocatesTargetId
          ? state.newInstallationId()
          : null,
      approvals: request.approvals,
      observations: <String, Object?>{
        ...request.observations,
        'coordinatorSourceRecord': sourceSnapshot,
        'coordinatorContext': _contextObservation(context),
        'coordinatorSourceRemoval': false,
        if (source.artifactKind == 'agent-file')
          'coordinatorSourceName': _agentName(
            source,
            _io.read(source.location, maxConversionSourceFileBytes),
          ),
        if (target.artifactKind == 'agent-file')
          'coordinatorTargetName': _agentName(
            target,
            request.targetFiles.values.single,
          ),
      },
    );
    // Apply the same byte, depth and node limits on writes as on recovery.
    ConversionEvidence.decode(currentEvidence.encode());
    // Publish shared user authority first, even when it is the coordinator.
    // A different project must see the reservation after the first intent write;
    // a missing coordinator remains a reservation, not proof of freedom.
    for (final scope in const [LifecycleScope.user, LifecycleScope.project]) {
      final participantState = context.stateRoot(scope);
      if (_io.fs.path.equals(participantState, stateRoot)) {
        _persistEvidence(stateRoot, currentEvidence);
        continue;
      }
      final marker = _io.fs.path.join(
        participantState,
        'conversion-participants',
        '${request.transactionId}.json',
      );
      if (_io.type(marker, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw MambaException(
          'Conversion participant already exists: $marker',
          exitCode: 6,
        );
      }
      state.writeProtectedDocument(
        marker,
        utf8.encode(currentEvidence.encode()),
      );
    }

    try {
      // Prepare and independently verify both payloads before publication.
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
      // Preserve the initial intent across the in-place evidence upgrade.
      // The fallback is removed before any live mutation is authorized.
      state.writeProtectedDocument(
        _initialFallbackPath(staging),
        utf8.encode(currentEvidence.encode()),
      );
      currentEvidence = currentEvidence.copyWith(
        source: currentEvidence.source.copyWith(
          payload: preparedSource.payload,
        ),
        target: currentEvidence.target.copyWith(
          staging: preparedTarget.staging,
        ),
      );
      _persistEvidence(stateRoot, currentEvidence);
      _removeInitialFallback(staging);

      // Recheck the reviewed observations at the live-mutation boundary.
      _verifyPaths(context, source, target);
      _verifySourceUnchanged(source);
      _verifyTargetAvailable(source, target);
      _verifyOwnership(context, request);

      // Publish: a same-location replacement quarantines the source instead
      // of deleting it. A moved output keeps the source live.
      if (inPlace) {
        _io.rename(source.location, quarantinePath);
      }
      _publishTarget(target, request.targetFiles);
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
      commitAttempted = true;
      _writeCommitDecision(commitPath, currentEvidence);
      committed = true;
      currentEvidence = currentEvidence.withPhase(
        ConversionEvidencePhase.committed,
      );
      _persistEvidence(stateRoot, currentEvidence);

      // Reconcile: materialize the target record and retire the source.
      await _reconcile(context, request, currentEvidence);
      currentEvidence = currentEvidence.withPhase(
        ConversionEvidencePhase.reconciled,
      );
      _persistEvidence(stateRoot, currentEvidence);

      // Cleanup retains the independent source payload as completed recovery
      // evidence and removes only private staging/quarantine entries.
      currentEvidence = _finishCleanup(stateRoot, staging, currentEvidence);
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
      if (!committed && commitAttempted) {
        _markRecoveryRequired(stateRoot, request.transactionId);
        throw MambaException(
          'The commit decision is uncertain and needs recovery: $error',
          exitCode: 6,
        );
      }
      if (committed) {
        try {
          // Read the durable decision and observations even when an IO call
          // completed its effect before reporting failure.
          return await _resume(context, request.options, request.transactionId);
        } on Exception catch (forwardError) {
          _markRecoveryRequired(stateRoot, request.transactionId);
          throw MambaException(
            'The conversion is committed and needs recovery: $forwardError',
            exitCode: 6,
          );
        }
      }
      try {
        _verifyRollbackAuthority(context, currentEvidence);
        _rollbackPersisted(currentEvidence, staging, keepPayload: true);
        _removeInitialFallback(staging);
        currentEvidence = currentEvidence.withPhase(
          ConversionEvidencePhase.rolledBack,
        );
        _persistEvidence(stateRoot, currentEvidence);
        _writeCleanupIntent(
          _io.fs.path.join(staging, 'cleanup.json'),
          currentEvidence,
        );
        _cleanup(staging, keepPayload: false);
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

  void _verifyRollbackAuthority(
    LifecycleContext context,
    ConversionEvidence evidence,
  ) {
    if (evidence.phase == ConversionEvidencePhase.committed ||
        evidence.phase == ConversionEvidencePhase.reconciled ||
        evidence.observations['coordinatorSourceRemoval'] == true) {
      throw MambaException(
        'The committed conversion decision is missing.',
        exitCode: 6,
      );
    }
    _verifyNoOtherOwners(context, evidence.source, evidence.target);
    final prior = _sourceRecord(evidence);
    for (final scope in [LifecycleScope.project, LifecycleScope.user]) {
      final scopeContext = LifecycleContext.resolve(
        context.options.copyWith(scope: scope),
        fileSystem: _io.fs,
      );
      for (final record in state.records(scopeContext)) {
        if (record.installationId == prior?.installationId) {
          if (jsonEncode(record.toJson()) != jsonEncode(prior!.toJson())) {
            throw MambaException(
              'Source ownership changed; rollback is unsafe.',
              exitCode: 6,
            );
          }
        } else if (record.installationId ==
            evidence.target.identity?.installationId) {
          throw MambaException(
            'Target ownership exists without its commit decision.',
            exitCode: 6,
          );
        }
      }
    }
    if (prior != null) {
      final sourceContext = LifecycleContext.resolve(
        context.options.copyWith(scope: prior.scope),
        fileSystem: _io.fs,
      );
      state.recordById(sourceContext, prior.installationId);
    }
  }

  void _rollbackPersisted(
    ConversionEvidence evidence,
    String staging, {
    bool dryRun = false,
    bool keepPayload = false,
  }) {
    final target = evidence.target;
    final publication = target.publication;
    final inPlace = _io.fs.path.equals(
      evidence.source.location,
      target.location,
    );
    if (evidence.source.payload == null && target.staging == null) {
      // No live mutation is authorized by initial intent. Never infer that an
      // unexpectedly occupied target or quarantine belongs to this process.
      final quarantine = _io.fs.path.join(staging, 'quarantine');
      if (publication != null ||
          _io.type(quarantine, followLinks: false) !=
              FileSystemEntityType.notFound ||
          (!inPlace &&
              _io.type(target.location, followLinks: false) !=
                  FileSystemEntityType.notFound)) {
        throw MambaException(
          'Initial conversion intent has ambiguous live state.',
          exitCode: 6,
        );
      }
      _verifySourceUnchanged(evidence.source);
      if (!dryRun) _cleanup(staging, keepPayload: keepPayload);
      return;
    }
    if (evidence.source.payload == null || target.staging == null) {
      throw MambaException(
        'Conversion preparation evidence is incomplete.',
        exitCode: 6,
      );
    }
    final quarantine = _io.fs.path.join(staging, 'quarantine');
    final quarantineExists =
        _io.type(quarantine, followLinks: false) !=
        FileSystemEntityType.notFound;
    // Verify everything we rely on before deleting any transaction-owned
    // target. An edited quarantine or backup is not permission to restore it.
    _verifyOriginalAt(
      evidence.source,
      inPlace && quarantineExists ? quarantine : evidence.source.location,
    );
    final payload = evidence.source.payload!;
    if (_io.type(payload.path, followLinks: false) !=
            FileSystemEntityType.notFound &&
        _manifestDigest(payload.path) != payload.digest) {
      throw MambaException(
        'The conversion recovery payload changed.',
        exitCode: 6,
      );
    }
    final targetType = _io.type(target.location, followLinks: false);
    final publicationAttempted =
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
      if (!dryRun) _io.delete(target.location);
    }
    if (dryRun) return;
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
    _cleanup(staging, keepPayload: keepPayload);
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
    if (decoded['schemaVersion'] != 1 ||
        decoded['transactionId'] != evidence.transactionId ||
        decoded['decision'] != 'commit' ||
        digest != expected ||
        decoded['evidenceDigest'] != _commitEvidenceDigest(evidence)) {
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
    ConversionEvidence evidence, {
    bool dryRun = false,
    bool verifyPayload = true,
  }) async {
    final target = evidence.target;
    final source = evidence.source;
    _verifyCommittedContent(evidence, verifyPayload: verifyPayload);
    _verifyNoOtherOwners(context, source, target, allowTarget: true);
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
    final prior = _sourceRecord(evidence);
    final sameIdentity = prior?.installationId == installationId;
    final record = InstallationRecord(
      installationId: installationId,
      kind: ArtifactKind.values.firstWhere(
        (kind) => kind.wireName == target.artifactKind,
      ),
      scope: LifecycleScope.values.firstWhere(
        (scope) => scope.name == targetOwnership.scope,
      ),
      nativeDestination: sameIdentity
          ? prior!.nativeDestination
          : targetOwnership.nativeDestination ??
                targetOwnership.nativeProfile ??
                targetOwnership.nativeForm,
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
        if (sameIdentity)
          ...prior!.origin
        else ...{
          'status': 'unknown',
          if (prior != null) 'conversionSourceOrigin': prior.origin,
        },
        'conversionTransactionId': request.transactionId,
        if (target.identity?.convertedFromId != null)
          'convertedFromInstallationId': target.identity!.convertedFromId,
        if (target.identity?.lineageId != null)
          'conversionLineageId': target.identity!.lineageId,
        if (target.membershipAfter != null)
          'conversionMembership': target.membershipAfter!.toJson(),
      },
      backupIds: sameIdentity ? prior!.backupIds : const <String>[],
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
      retired = prior!.copyWith(
        lifecycle: 'removed',
        origin: <String, Object?>{
          ...prior.origin,
          'conversionTransactionId': request.transactionId,
          if (source.membershipAfter != null)
            'conversionMembership': source.membershipAfter!.toJson(),
        },
      );
      final actual = jsonEncode(existing.toJson());
      final alreadyTarget =
          existing.installationId == record.installationId &&
          _io.fs.path.equals(source.location, target.location) &&
          actual == jsonEncode(record.toJson());
      if (actual != jsonEncode(prior.toJson()) &&
          actual != jsonEncode(retired.toJson()) &&
          !alreadyTarget) {
        throw MambaException(
          'The source installation changed before reconciliation.',
          exitCode: 6,
        );
      }
      retiredScope = sourceScope;
    }
    for (final existing in state.records(context)) {
      if (existing.installationId == record.installationId &&
          !(sameIdentity &&
              jsonEncode(existing.toJson()) == jsonEncode(prior!.toJson())) &&
          jsonEncode(existing.toJson()) != jsonEncode(record.toJson())) {
        throw MambaException(
          'The target installation changed before reconciliation.',
          exitCode: 6,
        );
      }
    }
    if (dryRun) return;
    await state.applyCoordinatedTransition(
      context: context,
      target: record,
      retiredSource: retired,
      retiredSourceScope: retiredScope,
    );
  }

  InstallationRecord? _sourceRecord(ConversionEvidence evidence) {
    final source = evidence.source;
    final ownership = source.ownershipBefore;
    if (ownership?.managed != true) return null;
    try {
      final record = InstallationRecord.fromJson(
        evidence.observations['coordinatorSourceRecord'],
      );
      if (record.installationId != ownership!.installationId ||
          record.scope.name != ownership.scope ||
          record.location != source.location ||
          record.nativeRoot != ownership.nativeRoot ||
          record.kind.wireName != source.artifactKind ||
          record.nativeForm != ownership.nativeForm ||
          record.lifecycle != 'live') {
        throw const FormatException(
          'Source snapshot does not bind the participant.',
        );
      }
      return record;
    } on Exception {
      throw MambaException(
        'The managed source record snapshot is missing or invalid.',
        exitCode: 6,
      );
    }
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

    _verifyNoOtherOwners(context, source, request.target);
  }

  Map<String, Object?> _contextObservation(LifecycleContext context) => {
    'scope': context.scope.name,
    'projectRoot': context.projectRoot,
    'projectState': context.stateRoot(LifecycleScope.project),
    'userState': context.stateRoot(LifecycleScope.user),
    'home': context.requireHome(),
  };

  void _verifyUnlinkedPath(String path) {
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
          'Linked conversion authority is unsupported: $component',
          exitCode: 6,
        );
      }
    }
  }

  void _verifyPaths(
    LifecycleContext context,
    ConversionParticipant source,
    ConversionParticipant target,
  ) {
    try {
      source.validate();
      target.validate();
    } on FormatException catch (error) {
      throw MambaException(
        'Invalid conversion participant: ${error.message}',
        exitCode: 4,
      );
    }
    if (source.artifactKind == 'skill-link' ||
        source.artifactKind == 'skill-canonical') {
      throw MambaException(
        'Linked or shared conversion sources are unsupported.',
        exitCode: 4,
      );
    }
    if (target.ownershipAfter?.scope != context.scope.name) {
      throw MambaException(
        'The target scope must match the coordinator scope.',
        exitCode: 4,
      );
    }
    if (!_io.fs.path.equals(source.location, target.location) &&
        _pathsOverlap(source.location, target.location)) {
      throw MambaException(
        'Conversion paths must not contain one another.',
        exitCode: 4,
      );
    }
    for (final scope in [LifecycleScope.project, LifecycleScope.user]) {
      final root = context.stateRoot(scope);
      _verifyUnlinkedPath(root);
      if (_pathsOverlap(source.location, root) ||
          _pathsOverlap(target.location, root)) {
        throw MambaException(
          'Conversion paths overlap management storage.',
          exitCode: 4,
        );
      }
    }
    _verifyUnlinkedPath(source.location);
    _verifyUnlinkedPath(target.location);
  }

  void _verifyNoOtherOwners(
    LifecycleContext context,
    ConversionParticipant source,
    ConversionParticipant target, {
    bool allowTarget = false,
  }) {
    for (final scope in const <LifecycleScope>[
      LifecycleScope.project,
      LifecycleScope.user,
    ]) {
      final scopeContext = scope == context.scope
          ? context
          : LifecycleContext.resolve(
              context.options.copyWith(scope: scope),
              fileSystem: _io.fs,
            );
      for (final record in state.records(scopeContext)) {
        final isSource =
            record.installationId == source.ownershipBefore?.installationId;
        final isTarget =
            allowTarget &&
            record.installationId == target.identity?.installationId;
        if ((isSource && scope.name != source.ownershipBefore?.scope) ||
            (isTarget && scope.name != target.ownershipAfter?.scope)) {
          throw MambaException(
            'Conversion identity exists in another scope.',
            exitCode: 6,
          );
        }
        if (isSource || isTarget || record.lifecycle != 'live') continue;
        if (_pathsOverlap(record.location, source.location) ||
            _pathsOverlap(record.location, target.location)) {
          throw MambaException(
            'Another scope already owns the conversion target location.',
            exitCode: 4,
          );
        }
      }
    }
  }

  String? _agentName(ConversionParticipant participant, List<int> bytes) {
    final harness = AgentHarness.values
        .where((value) => value.name == participant.nativeProfile)
        .firstOrNull;
    if (harness == null) return null;
    try {
      final report = inspectNativeAgentContent(
        content: utf8.decode(bytes),
        harness: harness,
        definitionFile: participant.location,
      );
      final identity = report.identity['name']! as Map<String, Object?>;
      return identity['resolved'] as String?;
    } on FormatException {
      return null;
    } on MambaException {
      return null;
    }
  }

  bool _pathsOverlap(String first, String second) =>
      _io.fs.path.equals(first, second) ||
      _io.fs.path.isWithin(first, second) ||
      _io.fs.path.isWithin(second, first);

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

  String _initialFallbackPath(String staging) =>
      _io.fs.path.join(staging, 'initial-intent.json');

  void _removeInitialFallback(String staging) {
    final path = _initialFallbackPath(staging);
    if (_io.type(path, followLinks: false) != FileSystemEntityType.notFound) {
      _io.delete(path);
    }
  }

  Future<ConversionEvidence?> _readEvidence(String stateRoot, String id) async {
    _verifyUnlinkedPath(_evidence.evidencePath(stateRoot, id));
    _verifyUnlinkedPath(
      _io.fs.path.join(_evidence.evidenceDirectory(stateRoot), id),
    );
    // A fallback is only authoritative during preparation. A valid main
    // document always wins, including after a completed replacement.
    try {
      final main = await _evidence.readPersisted(stateRoot, id);
      if (main != null) return main;
    } on Exception {
      // Validate the independent immutable copy below; never treat corruption
      // as absence or silently manufacture an intent.
    }
    final staging = _io.fs.path.join(
      _evidence.evidenceDirectory(stateRoot),
      id,
    );
    final path = _initialFallbackPath(staging);
    if (_io.type(path, followLinks: false) != FileSystemEntityType.file) {
      // Re-read to preserve the original corrupt-document diagnostic.
      return _evidence.readPersisted(stateRoot, id);
    }
    try {
      final bytes = _io.read(path, maxConversionEvidenceBytes);
      if (bytes.length > maxConversionEvidenceBytes) {
        throw const FormatException('Initial intent exceeds its byte limit.');
      }
      final initial = ConversionEvidence.decode(utf8.decode(bytes));
      if (initial.transactionId != id ||
          initial.phase != ConversionEvidencePhase.prepared ||
          initial.source.payload != null ||
          initial.target.staging != null ||
          initial.target.publication != null ||
          _io.type(
                _io.fs.path.join(staging, 'commit.json'),
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
        throw const FormatException('Invalid initial intent fallback.');
      }
      return initial;
    } on Exception catch (error) {
      throw MambaException(
        'The conversion initial intent is corrupt: $error',
        exitCode: 6,
      );
    }
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

  void _verifyOriginalAt(ConversionParticipant source, String path) {
    final entries = conversionManifestEntries(_io, path);
    // Quarantining a regular file changes its basename, not its contents.
    if (_io.type(path, followLinks: false) == FileSystemEntityType.file) {
      entries.single['path'] = _io.fs.path.basename(source.location);
    }
    if (conversionManifestDigest(entries) != source.baseline?.digest) {
      throw MambaException(
        'The original conversion source changed.',
        exitCode: 6,
      );
    }
  }

  void _verifyCommittedContent(
    ConversionEvidence evidence, {
    bool verifyPayload = true,
  }) {
    final payload = evidence.source.payload;
    final publication = evidence.target.publication;
    if (payload == null ||
        publication == null ||
        !publication.verified ||
        (verifyPayload && _manifestDigest(payload.path) != payload.digest) ||
        _manifestDigest(evidence.target.location) != publication.digest) {
      throw MambaException(
        'Committed conversion content changed.',
        exitCode: 6,
      );
    }
    if (!_io.fs.path.equals(
      evidence.source.location,
      evidence.target.location,
    )) {
      if (_io.type(evidence.source.location, followLinks: false) ==
          FileSystemEntityType.notFound) {
        if (evidence.observations['coordinatorSourceRemoval'] != true) {
          throw MambaException(
            'The conversion source is missing.',
            exitCode: 6,
          );
        }
      } else {
        _verifyOriginalAt(evidence.source, evidence.source.location);
      }
    }
  }

  ConversionEvidence _finishCleanup(
    String stateRoot,
    String staging,
    ConversionEvidence evidence,
  ) {
    _verifyCommittedContent(evidence);
    final inPlace = _io.fs.path.equals(
      evidence.source.location,
      evidence.target.location,
    );
    final original = inPlace
        ? _io.fs.path.join(staging, 'quarantine')
        : evidence.source.location;
    if (_io.type(original, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _verifyOriginalAt(evidence.source, original);
    } else if (evidence.observations['coordinatorSourceRemoval'] != true) {
      throw MambaException(
        'The original conversion source is missing.',
        exitCode: 6,
      );
    }
    // Persist removal intent after verification, so restart can distinguish
    // our completed deletion from a source that disappeared before cleanup.
    var current = evidence.copyWith(
      observations: <String, Object?>{
        ...evidence.observations,
        'coordinatorSourceRemoval': true,
      },
    );
    _persistEvidence(stateRoot, current);
    if (_io.type(original, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _io.delete(original);
    }
    _cleanup(staging, keepPayload: true);
    current = current.withPhase(ConversionEvidencePhase.completed);
    _persistEvidence(stateRoot, current);
    return current;
  }

  void _writeCommitDecision(String path, ConversionEvidence evidence) {
    final body = <String, Object?>{
      'schemaVersion': 1,
      'transactionId': evidence.transactionId,
      'decision': 'commit',
      'evidenceDigest': _commitEvidenceDigest(evidence),
    };
    final decision = <String, Object?>{
      ...body,
      'digest': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
    };
    state.writeProtectedDocument(path, utf8.encode(jsonEncode(decision)));
  }

  String _commitEvidenceDigest(ConversionEvidence evidence) => evidence
      .copyWith(
        phase: ConversionEvidencePhase.published,
        observations: {
          ...evidence.observations,
          'coordinatorSourceRemoval': false,
        },
      )
      .digest;

  void _markRecoveryRequired(String stateRoot, String transactionId) {
    try {
      final path = _evidence.evidencePath(stateRoot, transactionId);
      final type = _io.type(path, followLinks: false);
      if (type != FileSystemEntityType.file) return;
      final bytes = _io.read(path, maxConversionEvidenceBytes);
      final evidence = ConversionEvidence.decode(utf8.decode(bytes));
      // Never erase an observed commit or reopen a terminal transaction merely
      // because a later IO acknowledgement or recovery attempt failed.
      if (evidence.phase == ConversionEvidencePhase.committed ||
          evidence.phase == ConversionEvidencePhase.reconciled ||
          evidence.phase == ConversionEvidencePhase.completed ||
          evidence.phase == ConversionEvidencePhase.rolledBack) {
        return;
      }
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
