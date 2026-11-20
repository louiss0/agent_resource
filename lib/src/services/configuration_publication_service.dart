import 'dart:convert';
import 'dart:io' show FileSystemEntityType, FileSystemException;

import 'package:crypto/crypto.dart' show sha256;
import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart' show MambaException;

import 'lifecycle_state_service.dart'
    show LifecycleContext, LifecycleIO, LifecycleStateService;

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

  ConfigurationPublicationResult _publishLocked(
    ConfigurationPublicationRequest request,
    String target,
  ) {
    _refuseUnsupportedTargetPath(target);
    _refusePendingEvidence(request.context);
    final path = _io.fs.path;
    final stateRoot = request.context.stateRoot();
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
      stateRoot,
      'configuration-transactions',
      '$transactionId.quarantine',
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
    String? retainedBackupPath;
    String currentSource = '';
    try {
      _io.createDirectory(path.dirname(target));
      _refuseUnsupportedTargetPath(target);
      _advance(transactionPath, transaction, 'prepared');
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

  void _refusePendingEvidence(LifecycleContext context) {
    final path = _io.fs.path;
    final directory = path.join(
      context.stateRoot(),
      'configuration-transactions',
    );
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
      if (!entry.path.endsWith('.json')) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(_readBounded(entry.path)) as Object?;
      } on FormatException {
        throw MambaException(
          'Configuration publication requires recovery; evidence '
          '${entry.path} is unreadable.',
          exitCode: 6,
        );
      }
      if (decoded case final Map<String, dynamic> map) {
        final phase = map['phase'];
        if (phase is String &&
            const <String>{
              'prepared',
              'staged',
              'published',
              'committedCleanupPending',
              'recoveryRequired',
            }.contains(phase)) {
          throw MambaException(
            'Configuration publication requires recovery; evidence '
            '${entry.path}. Inspect and remove only validated terminal '
            'evidence before retrying.',
            exitCode: 6,
          );
        }
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

  void _advance(
    String transactionPath,
    Map<String, Object?> transaction,
    String phase,
  ) {
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
