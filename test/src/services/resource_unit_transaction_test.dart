import 'dart:io';

import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _SkillUnitResource implements LifecycleResource {
  const _SkillUnitResource();

  @override
  ArtifactKind get kind => ArtifactKind.skillCanonical;

  @override
  Future<LifecycleCandidate> inspect(
    String path,
    LifecycleContext context, {
    String? expectedName,
  }) async {
    final marker = File(p.join(path, 'SKILL.md')).readAsStringSync();
    final name = RegExp(
      r'^name: ([a-z-]+)$',
      multiLine: true,
    ).firstMatch(marker)!.group(1)!;
    if (expectedName != null && name != expectedName) {
      throw MambaException('Name changed.', exitCode: 4);
    }
    return LifecycleCandidate(
      name: name,
      nativeForm: 'skill-canonical',
      validatedProfiles: const ['claude', 'codex'],
      knownConsumers: const ['claude', 'codex'],
    );
  }

  @override
  Future<void> checkUnique(
    LifecycleContext context,
    String name, {
    required String nativeDestination,
    String? excludeInstallationId,
    String? excludePath,
    Set<String> allowedPaths = const <String>{},
  }) async {}

  @override
  void validateAuthority(InstallationRecord record, LifecycleContext context) {}
}

final class _StopBeforeSecondPublication extends LifecycleIO {
  var _publications = 0;

  @override
  void rename(String source, String destination) {
    if (source.contains('${p.separator}staging${p.separator}')) {
      _publications++;
      if (_publications == 2) {
        throw StateError('Injected forced stop before second publication');
      }
    }
    super.rename(source, destination);
  }
}

final class _StopBeforeSecondQuarantine extends LifecycleIO {
  var _quarantines = 0;

  @override
  void rename(String source, String destination) {
    if (destination.contains('${p.separator}quarantine${p.separator}')) {
      _quarantines++;
      if (_quarantines == 2) {
        throw StateError('Injected forced stop before exposure removal');
      }
    }
    super.rename(source, destination);
  }
}

final class _FailAfterFirstPublication extends LifecycleIO {
  var _failed = false;

  @override
  void write(String path, List<int> bytes) {
    if (!_failed && path.contains('transactions')) {
      final text = String.fromCharCodes(bytes);
      if (text.contains('"phase":"published"')) {
        _failed = true;
        throw const FileSystemException('Injected unit journal failure');
      }
    }
    super.write(path, bytes);
  }
}

