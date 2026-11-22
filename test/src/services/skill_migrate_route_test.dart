import 'dart:io';

import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/trusted_temp.dart';

void main() {
  group('SkillLifecycleService route migration', () {
    SkillLifecycleService service() =>
        SkillLifecycleService(state: LifecycleStateService());

    test(
      'migrates a claude copy to canonical content with an exposure',
      () async {
        final root = Directory(createTrustedTempPathSync('skill-migrate-'));
        addTearDown(() => root.deleteSync(recursive: true));
        final project = p.join(root.path, 'project');
        final home = p.join(root.path, 'home');
        final source = p.join(root.path, 'source');
        for (final dir in [project, home, source]) {
          Directory(dir).createSync(recursive: true);
        }
        File(p.join(source, 'SKILL.md')).writeAsStringSync(
          '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
        );
        LifecycleOptions options({
          bool dryRun = false,
          bool approved = false,
        }) => LifecycleOptions(
          approved: approved,
          processWorkingDirectory: project,
          cwd: project,
          projectRoot: project,
          home: home,
          dryRun: dryRun,
        );
        final lifecycle = service();
        await lifecycle.install(
          SkillInstallInput(
            options: options(),
            source: source,
            destination: SkillDestination.claude,
          ),
        );
        final context = LifecycleContext.resolve(options());
        final record = lifecycle.state.records(context).single;
        final live = p.join(project, '.claude', 'skills', 'review');
        expect(record.kind, ArtifactKind.skillCopy);
        expect(Directory(live).existsSync(), isTrue);

        final preview = await lifecycle.migrate(
          LifecycleIdInput(
            options: options(dryRun: true),
            id: record.installationId,
          ),
          method: InstallationMethod.canonical,
        );
        expect(preview.outcome, 'planned');
        final planId = preview.data['planId'] as String;
        expect(
          File(p.join(live, 'SKILL.md')).readAsStringSync(),
          contains('name: review'),
        );

        await expectLater(
          lifecycle.migrate(
            LifecycleIdInput(options: options(), id: record.installationId),
            method: InstallationMethod.canonical,
          ),
          throwsA(isA<MambaException>()),
        );
        await expectLater(
          lifecycle.migrate(
            LifecycleIdInput(options: options(), id: record.installationId),
            method: InstallationMethod.canonical,
            reviewedPlan: 'stale-plan',
          ),
          throwsA(isA<MambaException>()),
        );

        final migrated = await lifecycle.migrate(
          LifecycleIdInput(
            options: options(approved: true),
            id: record.installationId,
          ),
          method: InstallationMethod.canonical,
          reviewedPlan: planId,
        );
        expect(migrated.outcome, 'migrated');

        final after = lifecycle.state.records(context).single;
        expect(after.kind, ArtifactKind.skillCanonical);
        expect(after.installationRoute?.method, InstallationMethod.canonical);
        final canonical = p.join(project, '.agents', 'skills', 'review');
        expect(
          File(p.join(canonical, 'SKILL.md')).readAsStringSync(),
          contains('name: review'),
        );
        final type = FileSystemEntity.typeSync(live, followLinks: false);
        expect(type, FileSystemEntityType.link);
        final target = Link(live).targetSync();
        expect(
          p.normalize(
            p.isAbsolute(target) ? target : p.join(p.dirname(live), target),
          ),
          p.normalize(canonical),
        );
      },
    );

    test('refuses a stale reviewed plan without mutating', () async {
      final root = Directory(createTrustedTempPathSync('skill-migrate-stale-'));
      addTearDown(() => root.deleteSync(recursive: true));
      final project = p.join(root.path, 'project');
      final home = p.join(root.path, 'home');
      final source = p.join(root.path, 'source');
      for (final dir in [project, home, source]) {
        Directory(dir).createSync(recursive: true);
      }
      File(p.join(source, 'SKILL.md')).writeAsStringSync(
        '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
      );
      LifecycleOptions options() => LifecycleOptions(
        processWorkingDirectory: project,
        cwd: project,
        projectRoot: project,
        home: home,
      );
      final lifecycle = service();
      await lifecycle.install(
        SkillInstallInput(
          options: options(),
          source: source,
          destination: SkillDestination.claude,
        ),
      );
      final context = LifecycleContext.resolve(options());
      final record = lifecycle.state.records(context).single;
      final live = p.join(project, '.claude', 'skills', 'review');
      await expectLater(
        lifecycle.migrate(
          LifecycleIdInput(options: options(), id: record.installationId),
          method: InstallationMethod.canonical,
          reviewedPlan: 'stale',
        ),
        throwsA(isA<MambaException>()),
      );
      expect(
        File(p.join(live, 'SKILL.md')).readAsStringSync(),
        contains('name: review'),
      );
      expect(lifecycle.state.records(context).single.toJson(), record.toJson());
    });

    test('rejects an unchanged route as unsupported', () async {
      final root = Directory(createTrustedTempPathSync('skill-migrate-noop-'));
      addTearDown(() => root.deleteSync(recursive: true));
      final project = p.join(root.path, 'project');
      final home = p.join(root.path, 'home');
      final source = p.join(root.path, 'source');
      for (final dir in [project, home, source]) {
        Directory(dir).createSync(recursive: true);
      }
      File(p.join(source, 'SKILL.md')).writeAsStringSync(
        '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
      );
      final options = LifecycleOptions(
        processWorkingDirectory: project,
        cwd: project,
        projectRoot: project,
        home: home,
        dryRun: true,
      );
      final lifecycle = service();
      await lifecycle.install(
        SkillInstallInput(
          options: options.copyWith(dryRun: false),
          source: source,
          destination: SkillDestination.claude,
        ),
      );
      final context = LifecycleContext.resolve(options.copyWith(dryRun: false));
      final record = lifecycle.state.records(context).single;
      await expectLater(
        lifecycle.migrate(
          LifecycleIdInput(options: options, id: record.installationId),
          method: InstallationMethod.copy,
        ),
        throwsA(isA<MambaException>()),
      );
    });
  });
}
