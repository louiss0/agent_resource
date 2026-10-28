part of 'lifecycle_state_service.dart';

extension CanonicalLifecycleOperations on LifecycleStateService {
  Future<LifecycleResult> replaceCanonical({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String installationId,
    required String source,
    required Map<String, Object?> origin,
  }) async {
    final initial = recordById(context, installationId);
    _requireResource(initial, resource, context, live: true);
    _requireCanonicalUnchanged(initial);
    final candidate = await resource.inspect(
      source,
      context,
      expectedName: initial.name,
    );
    final baseline = _manifest(source, ArtifactKind.skillCanonical);
    final desired = initial.copyWith(baseline: baseline, origin: origin);
    await resource.checkUnique(
      context,
      candidate.name,
      nativeDestination: 'canonical',
      excludeInstallationId: installationId,
      allowedPaths: {
        initial.location,
        for (final exposure in initial.exposures) exposure.path,
      },
    );
    return _canonicalTransition(
      resource: resource,
      context: context,
      operation: 'replace',
      initial: initial,
      desired: desired,
      source: source,
    );
  }

  Future<LifecycleResult> removeCanonical({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String installationId,
    String? target,
  }) async {
    final initial = recordById(context, installationId);
    _requireResource(initial, resource, context, live: true);
    _requireCanonicalUnchanged(initial);
    if (target == 'codex') {
      throw MambaException(
        'A direct Codex reader cannot be revoked by metadata removal while '
        'shared canonical content remains discoverable. Remove the whole '
        'canonical installation explicitly instead.',
        exitCode: 4,
      );
    }
    if (target != null && target != 'claude') {
      throw MambaException('Unsupported canonical exposure target: $target');
    }
    final remainingExposures = initial.exposures
        .where((exposure) => exposure.target != target)
        .toList();
    final desired = target == null
        ? initial.copyWith(lifecycle: 'removed', exposures: const [])
        : initial.copyWith(
            exposures: remainingExposures,
            knownConsumers: initial.knownConsumers
                .where(
                  (consumer) =>
                      consumer != target ||
                      remainingExposures.any(
                        (exposure) => exposure.target == consumer,
                      ),
                )
                .toList(),
            validatedProfiles: initial.validatedProfiles
                .where(
                  (profile) =>
                      profile != target ||
                      remainingExposures.any(
                        (exposure) => exposure.target == profile,
                      ),
                )
                .toList(),
          );
    if (target != null &&
        desired.exposures.length == initial.exposures.length) {
      throw MambaException(
        'No managed $target exposure exists for ${initial.location}.',
        exitCode: 4,
      );
    }
    return _canonicalTransition(
      resource: resource,
      context: context,
      operation: target == null ? 'remove' : 'detach',
      initial: initial,
      desired: desired,
    );
  }

  Future<LifecycleResult> restoreCanonical({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String backupId,
  }) async {
    final backup = _backupById(
      context.stateRoot(),
      backupId,
      ArtifactKind.skillCanonical,
    );
    _verifyBackup(backup);
    final initial = recordById(context, backup.installationId);
    _requireResource(initial, resource, context, live: false);
    final historical = backup.canonicalRecord;
    if (historical == null) {
      throw MambaException(
        'Canonical backup evidence is incomplete.',
        exitCode: 4,
      );
    }
    final expectedExposure = p.join(context.claudeSkillsRoot(), initial.name);
    if (historical.installationId != backup.installationId ||
        historical.kind != ArtifactKind.skillCanonical ||
        historical.scope != backup.scope ||
        historical.scope != context.scope ||
        historical.lifecycle != 'live' ||
        !p.equals(historical.location, backup.location) ||
        !p.equals(historical.nativeRoot, backup.nativeRoot) ||
        historical.baseline.digest != backup.baseline.digest ||
        historical.exposures.any(
          (exposure) =>
              exposure.target != 'claude' ||
              !p.equals(exposure.path, expectedExposure),
        )) {
      throw MambaException(
        'Canonical backup evidence does not match its installation authority.',
        exitCode: 4,
      );
    }
    if (initial.lifecycle == 'live') {
      _requireCanonicalUnchanged(initial);
    } else {
      _requireCanonicalAbsent(initial);
    }
    final candidate = await resource.inspect(
      backup.artifactPath,
      context,
      expectedName: initial.name,
    );
    final desired = historical.copyWith(
      lifecycle: 'live',
      backupIds: initial.backupIds,
      clearTransaction: true,
    );
    await resource.checkUnique(
      context,
      candidate.name,
      nativeDestination: 'canonical',
      excludeInstallationId: initial.installationId,
      allowedPaths: {
        initial.location,
        for (final exposure in initial.exposures) exposure.path,
        for (final exposure in desired.exposures) exposure.path,
      },
    );
    return _canonicalTransition(
      resource: resource,
      context: context,
      operation: 'restore',
      initial: initial,
      desired: desired,
      source: backup.artifactPath,
      backupId: backupId,
    );
  }

