part of 'lifecycle_state_service.dart';

/// Executes one same-scope journaled cross-route transaction.
///
/// The transaction retires a complete reviewed installation group and
/// publishes the desired route's artifacts under the shared coordination
/// domain. Its journal is strict [RouteJournalEvidence]: every live rename is
/// recorded before the ledger commit, and any failure after the journal is
/// durable is compensated by [RouteRecoveryService]. Nothing outside the
/// recorded actions is touched, no artifact is deleted, and a ledger commit
/// whose outcome is uncertain is verified before compensation.
final class RouteMigrationService {
  RouteMigrationService({required this.state});

  final LifecycleStateService state;

  Future<List<InstallationRecord>> migrate(
    LifecycleContext context, {
    required List<InstallationRecord> expectedOldRecords,
    required InstallationUnitPlan desired,
  }) => state.runCoordinated(
    context: context,
    location: context.stateRoot(),
    body: () async {
      final io = state.io;
      final paths = io.fs.path;
      final stateRoot = context.stateRoot();
      final route = desired.installationRoute;
      if (context.scope == LifecycleScope.all ||
          route == null ||
          route.scope != context.scope) {
        throw ArgumentError(
          'A route migration requires a plan in the selected scope.',
        );
      }
      bool overlaps(String a, String b) =>
          paths.equals(a, b) || paths.isWithin(a, b) || paths.isWithin(b, a);
      final oldIds = {
        for (final record in expectedOldRecords) record.installationId,
      };
      final oldPaths = <String>{
        for (final record in expectedOldRecords) ...[
          record.location,
          ...record.exposures.map((exposure) => exposure.path),
        ],
      };
      List<InstallationRecord> participating() => state
          ._readRecords(stateRoot)
          .where(
            (record) =>
                oldIds.contains(record.installationId) ||
                record.lifecycle == 'live' &&
                    [
                      record.location,
                      ...record.exposures.map((e) => e.path),
                    ].any(
                      (path) => oldPaths.any((other) => overlaps(path, other)),
                    ),
          )
          .toList();
      bool ledgerMatches(List<InstallationRecord> expected) {
        final a =
            participating()
                .map((record) => jsonEncode(_sortedJson(record.toJson())))
                .toList()
              ..sort();
        final b =
            expected
                .map((record) => jsonEncode(_sortedJson(record.toJson())))
                .toList()
              ..sort();
        return jsonEncode(a) == jsonEncode(b);
      }

      if (!ledgerMatches(expectedOldRecords)) {
        throw MambaException(
          'The reviewed installation group changed before migration.',
          exitCode: 4,
        );
      }
      final occupied = <String>[
        for (final record in state._readRecords(stateRoot))
          if (record.lifecycle == 'live' &&
              !oldIds.contains(record.installationId)) ...[
            record.location,
            ...record.exposures.map((e) => e.path),
            ...record.derivedPrompts.map((prompt) => prompt.path),
          ],
      ];
      final actions = InstallationPathDiff(paths).prepare(
        oldRecords: expectedOldRecords,
        desired: desired,
        scope: context.scope,
        occupiedPaths: occupied,
      );
      final transactionId = LifecycleStateService._newId('trx');
      final journalPath = paths.join(
        stateRoot,
        'transactions',
        '$transactionId.json',
      );
      final recoveryPaths = RouteRecoveryPaths(paths);
      final actionPaths = [for (final action in actions) action.path];
      void checkPendingConversions({Set<String> excluded = const {}}) {
        state.checkPendingConversions(
          context,
          locations: actionPaths,
          installationIds: oldIds,
          packKeys: {
            ...expectedOldRecords
                .map((record) => record.installationRoute?.packKey)
                .nonNulls,
            ?route.packKey,
          },
          excludedRouteEvidencePaths: excluded,
        );
      }

      state.checkPendingMutations(context, locations: actionPaths);
      checkPendingConversions();
      final resource = SkillLifecycleService(state: state);
      for (final record in expectedOldRecords) {
        resource.validateAuthority(record, context);
        if (record.kind == ArtifactKind.skillCanonical) {
          state._requireCanonicalUnchanged(record);
        } else {
          state._requireUnchanged(record);
        }
        for (final prompt in record.derivedPrompts) {
          state._verifyBaseline(
            prompt.path,
            prompt.baseline,
            ArtifactKind.promptTemplate,
          );
        }
      }
      String? oldRootFor(String path) {
        for (final record in expectedOldRecords) {
          if (paths.equals(record.location, path)) return record.nativeRoot;
          for (final exposure in record.exposures) {
            if (paths.equals(exposure.path, path)) {
              return paths.dirname(exposure.path);
            }
          }
          for (final prompt in record.derivedPrompts) {
            if (paths.equals(prompt.path, path)) {
              return paths.dirname(prompt.path);
            }
          }
        }
        return null;
      }

      final publishEntries = [
        for (final entry in desired.entries)
          if (entry.kind != InstallationEntryKind.consumer) entry,
      ];
      final canonicalEntry = desired.method == InstallationMethod.canonical
          ? publishEntries.singleWhere(
              (entry) => entry.kind == InstallationEntryKind.content,
            )
          : null;
      final staged = <String, String>{};
      final baselines = <String, ArtifactBaseline>{};
      final kinds = <String, ArtifactKind>{};
      final newRoots = <String, String>{};
      for (final entry in publishEntries) {
        final kind = _ownedArtifactKind(entry.artifactKind);
        final nativeRoot = entry.nativeRoot;
        if (nativeRoot == null) {
          throw StateError('A published entry requires a native root.');
        }
        final action = actions.where(
          (candidate) => paths.equals(candidate.path, entry.path),
        );
        if (action.length != 1 || action.single.newKind == null) {
          throw ArgumentError(
            'A desired entry has no publish action: ${entry.path}',
          );
        }
        state._requireSafePath(
          entry.path,
          nativeRoot,
          allowFinalLink:
              kind == ArtifactKind.skillLink || action.single.oldKind != null,
        );
        state._requireSourceDistinct(
          desired.sourcePath,
          entry.path,
          nativeRoot,
          stateRoot,
        );
        if (action.single.oldKind == null) state._requireAbsent(entry.path);
        final stage = recoveryPaths
            .forLocation(nativeRoot, entry.path, transactionId)
            .staged;
        state._requireAbsent(stage);
        state._prepareStaging(nativeRoot);
        final linkSource =
            desired.method == InstallationMethod.canonical &&
                kind == ArtifactKind.skillLink
            ? canonicalEntry!.path
            : desired.sourcePath;
        if (kind == ArtifactKind.promptTemplate) {
          final content = entry.content;
          if (content == null) {
            throw StateError('A template entry requires rendered content.');
          }
          io.createDirectory(paths.dirname(stage));
          io.fs.file(stage).writeAsStringSync(content);
        } else if (desired.method == InstallationMethod.canonical &&
            kind == ArtifactKind.skillLink) {
          io.createDirectory(paths.dirname(stage));
          io.createLink(stage, linkSource);
        } else {
          state._copySource(
            linkSource,
            stage,
            kind,
            linkDestination: entry.path,
          );
        }
        final baseline = kind == ArtifactKind.skillLink
            ? state._linkBaselineFor(
                entry.path,
                io.readLink(stage),
                io.linkKind(stage),
              )
            : state._manifest(stage, kind);
        if (kind != ArtifactKind.skillLink &&
            kind != ArtifactKind.promptTemplate &&
            baseline.digest != desired.sourceDigest) {
          throw MambaException(
            'The staged resource did not match the reviewed source digest.',
            exitCode: 4,
          );
        }
        if (kind != ArtifactKind.promptTemplate &&
            state._manifest(desired.sourcePath, _contentKind(kind)).digest !=
                desired.sourceDigest) {
          throw MambaException(
            'The reviewed source changed while it was staged.',
            exitCode: 4,
          );
        }
        staged[_pathKey(entry.path)] = stage;
        baselines[entry.path] = baseline;
        kinds[entry.path] = kind;
        newRoots[entry.path] = nativeRoot;
      }
      final sortedOldRecords = [...expectedOldRecords]
        ..sort(
          (left, right) => left.installationId.compareTo(right.installationId),
        );
      final reusedIds = <String>{};
      String idFor(InstallationEntryPlan entry) {
        InstallationRecord? fallback;
        for (final record in sortedOldRecords) {
          if (reusedIds.contains(record.installationId)) continue;
          fallback ??= record;
          final consumers = {
            record.nativeDestination,
            ...record.validatedProfiles,
            ...record.knownConsumers,
          };
          if (entry.kind == InstallationEntryKind.content &&
                  record.kind == ArtifactKind.skillCanonical ||
              consumers.contains(entry.target)) {
            reusedIds.add(record.installationId);
            return record.installationId;
          }
        }
        if (fallback != null) {
          reusedIds.add(fallback.installationId);
          return fallback.installationId;
        }
        return LifecycleStateService._newId('ins');
      }

      final newRecords = <InstallationRecord>[];
      final derivedPrompts = <DerivedPromptRecord>[
        for (final entry in publishEntries)
          if (entry.kind == InstallationEntryKind.template)
            DerivedPromptRecord(
              path: entry.path,
              baseline: baselines[entry.path]!,
            ),
      ];
      if (canonicalEntry != null) {
        final targets = <String>{
          for (final entry in desired.entries)
            if (entry.kind != InstallationEntryKind.template) ?entry.target,
        }.toList()..sort();
        newRecords.add(
          InstallationRecord(
            installationId: idFor(canonicalEntry),
            kind: ArtifactKind.skillCanonical,
            scope: context.scope,
            nativeDestination: 'canonical',
            nativeForm: 'skill-canonical',
            location: canonicalEntry.path,
            nativeRoot: canonicalEntry.nativeRoot!,
            name: desired.nativeName,
            nativeProfile: null,
            validatedProfiles: targets,
            knownConsumers: targets,
            baseline: baselines[canonicalEntry.path]!,
            lifecycle: 'live',
            origin: desired.origin,
            installationRoute: route,
            backupIds: const <String>[],
            transactionId: null,
            exposures: List<ExposureRecord>.unmodifiable([
              for (final entry in publishEntries)
                if (entry.kind == InstallationEntryKind.link)
                  ExposureRecord(
                    path: entry.path,
                    target: entry.target!,
                    nativeKind:
                        baselines[entry.path]!.entries.single.nativeKind!,
                    baseline: baselines[entry.path]!,
                  ),
            ]),
          ),
        );
      } else {
        for (final entry in publishEntries) {
          if (entry.kind == InstallationEntryKind.template) continue;
          newRecords.add(
            InstallationRecord(
              installationId: idFor(entry),
              kind: kinds[entry.path]!,
              scope: context.scope,
              nativeDestination: entry.nativeDestination ?? 'shared',
              nativeForm: kinds[entry.path]!.wireName,
              location: entry.path,
              nativeRoot: entry.nativeRoot!,
              name: desired.nativeName,
              nativeProfile: null,
              validatedProfiles: <String>[?entry.target],
              knownConsumers: <String>[?entry.target],
              baseline: baselines[entry.path]!,
              lifecycle: 'live',
              origin: desired.origin,
              installationRoute: route,
              backupIds: const <String>[],
              transactionId: null,
            ),
          );
        }
      }
      if (derivedPrompts.isNotEmpty) {
        if (newRecords.isEmpty) {
          throw StateError('A derived Prompt requires a parent record.');
        }
        newRecords[0] = newRecords.first.copyWith(
          derivedPrompts: derivedPrompts,
        );
      }
      final steps = <String>[
        for (var i = 0; i < actions.length; i++) ...[
          if (actions[i].oldKind != null) '$i-remove',
          if (actions[i].newKind != null) '$i-publish',
        ],
      ];
      final completed = <String>[];
      Map<String, Object?> journal(String phase) => <String, Object?>{
        'schemaVersion': 1,
        'operation': 'cross-route',
        'transactionId': transactionId,
        'scope': context.scope.name,
        'phase': phase,
        'oldRecords': [
          for (final record in expectedOldRecords) record.toJson(),
        ],
        'newRecords': [for (final record in newRecords) record.toJson()],
        'actions': [
          for (final action in actions)
            <String, Object?>{
              'path': action.path,
              'oldKind': action.oldKind?.name,
              'newKind': action.newKind?.name,
            },
        ],
        'completedActions': completed,
      };
      void persist(Map<String, Object?> doc) {
        final encoded = jsonEncode(doc);
        RouteJournalEvidence.decode(encoded, paths);
        final temporary =
            '$journalPath.${LifecycleStateService._newId('tmp')}.tmp';
        state._requireAbsent(temporary);
        io.createDirectory(paths.dirname(journalPath));
        state._makePrivate(paths.dirname(journalPath));
        io.write(temporary, utf8.encode(encoded));
        io.rename(temporary, journalPath);
      }

      var journalWritten = false;
      Object? ledgerFailure;
      try {
        persist(journal('prepared'));
        journalWritten = true;
        checkPendingConversions(excluded: {journalPath});
        for (var i = 0; i < actions.length; i++) {
          final action = actions[i];
          if (action.oldKind != null) {
            final root = oldRootFor(action.path);
            if (root == null) {
              throw const FormatException('Missing route authority.');
            }
            final quarantine = recoveryPaths
                .forLocation(root, action.path, transactionId)
                .quarantine;
            io.createDirectory(paths.dirname(quarantine));
            io.rename(action.path, quarantine);
            completed.add('$i-remove');
            persist(
              journal(
                completed.length == steps.length ? 'published' : 'applying',
              ),
            );
          }
          if (action.newKind != null) {
            io.createDirectory(paths.dirname(action.path));
            io.rename(staged[_pathKey(action.path)]!, action.path);
            completed.add('$i-publish');
            persist(
              journal(
                completed.length == steps.length ? 'published' : 'applying',
              ),
            );
          }
        }
        var committed = false;
        try {
          final records = state
              ._readRecords(stateRoot)
              .where((record) => !oldIds.contains(record.installationId))
              .toList();
          for (final record in newRecords) {
            if (records.any(
              (current) =>
                  current.lifecycle == 'live' &&
                  record.lifecycle == 'live' &&
                  paths.equals(current.location, record.location),
            )) {
              throw MambaException(
                'A different managed installation already owns ${record.location}.',
                exitCode: 4,
              );
            }
            final index = records.indexWhere(
              (current) => current.installationId == record.installationId,
            );
            if (index < 0) {
              records.add(record);
            } else {
              records[index] = record;
            }
          }
          records.sort(
            (left, right) =>
                left.installationId.compareTo(right.installationId),
          );
          final ledgerPath = paths.join(stateRoot, 'installations.json');
          final existing =
              io.type(ledgerPath, followLinks: false) ==
                  FileSystemEntityType.notFound
              ? const <String, Object?>{}
              : _object(
                  state._readManagementJson(ledgerPath),
                  'installation ledger',
                );
          state._writeManagementJson(ledgerPath, <String, Object?>{
            ...existing,
            'schemaVersion': managementSchemaVersion,
            'installations': [for (final record in records) record.toJson()],
          });
          committed = true;
        } on Object catch (error) {
          // The write may have landed before it reported failure. Compensate
          // only against a verified ledger state.
          if (ledgerMatches(newRecords)) {
            committed = true;
          } else if (!ledgerMatches(expectedOldRecords)) {
            ledgerFailure = error;
          }
        }
        if (!committed) {
          throw MambaException(
            'The route migration ledger commit did not complete.',
            exitCode: 6,
          );
        }
        persist(journal('committed'));
        persist(journal('completed'));
        // Verified cleanup: quarantine that still matches each old baseline
        // is removed; anything changed or foreign stays as evidence.
        await RouteRecoveryService(state: state)
            .recover(context, transactionId, action: 'complete');
        return List<InstallationRecord>.unmodifiable(newRecords);
      } on Object {
        if (!journalWritten) rethrow;
        if (ledgerFailure != null || ledgerMatches(newRecords)) {
          // An indeterminate ledger must not be compensated, and a committed
          // ledger completes forward rather than rolling back.
          if (ledgerFailure == null) {
            try {
              persist(journal('committed'));
              persist(journal('completed'));
            } on Object {
              // The committed ledger is already authoritative; the journal is
              // finalized by a later recovery pass.
            }
            return List<InstallationRecord>.unmodifiable(newRecords);
          }
          try {
            persist(journal('recoveryRequired'));
          } on Object {
            // Evidence already records every completed mutation.
          }
          throw ledgerFailure;
        }
        try {
          await RouteRecoveryService(state: state)
              .recover(context, transactionId, action: 'rollback');
        } on Object {
          try {
            persist(journal('recoveryRequired'));
          } on Object {
            // Evidence already records every completed mutation.
          }
          rethrow;
        }
        rethrow;
      }
    },
  );
}

Object? _sortedJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sortedJson(value[key])};
  }
  if (value is List) return [for (final item in value) _sortedJson(item)];
  return value;
}