void main() {
  group('LifecycleStateService resource units', () {
    late Directory sandbox;
    late Directory project;
    late Directory home;
    late Directory source;
    late LifecycleContext context;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('resource-unit-');
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
    });

    tearDown(() async {
      if (sandbox.existsSync()) await sandbox.delete(recursive: true);
    });

    InstallationUnitPlan unit({bool unchanged = false}) {
      final content = p.join(project.path, '.agents', 'skills', 'review');
      final exposure = p.join(project.path, '.claude', 'skills', 'review');
      final action = unchanged ? InstallationEntryAction.unchanged : null;
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
            action: action ?? InstallationEntryAction.createContent,
            target: 'codex',
            nativeRoot: p.join(project.path, '.agents', 'skills'),
            nativeDestination: 'canonical',
            artifactKind: OwnedArtifactKind.skillCanonical,
          ),
          InstallationEntryPlan(
            path: exposure,
            kind: InstallationEntryKind.link,
            action: action ?? InstallationEntryAction.createLink,
            target: 'claude',
            linkTarget: content,
            nativeRoot: p.join(project.path, '.claude', 'skills'),
            nativeDestination: 'claude',
            artifactKind: OwnedArtifactKind.skillLink,
          ),
          InstallationEntryPlan(
            path: content,
            kind: InstallationEntryKind.consumer,
            action: action ?? InstallationEntryAction.recordConsumer,
            target: 'codex',
          ),
        ],
        sourcePath: source.path,
        sourceDigest: 'source-digest-is-recomputed-by-the-test-resource',
        origin: const {'status': 'evidenced', 'entryId': 'review'},
      );
    }

    InstallationUnitPlan validUnit({bool unchanged = false}) {
      final planned = unit(unchanged: unchanged);
      return InstallationUnitPlan(
        resourceType: planned.resourceType,
        resourceId: planned.resourceId,
        nativeName: planned.nativeName,
        profile: planned.profile,
        method: planned.method,
        status: planned.status,
        installationIds: planned.installationIds,
        entries: planned.entries,
        sourcePath: planned.sourcePath,
        sourceDigest: LifecycleStateService().contentDigest(
          source.path,
          ArtifactKind.skillCopy,
        ),
        origin: planned.origin,
      );
    }

    test(
      'publishes canonical content and tracks exposure and direct consumer',
      () async {
        final state = LifecycleStateService();
        final planned = validUnit();
        final result = await state.installResourceUnit(
          resource: const _SkillUnitResource(),
          context: context,
          unit: planned,
        );

        expect(result.status, InstallationUnitStatus.installed);
        expect(result.installationIds, hasLength(1));
        final content = planned.entries[0].path;
        final exposure = planned.entries[1].path;
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
        expect(records.single.knownConsumers, ['claude', 'codex']);
        expect(records.single.exposures.single.path, exposure);
        expect(records.single.origin['entryId'], 'review');
        expect(
          FileSystemEntity.typeSync(
            p.join(project.path, '.codex', 'skills'),
            followLinks: false,
          ),
          FileSystemEntityType.notFound,
        );
      },
    );

    test('canonical replacement, removal, backup restore, and list preserve consumers', () async {
      final state = LifecycleStateService();
      final planned = validUnit();
      await state.installResourceUnit(
        resource: const _SkillUnitResource(),
        context: context,
        unit: planned,
      );
      final service = SkillLifecycleService(state: state);
      final id = state.records(context).single.installationId;
      LifecycleOptions options({bool approved = false}) =>
          context.options.copyWith(approved: approved);

      final listed = await service.list(options(), verify: true);
      final occurrences = listed.data['occurrences']! as List<Object?>;
      final content =
          occurrences.singleWhere(
                (value) =>
                    (value! as Map<String, Object?>)['path'] ==
                    planned.entries[0].path,
              )!
              as Map<String, Object?>;
      expect(content['artifactKind'], 'skill-canonical');
      expect(content['directConsumers'], ['codex']);
      expect(content['exposures'], hasLength(1));
      expect(content['runtimeActivation'], 'notClaimed');

      final replacement = Directory(p.join(sandbox.path, 'replacement'))
        ..createSync();
      File(p.join(replacement.path, 'SKILL.md')).writeAsStringSync(
        '---\nname: review\ndescription: Replacement.\n---\nNew body.\n',
      );
      await service.replace(
        LifecycleReplaceInput(
          options: options(approved: true),
          installationId: id,
          source: replacement.path,
        ),
      );
      expect(
        File(p.join(planned.entries[0].path, 'SKILL.md')).readAsStringSync(),
        contains('New body.'),
      );
      expect(
        Link(planned.entries[1].path).targetSync(),
        planned.entries[0].path,
      );

      await expectLater(
        () => service.remove(
          LifecycleIdInput(options: options(approved: true), id: id),
          target: SkillHarness.codex,
        ),
        throwsA(isA<MambaException>().having((e) => e.exitCode, 'status', 4)),
      );
      await service.remove(
        LifecycleIdInput(options: options(approved: true), id: id),
        target: SkillHarness.claude,
      );
      expect(
        FileSystemEntity.typeSync(planned.entries[1].path, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(state.records(context).single.knownConsumers, ['codex']);

      final removed = await service.remove(
        LifecycleIdInput(options: options(approved: true), id: id),
      );
      expect(Directory(planned.entries[0].path).existsSync(), isFalse);
      final backupId = removed.data['outgoingBackupId']! as String;
      await service.restore(
        LifecycleIdInput(options: options(approved: true), id: backupId),
      );
      expect(
        File(p.join(planned.entries[0].path, 'SKILL.md')).readAsStringSync(),
        contains('New body.'),
      );
      expect(state.records(context).single.lifecycle, 'live');
    });

    test(
      'unchanged canonical content and exposures are a true no-op',
      () async {
        final state = LifecycleStateService();
        await state.installResourceUnit(
          resource: const _SkillUnitResource(),
          context: context,
          unit: validUnit(),
        );
        final result = await state.installResourceUnit(
          resource: const _SkillUnitResource(),
          context: context,
          unit: validUnit(unchanged: true),
        );
        expect(result.status, InstallationUnitStatus.unchanged);
        expect(state.records(context), hasLength(1));
        expect(
          Directory(p.join(project.path, '.agent-resource', 'transactions'))
              .listSync(),
          hasLength(1),
        );
      },
    );

    test(
      'unchanged units revalidate source and managed observations',
      () async {
        final state = LifecycleStateService();
        final planned = validUnit();
        await state.installResourceUnit(
          resource: const _SkillUnitResource(),
          context: context,
          unit: planned,
        );
        final unchanged = validUnit(unchanged: true);
        File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
          '---\nname: review\ndescription: Changed.\n---\nChanged.\n',
        );
        await expectLater(
          () => state.installResourceUnit(
            resource: const _SkillUnitResource(),
            context: context,
            unit: unchanged,
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 4)
                .having(
                  (error) => error.message,
                  'message',
                  contains('changed'),
                ),
          ),
        );
      },
    );

    test(
      'canonical record and backup schemas reject unknown versions',
      () async {
        final state = LifecycleStateService();
        await state.installResourceUnit(
          resource: const _SkillUnitResource(),
          context: context,
          unit: validUnit(),
        );
        final record = state.records(context).single;
        final unsupported = record.toJson();
        unsupported['recordSchemaVersion'] = 3;
        expect(
          () => InstallationRecord.fromJson(unsupported),
          throwsA(isA<FormatException>()),
        );
        final legacyWithExposures = record.toJson()
          ..['artifactKind'] = 'skill-copy';
        expect(
          () => InstallationRecord.fromJson(legacyWithExposures),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'a fresh service rolls back a partially published resource unit',
      () async {
        final planned = validUnit();
        final interrupted = LifecycleStateService(
          io: _StopBeforeSecondPublication(),
        );
        await expectLater(
          () => interrupted.installResourceUnit(
            resource: const _SkillUnitResource(),
            context: context,
            unit: planned,
          ),
          throwsA(isA<StateError>()),
        );
        final transactions = Directory(
          p.join(project.path, '.agent-resource', 'transactions'),
        ).listSync().whereType<File>().toList();
        expect(transactions, hasLength(1));
        final transactionId = p.basenameWithoutExtension(
          transactions.single.path,
        );
        final state = LifecycleStateService();
        final recovered = await state.recover(
          resource: const _SkillUnitResource(),
          context: LifecycleContext.resolve(
            context.options.copyWith(approved: true),
          ),
          transactionId: transactionId,
          action: 'rollback',
        );
        expect(recovered.outcome, 'recovered');
        expect(Directory(planned.entries[0].path).existsSync(), isFalse);
        expect(
          FileSystemEntity.typeSync(
            planned.entries[1].path,
            followLinks: false,
          ),
          FileSystemEntityType.notFound,
        );
        expect(state.records(context), isEmpty);
      },
    );

    test(
      'a fresh service completes a partially published resource unit',
      () async {
        final planned = validUnit();
        final interrupted = LifecycleStateService(
          io: _StopBeforeSecondPublication(),
        );
        await expectLater(
          () => interrupted.installResourceUnit(
            resource: const _SkillUnitResource(),
            context: context,
            unit: planned,
          ),
          throwsA(isA<StateError>()),
        );
        final transactionFile = Directory(
          p.join(project.path, '.agent-resource', 'transactions'),
        ).listSync().whereType<File>().single;
        final transactionId = p.basenameWithoutExtension(transactionFile.path);
        final state = LifecycleStateService();
        await state.recover(
          resource: const _SkillUnitResource(),
          context: LifecycleContext.resolve(
            context.options.copyWith(approved: true),
          ),
          transactionId: transactionId,
          action: 'complete',
        );
        expect(
          File(p.join(planned.entries[0].path, 'SKILL.md')).existsSync(),
          isTrue,
        );
        expect(
          FileSystemEntity.typeSync(
            planned.entries[1].path,
            followLinks: false,
          ),
          FileSystemEntityType.link,
        );
        expect(state.records(context), hasLength(1));
      },
    );

    test(
      'a fresh service rolls back an interrupted canonical removal',
      () async {
        final planned = validUnit();
        await LifecycleStateService().installResourceUnit(
          resource: const _SkillUnitResource(),
          context: context,
          unit: planned,
        );
        final id = LifecycleStateService()
            .records(context)
            .single
            .installationId;
        final service = SkillLifecycleService(
          state: LifecycleStateService(io: _StopBeforeSecondQuarantine()),
        );
        await expectLater(
          () => service.remove(
            LifecycleIdInput(
              options: context.options.copyWith(approved: true),
              id: id,
            ),
          ),
          throwsA(isA<StateError>()),
        );
        final transactionFile =
            Directory(p.join(project.path, '.agent-resource', 'transactions'))
                .listSync()
                .whereType<File>()
                .singleWhere(
                  (file) =>
                      file.readAsStringSync().contains('canonical-remove'),
                );
        final state = LifecycleStateService();
        await state.recover(
          resource: const _SkillUnitResource(),
          context: LifecycleContext.resolve(
            context.options.copyWith(approved: true),
          ),
          transactionId: p.basenameWithoutExtension(transactionFile.path),
          action: 'rollback',
        );
        expect(
          File(p.join(planned.entries[0].path, 'SKILL.md')).existsSync(),
          isTrue,
        );
        expect(
          FileSystemEntity.typeSync(
            planned.entries[1].path,
            followLinks: false,
          ),
          FileSystemEntityType.link,
        );
        expect(state.records(context).single.lifecycle, 'live');
      },
    );

    test(
      'safely restores every published entry after a journal failure',
      () async {
        final state = LifecycleStateService(io: _FailAfterFirstPublication());
        final planned = validUnit();
        await expectLater(
          () => state.installResourceUnit(
            resource: const _SkillUnitResource(),
            context: context,
            unit: planned,
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 5)
                .having(
                  (error) => error.message,
                  'message',
                  contains('restored'),
                ),
          ),
        );
        expect(Directory(planned.entries[0].path).existsSync(), isFalse);
        expect(Link(planned.entries[1].path).existsSync(), isFalse);
        expect(state.records(context), isEmpty);
        expect(File(p.join(source.path, 'SKILL.md')).existsSync(), isTrue);
      },
    );
  });
}
