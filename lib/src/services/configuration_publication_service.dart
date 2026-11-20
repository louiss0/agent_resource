import 'dart:convert';
import 'dart:io' show FileSystemEntityType, FileSystemException;

import 'package:crypto/crypto.dart' show sha256;
import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart' show MambaException;

import 'lifecycle_state_service.dart'
    show LifecycleContext, LifecycleIO, LifecycleResult, LifecycleStateService;

const maxConfigurationDocumentBytes = 8 * 1024 * 1024;

typedef ConfigurationProposal = String Function(String currentSource);

final class ConfigurationPublicationRequest({
  required final LifecycleContext context,
  required final String targetPath,
  required final String expectedSource,
  required final ConfigurationProposal propose,
});

final class ConfigurationPublicationResult(
  final String publishedSource,
  final String transactionId,
  final String transactionPath,
  final String? backupPath,
);

/// Publishes one reviewed configuration document through the lifecycle
/// coordination seam.
///
/// This supports trusted local-disk roots and cooperating writers only. It
/// does not claim crash/power-loss durability, hostile-writer resistance, or
/// uninterrupted visibility. Unsupported path, lock, or evidence conditions
/// refuse before live publication; interruption may require evidence-backed
/// recovery inspection.
interface class ConfigurationPublicationService {
  ConfigurationPublicationService({
    required fslib.FileSystem fileSystem,
    LifecycleIO? io,
    LifecycleStateService? state,
  }) : _io = state?.io ?? io ?? LifecycleIO(fs: fileSystem),
       _state =
           state ??
           LifecycleStateService(
             io: state?.io ?? io ?? LifecycleIO(fs: fileSystem),
           );

  final LifecycleIO _io;
  final LifecycleStateService _state;

  Future<ConfigurationPublicationResult> publish(
    ConfigurationPublicationRequest request,
  ) {
    final path = _io.fs.path;
    final target = path.normalize(
      path.isAbsolute(request.targetPath)
          ? request.targetPath
          : path.join(_io.fs.currentDirectory.path, request.targetPath),
    );
    return _state.runMutation(
      context: request.context,
      locations: [target],
      body: () async => _publishLocked(request, target),
    );
  }