  Future<LifecycleResult> _canonicalTransition({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String operation,
    required InstallationRecord initial,
    required InstallationRecord desired,
    String? source,
    String? backupId,
  }) async {
    final changes = _canonicalChanges(initial, desired);
    if (context.dryRun) {
      return LifecycleResult(
        command:
            'skill ${operation == 'restore' ? 'backup restore' : operation}',
        outcome: 'planned',
        data: <String, Object?>{
          'operation': operation,
          'installationId': initial.installationId,
          'location': initial.location,
          'scope': context.scope.name,
          'modification': initial.lifecycle == 'live' ? 'unchanged' : 'missing',
          'backupExpected': initial.lifecycle == 'live',
          'consumerEffect': operation == 'detach'
              ? 'managed-exposure-only'
              : 'all-canonical-consumers',
          'entries': [for (final change in changes) change.toJson()],
          'backupId': ?backupId,
        },
      );
    }
    _requireApproval(context, operation);
    final state = context.stateRoot();
    return _serialized(context, initial.location, () async {
      final current = recordById(context, initial.installationId);
      if (jsonEncode(current.toJson()) != jsonEncode(initial.toJson())) {
        throw MambaException(
          'The reviewed canonical record changed before $operation.',
          exitCode: 4,
        );
      }
      if (current.lifecycle == 'live') {
        _requireCanonicalUnchanged(current);
      } else {
        _requireCanonicalAbsent(current);
      }
      _blockPendingAcrossScopes(context, current.location);
      final transactionId = LifecycleStateService._newId('trx');
      final transactionPath = p.join(
        state,
        'transactions',
        '$transactionId.json',
      );
      BackupRecord? outgoing;
      if (current.lifecycle == 'live') {
        outgoing = _createBackup(state, current, transactionId);
      }
      final committedDesired = desired.copyWith(
        backupIds: <String>{...desired.backupIds, ?outgoing?.backupId}.toList(),
        clearTransaction: true,
      );
      final preparedChanges = changes
          .map((change) => change.withTransaction(transactionId))
          .toList();
      final completed = <String>[];
      var intentWritten = false;
      var commitAttempted = false;
      var committed = false;
      try {
        for (final change in preparedChanges) {
          if (change.publishNew) {
            if (change.kind == ArtifactKind.skillCanonical) {
              _prepareStaging(change.nativeRoot);
              _copySource(source!, change.stagedPath!, change.kind);
              final stagedCandidate = await resource.inspect(
                change.stagedPath!,
                context,
                expectedName: current.name,
              );
              _sameCandidate(
                LifecycleCandidate(
                  name: current.name,
                  nativeForm: current.nativeForm,
                ),
                stagedCandidate,
              );
              final actual = _manifest(change.stagedPath!, change.kind);
              if (actual.digest != change.newBaseline!.digest) {
                throw MambaException(
                  'The staged canonical content differs from the reviewed source.',
                  exitCode: 4,
                );
              }
            } else {
              io.createDirectory(p.dirname(change.stagedPath!));
              final target = desired.location;
              io.createLink(change.stagedPath!, target);
              final actual = _linkBaselineFor(
                change.location,
                io.readLink(change.stagedPath!),
                io.linkKind(change.stagedPath!),
              );
              if (actual.entries.single.target !=
                      change.newBaseline!.entries.single.target ||
                  actual.entries.single.nativeKind !=
                      change.newBaseline!.entries.single.nativeKind) {
                throw MambaException(
                  'The staged canonical exposure differs from its reviewed target.',
                  exitCode: 4,
                );
              }
            }
          }
        }
        _writeTransaction(transactionPath, <String, Object?>{
          'schemaVersion': 2,
          'transactionId': transactionId,
          'installationId': current.installationId,
          'backupId': ?backupId,
          'outgoingBackupId': ?outgoing?.backupId,
          'operation': 'canonical-$operation',
          'artifactKind': ArtifactKind.skillCanonical.wireName,
          'scope': context.scope.name,
          'location': current.location,
          'nativeRoot': current.nativeRoot,
          'oldRecord': current.toJson(),
          'newRecord': committedDesired.toJson(),
          'changes': [for (final change in preparedChanges) change.toJson()],
          'completedActions': completed,
          'phase': 'prepared',
        });
        intentWritten = true;
        for (var index = 0; index < preparedChanges.length; index++) {
          final change = preparedChanges[index];
          _applyCanonicalChange(change, completed, transactionPath, index);
        }
        _verifyCanonicalState(committedDesired);
        commitAttempted = true;
        _commitRecords(state, [committedDesired], const <String, Object?>{});
        committed = true;
        _advanceTransaction(transactionPath, 'committedCleanupPending');
        for (final change in preparedChanges) {
          if (change.removeOld &&
              io.type(change.quarantinePath!, followLinks: false) !=
                  FileSystemEntityType.notFound) {
            _verifyBaseline(
              change.quarantinePath!,
              change.oldBaseline!,
              change.kind,
            );
            io.delete(change.quarantinePath!);
          }
        }
        _advanceTransaction(transactionPath, 'committed');
        return LifecycleResult(
          command:
              'skill ${operation == 'restore' ? 'backup restore' : operation}',
          outcome: switch (operation) {
            'replace' => 'replaced',
            'remove' => 'removed',
            'detach' => 'detached',
            _ => 'restored',
          },
          data: <String, Object?>{
            'installationId': current.installationId,
            'transactionId': transactionId,
            'backupId': ?backupId,
            'outgoingBackupId': ?outgoing?.backupId,
            'location': current.location,
            'backupRetained': outgoing != null || backupId != null,
            'consumerEffect': operation == 'detach'
                ? 'managed-exposure-only'
                : 'all-canonical-consumers',
            'entries': [for (final change in preparedChanges) change.toJson()],
          },
        );
      } on Exception catch (error) {
        if (!intentWritten) {
          if (error is MambaException) rethrow;
          throw MambaException(
            'Canonical $operation failed before intent: $error',
          );
        }
        if (committed || commitAttempted) {
          throw MambaException(
            'Canonical $operation has uncertain committed state or cleanup '
            'pending; transaction $transactionId, evidence $transactionPath. $error',
            exitCode: 6,
          );
        }
        final restored = _rollbackCanonicalActions(
          preparedChanges,
          completed,
          this,
        );
        if (restored) {
          _advanceTransaction(transactionPath, 'failedRestored');
          throw MambaException(
            'Canonical $operation failed and all prior entries were restored; '
            'transaction $transactionId. $error',
            exitCode: 5,
          );
        }
        throw MambaException(
          'Canonical $operation requires recovery; transaction $transactionId, '
          'evidence $transactionPath. $error',
          exitCode: 6,
        );
      }
    });
  }

