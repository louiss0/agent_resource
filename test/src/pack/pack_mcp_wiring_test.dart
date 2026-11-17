import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource pack --type mcp wiring', () {
    late fslib.FileSystem fs;
    late fslib.Directory sandbox;
    late fslib.Directory project;
    late fslib.Directory home;
    late String sourceRoot;

    const stdioCatalog = r'''
schema_version = 1
[[catalog.mcp]]
name = "github"
command = "npx"
args = ["-y", "server-github"]
env = { GITHUB_TOKEN = "${GITHUB_TOKEN}" }
''';

    const claudeOnlyCatalog = r'''
schema_version = 1
[[catalog.mcp]]
name = "remote"
type = "http"
url = "https://example.test/mcp"
headers = { Authorization = "Bearer ${TOKEN}" }
''';

    void writePublisherCatalog(String body) =>
        fs.file(fs.path.join(sourceRoot, 'agent-resources.toml'))
          ..createSync(recursive: true)
          ..writeAsStringSync(body);

    void writeProjectConfig(List<String> targets) =>
        fs.file(fs.path.join(project.path, 'agent-resources.toml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
schema_version = 1
[cli.install]
targets = ${jsonEncode(targets)}
[packs."local/demo".source]
kind = "local"
path = "../source"
[packs."local/demo".update]
track = { kind = "local" }
''');

    void writeSourceNative(String relative, String content) =>
        fs.file(fs.path.joinAll(<String>[sourceRoot, ...relative.split('/')]))
          ..createSync(recursive: true)
          ..writeAsStringSync(content);

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      sandbox = fs.directory('/pack-mcp-wiring')..createSync();
      fs.currentDirectory = sandbox;
      project = fs.directory(fs.path.join(sandbox.path, 'project'))
        ..createSync(recursive: true);
      home = fs.directory(fs.path.join(sandbox.path, 'home'))
        ..createSync(recursive: true);
      sourceRoot = fs.path.join(sandbox.path, 'source');
      writePublisherCatalog(stdioCatalog);
      writeProjectConfig(<String>['claude', 'codex', 'pi']);
    });

    List<String> invocation(String operation) => <String>[
      'pack',
      operation,
      'local/demo',
      '--scope',
      'project',
      '--cwd',
      '${project.path}${fs.path.separator}',
      '--project-root',
      '${project.path}${fs.path.separator}',
      '--home',
      '${home.path}${fs.path.separator}',
      '--format',
      'json',
      if (operation != 'validate' && operation != 'discover') '--yes',
    ];

    Future<MambaExecutionResult> run(List<String> arguments) =>
        createExecutor(fileSystem: fs).fake().execute(arguments);

    test('untyped operations never include MCP', () async {
      final result = await run(invocation('install'));
      expect(result, isA<MambaSuccessResult>());
      final envelope = jsonDecode(
        (result as MambaSuccessResult).output!,
      ) as Map<String, Object?>;
      final resources = envelope['resources']! as List<Object?>;
      final types = resources
          .map((value) => (value! as Map<String, Object?>)['type'])
          .toSet();
      expect(types, isNot(contains('mcp')));
    });

    test(
      'validates an MCP selection through the real service without writes',
      () async {
        final result = await run(<String>[
          ...invocation('validate'),
          '--type',
          'mcp',
        ]);
        expect(
          result,
          isA<MambaSuccessResult>(),
          reason: result is MambaFailureResult ? result.message : null,
        );
        final envelope = jsonDecode(
          (result as MambaSuccessResult).output!,
        ) as Map<String, Object?>;
        expect(envelope['outcome'], 'validated');
        final resources = envelope['resources']! as List<Object?>;
        expect(resources, hasLength(1));
        final resource = resources.single! as Map<String, Object?>;
        expect(resource['type'], 'mcp');
        expect(resource['name'], 'github');
        expect(resource['disposition'], 'validated');
        // The gate publishes no native registration file.
        expect(
          fs.file(fs.path.join(project.path, '.mcp.json')).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'refuses the whole selection when a requested target is unsupported',
      () async {
        writePublisherCatalog(claudeOnlyCatalog);
        final result = await run(<String>[
          ...invocation('install'),
          '--type',
          'mcp',
          '--target',
          'codex',
        ]);
        expect(result, isA<MambaFailureResult>());
        expect(
          (result as MambaFailureResult).message,
          allOf(contains('MCP_TARGET_UNSUPPORTED'), contains('codex')),
        );
      },
    );

    test(
      'admits a declaration for configured targets that all support it',
      () async {
        writeProjectConfig(<String>['claude', 'pi']);
        writePublisherCatalog(claudeOnlyCatalog);
        final result = await run(<String>[
          ...invocation('install'),
          '--type',
          'mcp',
        ]);
        expect(
          result,
          isA<MambaSuccessResult>(),
          reason: result is MambaFailureResult ? result.message : null,
        );
        expect(
          jsonDecode((result as MambaSuccessResult).output!)['outcome'],
          'validated',
        );
      },
    );

    test('refuses a native name collision by default', () async {
      writeSourceNative(
        '.mcp.json',
        jsonEncode(<String, Object?>{
          'mcpServers': <String, Object?>{
            'github': <String, Object?>{'command': 'npx'},
          },
        }),
      );
      final result = await run(<String>[
        ...invocation('install'),
        '--type',
        'mcp',
      ]);
      expect(result, isA<MambaFailureResult>());
      expect(
        (result as MambaFailureResult).message,
        allOf(contains('MCP_COLLISION_REVIEW_REQUIRED'), contains('github')),
      );
    });

    test('allows a collision only with --approve-mcp-collision', () async {
      writeSourceNative(
        '.mcp.json',
        jsonEncode(<String, Object?>{
          'mcpServers': <String, Object?>{
            'github': <String, Object?>{'command': 'npx'},
          },
        }),
      );
      final before = fs
          .file(fs.path.join(sourceRoot, '.mcp.json'))
          .readAsStringSync();
      final result = await run(<String>[
        ...invocation('install'),
        '--type',
        'mcp',
        '--approve-mcp-collision',
        'github',
      ]);
      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      // Nothing is silently replaced.
      expect(
        fs.file(fs.path.join(sourceRoot, '.mcp.json')).readAsStringSync(),
        before,
      );
    });

    test('refuses combining mcp with another type', () async {
      final result = await run(<String>[
        ...invocation('install'),
        '--type',
        'mcp',
        '--type',
        'skill',
      ]);
      expect(result, isA<MambaFailureResult>());
      expect(
        (result as MambaFailureResult).message,
        contains('isolated opt-in selection'),
      );
    });

    test(
      'pack discover --type mcp reports inline and native candidates',
      () async {
        writeSourceNative(
          '.codex/config.toml',
          '[mcp_servers.build]\ncommand = "make"\n',
        );
        final result = await run(<String>[
          ...invocation('discover'),
          '--type',
          'mcp',
        ]);
        expect(
          result,
          isA<MambaSuccessResult>(),
          reason: result is MambaFailureResult ? result.message : null,
        );
        final document = jsonDecode(
          (result as MambaSuccessResult).output!,
        ) as Map<String, Object?>;
        expect(document['types'], <String>['mcp']);
        final candidates = document['candidates']! as List<Object?>;
        final ids = candidates
            .map((value) => (value! as Map<String, Object?>)['id'])
            .toList();
        expect(ids, containsAll(<String>['github', 'build']));
      },
    );
  });
}
