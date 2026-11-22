import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/conversion/route_journal_evidence.dart';
import 'package:agent_resource/src/conversion/route_recovery_plan.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/installation/installation_route.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/route_recovery_observation_service.dart';
import 'package:agent_resource/src/services/route_recovery_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/trusted_temp.dart';

void main() {
  group('RouteMigrationService', () {
    late Directory sandbox;
    late Directory project;
    late Directory home;
    late Directory source;
    late LifecycleContext context;
    late LifecycleStateService state;
    late AcquisitionProvenance provenance;

    late String claudeRoot;
    late String codexRoot;
    late String sharedRoot;
    late String stateRoot;

    setUp(() async {
      sandbox = Directory(await createTrustedTempPath('route-migration-'));
      project = Directory(p.join(sandbox.path, 'project'))..createSync();
      home = Directory(p.join(sandbox.path, 'home'))..createSync();
      source = Directory(p.join(sandbox.path, 'source'))..createSync();
      File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
        '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
      );
      context = LifecycleContext.resolve(
        LifecycleOptions(
          processWorkingDirectory: project.path,
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
        ),
      );
      state = LifecycleStateService();
      claudeRoot = p.join(project.path, '.claude', 'skills');
      codexRoot = p.join(project.path, '.codex', 'skills');
      sharedRoot = p.join(project.path, '.agents', 'skills');
      stateRoot = p.join(project.path, '.agent-resource');
      provenance = AcquisitionProvenance(
        kind: AcquisitionLocatorKind.local,
        requestedLocator: source.path,
        resolvedLocator: source.path,
        subpath: null,
        temporary: false,
        directFile: false,
        durableLocalDirectory: true,
      );
    });

    tearDown(() async {
      if (sandbox.existsSync()) await sandbox.delete(recursive: true);
    });

    InstallationRoute route(
      InstallationMethod method,
      List<InstallationRouteTarget> targets,
    ) => InstallationRoute(
      source: provenance,
      sourceKind: AcquisitionSourceKind.resource,
      sourceRelativePath: '.',
      scope: LifecycleScope.project,
      targets: targets,
      method: method,
      derivedArtifacts: const [],
    );

    InstallationRecord copyRecord({
      required String id,
      required String location,
      required String destination,
    }) {
      final root = destination == 'claude' ? claudeRoot : codexRoot;
      return InstallationRecord(
        installationId: id,
        kind: ArtifactKind.skillCopy,
        scope: LifecycleScope.project,
        nativeDestination: destination,
        nativeForm: 'skill-copy',
        location: location,
        nativeRoot: root,
        name: 'review',
        nativeProfile: null,
        validatedProfiles: [destination],
        knownConsumers: [destination],
        baseline: state.baselineFor(location, ArtifactKind.skillCopy),
        lifecycle: 'live',
        origin: {'source': provenance.toJson(), 'entryId': 'review'},
        backupIds: const [],
        transactionId: null,
        installationRoute: route(InstallationMethod.copy, [
          InstallationRouteTarget.values.byName(destination),
        ]),
      );
    }

    InstallationRecord linkRecord({
      required String id,
      required String location,
    }) => InstallationRecord(
      installationId: id,
      kind: ArtifactKind.skillLink,
      scope: LifecycleScope.project,
      nativeDestination: 'claude',
      nativeForm: 'skill-link',
      location: location,
      nativeRoot: claudeRoot,
      name: 'review',
      nativeProfile: null,
      validatedProfiles: const ['claude'],
      knownConsumers: const ['claude'],
      baseline: state.baselineFor(location, ArtifactKind.skillLink),
      lifecycle: 'live',
      origin: {'source': provenance.toJson(), 'entryId': 'review'},
      backupIds: const [],
      transactionId: null,
      installationRoute: route(InstallationMethod.sourceLink, [
        InstallationRouteTarget.claude,
      ]),
    );

    void seedCopy({String? id}) {
      final location = p.join(claudeRoot, 'review');
      Directory(location).createSync(recursive: true);
      File(p.join(location, 'SKILL.md')).writeAsStringSync(
        File(p.join(source.path, 'SKILL.md')).readAsStringSync(),
      );
      Directory(stateRoot).createSync(recursive: true);
      File(p.join(stateRoot, 'installations.json')).writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'installations': [
            copyRecord(
              id: id ?? 'ins_${'a' * 32}',
              location: location,
              destination: 'claude',
            ).toJson(),
          ],
        }),
      );
    }

    void seedLink({String? id}) {
      final location = p.join(claudeRoot, 'review');
      Directory(claudeRoot).createSync(recursive: true);
      state.io.createLink(location, source.path);
      Directory(stateRoot).createSync(recursive: true);
      File(p.join(stateRoot, 'installations.json')).writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'installations': [
            linkRecord(
              id: id ?? 'ins_${'a' * 32}',
              location: location,
            ).toJson(),
          ],
        }),
      );
    }

    InstallationRecord oldRecord() => InstallationRecord.fromJson(
      ((jsonDecode(
                File(p.join(stateRoot, 'installations.json'))
                    .readAsStringSync(),
              ) as Map)['installations']
              as List)
          .single,
    );

    InstallationUnitPlan copyUnit({String destination = 'codex'}) {
      final root = destination == 'claude' ? claudeRoot : codexRoot;
      return InstallationUnitPlan(
        resourceType: InstallationResourceType.skill,
        resourceId: 'review',
        nativeName: 'review',
        profile: null,
        method: InstallationMethod.copy,
        status: InstallationUnitStatus.planned,
        installationIds: const [],
        entries: [
          InstallationEntryPlan(
            path: p.join(root, 'review'),
            kind: InstallationEntryKind.copy,
            action: InstallationEntryAction.createCopy,
            target: destination,
            nativeRoot: root,
            nativeDestination: destination,
            artifactKind: OwnedArtifactKind.skillCopy,
          ),
        ],
        sourcePath: source.path,
        sourceDigest: state.contentDigest(source.path, ArtifactKind.skillCopy),
        origin: {'source': provenance.toJson(), 'entryId': 'review'},
        installationRoute: route(InstallationMethod.copy, [
          InstallationRouteTarget.values.byName(destination),
        ]),
      );
    }

    InstallationUnitPlan canonicalUnit() {
      final content = p.join(sharedRoot, 'review');
      final exposure = p.join(claudeRoot, 'review');
      return InstallationUnitPlan(
        resourceType: InstallationResourceType.skill,
        resourceId: 'review',
        nativeName: 'review',
        profile: null,
        method: InstallationMethod.canonical,
        status: InstallationUnitStatus.planned,
        installationIds: const [],
        entries: [
          InstallationEntryPlan(
            path: content,
            kind: InstallationEntryKind.content,
            action: InstallationEntryAction.createContent,
            target: 'codex',
            nativeRoot: sharedRoot,
            nativeDestination: 'canonical',
            artifactKind: OwnedArtifactKind.skillCanonical,
          ),
          InstallationEntryPlan(
            path: exposure,
            kind: InstallationEntryKind.link,
            action: InstallationEntryAction.createLink,
            target: 'claude',
            linkTarget: content,
            nativeRoot: claudeRoot,
            nativeDestination: 'claude',
            artifactKind: OwnedArtifactKind.skillLink,
          ),
          InstallationEntryPlan(
            path: content,
            kind: InstallationEntryKind.consumer,
            action: InstallationEntryAction.recordConsumer,
            target: 'codex',
          ),
        ],
        sourcePath: source.path,
        sourceDigest: state.contentDigest(
          source.path,
          ArtifactKind.skillCanonical,
        ),
        origin: {'source': provenance.toJson(), 'entryId': 'review'},
        installationRoute: route(InstallationMethod.canonical, [
          InstallationRouteTarget.claude,
          InstallationRouteTarget.codex,
        ]),
      );
    }

    Map<String, Object?> journalDoc() {
      final transactions = Directory(p.join(stateRoot, 'transactions'));
      final files = transactions.existsSync()
          ? transactions.listSync().whereType<File>().toList()
          : <File>[];
      expect(files, hasLength(1));
      return jsonDecode(files.single.readAsStringSync())
          as Map<String, Object?>;
    }

    test(
      'migrates a Claude copy to canonical content with exposures',
      () async {
        seedCopy();
        final old = [oldRecord()];
        final migrated = await RouteMigrationService(
          state: state,
        ).migrate(context, expectedOldRecords: old, desired: canonicalUnit());
        expect(migrated, hasLength(1));
        final record = migrated.single;
        expect(record.kind, ArtifactKind.skillCanonical);
        final content = p.join(sharedRoot, 'review');
        final exposure = p.join(claudeRoot, 'review');
        expect(
          File(p.join(content, 'SKILL.md')).readAsStringSync(),
          File(p.join(source.path, 'SKILL.md')).readAsStringSync(),
        );
        expect(
          FileSystemEntity.typeSync(exposure, followLinks: false),
          FileSystemEntityType.link,
        );
        expect(Link(exposure).targetSync(), content);
        final records = state.records(context);
        expect(records, hasLength(1));
        expect(records.single.kind, ArtifactKind.skillCanonical);
        expect(records.single.exposures.single.path, exposure);
        expect(journalDoc()['phase'], 'completed');
      },
    );

    test('migrates a source link to a copy across native roots', () async {
      seedLink();
      final migrated = await RouteMigrationService(state: state).migrate(
        context,
        expectedOldRecords: [oldRecord()],
        desired: copyUnit(destination: 'codex'),
      );
      expect(migrated, hasLength(1));
      final location = p.join(codexRoot, 'review');
      expect(
        File(p.join(location, 'SKILL.md')).readAsStringSync(),
        File(p.join(source.path, 'SKILL.md')).readAsStringSync(),
      );
      expect(
        FileSystemEntity.typeSync(
          p.join(claudeRoot, 'review'),
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
      final records = state.records(context);
      expect(records, hasLength(1));
      expect(records.single.location, location);
      expect(journalDoc()['phase'], 'completed');
    });

    test(
      'restores artifacts and ledger after a mid-transaction failure',
      () async {
        seedCopy();
        final io = _FailAfterFirstLiveRename();
        final failing = LifecycleStateService(io: io);
        await expectLater(
          RouteMigrationService(state: failing).migrate(
            context,
            expectedOldRecords: [oldRecord()],
            desired: canonicalUnit(),
          ),
          throwsA(isA<Exception>()),
        );
        expect(
          File(p.join(claudeRoot, 'review', 'SKILL.md')).readAsStringSync(),
          contains('Body.'),
        );
        expect(
          FileSystemEntity.typeSync(
            p.join(sharedRoot, 'review'),
            followLinks: false,
          ),
          FileSystemEntityType.notFound,
        );
        final doc = journalDoc();
        expect(doc['phase'], 'rolledBack');
        final records = state.records(context);
        expect(records, hasLength(1));
        expect(records.single.kind, ArtifactKind.skillCopy);
      },
    );

    test('restores the old group when the ledger write fails', () async {
      seedCopy();
      final io = _FailLedgerWrite();
      final failing = LifecycleStateService(io: io);
      await expectLater(
        RouteMigrationService(state: failing).migrate(
          context,
          expectedOldRecords: [oldRecord()],
          desired: canonicalUnit(),
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        File(p.join(claudeRoot, 'review', 'SKILL.md')).readAsStringSync(),
        contains('Body.'),
      );
      expect(journalDoc()['phase'], 'rolledBack');
      final records = state.records(context);
      expect(records.single.kind, ArtifactKind.skillCopy);
    });

    test(
      'completes forward when the post-commit journal write fails',
      () async {
        seedCopy();
        final io = _FailCommittedJournal();
        final failing = LifecycleStateService(io: io);
        final migrated = await RouteMigrationService(state: failing).migrate(
          context,
          expectedOldRecords: [oldRecord()],
          desired: canonicalUnit(),
        );
        expect(migrated.single.kind, ArtifactKind.skillCanonical);
        final doc = journalDoc();
        expect(doc['phase'], 'published');
        expect(state.records(context).single.kind, ArtifactKind.skillCanonical);
        final journal = RouteJournalEvidence.decode(jsonEncode(doc), p.context);
        final observation = RouteRecoveryObservationService(
          state: LifecycleStateService(),
        ).inspect(journal, context);
        expect(observation.plan.decision, RecoveryDecision.complete);
        await expectLater(
          RouteRecoveryService(state: LifecycleStateService()).recover(
            context,
            doc['transactionId'] as String,
            action: 'rollback',
          ),
          throwsStateError,
        );
      },
    );

    test('refuses a foreign destination before any mutation', () async {
      seedCopy();
      final foreign = p.join(codexRoot, 'review');
      Directory(foreign).createSync(recursive: true);
      File(p.join(foreign, 'sentinel.txt')).writeAsStringSync('preserve');
      await expectLater(
        RouteMigrationService(state: state).migrate(
          context,
          expectedOldRecords: [oldRecord()],
          desired: copyUnit(destination: 'codex'),
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        File(p.join(foreign, 'sentinel.txt')).readAsStringSync(),
        'preserve',
      );
      expect(
        File(p.join(claudeRoot, 'review', 'SKILL.md')).readAsStringSync(),
        contains('Body.'),
      );
      expect(state.records(context).single.kind, ArtifactKind.skillCopy);
      final transactions = Directory(p.join(stateRoot, 'transactions'));
      expect(
        transactions.existsSync()
            ? transactions.listSync()
            : <FileSystemEntity>[],
        isEmpty,
      );
    });

    test('refuses stale reviewed records', () async {
      seedCopy();
      final stale = oldRecord().toJson();
      stale['baseline'] = <Object?>[];
      await expectLater(
        RouteMigrationService(state: state).migrate(
          context,
          expectedOldRecords: [InstallationRecord.fromJson(stale)],
          desired: canonicalUnit(),
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        File(p.join(claudeRoot, 'review', 'SKILL.md')).readAsStringSync(),
        contains('Body.'),
      );
      final transactions = Directory(p.join(stateRoot, 'transactions'));
      expect(
        transactions.existsSync()
            ? transactions.listSync()
            : <FileSystemEntity>[],
        isEmpty,
      );
    });
  });
}

final class _FailAfterFirstLiveRename extends LifecycleIO {
  var _renamed = false;
  var _done = false;

  @override
  void rename(String source, String destination) {
    super.rename(source, destination);
    if (destination.contains('${p.separator}quarantine${p.separator}')) {
      _renamed = true;
    }
  }

  @override
  void write(String path, List<int> bytes) {
    if (_renamed && !_done && path.contains('transactions')) {
      _done = true;
      throw const FileSystemException('Injected interruption');
    }
    super.write(path, bytes);
  }
}

final class _FailLedgerWrite extends LifecycleIO {
  var _done = false;

  @override
  void write(String path, List<int> bytes) {
    if (!_done && path.contains('installations.json')) {
      _done = true;
      throw const FileSystemException('Injected ledger write failure');
    }
    super.write(path, bytes);
  }
}

final class _FailCommittedJournal extends LifecycleIO {
  @override
  void write(String path, List<int> bytes) {
    if (path.contains('transactions') &&
        String.fromCharCodes(bytes).contains('"phase":"committed"')) {
      throw const FileSystemException('Injected post-commit crash');
    }
    super.write(path, bytes);
  }
}