  void _applyCanonicalChange(
    _CanonicalChange change,
    List<String> completed,
    String transactionPath,
    int index,
  ) {
    if (change.removeOld && !completed.contains('$index-remove')) {
      _verifyBaseline(change.location, change.oldBaseline!, change.kind);
      _requireAbsent(change.quarantinePath!);
      io.createDirectory(p.dirname(change.quarantinePath!));
      io.rename(change.location, change.quarantinePath!);
      completed.add('$index-remove');
      _writeTransaction(transactionPath, <String, Object?>{
        ..._readTransaction(transactionPath),
        'completedActions': completed,
        'phase': change.publishNew ? 'quarantined' : 'published',
      });
    }
    if (change.publishNew && !completed.contains('$index-publish')) {
      _requireAbsent(change.location);
      io.createDirectory(p.dirname(change.location));
      _requireAbsent(change.location);
      io.rename(change.stagedPath!, change.location);
      completed.add('$index-publish');
      _writeTransaction(transactionPath, <String, Object?>{
        ..._readTransaction(transactionPath),
        'completedActions': completed,
        'phase': 'published',
      });
      _verifyBaseline(change.location, change.newBaseline!, change.kind);
    }
  }

  void _requireCanonicalUnchanged(InstallationRecord record) {
    _requireUnchanged(record);
    for (final exposure in record.exposures) {
      if (!verifyExposure(exposure)) {
        throw MambaException(
          'A canonical exposure is changed, missing, or unverifiable: ${exposure.path}',
          exitCode: 4,
        );
      }
    }
  }

