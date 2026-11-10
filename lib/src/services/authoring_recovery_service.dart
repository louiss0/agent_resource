import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../authoring/authoring_receipt.dart';
import '../authoring/authoring_transaction.dart';
import 'lifecycle_state_service.dart';

/// The directory that holds the authoring transactions of one state root.
const String authoringTransactionDirectoryName = 'authoring-transactions';

/// The directory that holds the retained authoring recovery payloads.
const String authoringRecoveryDirectoryName = 'authoring-recovery';

/// The directory that holds the staged authoring candidates.
const String authoringStagingDirectoryName = 'authoring-staging';

/// The largest ordinary file that a recovery reads.
const int maxAuthoringRecoveryFileBytes = 1048576;

/// The inspected and recoverable state of one authoring transaction.
///
/// The recovery of an ordinary publication is reviewed before it is applied.
/// The review binds the transaction, the current observations and the
/// permitted direction: a transaction before its commit may be rolled back,
/// a committed transaction may only be completed.
interface class AuthoringRecoveryService {
  factory AuthoringRecoveryService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    LifecycleStateService? state,
  }) {
    final io = LifecycleIO(fs: fileSystem);
    final resolved = state ?? LifecycleStateService(io: io);
    return AuthoringRecoveryService._(fileSystem, resolved);
  }

  AuthoringRecoveryService._(this._fileSystem, this._state);

  final fslib.FileSystem _fileSystem;
  final LifecycleStateService _state;

  /// The ownership authority of the recovery.
  LifecycleStateService get state => _state;

  LifecycleIO get _io => _state.io;

  /// The directory that holds the transactions of one state root.
  String evidenceDirectory(String stateRoot) =>
      _fileSystem.path.join(stateRoot, authoringTransactionDirectoryName);

  /// The path of the evidence document of one transaction.
  String evidencePath(String stateRoot, String transactionId) {
    if (!isAuthoringTransactionId(transactionId)) {
      throw MambaException('Invalid authoring transaction ID.', exitCode: 4);
    }
    return _fileSystem.path.join(
      evidenceDirectory(stateRoot),
      '$transactionId.json',
    );
  }

  /// A new authoring transaction identifier.
  String newTransactionId() => newAuthoringTransactionId();

  /// Persists one transaction document.
  ///
  /// The document is private and bounded. A torn document fails closed: it is
  /// never evidence of a free state.
  void persist(String stateRoot, AuthoringTransaction transaction) {
    final encoded = transaction.encode();
    if (encoded.length > maxAuthoringTransactionBytes) {
      throw MambaException(
        'The authoring transaction document exceeds its byte limit.',
        exitCode: 3,
      );
    }
    _state.writeProtectedDocument(
      evidencePath(stateRoot, transaction.transactionId),
      utf8.encode(encoded),
    );
  }

  /// Reads one persisted transaction.
  ///
  /// The read is bounded and fail closed. A missing document is null; a
  /// corrupt, truncated or unknown document is an operational failure.
  Future<AuthoringTransaction?> readPersisted(
    String stateRoot,
    String transactionId,
  ) async {
    final path = evidencePath(stateRoot, transactionId);
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The authoring transaction path is not a regular file: $path',
        exitCode: 3,
      );
    }
    final bytes = _io.read(path, maxAuthoringTransactionBytes + 1);
    if (bytes.length > maxAuthoringTransactionBytes) {
      throw MambaException(
        'The authoring transaction document exceeds its byte limit.',
        exitCode: 3,
      );
    }
    final String encoded;
    try {
      encoded = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw MambaException(
        'The authoring transaction document is not valid UTF-8.',
        exitCode: 3,
      );
    }
    try {
      return AuthoringTransaction.decode(encoded);
    } on FormatException catch (error) {
      throw MambaException(
        'The authoring transaction document is not usable: ${error.message}',
        exitCode: 3,
      );
    }
  }

  /// Inventories the authoring transactions of the selected scopes.
  ///
  /// The inventory is read-only: it takes no lock, writes no document and
  /// implies no free state. A corrupt document stays visible as unresolved,
  /// and a retained payload or a staged candidate without a transaction stays
  /// visible as an orphan.
  Future<LifecycleResult> inventory(LifecycleOptions options) async {
    final transactions = <Map<String, Object?>>[];
    final diagnostics = <Map<String, Object?>>[];
    final orphans = <Map<String, Object?>>[];
    for (final scope in _scopes(options)) {
      final context = LifecycleContext.resolve(
        options.copyWith(scope: scope),
        fileSystem: _fileSystem,
      );
      final stateRoot = context.stateRoot();
      final directory = evidenceDirectory(stateRoot);
      final recorded = <String>{};
      if (_io.type(directory, followLinks: false) !=
          FileSystemEntityType.notFound) {
        for (final entry in _io.list(directory)) {
          final name = _fileSystem.path.basename(entry.path);
          if (!name.endsWith('.json')) continue;
          final transactionId = name.substring(0, name.length - '.json'.length);
          try {
            final transaction = await readPersisted(stateRoot, transactionId);
            if (transaction == null) continue;
            recorded.add(transaction.planId);
            transactions.add(<String, Object?>{
              'transactionId': transaction.transactionId,
              'planId': transaction.planId,
              'operation': transaction.operation,
              'kind': transaction.kind,
              'ownership': transaction.ownership,
              'phase': transaction.phase.name,
              'target': transaction.target,
              'source': transaction.source,
              'scope': scope.name,
              'terminal': transaction.terminal,
              'recoveryPayload': transaction.recoveryPath,
              'receiptId': transaction.receiptId,
            });
          } on Exception catch (error) {
            diagnostics.add(<String, Object?>{
              'code': 'EVIDENCE_UNRESOLVED',
              'category': 'operational',
              'severity': 'error',
              'field': 'transactionId',
              'message':
                  'The authoring transaction $transactionId is unresolved: '
                  '$error',
            });
          }
        }
      }
      for (final entry in _privateEntries(stateRoot)) {
        if (recorded.contains(entry.path)) continue;
        orphans.add(<String, Object?>{
          'kind': entry.kind,
          'path': entry.path,
          'scope': scope.name,
        });
      }
    }
    transactions.sort(
      (left, right) =>
          '${left['transactionId']}'.compareTo('${right['transactionId']}'),
    );
    return LifecycleResult(
      command: 'authoring list',
      outcome: 'listed',
      data: <String, Object?>{
        'transactions': transactions,
        'count': transactions.length,
        'orphans': orphans,
      },
      diagnostics: diagnostics,
    );
  }

  /// Inspects one transaction and the recovery it permits.
  ///
  /// The inspection is read-only: it takes no lock and writes nothing.
  Future<LifecycleResult> inspect(
    LifecycleOptions options,
    String transactionId,
  ) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final review = await _review(context, transactionId);
    return LifecycleResult(
      command: 'authoring inspect',
      outcome: 'inspected',
      data: review.data,
      diagnostics: const <Map<String, Object?>>[],
    );
  }

  /// Reviews or applies the recovery of one transaction.
  ///
  /// Without a plan identity the call is a read-only review. The apply
  /// requires the current review identity, the explicit approval, a mode
  /// that permits the mutation and the permitted direction of the
  /// transaction.
  Future<LifecycleResult> recoverReviewed(
    LifecycleOptions options,
    String transactionId, {
    String? planId,
    String? action,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final review = await _review(context, transactionId);
    if (planId == null || options.dryRun) {
      return LifecycleResult(
        command: 'authoring recover',
        outcome: 'planned',
        data: review.data,
        diagnostics: const <Map<String, Object?>>[],
      );
    }
    if (planId != review.reviewId) {
      throw MambaException(
        'Recovery requires the current review identity; stale approval is '
        'refused.',
        exitCode: 4,
      );
    }
    if (!options.approved) {
      throw MambaException('Recovery requires --yes.', exitCode: 4);
    }
    final permitted = review.permittedAction;
    if (permitted == null) {
      throw MambaException(
        'The authoring transaction is terminal; there is nothing to recover.',
        exitCode: 4,
      );
    }
    if (action != null && action != permitted) {
      throw MambaException(
        'The recovery action must match the permitted direction: $permitted.',
        exitCode: 4,
      );
    }
    final transaction = review.transaction;
    return _state.runMutation(
      context: context,
      locations: <String>[
        transaction.target,
        if (transaction.source != null) transaction.source!,
      ],
      body: () async {
        final current = await readPersisted(
          context.stateRoot(),
          transaction.transactionId,
        );
        if (current == null || current.digest != transaction.digest) {
          throw MambaException(
            'The authoring transaction changed since the review.',
            exitCode: 6,
          );
        }
        return switch (permitted) {
          'rollback' => _rollback(context, current),
          'complete' => _complete(context, current),
          _ => throw MambaException(
            'The permitted recovery direction is unknown.',
            exitCode: 6,
          ),
        };
      },
    );
  }

  /// Reviews or applies the cleanup of one terminal transaction.
  ///
  /// The cleanup removes the retained private payload of a terminal
  /// transaction. It keeps the evidence document as the audit record and it
  /// forfeits the payload based restore of the source.
  Future<LifecycleResult> cleanupReviewed(
    LifecycleOptions options,
    String transactionId, {
    String? planId,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final review = await _review(context, transactionId);
    if (planId == null || options.dryRun) {
      return LifecycleResult(
        command: 'authoring cleanup',
        outcome: 'planned',
        data: review.data,
        diagnostics: const <Map<String, Object?>>[],
      );
    }
    if (planId != review.reviewId) {
      throw MambaException(
        'Cleanup requires the current review identity; stale approval is '
        'refused.',
        exitCode: 4,
      );
    }
    if (!options.approved) {
      throw MambaException('Cleanup requires --yes.', exitCode: 4);
    }
    final transaction = review.transaction;
    if (!transaction.terminal) {
      throw MambaException(
        'The authoring transaction is not terminal; an unfinished transaction '
        'is never cleaned up.',
        exitCode: 4,
      );
    }
    return _state.runMutation(
      context: context,
      locations: <String>[transaction.target],
      body: () async {
        final current = await readPersisted(
          context.stateRoot(),
          transaction.transactionId,
        );
        if (current == null || current.digest != transaction.digest) {
          throw MambaException(
            'The authoring transaction changed since the review.',
            exitCode: 6,
          );
        }
        final payload = current.recoveryPath;
        if (payload == null) {
          throw MambaException(
            'The authoring transaction has no retained payload.',
            exitCode: 4,
          );
        }
        final type = _io.type(payload, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          throw MambaException(
            'The retained payload was already removed; the cleanup is '
            'refused.',
            exitCode: 4,
          );
        }
        if (type != FileSystemEntityType.directory) {
          throw MambaException(
            'The retained payload is not a private payload directory.',
            exitCode: 6,
          );
        }
        _requireReviewedPayload(current, payload);
        // The cleanup intent binds the reviewed transaction before the
        // deletion, so an interrupted cleanup stays distinguishable from a
        // completed one.
        _state.writeProtectedDocument(
          _fileSystem.path.join(
            context.stateRoot(),
            authoringTransactionDirectoryName,
            '${current.transactionId}.cleanup.json',
          ),
          utf8.encode(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'transactionId': current.transactionId,
              'decision': 'cleanup',
              'digest': current.digest,
              'payload': payload,
            }),
          ),
        );
        _io.delete(payload);
        persist(
          context.stateRoot(),
          current.copyWith(
            observations: <String, Object?>{
              ...current.observations,
              'payloadRemoved': true,
            },
          ),
        );
        return LifecycleResult(
          command: 'authoring cleanup',
          outcome: 'cleaned',
          data: <String, Object?>{
            'transactionId': current.transactionId,
            'phase': current.phase.name,
            'payloadRemoved': true,
            'forfeitedRestore': true,
          },
        );
      },
    );
  }

  /// Rolls one publication back to its reviewed source.
  Future<LifecycleResult> _rollback(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) async {
    final target = transaction.target;
    final source = transaction.source;
    final payload = transaction.recoveryPath;
    // The receipt is the commit point of the publication. A committed
    // publication is never rolled back.
    final receiptId = transaction.receiptId;
    if (receiptId != null && _receiptExists(context, receiptId)) {
      throw MambaException(
        'The publication committed its receipt; the rollback would contradict '
        'the committed state.',
        exitCode: 6,
      );
    }
    // Every observation is verified before the first deletion: a refusal
    // never leaves a partially restored state behind.
    final targetType = _io.type(target, followLinks: false);
    if (targetType != FileSystemEntityType.notFound &&
        _markerDigest(target) != transaction.candidateSha256) {
      throw MambaException(
        'The published target changed; the rollback would destroy an '
        'unreviewed state.',
        exitCode: 6,
      );
    }
    final inPlace = source != null && _fileSystem.path.equals(source, target);
    if (source != null && !inPlace) {
      final sourceType = _io.type(source, followLinks: false);
      if (sourceType != FileSystemEntityType.notFound &&
          _markerDigest(source) != transaction.sourceSha256) {
        throw MambaException(
          'The source changed since the publication; the rollback would '
          'destroy an unreviewed state.',
          exitCode: 6,
        );
      }
    }
    if (inPlace && payload != null) {
      // The reviewed source is restored over the published content: an entry
      // outside the reviewed manifest is never removed.
      _requirePayload(payload);
      _restorePayload(payload, source);
    } else if (targetType != FileSystemEntityType.notFound) {
      _io.delete(target);
    }
    persist(
      context.stateRoot(),
      transaction.copyWith(
        phase: AuthoringTransactionPhase.rolledBack,
        observations: <String, Object?>{
          ...transaction.observations,
          'rolledBackAt': transaction.target,
        },
      ),
    );
    return LifecycleResult(
      command: 'authoring recover',
      outcome: 'rolledBack',
      data: <String, Object?>{
        'transactionId': transaction.transactionId,
        'phase': AuthoringTransactionPhase.rolledBack.name,
        'target': target,
        'source': source,
        'sourceRestored': inPlace && payload != null,
      },
    );
  }

  /// Completes one committed publication.
  Future<LifecycleResult> _complete(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) async {
    final target = transaction.target;
    final type = _io.type(target, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException(
        'The published target is missing; the completion cannot verify it.',
        exitCode: 6,
      );
    }
    if (_markerDigest(target) != transaction.candidateSha256) {
      throw MambaException(
        'The published target changed; the completion cannot verify it.',
        exitCode: 6,
      );
    }
    final receiptId = transaction.receiptId;
    if (receiptId != null && !_receiptExists(context, receiptId)) {
      writeAuthoringReceipt(
        state: _state,
        stateRoot: context.stateRoot(),
        document: authoringReceiptDocument(
          receiptId: receiptId,
          planId: transaction.planId,
          operation: transaction.operation,
          kind: transaction.kind,
          profile: transaction.profile,
          target: transaction.target,
          root: transaction.root,
          form: transaction.form,
          derivedFrom: transaction.source,
          sourceInstallationId: transaction.sourceInstallationId,
        ),
      );
    }
    persist(
      context.stateRoot(),
      transaction.copyWith(phase: AuthoringTransactionPhase.completed),
    );
    return LifecycleResult(
      command: 'authoring recover',
      outcome: 'completed',
      data: <String, Object?>{
        'transactionId': transaction.transactionId,
        'phase': AuthoringTransactionPhase.completed.name,
        'target': target,
        'receiptId': receiptId,
      },
    );
  }

  /// The review of one transaction.
  ///
  /// The review binds the transaction, the current observations and the
  /// permitted direction. It is read-only and it writes nothing.
  Future<AuthoringTransactionReview> _review(
    LifecycleContext context,
    String transactionId,
  ) async {
    final transaction = await readPersisted(context.stateRoot(), transactionId);
    if (transaction == null) {
      throw MambaException(
        'No authoring transaction exists for $transactionId.',
        exitCode: 4,
      );
    }
    final observations = _observe(context, transaction);
    final permitted = _permittedAction(transaction);
    final reviewId = _reviewDigest(transaction, observations, permitted);
    return AuthoringTransactionReview(
      transaction: transaction,
      observations: observations,
      permittedAction: permitted,
      reviewId: reviewId,
      data: <String, Object?>{
        'transactionId': transaction.transactionId,
        'planId': transaction.planId,
        'operation': transaction.operation,
        'kind': transaction.kind,
        'profile': transaction.profile,
        'ownership': transaction.ownership,
        'phase': transaction.phase.name,
        'target': transaction.target,
        'source': transaction.source,
        'recoveryPayload': transaction.recoveryPath,
        'receiptId': transaction.receiptId,
        'observations': observations,
        'permittedAction': permitted,
        'forfeitedRestore': permitted == null ? false : true,
        'reviewId': reviewId,
        'writes': false,
      },
    );
  }

  /// The current observations of one transaction.
  Map<String, Object?> _observe(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) {
    final target = transaction.target;
    final targetType = _io.type(target, followLinks: false);
    final targetExists = targetType != FileSystemEntityType.notFound;
    final source = transaction.source;
    final payload = transaction.recoveryPath;
    final receiptId = transaction.receiptId;
    return <String, Object?>{
      'targetExists': targetExists,
      'targetMatches':
          targetExists && _markerDigest(target) == transaction.candidateSha256,
      'sourceExists':
          source != null &&
          _io.type(source, followLinks: false) != FileSystemEntityType.notFound,
      'sourceMatches':
          source != null && _markerDigest(source) == transaction.sourceSha256,
      'payloadExists':
          payload != null &&
          _io.type(payload, followLinks: false) !=
              FileSystemEntityType.notFound,
      'receiptCommitted':
          receiptId != null && _receiptExists(context, receiptId),
    };
  }

  /// The recovery that one transaction permits.
  String? _permittedAction(AuthoringTransaction transaction) =>
      switch (transaction.phase) {
        AuthoringTransactionPhase.prepared ||
        AuthoringTransactionPhase.published => 'rollback',
        AuthoringTransactionPhase.committed => 'complete',
        AuthoringTransactionPhase.completed ||
        AuthoringTransactionPhase.rolledBack => null,
      };

  /// The digest of the review.
  String _reviewDigest(
    AuthoringTransaction transaction,
    Map<String, Object?> observations,
    String? permitted,
  ) {
    final body = <String, Object?>{
      'transactionId': transaction.transactionId,
      'digest': transaction.digest,
      'observations': observations,
      'permittedAction': permitted,
    };
    return sha256
        .convert(utf8.encode(jsonEncode(canonicalAuthoringJson(body))))
        .toString();
  }

  /// The digest of the published marker of one location.
  String? _markerDigest(String location) {
    final type = _io.type(location, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    final marker = authoringMarkerPath(_fileSystem, location);
    if (_io.type(marker, followLinks: false) != FileSystemEntityType.file) {
      return null;
    }
    final bytes = _io.read(marker, maxAuthoringRecoveryFileBytes);
    return sha256.convert(bytes).toString();
  }

  /// Whether the authoring receipt of one publication exists.
  bool _receiptExists(LifecycleContext context, String receiptId) {
    final path = _fileSystem.path.join(
      context.stateRoot(),
      authoringReceiptDirectoryName,
      '$receiptId.json',
    );
    return _io.type(path, followLinks: false) != FileSystemEntityType.notFound;
  }

  /// Refuses a payload that is not the reviewed private payload.
  void _requirePayload(String payload) {
    final type = _io.type(payload, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException(
        'The retained recovery payload is missing; the rollback would destroy '
        'an unreviewed state.',
        exitCode: 6,
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw MambaException(
        'The retained recovery payload is not a private payload directory.',
        exitCode: 6,
      );
    }
  }

  /// Refuses a payload that carries an unexpected or changed member.
  void _requireReviewedPayload(
    AuthoringTransaction transaction,
    String payload,
  ) {
    _requirePayload(payload);
    final recorded = transaction.observations['payloadMembers'];
    final expected = recorded is List<Object?>
        ? recorded.map((entry) => '$entry').toSet()
        : <String>{};
    final present = <String>{
      for (final entry in _io.list(payload))
        _fileSystem.path.basename(entry.path),
    };
    if (!present.containsAll(expected) || present.length != expected.length) {
      throw MambaException(
        'The retained recovery payload does not match the reviewed members.',
        exitCode: 6,
      );
    }
  }

  /// Restores the reviewed source from the retained payload.
  ///
  /// A file source is retained as one file inside the payload directory. A
  /// package source is retained as its reviewed tree.
  void _restorePayload(String payload, String source) {
    final type = _io.type(payload, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      final entries = _io.list(payload);
      if (entries.length == 1) {
        final only = entries.single;
        if (_fileSystem.path.basename(only.path) == 'source' &&
            _io.type(only.path, followLinks: false) ==
                FileSystemEntityType.file) {
          _io.createDirectory(_fileSystem.path.dirname(source));
          _io.copyFile(only.path, source);
          return;
        }
      }
      _io.createDirectory(source);
      for (final entry in entries) {
        final name = _fileSystem.path.basename(entry.path);
        final from = _fileSystem.path.join(payload, name);
        final to = _fileSystem.path.join(source, name);
        final childType = _io.type(from, followLinks: false);
        if (childType == FileSystemEntityType.directory) {
          _restorePayload(from, to);
          continue;
        }
        if (childType != FileSystemEntityType.file) {
          throw MambaException(
            'The retained recovery payload contains an unsupported entry: '
            '$from',
            exitCode: 6,
          );
        }
        _io.copyFile(from, to);
      }
      return;
    }
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The retained recovery payload is not a readable copy.',
        exitCode: 6,
      );
    }
    _io.createDirectory(_fileSystem.path.dirname(source));
    _io.copyFile(payload, source);
  }

  /// The private entries of one state root that no transaction records.
  /// orphan: it stays visible instead of implying an absent state.
  /// A retained payload or a staged candidate without a transaction is an
  List<_PrivateEntry> _privateEntries(String stateRoot) {
    final entries = <_PrivateEntry>[];
    for (final kind in const <String>[
      authoringRecoveryDirectoryName,
      authoringStagingDirectoryName,
    ]) {
      final directory = _fileSystem.path.join(stateRoot, kind);
      if (_io.type(directory, followLinks: false) ==
          FileSystemEntityType.notFound) {
        continue;
      }
      for (final entry in _io.list(directory)) {
        entries.add(_PrivateEntry(kind, entry.path));
      }
    }
    return entries;
  }

  /// The scopes of one inventory.
  List<LifecycleScope> _scopes(LifecycleOptions options) =>
      switch (options.scope) {
        LifecycleScope.project => const [LifecycleScope.project],
        LifecycleScope.user => const [LifecycleScope.user],
        LifecycleScope.all => const [
          LifecycleScope.project,
          LifecycleScope.user,
        ],
      };
}

/// One private entry of the authoring state.
final class _PrivateEntry {
  const _PrivateEntry(this.kind, this.path);

  /// The kind of the private storage.
  final String kind;

  /// The path of the private entry.
  final String path;
}

/// The review of one authoring transaction.
final class AuthoringTransactionReview {
  const AuthoringTransactionReview({
    required this.transaction,
    required this.observations,
    required this.permittedAction,
    required this.reviewId,
    required this.data,
  });

  /// The reviewed transaction.
  final AuthoringTransaction transaction;

  /// The current observations of the transaction.
  final Map<String, Object?> observations;

  /// The recovery that the transaction permits.
  final String? permittedAction;

  /// The identity of the review.
  final String reviewId;

  /// The reported review data.
  final Map<String, Object?> data;
}
