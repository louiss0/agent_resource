import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/pack/pack_models.dart' show PackPlan;
import 'package:agent_resource/src/services/lifecycle_state_service.dart'
    show LifecycleScope;
import 'package:agent_resource/src/services/pack_lifecycle_service.dart'
    show
        PackLifecycleRequest,
        PackLifecycleService,
        PackOperation,
        PackResourceType;
import 'package:agent_resource/src/mcp/mcp_native.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart' show MambaException;
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

    const claudePath = '/pack-mcp-wiring/project/.mcp.json';
    const codexPath = '/pack-mcp-wiring/project/.codex/config.toml';
    const piPath = '/pack-mcp-wiring/project/.pi/mcp.json';
    const ledgerPath = '/sandbox/state/mcp-registrations.json';

    void writeText(String path, String content) => fs.file(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

    void writePublisherCatalog(String body) =>
        writeText('$sourceRoot/agent-resources.toml', body);

    void writeProjectConfig(List<String> targets) =>
        writeText('${project.path}/agent-resources.toml', '''
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
        writeText('$sourceRoot/$relative', content);

    void seedUnrelatedNativeFiles() {
      writeText(
        claudePath,
        '{\n  "mcpServers": {"keep": {"command": "keep-svc"}},\n'
        '  "unrelatedTopLevel": "keep-me"\n}\n',
      );
      writeText(
        codexPath,
        '# keep this comment\nmodel = "o3"\n'
        '[mcp_servers.keep]\ncommand = "keep-svc"\n'
        '\n[other]\nvalue = "unchanged"\n',
      );
      writeText(
        piPath,
        '{\n  "mcpServers": {"keep": {"command": "keep-svc"}},\n'
        '  "autoEnableCodemode": false\n}\n',
      );
    }

    McpNativeLocation location(McpHarness harness) => switch (harness) {
      McpHarness.claude => const McpNativeLocation(
        harness: McpHarness.claude,
        scope: McpScope.project,
        path: claudePath,
        format: McpNativeFormat.json,
        section: McpNativeSection.mcpServers,
      ),
      McpHarness.codex => const McpNativeLocation(
        harness: McpHarness.codex,
        scope: McpScope.project,
        path: codexPath,
        format: McpNativeFormat.toml,
        section: McpNativeSection.codexMcpServers,
      ),
      McpHarness.pi => const McpNativeLocation(
        harness: McpHarness.pi,
        scope: McpScope.project,
        path: piPath,
        format: McpNativeFormat.json,
        section: McpNativeSection.mcpServers,
      ),
    };

    Map<String, Object?>? installedEntry(McpHarness harness, String name) =>
        McpNativeReader(fs).read(location(harness))[name];

    Map<String, Object?> readLedger() =>
        jsonDecode(fs.file(ledgerPath).readAsStringSync())
            as Map<String, Object?>;

    void expectRecords(List<McpHarness> harnesses) {
      final records = readLedger()['records']! as List<Object?>;
      expect(records, hasLength(harnesses.length));
      final byKey = <String, Map<String, Object?>>{
        for (final item in records)
          (item! as Map<String, Object?>)['harness']! as String:
              item as Map<String, Object?>,
      };
      for (final harness in harnesses) {
        final record = byKey[harness.wireName];
        expect(record, isNotNull, reason: harness.wireName);
        expect(record!['scope'], 'project');
        expect(record['location'], location(harness).path);
        expect(record['name'], 'github');
        final entry = installedEntry(harness, 'github');
        expect(entry, isNotNull, reason: harness.wireName);
        expect(record['baselineDigest'], mcpCanonicalDigest(entry));
      }
    }

    void expectFailure(
      MambaExecutionResult result, {
      required String token,
      required List<String> commandPath,
    }) {
      expect(
        result,
        isA<MambaFailureResult>()
            .having((value) => value.exitCode, 'exit code', isNonZero)
            .having((value) => value.message, 'message', contains(token))
            .having((value) => value.output, 'output', isNull)
            .having(
              (value) => value.error.commandPath,
              'command path',
              commandPath,
            ),
      );
    }

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
      '--state-dir',
      '/sandbox/state/',
      '--format',
      'json',
      if (operation != 'validate' && operation != 'discover') '--yes',
    ];

    Future<MambaExecutionResult> run(List<String> arguments) =>
        createExecutor(fileSystem: fs).fake().execute(arguments);

    Map<String, Object?> successEnvelope(MambaExecutionResult result) {
      expect(
        result,
        isA<MambaSuccessResult>().having(
          (value) => value.exitCode,
          'exit code',
          0,
        ),
        reason: result is MambaFailureResult ? result.message : null,
      );
      return jsonDecode((result as MambaSuccessResult).output!)
          as Map<String, Object?>;
    }

    test('untyped operations never include MCP', () async {
      final envelope = successEnvelope(await run(invocation('install')));
      final resources = envelope['resources']! as List<Object?>;
      final types = resources
          .map((value) => (value! as Map<String, Object?>)['type'])
          .toSet();
      expect(types, isNot(contains('mcp')));
      expect(fs.file(claudePath).existsSync(), isFalse);
    });

    test('validates an MCP selection without writing', () async {
      seedUnrelatedNativeFiles();
      final before = <String, String>{
        for (final path in <String>[claudePath, codexPath, piPath])
          path: fs.file(path).readAsStringSync(),
      };
      final envelope = successEnvelope(
        await run(<String>[...invocation('validate'), '--type', 'mcp']),
      );
      expect(envelope['schemaVersion'], 1);
      expect(envelope['outcome'], 'validated');
      final resources = envelope['resources']! as List<Object?>;
      expect(resources, hasLength(1));
      final resource = resources.single! as Map<String, Object?>;
      expect(resource['type'], 'mcp');
      expect(resource['name'], 'github');
      expect(resource['disposition'], 'validated');
      for (final entry in before.entries) {
        expect(fs.file(entry.key).readAsStringSync(), entry.value);
      }
      expect(fs.file(ledgerPath).existsSync(), isFalse);
    });

    test(
      'install writes every selected native entry and records ownership',
      () async {
        seedUnrelatedNativeFiles();
        final envelope = successEnvelope(
          await run(<String>[...invocation('install'), '--type', 'mcp']),
        );
        expect(envelope['schemaVersion'], 1);
        expect(envelope['operation'], 'pack.install');
        expect(envelope['outcome'], 'installed');
        expect(envelope['dryRun'], isFalse);
        final resources = envelope['resources']! as List<Object?>;
        expect(resources, hasLength(1));
        final resource = resources.single! as Map<String, Object?>;
        expect(resource['disposition'], 'installed');
        final plan = envelope['plan']! as Map<String, Object?>;
        expect(plan['planId'], startsWith('plan_v1_'));

        for (final harness in McpHarness.values) {
          final entry = installedEntry(harness, 'github');
          expect(entry, isNotNull, reason: harness.wireName);
          expect(entry!['command'], 'npx');
        }
        expect(fs.file(claudePath).readAsStringSync(), contains('keep-me'));
        expect(fs.file(claudePath).readAsStringSync(), contains('keep-svc'));
        expect(
          fs.file(codexPath).readAsStringSync(),
          contains('# keep this comment'),
        );
        expect(
          fs.file(codexPath).readAsStringSync(),
          contains('value = "unchanged"'),
        );
        expect(
          fs.file(piPath).readAsStringSync(),
          contains('autoEnableCodemode'),
        );
        expect(fs.file(piPath).readAsStringSync(), contains('keep-svc'));
        expectRecords(McpHarness.values);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('dry-run publishes a reviewed plan and writes nothing', () async {
      seedUnrelatedNativeFiles();
      final before = <String, String>{
        for (final path in <String>[claudePath, codexPath, piPath])
          path: fs.file(path).readAsStringSync(),
      };
      final envelope = successEnvelope(
        await run(<String>[
          ...invocation('install'),
          '--type',
          'mcp',
          '--dry-run',
        ]),
      );
      expect(envelope['outcome'], 'preview');
      expect(envelope['dryRun'], isTrue);
      final plan = envelope['plan']! as Map<String, Object?>;
      expect(plan['planId'], startsWith('plan_v1_'));
      final resources = plan['resources']! as List<Object?>;
      final resource = resources.single! as Map<String, Object?>;
      expect(resource['targets'], <String>['claude', 'codex', 'pi']);
      expect(resource['previousSnapshot'], isA<String>());
      for (final entry in before.entries) {
        expect(fs.file(entry.key).readAsStringSync(), entry.value);
      }
      expect(fs.file(ledgerPath).existsSync(), isFalse);
    });

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
        expectFailure(
          result,
          token: 'MCP_TARGET_UNSUPPORTED',
          commandPath: const <String>['agent_resource', 'pack', 'install'],
        );
        expect(fs.file(claudePath).existsSync(), isFalse);
        expect(fs.file(codexPath).existsSync(), isFalse);
        expect(fs.file(ledgerPath).existsSync(), isFalse);
      },
    );

    test(
      'admits a declaration for configured targets that all support it',
      () async {
        writeProjectConfig(<String>['claude', 'pi']);
        writePublisherCatalog(claudeOnlyCatalog);
        final envelope = successEnvelope(
          await run(<String>[...invocation('install'), '--type', 'mcp']),
        );
        expect(envelope['outcome'], 'installed');
        expect(installedEntry(McpHarness.claude, 'remote'), isNotNull);
        expect(installedEntry(McpHarness.pi, 'remote'), isNotNull);
        expect(installedEntry(McpHarness.codex, 'remote'), isNull);
        expect(fs.file(codexPath).existsSync(), isFalse);
      },
    );

    test(
      'refuses a native name collision by default without writing',
      () async {
        seedUnrelatedNativeFiles();
        fs
            .file(claudePath)
            .writeAsStringSync(
              jsonEncode(<String, Object?>{
                'mcpServers': <String, Object?>{
                  'github': <String, Object?>{'command': 'existing'},
                },
                'unrelatedTopLevel': 'keep-me',
              }),
            );
        final before = fs.file(claudePath).readAsStringSync();
        final result = await run(<String>[
          ...invocation('install'),
          '--type',
          'mcp',
        ]);
        expectFailure(
          result,
          token: 'MCP_COLLISION_REVIEW_REQUIRED',
          commandPath: const <String>['agent_resource', 'pack', 'install'],
        );
        expect(fs.file(claudePath).readAsStringSync(), before);
        expect(installedEntry(McpHarness.codex, 'github'), isNull);
        expect(fs.file(ledgerPath).existsSync(), isFalse);
      },
    );

    test(
      'an approved collision replaces only the selected named entry',
      () async {
        seedUnrelatedNativeFiles();
        writeSourceNative(
          '.mcp.json',
          '{"mcpServers":{"github":{"command":"source-old"}}}',
        );
        final sourceBefore = fs
            .file('$sourceRoot/.mcp.json')
            .readAsStringSync();
        fs
            .file(claudePath)
            .writeAsStringSync(
              '{\n  "mcpServers": {"github": {"command": "existing"}},\n'
              '  "unrelatedTopLevel": "keep-me"\n}\n',
            );
        final result = await run(<String>[
          ...invocation('install'),
          '--type',
          'mcp',
          '--approve-mcp-collision',
          'github',
        ]);
        final envelope = successEnvelope(result);
        expect(envelope['outcome'], 'installed');
        final entry = installedEntry(McpHarness.claude, 'github');
        expect(entry!['command'], 'npx');
        expect(fs.file(claudePath).readAsStringSync(), contains('keep-me'));
        expect(
          fs.file('$sourceRoot/.mcp.json').readAsStringSync(),
          sourceBefore,
        );
        expectRecords(McpHarness.values);
      },
    );

    test('declining a reviewed plan writes nothing', () async {
      seedUnrelatedNativeFiles();
      PackPlan? reviewed;
      final service = PackLifecycleService(fileSystem: fs);
      await expectLater(
        service.execute(
          PackLifecycleRequest(
            operation: PackOperation.install,
            resourceType: PackResourceType.mcp,
            resourceTypes: const <PackResourceType>[PackResourceType.mcp],
            processWorkingDirectory: sandbox.path,
            pack: 'local/demo',
            scope: LifecycleScope.project,
            cwd: '${project.path}/',
            projectRoot: '${project.path}/',
            home: '${home.path}/',
            stateDir: '/sandbox/state/',
            planReview: (plan) async {
              reviewed = plan;
              return false;
            },
          ),
        ),
        throwsA(isA<MambaException>()),
      );
      expect(reviewed, isNotNull);
      expect(
        fs.file(claudePath).readAsStringSync(),
        isNot(contains('"github"')),
      );
      expect(fs.file(ledgerPath).existsSync(), isFalse);
    });

    test('refuses combining mcp with another type', () async {
      final result = await run(<String>[
        ...invocation('install'),
        '--type',
        'mcp',
        '--type',
        'skill',
      ]);
      expectFailure(
        result,
        token: 'isolated opt-in selection',
        commandPath: const <String>['agent_resource', 'pack', 'install'],
      );
    });

    test('refuses unsupported MCP pack operations before any write', () async {
      final result = await run(<String>[
        ...invocation('update'),
        '--type',
        'mcp',
      ]);
      expectFailure(
        result,
        token: 'does not support',
        commandPath: const <String>['agent_resource', 'pack', 'update'],
      );
      expect(fs.file(ledgerPath).existsSync(), isFalse);
    });

    test('a validation failure blocks the native write', () async {
      writePublisherCatalog(claudeOnlyCatalog);
      writeProjectConfig(<String>['claude', 'codex', 'pi']);
      final result = await run(<String>[
        ...invocation('install'),
        '--type',
        'mcp',
        '--target',
        'codex',
      ]);
      expectFailure(
        result,
        token: 'MCP_TARGET_UNSUPPORTED',
        commandPath: const <String>['agent_resource', 'pack', 'install'],
      );
      expect(fs.file(claudePath).existsSync(), isFalse);
      expect(fs.file(ledgerPath).existsSync(), isFalse);
    });

    test(
      'pack discover --type mcp reports inline and native candidates',
      () async {
        writeSourceNative(
          '.codex/config.toml',
          '[mcp_servers.build]\ncommand = "make"\n',
        );
        final envelope = successEnvelope(
          await run(<String>[...invocation('discover'), '--type', 'mcp']),
        );
        expect(envelope['types'], <String>['mcp']);
        final candidates = envelope['candidates']! as List<Object?>;
        final ids = candidates
            .map((value) => (value! as Map<String, Object?>)['id'])
            .toList();
        expect(ids, containsAll(<String>['github', 'build']));
      },
    );
  });
}