  void _requireCanonicalAbsent(InstallationRecord record) {
    _requireAbsent(record.location);
    for (final exposure in record.exposures) {
      _requireAbsent(exposure.path);
    }
  }

  void _verifyCanonicalState(InstallationRecord record) {
    if (record.lifecycle == 'removed') {
      _requireCanonicalAbsent(record);
      return;
    }
    _verifyBaseline(record.location, record.baseline, record.kind);
    for (final exposure in record.exposures) {
      _verifyBaseline(exposure.path, exposure.baseline, ArtifactKind.skillLink);
    }
  }
}

final class _CanonicalChange {
  const _CanonicalChange({
    required this.location,
    required this.nativeRoot,
    required this.kind,
    required this.removeOld,
    required this.publishNew,
    this.oldBaseline,
    this.newBaseline,
    this.stagedPath,
    this.quarantinePath,
  });

  final String location;
  final String nativeRoot;
  final ArtifactKind kind;
  final bool removeOld;
  final bool publishNew;
  final ArtifactBaseline? oldBaseline;
  final ArtifactBaseline? newBaseline;
  final String? stagedPath;
  final String? quarantinePath;

  _CanonicalChange withTransaction(String transactionId) => _CanonicalChange(
    location: location,
    nativeRoot: nativeRoot,
    kind: kind,
    removeOld: removeOld,
    publishNew: publishNew,
    oldBaseline: oldBaseline,
    newBaseline: newBaseline,
    stagedPath: publishNew
        ? p.join(
            p.dirname(nativeRoot),
            '.agent-resource',
            'staging',
            transactionId,
            '${sha256.convert(utf8.encode(location)).toString().substring(0, 16)}-${p.basename(location)}',
          )
        : null,
    quarantinePath: removeOld
        ? p.join(
            p.dirname(nativeRoot),
            '.agent-resource',
            'quarantine',
            transactionId,
            '${sha256.convert(utf8.encode(location)).toString().substring(0, 16)}-${p.basename(location)}',
          )
        : null,
  );

