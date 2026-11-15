import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('PackLifecycleService prompt-aware validation', () {
    late fslib.FileSystem fs;
    late fslib.Directory sandbox;
    late fslib.Directory project;
    late fslib.Directory home;
    late fslib.Directory source;

    /// Writes a skill package with the given frontmatter.
    void writeSkill(String relative, String frontmatter) {
      final directory = fs.directory(
        fs.path.joinAll([source.path, ...relative.split('/')]),
      )..createSync(recursive: true);
      fs
          .file(fs.path.join(directory.path, 'SKILL.md'))
          .writeAsStringSync(frontmatter);
    }

    /// Bundles a reference document into a skill package.
    void bundleReference(String relative) {
      final directory = fs.directory(
        fs.path.joinAll([source.path, ...relative.split('/'), 'references']),
      )..createSync(recursive: true);
      fs
          .file(fs.path.join(directory.path, 'notes.md'))
          .writeAsStringSync('Notes.\n');
    }

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      sandbox = fs.directory('/sandbox')..createSync();
      project = fs.directory(fs.path.join(sandbox.path, 'project'))
        ..createSync();
      home = fs.directory(fs.path.join(sandbox.path, 'home'))..createSync();
      source = fs.directory(fs.path.join(sandbox.path, 'source'))..createSync();
      fs
          .file(fs.path.join(source.path, 'agent-resources.toml'))
          .writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/manual"
[[catalog.skills]]
path = "skills/plain"
''');
      writeSkill('skills/manual', '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual
''');
      writeSkill('skills/plain', '''
---
name: plain
description: An ordinary skill.
---
# Plain
''');
      fs
          .file(fs.path.join(project.path, 'agent-resources.toml'))
          .writeAsStringSync('''
schema_version = 1
[cli.install]
targets = ["claude"]
skill_method = "copy"
[packs."local/demo".source]
kind = "local"
path = "../source"
[packs."local/demo".update]
track = { kind = "local" }
''');
    });

    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    PackLifecycleRequest request({String target = 'claude'}) =>
        PackLifecycleRequest(
          operation: PackOperation.validate,
          resourceType: PackResourceType.skill,
          pack: 'local/demo',
          processWorkingDirectory: sandbox.path,
          environment: {
            'HOME': home.path,
            'USERPROFILE': home.path,
            'APPDATA': fs.path.join(home.path, 'AppData', 'Roaming'),
            'LOCALAPPDATA': fs.path.join(home.path, 'AppData', 'Local'),
          },
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          target: target,
          method: 'copy',
          dryRun: true,
          yes: true,
        );

    test(
      'refuses a manual-only Skill that is an invalid Prompt for the target',
      () async {
        bundleReference('skills/manual');
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        await expectLater(
          service.execute(request()),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'diagnostic',
              contains('invalid Prompt'),
            ),
          ),
        );
      },
    );

    test('accepts an ordinary Skill that carries bundled resources', () async {
      bundleReference('skills/plain');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final result = await service.execute(request());

      expect(result.outcome, 'valid');
    });

    test(
      'accepts a manual-only Skill for a target where it is an ordinary Skill',
      () async {
        bundleReference('skills/manual');
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        final result = await service.execute(request(target: 'codex'));

        expect(result.outcome, 'valid');
      },
    );
  });
}
