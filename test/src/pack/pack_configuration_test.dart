import 'package:agent_resource/src/pack/pack_configuration.dart';
import 'package:agent_resource/src/pack/pack_mcp_declaration.dart';
import 'package:file/memory.dart';
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

    test('rejects native Skill roots as extra-folder approvals', () {
      for (final folder in [
        'references',
        'scripts',
        'assets',
        'agents',
        'SKILL.md',
      ]) {
        final error = _parseError('''
schema_version = 1
[packs."local".source]
kind = "local"
path = "pack"
[[packs."local".resources.skills.overrides]]
name = "example"
extra_folders = ["$folder"]
''');

        expect(
          error.issues,
          contains(
            isA<PackConfigurationIssue>()
                .having(
                  (issue) => issue.keyPath,
                  'key path',
                  'packs."local".resources.skills.overrides[0].extra_folders[0]',
                )
                .having(
                  (issue) => issue.message,
                  'message',
                  contains('non-native'),
                ),
          ),
          reason: folder,
        );
      }
    });

    test('discovery defaults and per-pack overrides', () {
      final config = PackConfiguration.parse('''
schema_version = 1
[packs."default".source]
kind = "local"
path = "default"
[packs."custom".source]
kind = "local"
path = "custom"
[packs."custom".discovery]
skills_directory = "packages/skills"
agents_directory = "."
[packs."partial".source]
kind = "local"
path = "partial"
[packs."partial".discovery]
agents_directory = "custom/agents"
''');
      expect(config.findPack('default')!.discovery.skillsDirectory, 'skills');
      expect(config.findPack('default')!.discovery.agentsDirectory, 'agents');
      expect(
        config.findPack('custom')!.discovery.skillsDirectory,
        'packages/skills',
      );
      expect(config.findPack('custom')!.discovery.agentsDirectory, '.');
      expect(config.findPack('partial')!.discovery.skillsDirectory, 'skills');
      expect(
        config.findPack('partial')!.discovery.agentsDirectory,
        'custom/agents',
      );
    });

    test('rejects unsafe discovery paths and unknown fields', () {
      for (final value in [
        '',
        '   ',
        '../escape',
        'a/../b',
        '/absolute',
        r'C:\absolute',
        r'a\b',
        'a//b',
        'a/',
      ]) {
        final error = _parseError('''
schema_version = 1
[packs."local".source]
kind = "local"
path = "pack"
[packs."local".discovery]
skills_directory = '$value'
''');
        expect(
          error.issues.map((issue) => issue.keyPath),
          contains('packs."local".discovery.skills_directory'),
          reason: value,
        );
      }
      final error = _parseError('''
schema_version = 1
[packs."local".source]
kind = "local"
path = "pack"
[packs."local".discovery]
agents_directory = 42
unexpected = "value"
''');
      expect(
        error.issues.map((issue) => issue.keyPath),
        containsAll([
          'packs."local".discovery.agents_directory',
          'packs."local".discovery.unexpected',
        ]),
      );
    });

    test(
      'loads the selected project file and inherits only user preferences',
      () {
        final fs = MemoryFileSystem(style: FileSystemStyle.posix);
        final temporary = fs.directory('/sandbox')..createSync();
        final home = fs.directory(fs.path.join(temporary.path, 'home'))
          ..createSync();
        final project = fs.directory(fs.path.join(temporary.path, 'project'))
          ..createSync();
        final userConfig = fs.file(
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
        fs
            .file(fs.path.join(project.path, packConfigurationFileName))
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
          fileSystem: fs,
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
      final fs = MemoryFileSystem(style: FileSystemStyle.posix);
      final temporary = fs.directory('/sandbox')..createSync();
      final project = fs.directory(fs.path.join(temporary.path, 'project'))
        ..createSync();
      fs
          .file(fs.path.join(project.path, packConfigurationFileName))
          .writeAsStringSync('schema_version = 1\n');

      final configuration = PackConfiguration.load(
        scope: PackConfigurationScope.project,
        projectRoot: 'project',
        workingDirectory: temporary.path,
        environment: {'HOME': temporary.path},
        operatingSystem: 'linux',
        fileSystem: fs,
      );

      expect(
        configuration.configPath,
        fs.path.join(project.path, packConfigurationFileName),
      );
    });

    test(
      'resolves explicit files and their local paths from the right bases',
      () {
        final fs = MemoryFileSystem(style: FileSystemStyle.posix);
        final temporary = fs.directory('/sandbox')..createSync();
        final invocation = fs.directory(
          fs.path.join(temporary.path, 'invocation'),
        )..createSync();
        final configDirectory = fs.directory(
          fs.path.join(temporary.path, 'config'),
        )..createSync();
        final config =
            fs.file(fs.path.join(configDirectory.path, 'chosen.toml'))
              ..writeAsStringSync('''
schema_version = 1
[packs."local".source]
kind = "local"
path = "../sources/pack"
''');

        final configuration = PackConfiguration.load(
          scope: PackConfigurationScope.user,
          explicitPath: fs.path.join('..', 'config', 'chosen.toml'),
          workingDirectory: invocation.path,
          fileSystem: fs,
        );

        expect(configuration.configPath, config.path);
        expect(
          configuration.findPack('local')!.source,
          isA<LocalPackSource>().having(
            (source) => source.path,
            'path',
            fs.path.normalize(fs.path.join(temporary.path, 'sources', 'pack')),
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
          p.windows.normalize(
            r'C:\Users\me\AppData\Roaming\AgentResource\agent-resources.toml',
          ),
        );
        expect(
          PackConfiguration.userConfigPath(
            environment: {'HOME': '/Users/me'},
            operatingSystem: 'macos',
          ),
          p.posix.normalize(
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
          p.posix.normalize(
            '/home/me/.config/agent-resource/agent-resources.toml',
          ),
        );
        expect(
          PackConfiguration.userConfigPath(
            environment: {'HOME': '/home/me', 'XDG_CONFIG_HOME': '/xdg/config'},
            operatingSystem: 'linux',
          ),
          p.posix.normalize('/xdg/config/agent-resource/agent-resources.toml'),
        );
      },
    );

    test('the explicit home wins over the environment of the process', () {
      expect(
        PackConfiguration.userConfigPath(
          environment: {'APPDATA': r'C:\Users\me\AppData\Roaming'},
          operatingSystem: 'windows',
          home: r'C:\Users\sandbox',
        ),
        p.windows.normalize(
          r'C:\Users\sandbox\AppData\Roaming\AgentResource\agent-resources.toml',
        ),
      );
      expect(
        PackConfiguration.userConfigPath(
          environment: {'HOME': '/Users/me'},
          operatingSystem: 'macos',
          home: '/Users/sandbox',
        ),
        p.posix.normalize(
          '/Users/sandbox/Library/Application Support/AgentResource/agent-resources.toml',
        ),
      );
      expect(
        PackConfiguration.userConfigPath(
          environment: {'HOME': '/home/me', 'XDG_CONFIG_HOME': '/xdg/config'},
          operatingSystem: 'linux',
          home: '/home/sandbox',
        ),
        p.posix.normalize(
          '/home/sandbox/.config/agent-resource/agent-resources.toml',
        ),
      );
    });

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

    group('inline MCP declarations (stories 34-35)', () {
      List<PackMcpDeclaration> parseMcp(String body) => PackConfiguration.parse(
        'schema_version = 1\n$body',
        catalogScope: PackCatalogSection.mcp,
      ).catalog.mcp;

      PackConfigurationException mcpError(String body) {
        try {
          parseMcp(body);
        } on PackConfigurationException catch (error) {
          return error;
        }
        fail('Expected inline MCP declaration to be refused.');
      }

      test('admits environment-variable and command credential references', () {
        final declarations = parseMcp(r'''
[[catalog.mcp]]
name = "github"
command = "npx"
args = ["-y", "server-github"]
env = { GITHUB_TOKEN = "${GITHUB_TOKEN}", OP_KEY = "!op read secret" }
headers = { Authorization = "Bearer ${TOKEN}" }
''');
        expect(declarations, hasLength(1));
        expect(declarations.single.name, 'github');
        expect(declarations.single.fields['command'], 'npx');
      });

      test('admits reference-only native fields', () {
        final declarations = parseMcp(r'''
[[catalog.mcp]]
name = "remote"
url = "https://example.test/mcp"
type = "http"
bearer_token_env_var = "MCP_TOKEN"
env_vars = ["MCP_TOKEN"]
env_http_headers = { Authorization = "MCP_AUTH" }
''');
        expect(declarations.single.name, 'remote');
        expect(declarations.single.fields['bearer_token_env_var'], 'MCP_TOKEN');
      });

      test('refuses a literal secret with a value-free diagnostic', () {
        final error = mcpError(r'''
[[catalog.mcp]]
name = "github"
command = "npx"
env = { GITHUB_TOKEN = "ghp_supersecretvalue" }
''');
        final codes = error.issues.map((issue) => issue.code).toList();
        expect(codes, contains(mcpPackLiteralSecret));
        expect(
          error.issues.map((issue) => issue.keyPath),
          anyElement(contains('env')),
        );
        expect(error.message, isNot(contains('ghp_supersecretvalue')));
      });

      test('refuses literal values in arbitrary env and header keys', () {
        final error = mcpError(r'''
[[catalog.mcp]]
name = "github"
command = "npx"
env = { FOO = "literal-env-secret" }
headers = { X-Custom = "literal-header-secret" }
''');
        final codes = error.issues.map((issue) => issue.code).toList();
        expect(codes, contains(mcpPackLiteralSecret));
        expect(
          error.issues.map((issue) => issue.keyPath),
          anyElement(contains('env')),
        );
        expect(
          error.issues.map((issue) => issue.keyPath),
          anyElement(contains('headers')),
        );
        expect(error.message, isNot(contains('literal-env-secret')));
        expect(error.message, isNot(contains('literal-header-secret')));
      });

      test(
        'refuses literal OAuth secret values under arbitrary nested keys',
        () {
          final error = mcpError(r'''
[[catalog.mcp]]
name = "remote"
url = "https://example.test/mcp"
type = "http"
oauth = { opaque = "literal-oauth-secret" }
''');
          expect(
            error.issues.map((issue) => issue.code),
            contains(mcpPackLiteralSecret),
          );
          expect(error.message, isNot(contains('literal-oauth-secret')));
        },
      );

      test('admits credential references under arbitrary keys', () {
        final declarations = parseMcp(r'''
[[catalog.mcp]]
name = "github"
command = "npx"
env = { FOO = "${FOO}", BAR = "!op read secret/foo" }
headers = { X-Custom = "Bearer ${TOKEN}" }
oauth = { opaque = "${CLIENT_SECRET}" }
''');
        expect(declarations, hasLength(1));
        expect(declarations.single.fields['env'], isA<Map<Object?, Object?>>());
      });

      test(
        'refuses provider-credential selection with a value-free diagnostic',
        () {
          final error = mcpError(r'''
[[catalog.mcp]]
name = "remote"
url = "https://example.test/mcp"
type = "http"
auth = { provider = "anthropic-provider" }
''');
          expect(
            error.issues.map((issue) => issue.code),
            contains(mcpPackProviderAuthForbidden),
          );
          expect(error.message, isNot(contains('anthropic-provider')));
        },
      );

      test('refuses an unknown native field', () {
        final error = mcpError(r'''
[[catalog.mcp]]
name = "github"
command = "npx"
surprise_field = "value"
''');
        expect(
          error.issues.map((issue) => issue.code),
          contains(mcpPackUnknownField),
        );
        expect(
          error.issues.map((issue) => issue.keyPath),
          anyElement(contains('surprise_field')),
        );
      });

      test('refuses a malformed declaration and an invalid name', () {
        final error = mcpError(r'''
[[catalog.mcp]]
name = "bad name!"
command = "npx"
''');
        expect(
          error.issues.map((issue) => issue.code),
          contains(mcpPackNameInvalid),
        );
      });

      test('keeps schema_version strictness for MCP selections', () {
        PackConfigurationException? caught;
        try {
          PackConfiguration.parse(
            'schema_version = 2\n[[catalog.mcp]]\nname = "x"\ncommand = "npx"\n',
            catalogScope: PackCatalogSection.mcp,
          );
        } on PackConfigurationException catch (error) {
          caught = error;
        }
        expect(caught, isNotNull);
        expect(
          caught!.issues.map((issue) => issue.keyPath),
          contains('schema_version'),
        );
      });

      test('an untyped selection never parses or admits MCP declarations', () {
        // Without an explicit mcp scope the section is ignored entirely: a
        // literal secret in an MCP declaration cannot affect an ordinary
        // skill/agent/prompt operation (story 33).
        final configuration = PackConfiguration.parse(r'''
schema_version = 1
[[catalog.mcp]]
name = "github"
command = "npx"
env = { GITHUB_TOKEN = "ghp_supersecretvalue" }
''');
        expect(configuration.catalog.mcp, isEmpty);
      });
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
