import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../authoring/authoring_authority.dart';
import '../authoring/authoring_receipt.dart';
import '../authoring/authoring_transaction.dart';
import '../skill_files.dart';
import 'lifecycle_state_service.dart';

/// The largest ordinary file that a recovery reads.
const int maxAuthoringRecoveryFileBytes = 1048576;

/// The recorded states of one cleanup intent.
const Set<String> _cleanupStatuses = <String>{
  'prepared',
  'interrupted',
  'cleaned',
  'partial',
};

/// The recorded states of one rollback intent.
const Set<String> _rollbackStatuses = <String>{
  'prepared',
  'interrupted',
  'completed',
};

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
    AuthoringAuthority? authority,
  }) {
    final io = LifecycleIO(fs: fileSystem);
    final resolved = state ?? LifecycleStateService(io: io);
    return AuthoringRecoveryService._(
      fileSystem,
      resolved,
      authority ?? const AuthoringAuthority(),
    );
  }

  AuthoringRecoveryService._(this._fileSystem, this._state, this._authority);

  final fslib.FileSystem _fileSystem;
  final LifecycleStateService _state;
  final AuthoringAuthority _authority;

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
    // The document is decoded before it is written: an unreadable evidence
    // document is never recorded.
    try {
      decodeAuthoringTransactionDocument(encoded);
    } on FormatException catch (error) {
      throw MambaException(
        'The authoring transaction document is not usable: ${error.message}',
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
  Future<AuthoringTransactionDocument?> readPersistedDocument(
    String stateRoot,
    String transactionId,
  ) async {
    final path = evidencePath(stateRoot, transactionId);
    _requireUnlinkedPath(path);
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
      final document = decodeAuthoringTransactionDocument(encoded);
      if (document.transactionId != transactionId) {
        throw MambaException(
          'The authoring transaction document does not carry its own '
          'identity: $path',
          exitCode: 6,
        );
      }
      return document;
    } on FormatException catch (error) {
      throw MambaException(
        'The authoring transaction document is not usable: ${error.message}',
        exitCode: 3,
      );
    }
  }

  /// Reads one actionable transaction, refusing a legacy read-only document.
  Future<AuthoringTransaction?> readPersisted(
    String stateRoot,
    String transactionId,
  ) async => switch (await readPersistedDocument(stateRoot, transactionId)) {
    null => null,
    CurrentAuthoringTransactionDocument(:final transaction) => transaction,
    LegacyAuthoringTransactionDocument(:final transaction) =>
      throw MambaException(transaction.blockedReason, exitCode: 4),
  };

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
    final cleanups = <Map<String, Object?>>[];
    final recordedRollbacks = <Map<String, Object?>>[];
    for (final scope in _scopes(options)) {
      final context = LifecycleContext.resolve(
        options.copyWith(scope: scope),
        fileSystem: _fileSystem,
      );
      final stateRoot = context.stateRoot();
      final directory = evidenceDirectory(stateRoot);
      final recorded = <String>{};
      final intents = <String>[];
      final rollbacks = <String>[];
      final documents = <String, AuthoringTransactionDocument>{};
      if (_io.type(directory, followLinks: false) !=
          FileSystemEntityType.notFound) {
        for (final entry in _io.list(directory)) {
          final name = _fileSystem.path.basename(entry.path);
          if (!name.endsWith('.json')) continue;
          if (name.endsWith('.cleanup.json')) {
            // A cleanup intent is not a transaction: it is bound to one
            // transaction and it is reported with its own status.
            intents.add(
              name.substring(0, name.length - '.cleanup.json'.length),
            );
            continue;
          }
          if (name.endsWith('.rollback.json')) {
            // A rollback intent is not a transaction either: it binds one
            // interrupted rollback.
            rollbacks.add(
              name.substring(0, name.length - '.rollback.json'.length),
            );
            continue;
          }
          final transactionId = name.substring(0, name.length - '.json'.length);
          try {
            final document = await readPersistedDocument(
              stateRoot,
              transactionId,
            );
            if (document == null) continue;
            if (document.transactionId != transactionId) {
              diagnostics.add(<String, Object?>{
                'code': 'EVIDENCE_UNRESOLVED',
                'category': 'operational',
                'severity': 'error',
                'field': 'transactionId',
                'message':
                    'The authoring transaction document $name does not carry '
                    'its own identity; the evidence is unresolved.',
              });
              continue;
            }
            documents[transactionId] = document;
            switch (document) {
              case CurrentAuthoringTransactionDocument(:final transaction):
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
                  'schemaVersion': authoringTransactionSchemaVersion,
                  'legacyReadOnly': false,
                });
              case LegacyAuthoringTransactionDocument(:final transaction):
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
                  'schemaVersion': authoringLegacyTransactionSchemaVersion,
                  'legacyReadOnly': true,
                  'blockedReason': transaction.blockedReason,
                });
            }
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
        cleanups.addAll(
          _cleanupIntents(context, scope, intents, documents, diagnostics),
        );
        recordedRollbacks.addAll(
          _rollbackIntents(context, scope, rollbacks, documents, diagnostics),
        );
      }
      for (final entry in _privateEntries(stateRoot)) {
        if (recorded.contains(_fileSystem.path.basename(entry.path))) continue;
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
    cleanups.sort(
      (left, right) =>
          '${left['transactionId']}'.compareTo('${right['transactionId']}'),
    );
    return LifecycleResult(
      command: 'authoring list',
      outcome: 'listed',
      data: <String, Object?>{
        'transactions': transactions,
        'count': transactions.length,
        'cleanups': cleanups,
        'rollbacks': recordedRollbacks,
        'orphans': orphans,
      },
      diagnostics: diagnostics,
    );
  }

  /// The recorded rollback intents of one scope.
  ///
  /// A rollback intent binds one interrupted rollback. A prepared intent
  /// means that the rollback was interrupted before it was recorded.
  List<Map<String, Object?>> _rollbackIntents(
    LifecycleContext context,
    LifecycleScope scope,
    List<String> transactionIds,
    Map<String, AuthoringTransactionDocument> documents,
    List<Map<String, Object?>> diagnostics,
  ) {
    final reported = <Map<String, Object?>>[];
    for (final transactionId in transactionIds) {
      final document = documents[transactionId];
      if (document == null) {
        diagnostics.add(<String, Object?>{
          'code': 'EVIDENCE_UNRESOLVED',
          'category': 'operational',
          'severity': 'error',
          'field': 'transactionId',
          'message':
              'The rollback intent of $transactionId has no transaction; the '
              'evidence is unresolved.',
        });
        continue;
      }
      final transaction = switch (document) {
        CurrentAuthoringTransactionDocument(:final transaction) => transaction,
        LegacyAuthoringTransactionDocument() => null,
      };
      if (transaction == null) {
        diagnostics.add(<String, Object?>{
          'code': 'EVIDENCE_UNRESOLVED',
          'category': 'operational',
          'severity': 'error',
          'field': 'transactionId',
          'message':
              'The rollback intent of $transactionId does not bind a current '
              'transaction; the evidence is unresolved.',
        });
        continue;
      }
      final Map<String, Object?>? intent;
      try {
        intent = _readRollbackIntent(context, transaction);
      } on MambaException catch (error) {
        diagnostics.add(<String, Object?>{
          'code': 'EVIDENCE_UNRESOLVED',
          'category': 'operational',
          'severity': 'error',
          'field': 'transactionId',
          'message':
              'The rollback intent of $transactionId is unresolved: '
              '${error.message}',
        });
        continue;
      }
      reported.add(<String, Object?>{
        'transactionId': transactionId,
        'scope': scope.name,
        'status': intent?['status'] == 'completed'
            ? 'completed'
            : 'interrupted',
        'phase': transaction.phase.name,
      });
    }
    return reported;
  }

  /// The recorded cleanup intents of one scope.
  ///
  /// An intent is bound to one transaction and to the digest it reviewed. An
  /// intent that does not match its transaction is unresolved evidence, and a
  /// payload that survived a recorded intent is an interrupted or a partial
  /// cleanup.
  List<Map<String, Object?>> _cleanupIntents(
    LifecycleContext context,
    LifecycleScope scope,
    List<String> transactionIds,
    Map<String, AuthoringTransactionDocument> documents,
    List<Map<String, Object?>> diagnostics,
  ) {
    final reported = <Map<String, Object?>>[];
    for (final transactionId in transactionIds) {
      if (!isAuthoringTransactionId(transactionId)) {
        diagnostics.add(<String, Object?>{
          'code': 'EVIDENCE_UNRESOLVED',
          'category': 'operational',
          'severity': 'error',
          'field': 'transactionId',
          'message':
              'The cleanup intent $transactionId does not name a valid '
              'transaction; the evidence is unresolved.',
        });
        continue;
      }
      final document = documents[transactionId];
      if (document == null) {
        diagnostics.add(<String, Object?>{
          'code': 'EVIDENCE_UNRESOLVED',
          'category': 'operational',
          'severity': 'error',
          'field': 'transactionId',
          'message':
              'The cleanup intent of $transactionId has no transaction; the '
              'evidence is unresolved.',
        });
        continue;
      }
      final transaction = switch (document) {
        CurrentAuthoringTransactionDocument(:final transaction) => transaction,
        LegacyAuthoringTransactionDocument() => null,
      };
      if (transaction == null) {
        diagnostics.add(<String, Object?>{
          'code': 'EVIDENCE_UNRESOLVED',
          'category': 'operational',
          'severity': 'error',
          'field': 'transactionId',
          'message':
              'The cleanup intent of $transactionId does not bind a current '
              'transaction; the evidence is unresolved.',
        });
        continue;
      }
      final Map<String, Object?>? intent;
      try {
        intent = _readCleanupIntent(context, transaction);
      } on MambaException catch (error) {
        diagnostics.add(<String, Object?>{
          'code': 'EVIDENCE_UNRESOLVED',
          'category': 'operational',
          'severity': 'error',
          'field': 'transactionId',
          'message':
              'The cleanup intent of $transactionId is unresolved: '
              '${error.message}',
        });
        continue;
      }
      final status = _cleanupStatus(context, transaction, intent);
      reported.add(<String, Object?>{
        'transactionId': transactionId,
        'scope': scope.name,
        'status': status.status,
        'payload': transaction.recoveryPath,
        'recordedStatus': intent?['status'],
      });
    }
    return reported;
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
    final transaction = review.transaction;
    if (transaction == null) {
      throw MambaException(
        review.data['blockedReason']! as String,
        exitCode: 4,
      );
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
    return _state.runMutation(
      context: context,
      locations: <String>[
        transaction.target,
        if (transaction.source != null) transaction.source!,
      ],
      excludedAuthoringEvidencePaths: <String>{
        evidencePath(context.stateRoot(), transaction.transactionId),
      },
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
        // The current observations are recomputed under the lock: the review
        // approves one exact state, not a boolean summary of it.
        final currentObservations = _observe(context, current);
        if (!_sameObservations(currentObservations, review.observations)) {
          throw MambaException(
            'The observed authoring state changed since the review.',
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
  /// forfeits the payload based restore of the source. The cleanup has its
  /// own review identity: a cleanup approval never authorizes a recovery.
  Future<LifecycleResult> cleanupReviewed(
    LifecycleOptions options,
    String transactionId, {
    String? planId,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final review = await _review(context, transactionId, purpose: 'cleanup');
    final transaction = review.transaction;
    final cleanup = _cleanupState(context, transaction);
    final data = <String, Object?>{
      ...review.data,
      'cleanupStatus': cleanup.status,
      'forfeitedRestore': cleanup.forfeitsRestore,
    };
    if (planId == null || options.dryRun) {
      return LifecycleResult(
        command: 'authoring cleanup',
        outcome: 'planned',
        data: data,
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
    if (transaction == null) {
      throw MambaException(
        review.data['blockedReason']! as String,
        exitCode: 4,
      );
    }
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
      excludedAuthoringEvidencePaths: <String>{
        evidencePath(context.stateRoot(), transaction.transactionId),
      },
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
        // The current observations are recomputed under the lock: the review
        // approves one exact state, not a boolean summary of it.
        final currentObservations = _observe(context, current);
        if (!_sameObservations(currentObservations, review.observations)) {
          throw MambaException(
            'The observed authoring state changed since the review.',
            exitCode: 6,
          );
        }
        final payload = _payloadPath(context, current);
        if (current.recoveryPath == null) {
          throw MambaException(
            'The authoring transaction has no retained payload.',
            exitCode: 4,
          );
        }
        final intent = _readCleanupIntent(context, current);
        final type = _io.type(payload, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          if (intent == null) {
            throw MambaException(
              'The retained payload is missing without a recorded cleanup; '
              'the evidence is unresolved and the cleanup is refused.',
              exitCode: 6,
            );
          }
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
        // A recorded cleanup intent authorizes the members that an
        // interrupted cleanup already removed. The survivors are verified
        // against the reviewed manifest.
        _requireReviewedPayload(
          current,
          payload,
          allowMissingMembers: intent != null,
        );
        // The cleanup intent binds the reviewed transaction before the
        // deletion, so an interrupted cleanup stays distinguishable from a
        // completed one.
        final intentPath = _cleanupIntentPath(context, current.transactionId);
        final reviewedDigest = current.digest;
        _writeCleanupIntent(
          intentPath,
          current,
          payload,
          review.reviewId,
          'prepared',
        );
        Object? failure;
        try {
          _io.delete(payload);
        } on Exception catch (error) {
          failure = error;
        }
        final removed =
            _io.type(payload, followLinks: false) ==
            FileSystemEntityType.notFound;
        final status = failure != null
            ? 'interrupted'
            : (removed ? 'cleaned' : 'partial');
        if (removed) _removeEmptyPrivateParents(context, payload);
        _writeCleanupIntent(
          intentPath,
          current,
          payload,
          review.reviewId,
          status,
        );
        final updated = current.copyWith(
          observations: <String, Object?>{
            ...current.observations,
            'payloadRemoved': removed,
            'cleanupStatus': status,
            'cleanupDigest': reviewedDigest,
          },
        );
        persist(context.stateRoot(), updated);
        if (failure != null) {
          throw MambaException(
            'The retained payload could not be removed; the cleanup stays '
            'interrupted and the evidence is retained.',
            exitCode: 6,
          );
        }
        return LifecycleResult(
          command: 'authoring cleanup',
          outcome: removed ? 'cleaned' : 'partiallyCleaned',
          data: <String, Object?>{
            'transactionId': current.transactionId,
            'phase': current.phase.name,
            'payloadRemoved': removed,
            'cleanupStatus': status,
            'forfeitedRestore': true,
          },
        );
      },
    );
  }

  /// The observed state of the cleanup of one transaction.
  ///
  /// The status is truthful about the retained payload: a payload that is
  /// gone without a recorded cleanup is unresolved evidence, a payload that
  /// survived a recorded intent is interrupted or partially cleaned, and a
  /// payload without an intent is still available.
  _CleanupState _cleanupStatus(
    LifecycleContext context,
    AuthoringTransaction transaction,
    Map<String, Object?>? intent,
  ) {
    final payload = transaction.recoveryPath;
    if (payload == null) {
      return const _CleanupState('unavailable', false);
    }
    final present =
        _io.type(payload, followLinks: false) != FileSystemEntityType.notFound;
    if (!present) {
      if (intent == null) {
        return const _CleanupState('unresolved', false);
      }
      return const _CleanupState('cleaned', false);
    }
    if (intent == null) {
      return _CleanupState('available', true);
    }
    final status = intent['status'];
    if (status == 'prepared') {
      // The deletion was authorized but the retained payload still survives.
      return _CleanupState('interrupted', true);
    }
    if (status == 'cleaned') {
      // The recorded completion is contradicted by the surviving payload.
      return _CleanupState('partial', true);
    }
    // The deletion was attempted: an intact payload was interrupted, a
    // reduced payload was partially deleted.
    final expected = transaction.payloadManifest;
    final actual = authoringContentEvidence(_fileSystem, payload);
    final intact =
        expected != null && authoringContentEvidenceMatches(expected, actual);
    return _CleanupState(intact ? 'interrupted' : 'partial', true);
  }

  /// The observed state of the cleanup of one transaction.
  _CleanupState _cleanupState(
    LifecycleContext context,
    AuthoringTransaction? transaction,
  ) {
    if (transaction == null) {
      return const _CleanupState('unavailable', false);
    }
    final intent = _readCleanupIntent(context, transaction);
    return _cleanupStatus(context, transaction, intent);
  }

  /// The recorded cleanup intent of one transaction.
  ///
  /// The intent is bound to its transaction: it names the transaction, the
  /// reviewed digest, the retained payload and a known status. A corrupt or
  /// mismatched intent is refused instead of being ignored, and it is
  /// validated even when the transaction has no retained payload.
  Map<String, Object?>? _readCleanupIntent(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) => _readBoundIntent(
    context,
    transaction,
    'cleanup',
    'cleanupDigest',
    _cleanupStatuses,
  );

  /// The recorded rollback intent of one transaction.
  ///
  /// The intent authorizes the restore that an interrupted rollback started.
  /// It is bound to its transaction exactly like the cleanup intent.
  Map<String, Object?>? _readRollbackIntent(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) => _readBoundIntent(
    context,
    transaction,
    'rollback',
    'rollbackDigest',
    _rollbackStatuses,
  );

  /// The recorded intent of one decision of one transaction.
  Map<String, Object?>? _readBoundIntent(
    LifecycleContext context,
    AuthoringTransaction transaction,
    String decision,
    String digestObservation,
    Set<String> statuses,
  ) {
    final path = _intentPath(context, transaction.transactionId, decision);
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The $decision intent is not a regular file: $path',
        exitCode: 6,
      );
    }
    final bytes = _io.read(path, maxAuthoringRecoveryFileBytes);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      throw MambaException(
        'The $decision intent is not usable: $path',
        exitCode: 6,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw MambaException(
        'The $decision intent is not usable: $path',
        exitCode: 6,
      );
    }
    final boundDigest = decoded['digest'];
    final recordedDigest = transaction.observations[digestObservation];
    if (decoded['transactionId'] != transaction.transactionId ||
        (boundDigest != transaction.digest && boundDigest != recordedDigest) ||
        decoded['payload'] != transaction.recoveryPath ||
        !statuses.contains(decoded['status'])) {
      throw MambaException(
        'The $decision intent does not bind its transaction: $path',
        exitCode: 6,
      );
    }
    return decoded;
  }

  /// Writes the bound cleanup intent of one transaction.
  void _writeCleanupIntent(
    String path,
    AuthoringTransaction transaction,
    String payload,
    String reviewId,
    String status,
  ) {
    _state.writeProtectedDocument(
      path,
      utf8.encode(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'transactionId': transaction.transactionId,
          'decision': 'cleanup',
          'digest': transaction.digest,
          'payload': payload,
          'reviewId': reviewId,
          'status': status,
        }),
      ),
    );
  }

  /// The path of the cleanup intent of one transaction.
  String _cleanupIntentPath(LifecycleContext context, String transactionId) =>
      _intentPath(context, transactionId, 'cleanup');

  /// The path of one recorded intent of one transaction.
  String _intentPath(
    LifecycleContext context,
    String transactionId,
    String decision,
  ) => _fileSystem.path.join(
    context.stateRoot(),
    authoringTransactionDirectoryName,
    '$transactionId.$decision.json',
  );

  /// Removes the empty private parents of a removed payload.
  ///
  /// The private storage keeps its own directory: only an empty payload
  /// directory is removed.
  void _removeEmptyPrivateParents(LifecycleContext context, String payload) {
    final root = _fileSystem.path.join(
      context.stateRoot(),
      authoringRecoveryDirectoryName,
    );
    var parent = _fileSystem.path.dirname(payload);
    while (_fileSystem.path.isWithin(root, parent) ||
        _fileSystem.path.equals(root, parent)) {
      final type = _io.type(parent, followLinks: false);
      if (type != FileSystemEntityType.directory) return;
      if (_io.list(parent).isNotEmpty) return;
      _io.deleteEmptyDirectory(parent);
      parent = _fileSystem.path.dirname(parent);
    }
  }

  /// Rolls one publication back to its reviewed source.
  ///
  /// The rollback is protected by a bound intent that is written before the
  /// live change. An interrupted rollback may leave the source partially
  /// restored or the target partially removed: the retry accepts an
  /// unchanged subset of the reviewed evidence, refuses an added or a
  /// changed member and completes the restore before the target is removed.
  Future<LifecycleResult> _rollback(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) async {
    final target = transaction.target;
    final source = transaction.source;
    final payload = _payloadPath(context, transaction);
    // The ownership of both scopes is verified before anything changes.
    _requireUnownedLocations(context, transaction);
    // The receipt is the commit point of the publication. A committed
    // publication is never rolled back.
    if (_receiptState(context, transaction) == _ReceiptState.valid) {
      throw MambaException(
        'The publication committed its receipt; the rollback would contradict '
        'the committed state.',
        exitCode: 6,
      );
    }
    // Every observation is verified before the first deletion: a refusal
    // never leaves a partially restored state behind.
    if (transaction.recoveryPath != null) {
      _requireReviewedPayload(transaction, payload);
    }
    final intent = _readRollbackIntent(context, transaction);
    final intentPath = _intentPath(
      context,
      transaction.transactionId,
      'rollback',
    );
    final reviewedDigest = transaction.digest;
    final inPlace = source != null && _fileSystem.path.equals(source, target);
    final expectedTarget =
        transaction.publishedManifest ?? transaction.plannedManifest;
    // The published target holds only reviewed content, or an unchanged
    // subset of it when an interrupted rollback already removed members.
    final targetType = _io.type(target, followLinks: false);
    if (targetType != FileSystemEntityType.notFound) {
      if (!_targetHoldsReviewedContent(transaction)) {
        final partial =
            intent != null &&
            expectedTarget != null &&
            _observedIsSubsetOf(expectedTarget, _observedTarget(transaction));
        if (!partial) {
          throw MambaException(
            'The published target changed; the rollback would destroy an '
            'unreviewed state.',
            exitCode: 6,
          );
        }
      }
    }
    // The intent binds the rollback before the live change.
    _writeIntent(intentPath, transaction, payload, 'prepared');
    // The reviewed source is restored before the published target is
    // removed: an interrupted restore is completed, never abandoned.
    var sourceRestored = false;
    if (source != null) {
      if (inPlace) {
        if (transaction.recoveryPath != null) {
          // The reviewed source is restored over the published content: an
          // entry outside the reviewed manifest is never removed. Only an
          // entry that the reviewed publication evidence names is removed.
          _removeEvidencedAdditions(transaction);
          _restorePayload(
            payload,
            source,
            fileForm: _isFilePayload(transaction),
          );
          sourceRestored = true;
        }
      } else {
        final sourceType = _io.type(source, followLinks: false);
        if (sourceType == FileSystemEntityType.notFound) {
          if (transaction.recoveryPath == null) {
            throw MambaException(
              'The source is missing and no retained payload can restore it.',
              exitCode: 6,
            );
          }
          _restorePayload(
            payload,
            source,
            fileForm: _isFilePayload(transaction),
          );
          sourceRestored = true;
        } else if (!_sourceMatches(transaction)) {
          // An interrupted restore may have restored part of the reviewed
          // source. The survivors have to be an unchanged subset of the
          // retained evidence.
          final partial =
              intent != null &&
              transaction.payloadManifest != null &&
              _observedIsSubsetOf(
                transaction.payloadManifest!,
                _currentEvidence(source),
              );
          if (!partial) {
            throw MambaException(
              'The source changed since the publication; the rollback would '
              'destroy an unreviewed state.',
              exitCode: 6,
            );
          }
          _restorePayload(
            payload,
            source,
            fileForm: _isFilePayload(transaction),
          );
          sourceRestored = true;
        }
      }
    }
    if (source != null && transaction.recoveryPath != null) {
      // The restore is complete before the target is removed.
      if (!_sourceMatches(transaction)) {
        throw MambaException(
          'The reviewed source was not restored exactly; the rollback is '
          'refused before the published target is removed.',
          exitCode: 6,
        );
      }
    }
    if (!inPlace && targetType != FileSystemEntityType.notFound) {
      _io.delete(target);
    }
    if (!inPlace &&
        _io.type(target, followLinks: false) != FileSystemEntityType.notFound) {
      throw MambaException(
        'The published target was not removed; the rollback is refused before '
        'it is recorded.',
        exitCode: 6,
      );
    }
    _writeIntent(intentPath, transaction, payload, 'completed');
    persist(
      context.stateRoot(),
      transaction.copyWith(
        phase: AuthoringTransactionPhase.rolledBack,
        observations: <String, Object?>{
          ...transaction.observations,
          'rolledBackAt': transaction.target,
          'rollbackStatus': 'completed',
          'rollbackDigest': reviewedDigest,
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
        'sourceRestored': sourceRestored,
      },
    );
  }

  /// Whether the observed content is an unchanged subset of the reviewed
  /// manifest.
  ///
  /// A member outside the reviewed evidence is refused and a changed member
  /// is refused: only a member that an authorized deletion removed is
  /// missing.
  bool _observedIsSubsetOf(
    List<Map<String, Object?>> expected,
    List<Map<String, Object?>> observed,
  ) {
    final index = <String, Map<String, Object?>>{
      for (final entry in expected) entry['path']! as String: entry,
    };
    final singleFile =
        expected.length == 1 &&
        expected.single['path'] == 'source' &&
        expected.single['type'] == 'file' &&
        observed.length == 1;
    for (final entry in observed) {
      final member = index[entry['path']];
      if (member == null) {
        if (!singleFile) return false;
        if (!_sameContent(expected.single, entry)) return false;
        continue;
      }
      if (!_sameContent(member, entry)) return false;
    }
    return true;
  }

  /// Writes one bound intent of one transaction.
  void _writeIntent(
    String path,
    AuthoringTransaction transaction,
    String? payload,
    String status,
  ) {
    _state.writeProtectedDocument(
      path,
      utf8.encode(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'transactionId': transaction.transactionId,
          'decision': 'rollback',
          'digest': transaction.digest,
          'payload': payload,
          'status': status,
        }),
      ),
    );
  }

  /// Whether the current target holds only reviewed content.
  ///
  /// A published transaction must carry exactly the reviewed members. A
  /// prepared transaction may carry a subset of them: the publication
  /// stopped between the preparation and the publication. A member outside
  /// the reviewed evidence is never removed.
  bool _targetHoldsReviewedContent(AuthoringTransaction transaction) {
    final observed = _observedTarget(transaction);
    final inPlace =
        transaction.source != null &&
        _fileSystem.path.equals(transaction.source!, transaction.target);
    final published = transaction.publishedManifest;
    final planned = transaction.plannedManifest;
    if (transaction.phase == AuthoringTransactionPhase.published) {
      if (published == null) return false;
      if (authoringContentEvidenceMatches(published, observed)) return true;
      // An interrupted in-place rollback may already have restored the
      // reviewed source. A relocated target never qualifies: an external
      // occupant that happens to equal the retained bytes is not the
      // published evidence of this transaction.
      if (!inPlace) return false;
      return _observedMatchesReviewedContent(transaction, observed, published);
    }
    if (planned == null) return false;
    // A prepared publication may have stopped before its candidate was
    // written: the target still holds the reviewed source content.
    if (inPlace && _observedMatchesPayload(transaction, observed)) return true;
    return _observedMatchesReviewedContent(transaction, observed, planned);
  }

  /// Whether every observed member equals the reviewed content before or
  /// after the publication.
  ///
  /// A mixed occupant is only accepted when every one of its members is
  /// explained by the reviewed evidence: the retained bytes of the source or
  /// the published bytes. An arbitrary occupant is never accepted.
  bool _observedMatchesReviewedContent(
    AuthoringTransaction transaction,
    List<Map<String, Object?>> observed,
    List<Map<String, Object?>> after,
  ) {
    final before =
        transaction.payloadManifest ?? const <Map<String, Object?>>[];
    Map<String, Map<String, Object?>> indexOf(
      List<Map<String, Object?>> entries,
    ) => <String, Map<String, Object?>>{
      for (final entry in entries) entry['path']! as String: entry,
    };
    final afterIndex = indexOf(after);
    final beforeIndex = indexOf(before);
    final singleFile =
        before.length == 1 &&
        before.single['path'] == 'source' &&
        before.single['type'] == 'file' &&
        observed.length == 1;
    for (final entry in observed) {
      final path = entry['path']! as String;
      final afterEntry = afterIndex[path];
      final beforeEntry = beforeIndex[path];
      if (afterEntry != null && _sameContent(afterEntry, entry)) continue;
      if (beforeEntry != null && _sameContent(beforeEntry, entry)) continue;
      if (singleFile && _sameContent(before.single, entry)) continue;
      return false;
    }
    return true;
  }

  /// Whether two content evidence records bind the same bytes.
  bool _sameContent(
    Map<String, Object?> expected,
    Map<String, Object?> actual,
  ) =>
      expected['type'] == actual['type'] &&
      expected['length'] == actual['length'] &&
      expected['sha256'] == actual['sha256'];

  /// Whether the observed content equals the retained payload content.
  ///
  /// A single file source is retained as one file inside the payload
  /// directory, so its recorded name differs from the name of the location it
  /// restores. The content is compared, not the name.
  bool _observedMatchesPayload(
    AuthoringTransaction transaction,
    List<Map<String, Object?>> observed,
  ) {
    final expected = transaction.payloadManifest;
    if (expected == null) return false;
    if (authoringContentEvidenceMatches(expected, observed)) return true;
    if (expected.length == 1 &&
        expected.single['path'] == 'source' &&
        expected.single['type'] == 'file' &&
        observed.length == 1) {
      return _sameContent(expected.single, observed.single);
    }
    return false;
  }

  /// The observed content evidence of the published target.
  List<Map<String, Object?>> _observedTarget(AuthoringTransaction transaction) {
    final type = _io.type(transaction.target, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const <Map<String, Object?>>[];
    }
    return authoringContentEvidence(_fileSystem, transaction.target);
  }

  /// Removes the entries that the publication added to an in-place target.
  ///
  /// Only an entry that the reviewed publication evidence names and that
  /// still carries the reviewed bytes is removed. An entry outside the
  /// reviewed evidence is never removed, and a changed entry is kept.
  void _removeEvidencedAdditions(AuthoringTransaction transaction) {
    final published =
        transaction.publishedManifest ?? transaction.plannedManifest;
    final payload = transaction.payloadManifest;
    if (published == null) return;
    // A regular file target carries no added member: the retained payload
    // restores the file itself.
    if (_io.type(transaction.target, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final retained = <String>{
      if (payload != null)
        for (final entry in payload) entry['path']! as String,
    };
    final added = <Map<String, Object?>>[
      for (final entry in published)
        if (!retained.contains(entry['path'])) entry,
    ];
    for (final entry in added.reversed) {
      if (entry['type'] != 'file') continue;
      final path = _fileSystem.path.join(
        transaction.target,
        entry['path']! as String,
      );
      if (_io.type(path, followLinks: false) != FileSystemEntityType.file) {
        continue;
      }
      final bytes = _io.read(path, maxAuthoringRecoveryFileBytes);
      if (sha256.convert(bytes).toString() != entry['sha256']) continue;
      _io.delete(path);
    }
    for (final entry in added.reversed) {
      if (entry['type'] != 'directory') continue;
      final path = _fileSystem.path.join(
        transaction.target,
        entry['path']! as String,
      );
      if (_io.type(path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      try {
        _io.deleteEmptyDirectory(path);
      } on Exception {
        // A directory that still holds an unreviewed member is kept.
      }
    }
  }

  /// Completes one committed publication.
  Future<LifecycleResult> _complete(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) async {
    final target = transaction.target;
    _requireUnownedLocations(context, transaction);
    final type = _io.type(target, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException(
        'The published target is missing; the completion cannot verify it.',
        exitCode: 6,
      );
    }
    if (!_publishedTargetMatches(transaction)) {
      throw MambaException(
        'The published target changed; the completion cannot verify it.',
        exitCode: 6,
      );
    }
    final receiptId = transaction.receiptId;
    if (receiptId == null ||
        _receiptState(context, transaction) != _ReceiptState.valid) {
      throw MambaException(
        'The authoring receipt is missing; the completion cannot verify the '
        'committed publication.',
        exitCode: 6,
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
    String transactionId, {
    String purpose = 'recover',
  }) async {
    _requireSameAuthority(context, transactionId);
    final document = await readPersistedDocument(
      context.stateRoot(),
      transactionId,
    );
    if (document == null) {
      throw MambaException(
        'No authoring transaction exists for $transactionId.',
        exitCode: 4,
      );
    }
    switch (document) {
      case CurrentAuthoringTransactionDocument(:final transaction):
        final observations = _observe(context, transaction);
        final permitted = _permittedAction(context, transaction);
        final reviewId = _reviewDigest(
          transaction.transactionId,
          transaction.digest,
          observations,
          permitted,
          purpose,
        );
        return AuthoringTransactionReview(
          document: document,
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
            'forfeitedRestore': false,
            'reviewId': reviewId,
            'purpose': purpose,
            'schemaVersion': authoringTransactionSchemaVersion,
            'legacyReadOnly': false,
            'writes': false,
          },
        );
      case LegacyAuthoringTransactionDocument(:final transaction):
        final observations = _observeLegacy(context, transaction);
        final reviewId = _reviewDigest(
          transaction.transactionId,
          transaction.digest,
          observations,
          null,
          purpose,
        );
        return AuthoringTransactionReview(
          document: document,
          observations: observations,
          permittedAction: null,
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
            'permittedAction': null,
            'forfeitedRestore': false,
            'reviewId': reviewId,
            'schemaVersion': authoringLegacyTransactionSchemaVersion,
            'legacyReadOnly': true,
            'blockedReason': transaction.blockedReason,
            'writes': false,
          },
        );
    }
  }

  /// The limited observations available for a legacy read-only document.
  Map<String, Object?> _observeLegacy(
    LifecycleContext context,
    AuthoringLegacyTransaction transaction,
  ) {
    final source = transaction.source;
    final payload = transaction.recoveryPath;
    final receiptId = transaction.receiptId;
    return <String, Object?>{
      'targetExists':
          _io.type(transaction.target, followLinks: false) !=
          FileSystemEntityType.notFound,
      'targetMatches': false,
      'sourceExists':
          source != null &&
          _io.type(source, followLinks: false) != FileSystemEntityType.notFound,
      'sourceMatches': false,
      'payloadExists':
          payload != null &&
          _io.type(payload, followLinks: false) !=
              FileSystemEntityType.notFound,
      'payloadMatches': false,
      'receiptCommitted':
          receiptId != null && _receiptExists(context, receiptId),
      'unresolved': true,
    };
  }

  /// Refuses a transaction that belongs to another authority context.
  ///
  /// The scope, the state root and the project that recorded the
  /// transaction are bound to its digest. Copied evidence never authorizes a
  /// recovery in another scope or another project.
  void _requireSameAuthority(LifecycleContext context, String transactionId) {
    final document = _authorityDocument(context, transactionId);
    if (document == null) return;
    final authority = document.authority;
    if (authority['scope'] != context.scope.name ||
        authority['stateRoot'] != context.stateRoot() ||
        authority['projectRoot'] != context.projectRoot) {
      throw MambaException(
        'The authoring transaction belongs to another authority context; the '
        'recovery is refused.',
        exitCode: 6,
      );
    }
    final recordedHome = authority['home'];
    final currentHome = _effectiveHome(context);
    if (recordedHome == null && currentHome != null) {
      // The recorded context had no home: a newly resolvable home would
      // rebaseline the authority of the transaction.
      throw MambaException(
        'The authoring transaction was recorded without a home; the recovery '
        'is refused.',
        exitCode: 6,
      );
    }
    if (recordedHome != null && recordedHome != currentHome) {
      throw MambaException(
        'The authoring transaction belongs to another home; the recovery is '
        'refused.',
        exitCode: 6,
      );
    }
    final recordedUserState = authority['userStateRoot'];
    final currentUserState = _userStateRoot(context);
    if (recordedUserState == null && currentUserState != null) {
      // The recorded context had no user scope authority: a newly
      // resolvable user ledger would rebaseline it.
      throw MambaException(
        'The authoring transaction was recorded without a user state root; '
        'the recovery is refused.',
        exitCode: 6,
      );
    }
    if (recordedUserState != null) {
      if (currentUserState == null) {
        throw MambaException(
          'The original user scope authority is unavailable; the recovery is '
          'refused.',
          exitCode: 6,
        );
      }
      if (currentUserState != recordedUserState) {
        throw MambaException(
          'The authoring transaction belongs to another user state root; the '
          'recovery is refused.',
          exitCode: 6,
        );
      }
    }
  }

  /// The effective home of one context.
  String? _effectiveHome(LifecycleContext context) {
    try {
      return context.requireHome();
    } on MambaException {
      return context.home;
    }
  }

  /// The state root of the user scope.
  ///
  /// A scope that the host does not configure is not part of the authority:
  /// it never binds a transaction and it never blocks a recovery.
  ///
  /// The authority of the host decides which user scope it configures.
  String? _userStateRoot(LifecycleContext context) =>
      _authority.userStateRoot(context, _fileSystem);

  /// The authority context of one recorded transaction.
  AuthoringTransaction? _authorityDocument(
    LifecycleContext context,
    String transactionId,
  ) {
    if (!isAuthoringTransactionId(transactionId)) return null;
    final path = evidencePath(context.stateRoot(), transactionId);
    final type = _io.type(path, followLinks: false);
    if (type != FileSystemEntityType.file) return null;
    final bytes = _io.read(path, maxAuthoringTransactionBytes);
    final String encoded;
    try {
      encoded = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return null;
    }
    final AuthoringTransactionDocument document;
    try {
      document = decodeAuthoringTransactionDocument(encoded);
    } on FormatException {
      return null;
    }
    return switch (document) {
      CurrentAuthoringTransactionDocument(:final transaction) => transaction,
      LegacyAuthoringTransactionDocument() => null,
    };
  }

  /// Refuses a recovery whose locations became owned by an installation.
  ///
  /// The ownership of both scopes is verified: a record that adopted the
  /// published target or the reviewed source after the interruption
  /// contradicts the authority of the transaction.
  void _requireUnownedLocations(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) {
    final locations = transaction.reservedLocations;
    final authority = transaction.authority;
    // Every bound scope is read: the project ledger and the user ledger of
    // the recorded context. A scope that the recorded context does not bind
    // is never consulted.
    final scopes = <({LifecycleScope scope, String expectedRoot})>[];
    final recordedProjectRoot = authority['projectRoot'];
    if (recordedProjectRoot is String) {
      scopes.add((
        scope: LifecycleScope.project,
        expectedRoot: _fileSystem.path.normalize(
          _fileSystem.path.join(recordedProjectRoot, '.agent-resource'),
        ),
      ));
    }
    final recordedUserState = authority['userStateRoot'];
    if (recordedUserState is String) {
      scopes.add((scope: LifecycleScope.user, expectedRoot: recordedUserState));
    }
    for (final entry in scopes) {
      final LifecycleContext scoped;
      try {
        scoped = LifecycleContext.resolve(
          context.options.copyWith(scope: entry.scope),
          fileSystem: _fileSystem,
        );
      } on MambaException catch (error) {
        // An authority that cannot be read is never an unowned location.
        throw MambaException(
          'The ${entry.scope.name} scope authority is unavailable; the '
          'recovery is refused: ${error.message}',
          exitCode: 6,
        );
      }
      if (scoped.stateRoot() != entry.expectedRoot) {
        throw MambaException(
          'The ${entry.scope.name} scope authority changed; the recovery is '
          'refused.',
          exitCode: 6,
        );
      }
      for (final record in _state.records(scoped)) {
        if (record.lifecycle != 'live') continue;
        final claimed = <String>[
          record.location,
          for (final exposure in record.exposures) exposure.path,
        ];
        for (final location in locations) {
          if (!claimed.any((path) => _overlaps(path, location))) continue;
          throw MambaException(
            'The location $location is owned by the installation '
            '${record.installationId}; the recovery is refused.',
            exitCode: 6,
          );
        }
      }
    }
  }

  /// Whether two locations overlap.
  bool _overlaps(String first, String second) =>
      _fileSystem.path.equals(first, second) ||
      _fileSystem.path.isWithin(first, second) ||
      _fileSystem.path.isWithin(second, first);

  /// The current observations of one transaction.
  ///
  /// The observations bind the exact current state: the observed content of
  /// the target, of the source and of the retained payload, the state of the
  /// authoring receipt and the bound cleanup intent. A boolean summary would
  /// approve a state that the recovery never verified.
  Map<String, Object?> _observe(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) {
    final target = transaction.target;
    // A linked ancestor redirects the live content to another location: the
    // content evidence alone would not detect it.
    _requireUnlinkedPath(target);
    final source = transaction.source;
    if (source != null) _requireUnlinkedPath(source);
    final targetType = _io.type(target, followLinks: false);
    final targetExists = targetType != FileSystemEntityType.notFound;
    final payload = transaction.recoveryPath;
    final receipt = _receiptState(context, transaction);
    final intent = _readCleanupIntent(context, transaction);
    return <String, Object?>{
      'targetExists': targetExists,
      'targetMatches': targetExists && _publishedTargetMatches(transaction),
      'targetManifest': targetExists
          ? _currentEvidence(target)
          : const <Map<String, Object?>>[],
      'sourceExists':
          source != null &&
          _io.type(source, followLinks: false) != FileSystemEntityType.notFound,
      'sourceMatches':
          source != null &&
          _io.type(source, followLinks: false) !=
              FileSystemEntityType.notFound &&
          _sourceMatches(transaction),
      'sourceManifest': source == null ? null : _currentEvidence(source),
      'payloadExists':
          payload != null &&
          _io.type(payload, followLinks: false) !=
              FileSystemEntityType.notFound,
      'payloadManifest': payload == null ? null : _currentEvidence(payload),
      'receiptCommitted': receipt == _ReceiptState.valid,
      'receiptState': switch (receipt) {
        _ReceiptState.absent => 'absent',
        _ReceiptState.valid => 'valid',
        _ReceiptState.invalid => 'invalid',
      },
      'cleanupIntent': intent == null
          ? null
          : <String, Object?>{
              'status': intent['status'],
              'digest': intent['digest'],
              'payload': intent['payload'],
            },
      'cleanupStatus': _cleanupStatus(context, transaction, intent).status,
    };
  }

  /// The observed content evidence of one location.
  ///
  /// A missing location has no evidence. An unreadable location is refused
  /// instead of producing an unreviewed record.
  List<Map<String, Object?>> _currentEvidence(String location) {
    final type = _io.type(location, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const <Map<String, Object?>>[];
    }
    return authoringContentEvidence(_fileSystem, location);
  }

  /// The state of the authoring receipt of one transaction.
  ///
  /// The receipt is the commit point of a publication. An absent receipt, a
  /// receipt that does not match the reviewed publication and a receipt that
  /// matches it exactly are three different facts, and the recovery never
  /// treats them as one.
  _ReceiptState _receiptState(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) {
    final receiptId = transaction.receiptId;
    final receiptTarget = transaction.receiptTarget;
    if (receiptId == null || receiptTarget == null) {
      return _ReceiptState.absent;
    }
    // The receipt identity is derived from the reviewed plan and the
    // published location: a substituted identifier never proves a commit.
    if (authoringReceiptId(transaction.planId, receiptTarget) != receiptId) {
      return _ReceiptState.invalid;
    }
    final path = _fileSystem.path.join(
      context.stateRoot(),
      authoringReceiptDirectoryName,
      '$receiptId.json',
    );
    _requireUnlinkedPath(path);
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return _ReceiptState.absent;
    if (type != FileSystemEntityType.file) return _ReceiptState.invalid;
    final bytes = _io.read(path, maxAuthoringRecoveryFileBytes);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      return _ReceiptState.invalid;
    }
    if (decoded is! Map<String, Object?>) return _ReceiptState.invalid;
    final expected = authoringReceiptDocument(
      receiptId: receiptId,
      planId: transaction.planId,
      operation: transaction.operation,
      kind: transaction.kind,
      profile: transaction.profile,
      target: receiptTarget,
      root: transaction.root,
      form: transaction.form,
      derivedFrom: transaction.source,
      sourceInstallationId: transaction.sourceInstallationId,
    );
    if (jsonEncode(canonicalAuthoringJson(expected)) !=
        jsonEncode(canonicalAuthoringJson(decoded))) {
      return _ReceiptState.invalid;
    }
    return _ReceiptState.valid;
  }

  /// The recovery that one transaction permits.
  ///
  /// The direction comes from the validated receipt, not from the recorded
  /// phase alone. A publication whose receipt matches the reviewed plan
  /// committed, so it may only be completed. A publication without a receipt
  /// never committed, so it may be rolled back. A journal that claims a
  /// commit without its receipt is inconsistent evidence and is refused.
  String? _permittedAction(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) {
    if (transaction.terminal) return null;
    switch (_receiptState(context, transaction)) {
      case _ReceiptState.valid:
        return 'complete';
      case _ReceiptState.invalid:
        throw MambaException(
          'The authoring receipt does not match the reviewed publication; the '
          'recovery is refused.',
          exitCode: 6,
        );
      case _ReceiptState.absent:
        if (transaction.phase == AuthoringTransactionPhase.committed) {
          throw MambaException(
            'The authoring transaction is committed without its receipt; the '
            'evidence is inconsistent and the recovery is refused.',
            exitCode: 6,
          );
        }
        return 'rollback';
    }
  }

  /// The digest of the review.
  String _reviewDigest(
    String transactionId,
    String digest,
    Map<String, Object?> observations,
    String? permitted,
    String purpose,
  ) {
    final body = <String, Object?>{
      'transactionId': transactionId,
      'digest': digest,
      'observations': observations,
      'permittedAction': permitted,
      'purpose': purpose,
    };
    return sha256
        .convert(utf8.encode(jsonEncode(canonicalAuthoringJson(body))))
        .toString();
  }

  /// Whether the complete current source equals its retained evidence.
  bool _sourceMatches(AuthoringTransaction transaction) {
    final source = transaction.source;
    if (source == null) return false;
    final expected = transaction.payloadManifest;
    if (expected == null) {
      return _markerDigest(source) == transaction.sourceSha256;
    }
    final actual = authoringContentEvidence(_fileSystem, source);
    if (expected.length == 1 &&
        expected.single['path'] == 'source' &&
        expected.single['type'] == 'file' &&
        actual.length == 1) {
      return authoringContentEvidenceMatches(<Map<String, Object?>>[
        <String, Object?>{...expected.single, 'path': actual.single['path']},
      ], actual);
    }
    return authoringContentEvidenceMatches(expected, actual);
  }

  /// Whether the complete current target equals its recorded evidence.
  bool _publishedTargetMatches(AuthoringTransaction transaction) {
    final expected = transaction.publishedManifest;
    if (expected == null) return false;
    return authoringContentEvidenceMatches(
      expected,
      authoringContentEvidence(_fileSystem, transaction.target),
    );
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

  /// The retained payload path of one transaction.
  ///
  /// The payload is derived from the plan identity and the state root. A
  /// recorded path that names another location is refused: a substituted
  /// path never proves a retained copy.
  String _payloadPath(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) {
    final expected = _fileSystem.path.join(
      context.stateRoot(),
      authoringRecoveryDirectoryName,
      transaction.planId,
    );
    final recorded = transaction.recoveryPath;
    if (recorded == null) return expected;
    if (!_fileSystem.path.equals(
      _fileSystem.path.normalize(recorded),
      _fileSystem.path.normalize(expected),
    )) {
      throw MambaException(
        'The retained recovery payload is not the private payload of this '
        'transaction.',
        exitCode: 6,
      );
    }
    return expected;
  }

  /// Refuses a path whose ancestors carry a link.
  ///
  /// A linked ancestor redirects the private evidence to another location.
  /// The refusal is fail closed: the evidence is never read through a link.
  void _requireUnlinkedPath(String path) {
    for (final component in skillPathComponents(
      path,
      base: _fileSystem.path.rootPrefix(path),
      fs: _fileSystem,
    )) {
      if (_io.type(component, followLinks: false) ==
          FileSystemEntityType.link) {
        throw MambaException(
          'Linked authoring evidence: $component',
          exitCode: 6,
        );
      }
    }
  }

  /// Whether two observation records describe the same observed state.
  bool _sameObservations(
    Map<String, Object?> left,
    Map<String, Object?> right,
  ) =>
      jsonEncode(canonicalAuthoringJson(left)) ==
      jsonEncode(canonicalAuthoringJson(right));

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
    String payload, {
    bool allowMissingMembers = false,
  }) {
    _requirePayload(payload);
    _requireUnlinkedPath(payload);
    final expected = transaction.payloadManifest;
    if (expected == null || transaction.evidence['payloadPath'] != payload) {
      throw MambaException(
        'The retained recovery payload does not match the reviewed content.',
        exitCode: 6,
      );
    }
    final actual = authoringContentEvidence(_fileSystem, payload);
    if (authoringContentEvidenceMatches(expected, actual)) return;
    if (!allowMissingMembers) {
      throw MambaException(
        'The retained recovery payload does not match the reviewed content.',
        exitCode: 6,
      );
    }
    // An authorized cleanup may already have removed members. Every
    // survivor still has to carry the reviewed bytes.
    final reviewed = <String, Map<String, Object?>>{
      for (final entry in expected) entry['path']! as String: entry,
    };
    for (final entry in actual) {
      final member = reviewed[entry['path']];
      if (member == null ||
          member['type'] != entry['type'] ||
          member['length'] != entry['length'] ||
          member['sha256'] != entry['sha256']) {
        throw MambaException(
          'The retained recovery payload does not match the reviewed content.',
          exitCode: 6,
        );
      }
    }
  }

  /// Whether the retained payload holds the file form of the source.
  ///
  /// A file source is retained as one file named `source` inside the payload
  /// directory. The form is decided from the reviewed evidence, never from
  /// the shape of a nested member.
  bool _isFilePayload(AuthoringTransaction transaction) {
    final manifest = transaction.payloadManifest;
    if (manifest == null || manifest.length != 1) return false;
    final entry = manifest.single;
    return entry['path'] == 'source' && entry['type'] == 'file';
  }

  /// Restores the reviewed source from the retained payload.
  ///
  /// A file source is retained as one file inside the payload directory. A
  /// package source is retained as its reviewed tree. The form is decided
  /// once, from the reviewed evidence: a nested member that happens to be
  /// named `source` is never reinterpreted as the file form.
  void _restorePayload(
    String payload,
    String source, {
    required bool fileForm,
  }) {
    final type = _io.type(payload, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      if (fileForm) {
        final retained = _fileSystem.path.join(payload, 'source');
        if (_io.type(retained, followLinks: false) !=
            FileSystemEntityType.file) {
          throw MambaException(
            'The retained recovery payload does not hold the reviewed file.',
            exitCode: 6,
          );
        }
        _io.createDirectory(_fileSystem.path.dirname(source));
        _io.copyFile(retained, source);
        return;
      }
      _restoreTree(payload, source);
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

  /// Copies a retained package tree over its reviewed location.
  ///
  /// The tree is copied member by member. A nested member is never read as
  /// the file form of the payload.
  void _restoreTree(String payload, String source) {
    _io.createDirectory(source);
    for (final entry in _io.list(payload)) {
      final name = _fileSystem.path.basename(entry.path);
      final from = _fileSystem.path.join(payload, name);
      final to = _fileSystem.path.join(source, name);
      final childType = _io.type(from, followLinks: false);
      if (childType == FileSystemEntityType.directory) {
        _restoreTree(from, to);
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

/// The state of the authoring receipt of one transaction.
enum _ReceiptState {
  /// The publication never wrote its receipt.
  absent,

  /// The receipt matches the reviewed publication field by field.
  valid,

  /// The receipt is unreadable, substituted or inconsistent.
  invalid,
}

/// The observed state of the cleanup of one transaction.
final class _CleanupState {
  const _CleanupState(this.status, this.forfeitsRestore);

  /// The truthful status of the retained payload.
  final String status;

  /// Whether the cleanup forfeits the payload based restore of the source.
  final bool forfeitsRestore;
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
    required this.document,
    this.transaction,
    required this.observations,
    required this.permittedAction,
    required this.reviewId,
    required this.data,
  });

  /// The reviewed document of either supported schema.
  final AuthoringTransactionDocument document;

  /// The actionable transaction, or null for a legacy read-only document.
  final AuthoringTransaction? transaction;

  /// The current observations of the transaction.
  final Map<String, Object?> observations;

  /// The recovery that the transaction permits.
  final String? permittedAction;

  /// The identity of the review.
  final String reviewId;

  /// The reported review data.
  final Map<String, Object?> data;
}