  /// Inventories evidence only for the explicitly selected configuration target.
  Future<LifecycleResult> inspectRecovery({
    required LifecycleContext context,
    required String targetPath,
    required String command,
    String? transactionId,
    String? action,
    String? planId,
  }) async {
    if (planId != null ||
        (action != null && action != 'rollback' && action != 'complete')) {
      throw MambaException(
        'Unsupported configuration recovery action or plan.',
        exitCode: 4,
      );
    }
    if (action != null && transactionId == null) {
      throw MambaException('--action requires a transaction ID.', exitCode: 4);
    }
    final target = context.resolvePath(targetPath);
    _refuseUnsupportedTargetPath(target);
    _refuseUnsupportedTargetPath(
      _io.fs.path.join(_targetEvidenceRoot(target), 'evidence'),
    );
    final directory = _io.fs.path.join(
      _targetEvidenceRoot(target),
      'configuration-transactions',
    );
    final type = _io.type(directory, followLinks: false);
    final transactions = <Map<String, Object?>>[];
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.directory) {
        _refusePublication(
          directory,
          'configuration transaction storage is not a regular directory',
        );
      }
      for (final entry in _io.list(directory)) {
        if (_io.type(entry.path, followLinks: false) !=
            FileSystemEntityType.file) {
          _refusePublication(
            directory,
            'configuration transaction storage contains an unsafe entry',
          );
        }
        if (entry.path.endsWith('.json.previous')) {
          final primary = entry.path.substring(
            0,
            entry.path.length - '.previous'.length,
          );
          if (_io.type(primary, followLinks: false) !=
              FileSystemEntityType.file) {
            _refusePublication(
              directory,
              'configuration evidence fallback has no primary',
            );
          }
          continue;
        }
        if (!entry.path.endsWith('.json')) {
          _refusePublication(
            directory,
            'configuration transaction storage contains an unsafe entry',
          );
        }
        final decoded = _readTransaction(entry.path);
        if (decoded['schemaVersion'] != 1 ||
            decoded['operation'] != 'config-prefer-apply' ||
            decoded['target'] != target ||
            decoded['transactionId'] is! String ||
            decoded['phase'] is! String ||
            _io.fs.path.basename(entry.path) !=
                '${decoded['transactionId']}.json') {
          throw MambaException(
            'Configuration evidence is invalid: ${entry.path}.',
            exitCode: 6,
          );
        }
        if (transactionId != null &&
            decoded['transactionId'] != transactionId) {
          continue;
        }
        if (transactionId == null &&
            const {
              'committed',
              'failed',
              'failedRestored',
            }.contains(decoded['phase'])) {
          continue;
        }
        transactions.add(<String, Object?>{
          'transactionId': decoded['transactionId'],
          'target': target,
          'phase': decoded['phase'],
          'evidencePath': entry.path,
        });
      }
    }
    if (transactionId != null && transactions.isEmpty) {
      throw MambaException(
        'Configuration transaction not found: $transactionId.',
        exitCode: 4,
      );
    }
    if (action != null) {
      if (!context.dryRun && !context.approved) {
        throw MambaException(
          'Configuration recovery requires --yes or interactive approval.',
          exitCode: 4,
        );
      }
      LifecycleResult planned() => LifecycleResult(
        command: command,
        outcome: 'planned',
        data: {
          'configurationTarget': target,
          'transactionId': transactionId,
          'action': action,
          'approvalRequiredForApply': true,
        },
      );
      Future<LifecycleResult> perform() async {
        final evidencePath = transactions.single['evidencePath']! as String;
        final decoded = _readTransaction(evidencePath);
        if (decoded['transactionId'] != transactionId ||
            decoded['target'] != target ||
            decoded['operation'] != 'config-prefer-apply' ||
            decoded['schemaVersion'] != 1 ||
            decoded['expectedDigest'] is! String ||
            !RegExp(r'^[0-9a-f]{64}$')
                .hasMatch(decoded['expectedDigest'] as String)) {
          throw MambaException(
            'Configuration recovery evidence is invalid: $evidencePath.',
            exitCode: 6,
          );
        }
        final phase = decoded['phase'];
        if (action == 'complete') {
          if (!const {
            'staged',
            'published',
            'recoveryRequired',
            'committedCleanupPending',
          }.contains(phase)) {
            throw MambaException(
              'Configuration completion is not supported for phase $phase.',
              exitCode: 4,
            );
          }
          final candidate = decoded['candidateDigest'];
          final quarantine = _io.fs.path.join(
            _io.fs.path.dirname(target),
            '.agent-resource-prefer-$transactionId.quarantine',
          );
          if (decoded['quarantinePath'] != quarantine ||
              candidate is! String ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate) ||
              _io.type(target, followLinks: false) !=
                  FileSystemEntityType.file ||
              _digest(_readBounded(target)) != candidate) {
            throw MambaException(
              'Configuration completion cannot prove the published bytes.',
              exitCode: 6,
            );
          }
          final expected = decoded['expectedDigest'] as String;
          final backup = decoded['backupPath'];
          if (backup != null) {
            final expectedBackup = _io.fs.path.join(
              _targetEvidenceRoot(target),
              'configuration-backups',
              '$transactionId.bak',
            );
            if (backup != expectedBackup ||
                _io.type(expectedBackup, followLinks: false) !=
                    FileSystemEntityType.file ||
                _digest(_readBounded(expectedBackup)) != expected) {
              throw MambaException(
                'Configuration completion cannot prove the backup.',
                exitCode: 6,
              );
            }
          }
          final quarantineType = _io.type(quarantine, followLinks: false);
          if (quarantineType == FileSystemEntityType.file) {
            if (_digest(_readBounded(quarantine)) != expected) {
              throw MambaException(
                'Configuration quarantine changed; evidence retained.',
                exitCode: 6,
              );
            }
            if (!context.dryRun) _io.delete(quarantine);
          } else if (quarantineType != FileSystemEntityType.notFound) {
            throw MambaException(
              'Configuration quarantine is unsafe; evidence retained.',
              exitCode: 6,
            );
          }
          if (context.dryRun) return planned();
          _advance(
            evidencePath,
            Map<String, Object?>.from(decoded),
            'committed',
          );
          return LifecycleResult(
            command: command,
            outcome: 'recovered',
            data: {
              'configurationTarget': target,
              'transactionId': transactionId,
              'action': action,
            },
          );
        }
        if (phase != 'prepared' &&
            phase != 'staged' &&
            phase != 'recoveryRequired') {
          throw MambaException(
            'Configuration rollback is not supported for phase $phase.',
            exitCode: 4,
          );
        }
        final quarantine = _io.fs.path.join(
          _io.fs.path.dirname(target),
          '.agent-resource-prefer-$transactionId.quarantine',
        );
        if (decoded['quarantinePath'] != quarantine) {
          throw MambaException(
            'Configuration quarantine authority is invalid.',
            exitCode: 6,
          );
        }
        _refuseUnsupportedTargetPath(target);
        final targetType = _io.type(target, followLinks: false);
        final quarantineType = _io.type(quarantine, followLinks: false);
        final expected = decoded['expectedDigest'] as String;
        if (targetType == FileSystemEntityType.notFound &&
            quarantineType == FileSystemEntityType.file &&
            _digest(_readBounded(quarantine)) == expected) {
          if (!context.dryRun) _io.rename(quarantine, target);
        } else if (targetType == FileSystemEntityType.file &&
            quarantineType == FileSystemEntityType.notFound &&
            _digest(_readBounded(target)) == expected) {
          // A previous recovery may have restored the target before interruption.
        } else {
          throw MambaException(
            'Configuration rollback cannot prove the original bytes; evidence retained.',
            exitCode: 6,
          );
        }
        if (context.dryRun) return planned();
        _advance(
          evidencePath,
          Map<String, Object?>.from(decoded),
          'failedRestored',
        );
        return LifecycleResult(
          command: command,
          outcome: 'recovered',
          data: {
            'configurationTarget': target,
            'transactionId': transactionId,
            'action': action,
          },
        );
      }

      if (context.dryRun) return perform();
      return _state.runMutation(
        context: context,
        locations: [target],
        body: perform,
      );
    }
    return LifecycleResult(
      command: command,
      outcome: transactionId == null ? 'inventoried' : 'inspected',
      data: {'configurationTarget': target, 'transactions': transactions},
    );
  }

  ConfigurationPublicationResult _publishLocked(
    ConfigurationPublicationRequest request,
    String target,
  ) {
    _refuseUnsupportedTargetPath(target);
    _refuseUnsupportedTargetPath(
      _io.fs.path.join(_targetEvidenceRoot(target), 'evidence'),
    );
    _refusePendingEvidence(request.context, target);
    final path = _io.fs.path;
    final stateRoot = _targetEvidenceRoot(target);
    final transactionId = _state.newInstallationId();
    final transactionPath = path.join(
      stateRoot,
      'configuration-transactions',
      '$transactionId.json',
    );
    final backupPath = path.join(
      stateRoot,
      'configuration-backups',
      '$transactionId.bak',
    );
    final quarantinePath = path.join(
      path.dirname(target),
      '.agent-resource-prefer-$transactionId.quarantine',
    );
    final failedNewPath = '$quarantinePath.failed-new';
    final expectedDigest = _digest(request.expectedSource);
    final transaction = <String, Object?>{
      'schemaVersion': 1,
      'transactionId': transactionId,
      'operation': 'config-prefer-apply',
      'target': target,
      'expectedDigest': expectedDigest,
      'backupPath': backupPath,
      'quarantinePath': quarantinePath,
      'phase': 'prepared',
    };
    _requireAbsent(transactionPath, target);
    _requireAbsent(backupPath, target);
    _requireAbsent(quarantinePath, target);
    _requireAbsent(failedNewPath, target);
    fslib.Directory? stagingDirectory;
    var quarantined = false;
    var published = false;
    var liveChanged = false;
    var prepared = false;
    String? retainedBackupPath;
    String currentSource = '';
    try {
      _io.createDirectory(path.dirname(target));
      _refuseUnsupportedTargetPath(target);
      _advance(transactionPath, transaction, 'prepared');
      prepared = true;
      final initialType = _io.type(target, followLinks: false);
      if (initialType == FileSystemEntityType.link) {
        _refusePublication(target, 'configuration target is a symbolic link');
      }
      if (initialType != FileSystemEntityType.file &&
          initialType != FileSystemEntityType.notFound) {
        _refusePublication(
          target,
          'configuration target is not a regular file',
        );
      }
      if (initialType == FileSystemEntityType.file) {
        _io.rename(target, quarantinePath);
        quarantined = true;
        liveChanged = true;
        if (_io.type(quarantinePath, followLinks: false) !=
            FileSystemEntityType.file) {
          throw _targetChanged(target, transactionPath);
        }
        currentSource = _readBounded(quarantinePath);
        _state.writeProtectedDocument(backupPath, utf8.encode(currentSource));
        retainedBackupPath = backupPath;
      }
      if (_digest(currentSource) != expectedDigest) {
        if (quarantined &&
            _io.type(target, followLinks: false) ==
                FileSystemEntityType.notFound) {
          _io.rename(quarantinePath, target);
          quarantined = false;
          liveChanged = false;
        }
        _advance(transactionPath, transaction, 'failed');
        throw MambaException(
          'Configuration changed after review; re-run config prefer.',
          exitCode: 4,
        );
      }

      final proposed = request.propose(currentSource);
      final proposedBytes = utf8.encode(proposed);
      final candidateDigest = _digest(proposed);
      stagingDirectory = _io.fs
          .directory(path.dirname(target))
          .createTempSync('agent-resource-prefer-');
      final stagedPath = path.join(stagingDirectory.path, 'config.toml');
      _io.write(stagedPath, proposedBytes);
      if (_digest(_readBounded(stagedPath)) != candidateDigest) {
        throw MambaException(
          'Staged configuration bytes did not verify.',
          exitCode: 4,
        );
      }
      transaction['currentDigest'] = _digest(currentSource);
      transaction['candidateDigest'] = candidateDigest;
      transaction['backupPath'] = retainedBackupPath;
      _advance(transactionPath, transaction, 'staged');

      final targetBeforePublish = _io.type(target, followLinks: false);
      if (targetBeforePublish != FileSystemEntityType.notFound) {
        throw _targetChanged(target, transactionPath);
      }
      _io.rename(stagedPath, target);
      published = true;
      liveChanged = true;
      _advance(transactionPath, transaction, 'published');
      if (_io.type(target, followLinks: false) != FileSystemEntityType.file) {
        throw MambaException(
          'Published configuration is not a regular file.',
          exitCode: 6,
        );
      }
      if (quarantined) {
        if (_digest(_readBounded(quarantinePath)) != _digest(currentSource)) {
          throw MambaException(
            'Quarantined configuration evidence changed before cleanup.',
            exitCode: 6,
          );
        }
        _io.delete(quarantinePath);
        quarantined = false;
      }
      _advance(transactionPath, transaction, 'committedCleanupPending');
      _cleanupStaging(stagingDirectory);
      stagingDirectory = null;
      _advance(transactionPath, transaction, 'committed');
      return ConfigurationPublicationResult(
        proposed,
        transactionId,
        transactionPath,
        retainedBackupPath,
      );
    } on MambaException catch (error) {
      if (liveChanged && !published) {
        _restoreOrRequireRecovery(
          target: target,
          transactionPath: transactionPath,
          transaction: transaction,
          quarantinePath: quarantinePath,
          quarantined: quarantined,
          targetChanged: error.message.contains('target changed'),
          original: error,
        );
      } else if (liveChanged) {
        _advance(transactionPath, transaction, 'recoveryRequired');
        throw MambaException(
          'Cannot safely publish configuration $target after publication; '
          'recovery evidence $transactionPath. ${error.message}',
          exitCode: 6,
        );
      }
      rethrow;
    } on FileSystemException catch (error) {
      final failure = MambaException(
        'Cannot safely publish configuration $target: ${error.message}; '
        'recovery evidence $transactionPath.',
        exitCode: 6,
      );
      if (liveChanged && !published) {
        _restoreOrRequireRecovery(
          target: target,
          transactionPath: transactionPath,
          transaction: transaction,
          quarantinePath: quarantinePath,
          quarantined: quarantined,
          targetChanged: false,
          original: failure,
        );
      }
      if (prepared &&
          !liveChanged &&
          _io.type(quarantinePath, followLinks: false) ==
              FileSystemEntityType.notFound &&
          ((_io.type(target, followLinks: false) == FileSystemEntityType.file &&
                  _digest(_readBounded(target)) == expectedDigest) ||
              (_io.type(target, followLinks: false) ==
                      FileSystemEntityType.notFound &&
                  request.expectedSource.isEmpty))) {
        _advance(transactionPath, transaction, 'failed');
      }
      throw failure;
    } on FormatException catch (error) {
      _advance(transactionPath, transaction, 'recoveryRequired');
      throw MambaException(
        'Cannot safely publish configuration $target: ${error.message}; '
        'recovery evidence $transactionPath.',
        exitCode: 6,
      );
    } finally {
      _cleanupStaging(stagingDirectory);
    }
  }

  Never _restoreOrRequireRecovery({
    required String target,
    required String transactionPath,
    required Map<String, Object?> transaction,
    required String quarantinePath,
    required bool quarantined,
    required bool targetChanged,
    required MambaException original,
  }) {
    final targetType = _io.type(target, followLinks: false);
    if (!targetChanged &&
        quarantined &&
        targetType == FileSystemEntityType.notFound &&
        _io.type(quarantinePath, followLinks: false) ==
            FileSystemEntityType.file) {
      _io.rename(quarantinePath, target);
      _advance(transactionPath, transaction, 'failedRestored');
      throw original;
    }
    _advance(transactionPath, transaction, 'recoveryRequired');
    throw MambaException(
      'Cannot safely publish configuration $target: target changed before '
      'staged rename; recovery evidence $transactionPath.',
      exitCode: 6,
    );
  }

  String _targetEvidenceRoot(String target) => _io.fs.path.join(
    _io.fs.path.dirname(target),
    '.agent-resource-configuration',
    _digest(target),
  );

  void _refusePendingEvidence(LifecycleContext context, String target) {
    final path = _io.fs.path;
    for (final root in [context.stateRoot(), _targetEvidenceRoot(target)]) {
      _refusePendingDirectory(path.join(root, 'configuration-transactions'));
    }
  }

  void _refusePendingDirectory(String directory) {
    final type = _io.type(directory, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      _refusePublication(
        directory,
        'configuration transaction storage is not a regular directory',
      );
    }
    for (final entry in _io.list(directory)) {
      if (_io.type(entry.path, followLinks: false) !=
          FileSystemEntityType.file) {
        _refusePublication(
          directory,
          'configuration transaction storage contains an unsafe entry',
        );
      }
      if (entry.path.endsWith('.json.previous')) {
        final primary = entry.path.substring(
          0,
          entry.path.length - '.previous'.length,
        );
        if (_io.type(primary, followLinks: false) !=
            FileSystemEntityType.file) {
          _refusePublication(
            directory,
            'configuration evidence fallback has no primary',
          );
        }
        continue;
      }
      if (!entry.path.endsWith('.json')) {
        _refusePublication(
          directory,
          'configuration transaction storage contains an unsafe entry',
        );
      }
      final decoded = _readTransaction(entry.path);
      if (!const {
        'committed',
        'failed',
        'failedRestored',
      }.contains(decoded['phase'])) {
        throw MambaException(
          'Configuration publication requires recovery; evidence ${entry.path}.',
          exitCode: 6,
        );
      }
    }
  }

  void _refuseUnsupportedTargetPath(String target) {
    final path = _io.fs.path;
    final targetType = _io.type(target, followLinks: false);
    if (targetType == FileSystemEntityType.link) {
      _refusePublication(target, 'configuration target is a symbolic link');
    }
    if (targetType != FileSystemEntityType.file &&
        targetType != FileSystemEntityType.notFound) {
      _refusePublication(target, 'configuration target is not a regular file');
    }
    var parent = path.dirname(target);
    for (var step = 0; step < 64; step++) {
      final type = _io.type(parent, followLinks: false);
      if (type == FileSystemEntityType.link) {
        _refusePublication(
          target,
          'configuration parent chain contains a symbolic link',
        );
      }
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        _refusePublication(
          target,
          'configuration parent chain is not a regular directory',
        );
      }
      final next = path.dirname(parent);
      if (path.equals(next, parent)) return;
      parent = next;
    }
    _refusePublication(
      target,
      'configuration parent chain exceeds the 64-step budget',
    );
  }

  void _requireAbsent(String path, String target) {
    if (_io.type(path, followLinks: false) != FileSystemEntityType.notFound) {
      _refusePublication(
        target,
        'required private publication path is already occupied: $path',
      );
    }
  }

  Map<String, dynamic>? _tryReadTransaction(String path) {
    if (_io.type(path, followLinks: false) != FileSystemEntityType.file) {
      return null;
    }
    try {
      final value = jsonDecode(_readBounded(path));
      if (value is Map<String, dynamic> &&
          value['schemaVersion'] == 1 &&
          value['operation'] == 'config-prefer-apply' &&
          value['transactionId'] is String &&
          value['target'] is String &&
          value['phase'] is String &&
          value['expectedDigest'] is String) {
        return value;
      }
    } on FormatException {
      return null;
    } on MambaException {
      return null;
    }
    return null;
  }

  Map<String, dynamic> _readTransaction(String path) {
    final current = _tryReadTransaction(path);
    if (current != null) return current;
    final previous = _tryReadTransaction('$path.previous');
    if (previous != null) return previous;
    throw MambaException(
      'Configuration publication requires recovery; evidence $path is unreadable.',
      exitCode: 6,
    );
  }

  void _advance(
    String transactionPath,
    Map<String, Object?> transaction,
    String phase,
  ) {
    // Keep a complete prior record before overwriting the current one. If an
    // earlier write was interrupted, preserve its already-valid fallback.
    final current = _tryReadTransaction(transactionPath);
    if (current != null) {
      final previous = '$transactionPath.previous';
      final type = _io.type(previous, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        _refusePublication(
          previous,
          'configuration evidence fallback is not a regular file',
        );
      }
      _state.writeProtectedDocument(previous, utf8.encode(jsonEncode(current)));
    }
    _state.writeProtectedDocument(
      transactionPath,
      utf8.encode(
        jsonEncode(<String, Object?>{...transaction, 'phase': phase}),
      ),
    );
  }

  void _cleanupStaging(fslib.Directory? stagingDirectory) {
    if (stagingDirectory == null) return;
    if (_io.type(stagingDirectory.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      _io.delete(stagingDirectory.path);
    }
  }

  String _readBounded(String path) {
    final bytes = _io.read(path, maxConfigurationDocumentBytes);
    if (bytes.length > maxConfigurationDocumentBytes) {
      throw MambaException(
        'Configuration document exceeds the 8 MiB budget.',
        exitCode: 3,
      );
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw MambaException('Configuration document is not UTF-8.', exitCode: 2);
    }
  }

  String _digest(String source) =>
      sha256.convert(utf8.encode(source)).toString();

  MambaException _targetChanged(String target, String transactionPath) =>
      MambaException(
        'Cannot safely publish configuration $target: target changed before '
        'staged rename; recovery evidence $transactionPath.',
        exitCode: 6,
      );
}

Never _refusePublication(String target, String reason) => throw MambaException(
  'Cannot safely publish configuration $target: $reason.',
  exitCode: 4,
);
