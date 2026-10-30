import 'dart:io';

import 'package:agent_resource/src/pack/pack_configuration.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group(PackConfiguration, () {
    test(
      'parses consumer preferences, packs, resource rules, and catalogs',
      () {
        final configuration = PackConfiguration.parse(r'''
schema_version = 1

[cli.install]
targets = ["codex"]
skill_method = "canonical"

[cli.retention]
snapshot_days = 30

[packs."mattpocock/skills".source]
kind = "github"
repository = "mattpocock/skills"
subpath = "packages/resources"

[packs."mattpocock/skills".install]
targets = ["codex", "claude"]
skill_method = "copy"

[packs."mattpocock/skills".update]
track = { kind = "release", artifact = "attachment", attachment = "skills.zip" }
bump = "minor"
include_prerelease = true

[packs."mattpocock/skills".resources.skills]
exclude = [{ name = "unwanted-skill" }]

[[packs."mattpocock/skills".resources.skills.overrides]]
name = "example-skill"
extra_folders = ["rules"]

[packs."mattpocock/skills".resources.agents]
exclude = [{ name = "old-reviewer" }]

[packs."git-example".source]
kind = "git"
url = "https://git.example.test/team/resources.git"

[packs."git-example".update]
track = { kind = "branch", name = "main" }

[packs."local-example".source]
kind = "local"
path = "../resources"

[packs."download-example".source]
kind = "download"
url = "https://downloads.example.test/resources.zip"

[[catalog.skills]]
path = "skills/my-skill"

[[catalog.agents]]
path = "agents/reviewer.md"
profile = "claude"
''', configPath: '/workspace/project/agent-resources.toml');

        expect(configuration.schemaVersion, 1);
        expect(configuration.cli.install.targets, ['codex']);
        expect(
          configuration.cli.install.skillMethod,
          SkillInstallMethod.canonical,
        );
        expect(configuration.cli.retention.snapshotDays, 30);
        expect(configuration.packs, hasLength(4));

        final github = configuration.findPack('MATTPOCOCK/SKILLS')!;
        expect(github.source, isA<GitHubPackSource>());
        expect(
          github.source,
          isA<GitHubPackSource>()
              .having((source) => source.host, 'host', 'github.com')
              .having(
                (source) => source.repository,
                'repository',
                'mattpocock/skills',
              )
              .having(
                (source) => source.subpath,
                'subpath',
                'packages/resources',
              ),
        );
        expect(github.install.skillMethod, SkillInstallMethod.copy);
        expect(github.update.bump, ReleaseBump.minor);
        expect(github.update.includePrerelease, isTrue);
        expect(
          github.update.track,
          isA<ReleaseTrack>()
              .having(
                (track) => track.artifact,
                'artifact',
                ReleaseArtifact.attachment,
              )
              .having((track) => track.attachment, 'attachment', 'skills.zip'),
        );
        expect(github.resources.skills.exclusions, ['unwanted-skill']);
        expect(github.resources.skills.overrides.single.name, 'example-skill');
        expect(github.resources.skills.overrides.single.extraFolders, [
          'rules',
        ]);
        expect(github.resources.agents.exclusions, ['old-reviewer']);

        expect(
          configuration.findPack('git-example')!.update.track,
          isA<BranchTrack>().having((track) => track.name, 'name', 'main'),
        );
        expect(
          configuration.findPack('local-example')!.source,
          isA<LocalPackSource>().having(
            (source) => source.path,
            'resolved path',
            p.normalize('/workspace/resources'),
          ),
        );
        expect(
          configuration.findPack('local-example')!.update.track,
          isA<LocalTrack>(),
        );
        expect(
          configuration.findPack('download-example')!.update.track,
          isA<DownloadTrack>(),
        );
        expect(configuration.catalog.skills.single.path, 'skills/my-skill');
        expect(
          configuration.catalog.agents.single.profile,
          NativeAgentProfile.claude,
        );
      },
    );

    test(
      'loads the selected project file and inherits only user preferences',
      () {
        final temporary = Directory.systemTemp.createTempSync('pack-config-');
        addTearDown(() => temporary.deleteSync(recursive: true));
        final home = Directory(p.join(temporary.path, 'home'))..createSync();
        final project = Directory(p.join(temporary.path, 'project'))
          ..createSync();
        final userConfig = File(
          PackConfiguration.userConfigPath(
            environment: {'HOME': home.path},
            operatingSystem: 'linux',
          ),
        )..createSync(recursive: true);
        userConfig.writeAsStringSync('''
schema_version = 1
[cli.install]
targets = ["codex"]
skill_method = "copy"
[cli.retention]
snapshot_days = 45
[packs."user-only".source]
kind = "local"
path = "user-pack"
''');
        File(p.join(project.path, packConfigurationFileName))
            .writeAsStringSync('''
schema_version = 1
[cli.retention]
snapshot_days = 10
[packs."project-only".source]
kind = "local"
path = "project-pack"
''');

        final configuration = PackConfiguration.load(
          scope: PackConfigurationScope.project,
          projectRoot: project.path,
          environment: {'HOME': home.path},
          operatingSystem: 'linux',
        );

        expect(configuration.scope, PackConfigurationScope.project);
        expect(configuration.cli.install.targets, ['codex']);
        expect(configuration.cli.install.skillMethod, SkillInstallMethod.copy);
        expect(configuration.cli.retention.snapshotDays, 10);
        expect(configuration.packs.map((pack) => pack.key), ['project-only']);
        expect(configuration.findPack('user-only'), isNull);
      },
    );

    test('resolves a relative project root from the invocation directory', () {
      final temporary = Directory.systemTemp.createTempSync('pack-config-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final project = Directory(p.join(temporary.path, 'project'))
        ..createSync();
      File(p.join(project.path, packConfigurationFileName))
          .writeAsStringSync('schema_version = 1\n');

      final configuration = PackConfiguration.load(
        scope: PackConfigurationScope.project,
        projectRoot: 'project',
        workingDirectory: temporary.path,
        environment: {'HOME': temporary.path},
        operatingSystem: 'linux',
      );

      expect(
        configuration.configPath,
        p.join(project.path, packConfigurationFileName),
      );
    });

    test(
      'resolves explicit files and their local paths from the right bases',
      () {
        final temporary = Directory.systemTemp.createTempSync('pack-config-');
        addTearDown(() => temporary.deleteSync(recursive: true));
        final invocation = Directory(p.join(temporary.path, 'invocation'))
          ..createSync();
        final configDirectory = Directory(p.join(temporary.path, 'config'))
          ..createSync();
        final config = File(p.join(configDirectory.path, 'chosen.toml'))
          ..writeAsStringSync('''
schema_version = 1
[packs."local".source]
kind = "local"
path = "../sources/pack"
''');

        final configuration = PackConfiguration.load(
          scope: PackConfigurationScope.user,
          explicitPath: p.join('..', 'config', 'chosen.toml'),
          workingDirectory: invocation.path,
        );

        expect(configuration.configPath, config.path);
        expect(
          configuration.findPack('local')!.source,
          isA<LocalPackSource>().having(
            (source) => source.path,
            'path',
            p.normalize(p.join(temporary.path, 'sources', 'pack')),
          ),
        );
      },
    );

    test(
      'discovers platform user paths without honoring relative XDG paths',
      () {
        expect(
          PackConfiguration.userConfigPath(
            environment: {'APPDATA': r'C:\Users\me\AppData\Roaming'},
            operatingSystem: 'windows',
          ),
          p.normalize(
            r'C:\Users\me\AppData\Roaming\AgentResource\agent-resources.toml',
          ),
        );
        expect(
          PackConfiguration.userConfigPath(
            environment: {'HOME': '/Users/me'},
            operatingSystem: 'macos',
          ),
          p.normalize(
            '/Users/me/Library/Application Support/AgentResource/agent-resources.toml',
          ),
        );
        expect(
          PackConfiguration.userConfigPath(
            environment: {
              'HOME': '/home/me',
              'XDG_CONFIG_HOME': 'relative/config',
            },
            operatingSystem: 'linux',
          ),
          p.normalize('/home/me/.config/agent-resource/agent-resources.toml'),
        );
        expect(
          PackConfiguration.userConfigPath(
            environment: {'HOME': '/home/me', 'XDG_CONFIG_HOME': '/xdg/config'},
            operatingSystem: 'linux',
          ),
          p.normalize('/xdg/config/agent-resource/agent-resources.toml'),
        );
      },
    );

    test('collects independent semantic errors with actionable key paths', () {
      final error = _parseError(r'''
schema_version = 2
[cli]
surprise = true
[cli.retention]
snapshot_days = 0
[packs."owner/repo".source]
kind = "github"
repository = "other/repo"
unknown = "field"
[packs."owner/repo".install]
targets = "codex"
skill_method = "source-link"
[packs."owner/repo".update]
track = { kind = "branch", name = "main" }
bump = "minor"
include_prerelease = true
[packs."owner/repo".resources.skills]
exclude = [{ name = "demo" }, { name = "demo" }]
[[packs."owner/repo".resources.skills.overrides]]
name = "demo"
extra_folders = ["../escape"]
[[catalog.skills]]
path = "/absolute"
profile = "claude"
''');

      final paths = error.issues.map((issue) => issue.keyPath).toList();
      expect(error.issues.length, greaterThanOrEqualTo(10));
      expect(
        paths,
        containsAll([
          'schema_version',
          'cli.surprise',
          'cli.retention.snapshot_days',
          'packs."owner/repo".source.unknown',
          'packs."owner/repo".install.targets',
          'packs."owner/repo".install.skill_method',
          'packs."owner/repo".update.bump',
          'packs."owner/repo".update.include_prerelease',
          'packs."owner/repo".resources.skills.exclude[1].name',
          'packs."owner/repo".resources.skills.overrides[0].name',
          'packs."owner/repo".resources.skills.overrides[0].extra_folders[0]',
          'catalog.skills[0].path',
          'catalog.skills[0].profile',
        ]),
      );
    });

    test('parses tag, commit, and archive release tracks exactly', () {
      final configuration = PackConfiguration.parse(r'''
schema_version = 1
[packs."tagged".source]
kind = "git"
url = "https://git.example.test/tagged.git"
[packs."tagged".update]
track = { kind = "tag", name = "v1.2.3" }
[packs."pinned".source]
kind = "git"
url = "https://git.example.test/pinned.git"
[packs."pinned".update]
track = { kind = "commit", commit = "0123456789abcdef0123456789abcdef01234567" }
[packs."owner/release".source]
kind = "github"
repository = "owner/release"
[packs."owner/release".update]
track = { kind = "release", artifact = "archive" }
''');

      expect(
        configuration.findPack('tagged')!.update.track,
        isA<TagTrack>().having((track) => track.name, 'name', 'v1.2.3'),
      );
      expect(
        configuration.findPack('pinned')!.update.track,
        isA<CommitTrack>().having(
          (track) => track.commit,
          'commit',
          '0123456789abcdef0123456789abcdef01234567',
        ),
      );
      expect(
        configuration.findPack('owner/release')!.update.track,
        isA<ReleaseTrack>().having(
          (track) => track.artifact,
          'artifact',
          ReleaseArtifact.archive,
        ),
      );
    });

    test('rejects incompatible track fields and modes', () {
      final error = _parseError(r'''
schema_version = 1
[packs."git".source]
kind = "git"
url = "https://git.example.test/repo.git"
[packs."git".update]
track = { kind = "release", artifact = "archive" }
[packs."local".source]
kind = "local"
path = "pack"
[packs."local".update]
track = { kind = "branch", name = "main" }
''');

      expect(
        error.issues.map((issue) => issue.keyPath),
        containsAll([
          'packs."git".update.track.kind',
          'packs."local".update.track.kind',
        ]),
      );
    });

    test('rejects duplicate normalized keys and source aliases', () {
      final error = _parseError(r'''
schema_version = 1
[packs."Owner/Repo".source]
kind = "github"
repository = "Owner/Repo"
[packs."Owner/Repo".update]
track = { kind = "branch", name = "main" }
[packs."owner/repo".source]
kind = "github"
repository = "owner/repo"
[packs."owner/repo".update]
track = { kind = "branch", name = "main" }
[packs."first".source]
kind = "git"
url = "https://GIT.example.test/team/repo.git"
[packs."first".update]
track = { kind = "branch", name = "main" }
[packs."second".source]
kind = "git"
url = "https://git.example.test/team/repo.git"
[packs."second".update]
track = { kind = "branch", name = "main" }
''');

      expect(error.issues, hasLength(2));
      expect(
        error.issues.map((issue) => issue.keyPath),
        containsAll(['packs."owner/repo"', 'packs."second"']),
      );
    });

    test(
      'rejects URL credentials without copying secrets into diagnostics',
      () {
        const credential = 'test-credential';
        final gitUrl = [
          'https://user:',
          credential,
          '@git.example.test/repo.git',
        ].join();
        final downloadUrl = [
          'https://downloads.example.test/pack.zip?token=',
          credential,
        ].join();
        final error = _parseError('''
schema_version = 1
[packs."git".source]
kind = "git"
url = "$gitUrl"
[packs."git".update]
track = { kind = "branch", name = "main" }
[packs."download".source]
kind = "download"
url = "$downloadUrl"
''');

        expect(error.issues, hasLength(2));
        expect(error.toString(), isNot(contains(credential)));
        expect(
          error.issues.map((issue) => issue.keyPath),
          containsAll([
            'packs."git".source.url',
            'packs."download".source.url',
          ]),
        );
      },
    );

    test('reports TOML redefinition separately from semantic aggregation', () {
      final error = _parseError('''
schema_version = 1
schema_version = 1
''');

      expect(error.issues, hasLength(1));
      expect(error.issues.single.message, contains('duplicate TOML'));
    });
  });
}

PackConfigurationException _parseError(String source) {
  try {
    PackConfiguration.parse(source);
  } on PackConfigurationException catch (error) {
    return error;
  }
  fail('Expected invalid pack configuration to be rejected.');
}