  factory _CanonicalChange.fromJson(Object? value) {
    final map = _object(value, 'canonical change');
    return _CanonicalChange(
      location: _absolutePath(_string(map, 'location')),
      nativeRoot: _absolutePath(_string(map, 'nativeRoot')),
      kind: _artifactKindFromWire(_string(map, 'artifactKind')),
      removeOld: _bool(map, 'removeOld'),
      publishNew: _bool(map, 'publishNew'),
      oldBaseline: map['oldBaseline'] == null
          ? null
          : ArtifactBaseline.fromJson(map['oldBaseline']),
      newBaseline: map['newBaseline'] == null
          ? null
          : ArtifactBaseline.fromJson(map['newBaseline']),
      stagedPath: map['stagedPath'] == null
          ? null
          : _absolutePath(_string(map, 'stagedPath')),
      quarantinePath: map['quarantinePath'] == null
          ? null
          : _absolutePath(_string(map, 'quarantinePath')),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'location': location,
    'nativeRoot': nativeRoot,
    'artifactKind': kind.wireName,
    'removeOld': removeOld,
    'publishNew': publishNew,
    if (oldBaseline != null) 'oldBaseline': oldBaseline!.toJson(),
    if (newBaseline != null) 'newBaseline': newBaseline!.toJson(),
    if (stagedPath != null) 'stagedPath': stagedPath,
    if (quarantinePath != null) 'quarantinePath': quarantinePath,
  };
}

List<_CanonicalChange> _canonicalChanges(
  InstallationRecord initial,
  InstallationRecord desired,
) {
  final changes = <_CanonicalChange>[];
  final contentChanged =
      initial.lifecycle != desired.lifecycle ||
      initial.baseline.digest != desired.baseline.digest;
  if (contentChanged) {
    changes.add(
      _CanonicalChange(
        location: initial.location,
        nativeRoot: initial.nativeRoot,
        kind: ArtifactKind.skillCanonical,
        removeOld: initial.lifecycle == 'live',
        publishNew: desired.lifecycle == 'live',
        oldBaseline: initial.lifecycle == 'live' ? initial.baseline : null,
        newBaseline: desired.lifecycle == 'live' ? desired.baseline : null,
      ),
    );
  }
  final oldExposures = <String, ExposureRecord>{
    for (final exposure in initial.exposures) exposure.path: exposure,
  };
  final newExposures = <String, ExposureRecord>{
    for (final exposure in desired.exposures) exposure.path: exposure,
  };
  for (final exposure in initial.exposures) {
    final replacement = newExposures[exposure.path];
    if (replacement == null ||
        replacement.target != exposure.target ||
        replacement.nativeKind != exposure.nativeKind ||
        replacement.baseline.digest != exposure.baseline.digest) {
      changes.add(
        _CanonicalChange(
          location: exposure.path,
          nativeRoot: p.dirname(exposure.path),
          kind: ArtifactKind.skillLink,
          removeOld: true,
          publishNew: replacement != null,
          oldBaseline: exposure.baseline,
          newBaseline: replacement?.baseline,
        ),
      );
    }
  }
  for (final exposure in desired.exposures) {
    if (!oldExposures.containsKey(exposure.path)) {
      changes.add(
        _CanonicalChange(
          location: exposure.path,
          nativeRoot: p.dirname(exposure.path),
          kind: ArtifactKind.skillLink,
          removeOld: false,
          publishNew: true,
          newBaseline: exposure.baseline,
        ),
      );
    }
  }
  return changes;
}

bool _rollbackCanonicalActions(
  List<_CanonicalChange> changes,
  List<String> completed,
  LifecycleStateService state,
) {
  final io = state.io;
  try {
    for (final action in completed.reversed) {
      final separator = action.indexOf('-');
      final index = int.parse(action.substring(0, separator));
      final operation = action.substring(separator + 1);
      final change = changes[index];
      if (operation == 'publish') {
        state._verifyBaseline(
          change.location,
          change.newBaseline!,
          change.kind,
        );
        final failedNew =
            '${change.quarantinePath ?? change.stagedPath}.failed-new';
        state._requireAbsent(failedNew);
        io.rename(change.location, failedNew);
      } else {
        state._verifyBaseline(
          change.quarantinePath!,
          change.oldBaseline!,
          change.kind,
        );
        state._requireAbsent(change.location);
        io.rename(change.quarantinePath!, change.location);
      }
    }
    return true;
  } on Exception {
    return false;
  }
}
