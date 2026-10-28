import 'dart:io';

import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
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
