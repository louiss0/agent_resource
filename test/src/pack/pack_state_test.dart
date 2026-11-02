import 'dart:convert';

import 'package:file/file.dart';
import 'package:file/memory.dart';

import 'package:agent_resource/src/pack/pack_state.dart';
import 'package:test/test.dart';

void main() {
  late FileSystem fs;
  late Directory sandbox;
  late Directory state;
  late File ledger;

  setUp(() {
    fs = MemoryFileSystem(style: FileSystemStyle.posix);
    sandbox = fs.directory('/sandbox')..createSync();
    state = fs.directory(fs.path.join(sandbox.path, 'state'))..createSync();
    ledger = fs.file(fs.path.join(state.path, 'installations.json'));
  });

  Map<String, Object?> readLedger() =>
      jsonDecode(ledger.readAsStringSync()) as Map<String, Object?>;

  group(PackState, () {
    test(
      'upserts approvals, selections, and operations as separate groups',
      () {
        final stateStore = PackState(
          stateDirectory: state.path,
          fileSystem: fs,
        );
        stateStore.recordApprovals([
          {
            'packKey': 'owner/repo',
            'resourceType': 'skill',
            'resourceName': 'reviewer',
            'scope': 'project',
            'destination': 'shared',
            'folder': 'rules',
            'sourceRequested': '/source',
            'sourceResolved': '/source',
            'approvedAt': 'first',
          },
        ]);
        stateStore.recordApprovals([
          {
            'packKey': 'owner/repo',
            'resourceType': 'skill',
            'resourceName': 'reviewer',
            'scope': 'project',
            'destination': 'shared',
            'folder': 'rules',
            'sourceRequested': '/source',
            'sourceResolved': '/source',
            'approvedAt': 'second',
          },
        ]);
        stateStore.recordSelections([
          {
            'packKey': 'owner/repo',
            'resourceType': 'skill',
            'resourceName': 'reviewer',
            'scope': 'project',
            'selected': true,
          },
        ]);
        stateStore.recordOperation({
          'operationId': 'plan_v1_test',
          'operation': 'skills.install',
          'outcome': 'completed',
        });

        final document = stateStore.read();
        expect(document.approvals, hasLength(1));
        expect(document.approvals.single['approvedAt'], 'second');
        expect(document.selections.single['selected'], isTrue);
        expect(document.operations.single['operationId'], 'plan_v1_test');
        expect(document.installations, isEmpty);
      },
    );

    test('reads bounded record groups without creating or changing a lock', () {
      ledger.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'installations': [
            {'installationId': 'ins_existing', 'baseline': 'preserved'},
          ],
          'packs': [
            {'key': 'owner/repository'},
          ],
          'snapshots': const <Object?>[],
          'approvals': const <Object?>[],
          'selections': const <Object?>[],
          'operations': const <Object?>[],
        }),
      );
      final before = ledger.readAsBytesSync();

      final document = PackState(
        stateDirectory: state.path,
        fileSystem: fs,
      ).read();

      expect(document.installations.single['installationId'], 'ins_existing');
      expect(document.packs.single['key'], 'owner/repository');
      expect(ledger.readAsBytesSync(), before);
      expect(
        PackState(
          stateDirectory: fs.path.join(sandbox.path, 'absent'),
          fileSystem: fs,
        ).read().installations,
        isEmpty,
      );
      expect(
        fs.directory(fs.path.join(sandbox.path, 'absent')).existsSync(),
        isFalse,
      );
    });

    test(
      'records a complete artifact with stable UTC-millisecond refs and reuse',
      () {
        var now = DateTime.utc(2026, 10, 30, 4, 15, 0, 123);
        final artifact = fs.directory(fs.path.join(sandbox.path, 'source'))
          ..createSync();
        fs
            .file(fs.path.join(artifact.path, 'SKILL.md'))
            .writeAsStringSync('first');
        final packState = PackState(
          stateDirectory: state.path,
          fileSystem: fs,
          clock: () => now,
        );

        final first = packState.recordSnapshot(
          installationId: 'ins_one',
          artifactPath: artifact.path,
          baseline: const [
            {'path': 'SKILL.md', 'type': 'file', 'length': 5},
          ],
          sourceEvidence: const {'track': 'main', 'commit': 'abc123'},
        );
        final retained = fs.file(
          fs.path.join(
            state.path,
            'snapshots',
            first.contentDigest,
            'artifact',
            'SKILL.md',
          ),
        );
        expect(first.ref, matches(r'^20261030T041500\.123Z~[0-9a-f]{8}$'));
        expect(first.installedAt, '2026-10-30T04:15:00.123Z');
        expect(first.activations, ['2026-10-30T04:15:00.123Z']);
        expect(retained.readAsStringSync(), 'first');
        expect(
          packState.snapshotArtifactPath(
            installationId: 'ins_one',
            ref: first.ref,
          ),
          retained.parent.path,
        );
        expect(first.baseline.single['path'], 'SKILL.md');
        expect(first.sourceEvidence['commit'], 'abc123');

        now = now.add(const Duration(days: 1));
        final reused = packState.recordSnapshot(
          installationId: 'ins_one',
          artifactPath: artifact.path,
          baseline: const [
            {'path': 'SKILL.md', 'type': 'file', 'length': 5},
          ],
          sourceEvidence: const {'track': 'main', 'commit': 'def456'},
        );
        expect(reused.ref, first.ref);
        expect(reused.installedAt, first.installedAt);
        expect(reused.activations, hasLength(2));
        expect(reused.sourceEvidence['commit'], 'abc123');
        expect(readLedger()['snapshots'], hasLength(1));
      },
    );

    test(
      'looks up refs per installation and tracks noncurrent transitions',
      () {
        var now = DateTime.utc(2026, 1, 1);
        final packState = PackState(
          stateDirectory: state.path,
          fileSystem: fs,
          clock: () => now,
        );
        final firstArtifact = fs.directory(fs.path.join(sandbox.path, 'first'))
          ..createSync();
        fs
            .file(fs.path.join(firstArtifact.path, 'SKILL.md'))
            .writeAsStringSync('one');
        final secondArtifact = fs.directory(
          fs.path.join(sandbox.path, 'second'),
        )..createSync();
        fs
            .file(fs.path.join(secondArtifact.path, 'SKILL.md'))
            .writeAsStringSync('two');
        final first = packState.recordSnapshot(
          installationId: 'ins_one',
          artifactPath: firstArtifact.path,
          baseline: const [],
          sourceEvidence: const {'version': 1},
        );
        now = now.add(const Duration(hours: 1));
        final second = packState.recordSnapshot(
          installationId: 'ins_one',
          artifactPath: secondArtifact.path,
          baseline: const [],
          sourceEvidence: const {'version': 2},
        );
        packState.recordSnapshot(
          installationId: 'ins_two',
          artifactPath: secondArtifact.path,
          baseline: const [],
          sourceEvidence: const {'version': 2},
        );

        expect(
          packState
              .snapshot(installationId: 'ins_one', ref: first.ref)
              .noncurrentAt,
          '2026-01-01T01:00:00.000Z',
        );
        expect(
          packState
              .snapshot(installationId: 'ins_one', ref: second.ref)
              .noncurrentAt,
          isNull,
        );
        expect(
          () => packState.snapshot(
            installationId: 'ins_one',
            ref: packState.snapshots(installationId: 'ins_two').single.ref,
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'prunes only expired noncurrent bytes while keeping history visible',
      () {
        var now = DateTime.utc(2026, 1, 1);
        final packState = PackState(
          stateDirectory: state.path,
          fileSystem: fs,
          clock: () => now,
        );
        final artifact = fs.directory(fs.path.join(sandbox.path, 'artifact'))
          ..createSync();
        fs
            .file(fs.path.join(artifact.path, 'SKILL.md'))
            .writeAsStringSync('old');
        final old = packState.recordSnapshot(
          installationId: 'ins_one',
          artifactPath: artifact.path,
          baseline: const [],
          sourceEvidence: const {},
        );
        now = now.add(const Duration(days: 1));
        fs
            .file(fs.path.join(artifact.path, 'SKILL.md'))
            .writeAsStringSync('current');
        final current = packState.recordSnapshot(
          installationId: 'ins_one',
          artifactPath: artifact.path,
          baseline: const [],
          sourceEvidence: const {},
        );
        now = DateTime.utc(2026, 4, 2);

        expect(packState.cleanup(), [old.ref]);
        expect(
          packState
              .snapshot(installationId: 'ins_one', ref: old.ref)
              .contentAvailable,
          isFalse,
        );
        expect(
          packState
              .snapshot(installationId: 'ins_one', ref: current.ref)
              .contentAvailable,
          isTrue,
        );
        expect(packState.snapshots(), hasLength(2));
        expect(packState.cleanup(), isEmpty);
      },
    );

    test(
      'retains local edits indefinitely unless cleanup explicitly selects them',
      () {
        var now = DateTime.utc(2026, 1, 1);
        final packState = PackState(
          stateDirectory: state.path,
          fileSystem: fs,
          clock: () => now,
        );
        final artifact = fs.directory(fs.path.join(sandbox.path, 'edited'))
          ..createSync();
        fs
            .file(fs.path.join(artifact.path, 'SKILL.md'))
            .writeAsStringSync('my edits');
        final edited = packState.recordLocalEdit(
          installationId: 'ins_one',
          artifactPath: artifact.path,
          baseline: const [],
          editedEvidence: const {'reason': 'replace-local'},
        );
        now = now.add(const Duration(days: 10000));

        expect(packState.cleanup(), isEmpty);
        expect(
          packState
              .snapshot(installationId: 'ins_one', ref: edited.ref)
              .contentAvailable,
          isTrue,
        );
        expect(packState.cleanup(localEdits: true), [edited.ref]);
        expect(
          packState
              .snapshot(installationId: 'ins_one', ref: edited.ref)
              .contentAvailable,
          isFalse,
        );
      },
    );

    test('keeps source snapshots and identical local-edit backups in separate retention classes', () {
      final packState = PackState(
        stateDirectory: state.path,
        fileSystem: fs,
        clock: () => DateTime.utc(2026, 1, 1),
      );
      final artifact = fs.directory(fs.path.join(sandbox.path, 'same'))
        ..createSync();
      fs
          .file(fs.path.join(artifact.path, 'SKILL.md'))
          .writeAsStringSync('same bytes');
      final edited = packState.recordLocalEdit(
        installationId: 'ins_one',
        artifactPath: artifact.path,
        baseline: const [],
        editedEvidence: const {'kind': 'edited'},
      );

      final source = packState.recordSnapshot(
        installationId: 'ins_one',
        artifactPath: artifact.path,
        baseline: const [],
        sourceEvidence: const {'kind': 'source'},
      );

      expect(source.ref, isNot(edited.ref));
      expect(source.retentionClass, 'source');
      expect(source.noncurrentAt, isNull);
      expect(packState.snapshots(), hasLength(2));
    });

    test(
      'extends a content suffix when a timestamp prefix is already occupied',
      () {
        final now = DateTime.utc(2026, 1, 1);
        final packState = PackState(
          stateDirectory: state.path,
          fileSystem: fs,
          clock: () => now,
        );
        final artifact = fs.directory(fs.path.join(sandbox.path, 'artifact'))
          ..createSync();
        fs
            .file(fs.path.join(artifact.path, 'SKILL.md'))
            .writeAsStringSync('content');
        final original = packState.recordSnapshot(
          installationId: 'ins_one',
          artifactPath: artifact.path,
          baseline: const [],
          sourceEvidence: const {},
        );
        final document = readLedger();
        final forged = Map<String, Object?>.from(
          (document['snapshots']! as List).single as Map<String, Object?>,
        )..['contentDigest'] = 'f' * 64;
        ledger.writeAsStringSync(
          jsonEncode({
            ...document,
            'snapshots': [forged],
          }),
        );

        final disambiguated = packState.recordSnapshot(
          installationId: 'ins_two',
          artifactPath: artifact.path,
          baseline: const [],
          sourceEvidence: const {},
        );
        expect(
          disambiguated.ref,
          startsWith(original.ref.substring(0, original.ref.length - 1)),
        );
        expect(disambiguated.ref.split('~').last, hasLength(9));
      },
    );

    test(
      'protects active recovery and bytes shared with a current snapshot',
      () {
        var now = DateTime.utc(2026, 1, 1);
        final packState = PackState(
          stateDirectory: state.path,
          fileSystem: fs,
          clock: () => now,
        );
        final artifact = fs.directory(fs.path.join(sandbox.path, 'artifact'))
          ..createSync();
        fs
            .file(fs.path.join(artifact.path, 'SKILL.md'))
            .writeAsStringSync('shared');
        final shared = packState.recordSnapshot(
          installationId: 'ins_old',
          artifactPath: artifact.path,
          baseline: const [],
          sourceEvidence: const {},
        );
        packState.recordSnapshot(
          installationId: 'ins_current',
          artifactPath: artifact.path,
          baseline: const [],
          sourceEvidence: const {},
        );
        now = now.add(const Duration(days: 100));
        expect(packState.cleanup(), isEmpty);
        expect(
          packState
              .snapshot(installationId: 'ins_old', ref: shared.ref)
              .contentAvailable,
          isTrue,
        );

        fs
            .file(fs.path.join(artifact.path, 'SKILL.md'))
            .writeAsStringSync('recovery');
        final recovery = packState.recordSnapshot(
          installationId: 'ins_recovery',
          artifactPath: artifact.path,
          baseline: const [],
          sourceEvidence: const {},
        );
        packState.markInstallationNoncurrent('ins_recovery');
        now = now.add(const Duration(days: 100));
        packState.updateRecordGroups(
          operations: [
            {
              'operationId': 'op_recovery',
              'recovery': 'active',
              'snapshotRef': recovery.ref,
            },
          ],
        );
        expect(packState.cleanup(), isEmpty);
        expect(
          packState
              .snapshot(installationId: 'ins_recovery', ref: recovery.ref)
              .contentAvailable,
          isTrue,
        );
      },
    );

    test('rejects an unsupported schema without mutation', () {
      ledger.writeAsStringSync('{"schemaVersion":0,"installations":[]}');
      final before = ledger.readAsBytesSync();
      final packState = PackState(stateDirectory: state.path, fileSystem: fs);
      expect(packState.read, throwsFormatException);
      expect(ledger.readAsBytesSync(), before);
      expect(() => packState.cleanup(), throwsFormatException);
      expect(ledger.readAsBytesSync(), before);
    });

    test(
      'updates pack record groups atomically without replacing installations',
      () {
        ledger.writeAsStringSync(
          jsonEncode({
            'schemaVersion': 1,
            'installations': [
              {
                'installationId': 'ins_existing',
                'baseline': ['unchanged'],
              },
            ],
          }),
        );
        final packState = PackState(stateDirectory: state.path, fileSystem: fs);

        packState.updateRecordGroups(
          packs: const [
            {
              'key': 'owner/repository',
              'source': {'kind': 'github'},
            },
          ],
          approvals: const [
            {'installationId': 'ins_existing', 'folder': 'rules'},
          ],
          selections: const [
            {
              'pack': 'owner/repository',
              'selected': ['example'],
            },
          ],
          operations: const [
            {'operationId': 'op_one', 'recovery': 'active'},
          ],
        );

        final document = packState.read();
        expect(document.installations.single['baseline'], ['unchanged']);
        expect(document.packs.single['key'], 'owner/repository');
        expect(document.approvals.single['folder'], 'rules');
        expect(document.selections, hasLength(1));
        expect(document.operations.single['recovery'], 'active');
      },
    );
  });
}
