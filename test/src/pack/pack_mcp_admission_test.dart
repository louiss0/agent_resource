import 'dart:convert';

import 'package:agent_resource/src/mcp/mcp_ownership_ledger.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/pack/pack_mcp_admission.dart';
import 'package:agent_resource/src/pack/pack_mcp_declaration.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('PackMcpAdmissionService', () {
    late fslib.FileSystem fs;
    late String sourceRoot;
    late String stateRoot;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      sourceRoot = '/work/pack-source';
      stateRoot = '/work/state';
      fs.directory(sourceRoot).createSync(recursive: true);
    });

    PackMcpAdmissionService service() =>
        PackMcpAdmissionService(fileSystem: fs);

    PackMcpDeclaration declaration(
      String name, [
      Map<String, Object?> fields = const <String, Object?>{
        'command': 'npx',
        'args': <String>['-y', 'server'],
      },
    ]) => PackMcpDeclaration(name: name, fields: fields);

    PackMcpAdmissionRequest request({
      required List<PackMcpDeclaration> declarations,
      List<McpHarness> targets = const <McpHarness>[McpHarness.claude],
      Set<String> reviewed = const <String>{},
    }) => PackMcpAdmissionRequest(
      declarations: declarations,
      targetHarnesses: targets,
      sourceRoot: sourceRoot,
      stateRoot: stateRoot,
      reviewedResolutions: reviewed,
    );

    void writeFile(String relative, String content) =>
        fs.file(fs.path.joinAll(<String>[sourceRoot, ...relative.split('/')]))
          ..createSync(recursive: true)
          ..writeAsStringSync(content);

    void writeManaged(String name) {
      McpOwnershipLedger(fs: fs, stateRoot: stateRoot).upsert(
        McpRegistrationRecord(
          identity: McpRegistrationIdentity(
            harness: McpHarness.claude,
            scope: McpScope.project,
            location: '/work/project/.mcp.json',
            name: name,
          ),
          baselineDigest: 'baseline-digest',
        ),
      );
    }

    group('per-target validation (stories 36, 44)', () {
      // `headers` is a Claude/Pi HTTP field that Codex does not recognize,
      // so this declaration is valid for claude/pi but invalid for codex.
      Map<String, Object?> claudeOnly() => <String, Object?>{
        'type': 'http',
        'url': 'https://secret-host.example/mcp',
        'headers': <String, Object?>{'Authorization': 'Bearer \${TOKEN}'},
      };

      test('validates a stdio declaration against every harness', () {
        final report = service().admit(
          request(
            declarations: <PackMcpDeclaration>[declaration('github')],
            targets: McpHarness.values,
          ),
        );
        expect(report.admittedNames, <String>['github']);
        expect(report.targetHarnesses, McpHarness.values);
      });

      test('refuses the whole selection when one target cannot support it', () {
        expect(
          () => service().admit(
            request(
              declarations: <PackMcpDeclaration>[
                declaration('remote', claudeOnly()),
              ],
              targets: const <McpHarness>[McpHarness.claude, McpHarness.codex],
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('MCP_TARGET_UNSUPPORTED'),
                contains('codex'),
                contains('whole MCP selection is refused'),
                isNot(contains('secret-host.example')),
                isNot(contains('TOKEN')),
              ),
            ),
          ),
        );
      });

      test('admits the same declaration for targets that all support it', () {
        final report = service().admit(
          request(
            declarations: <PackMcpDeclaration>[
              declaration('remote', claudeOnly()),
            ],
            targets: const <McpHarness>[McpHarness.claude, McpHarness.pi],
          ),
        );
        expect(report.admittedNames, <String>['remote']);
      });

      test('refuses the whole selection before any installation effect', () {
        final before = fs
            .directory('/work')
            .listSync(recursive: true)
            .map((entity) => entity.path)
            .toList();
        try {
          service().admit(
            request(
              declarations: <PackMcpDeclaration>[
                declaration('remote', claudeOnly()),
              ],
              targets: const <McpHarness>[McpHarness.codex],
            ),
          );
        } on Exception {
          // Expected refusal.
        }
        final after = fs
            .directory('/work')
            .listSync(recursive: true)
            .map((entity) => entity.path)
            .toList();
        expect(after, unorderedEquals(before));
      });
    });

    group('bounded native discovery (story 37)', () {
      test('reads only the three fixed project-level files', () {
        writeFile(
          '.mcp.json',
          jsonEncode(<String, Object?>{
            'mcpServers': <String, Object?>{
              'github': <String, Object?>{'command': 'npx'},
            },
          }),
        );
        writeFile(
          '.codex/config.toml',
          '[mcp_servers.build]\ncommand = "make"\n',
        );
        writeFile(
          '.pi/mcp.json',
          jsonEncode(<String, Object?>{
            'mcpServers': <String, Object?>{
              'search': <String, Object?>{'command': 'searchd'},
            },
          }),
        );

        final discovered = service().discoverNative(sourceRoot);
        expect(discovered[McpHarness.claude], <String>{'github'});
        expect(discovered[McpHarness.codex], <String>{'build'});
        expect(discovered[McpHarness.pi], <String>{'search'});
      });

      test('never recursively sweeps the source tree', () {
        writeFile(
          'nested/deep/ignored/.mcp.json',
          jsonEncode(<String, Object?>{
            'mcpServers': <String, Object?>{
              'deep-server': <String, Object?>{'command': 'npx'},
            },
          }),
        );
        writeFile(
          'subdir/.codex/config.toml',
          '[mcp_servers.hidden]\ncommand = "x"\n',
        );

        final discovered = service().discoverNative(sourceRoot);
        final all = discovered.values.expand((names) => names).toList();
        expect(all, isEmpty);
      });

      test('never reads user/home configuration', () {
        fs.file('/work/home/.claude.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'mcpServers': <String, Object?>{
                'user-server': <String, Object?>{'command': 'npx'},
              },
            }),
          );
        fs.file('/work/home/.codex/config.toml')
          ..createSync(recursive: true)
          ..writeAsStringSync('[mcp_servers.user_codex]\ncommand = "x"\n');
        fs.file('/work/home/.pi/agent/mcp.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'mcpServers': <String, Object?>{
                'user_pi': <String, Object?>{'command': 'x'},
              },
            }),
          );

        final discovered = service().discoverNative(sourceRoot);
        final all = discovered.values.expand((names) => names).toList();
        expect(
          all,
          isNot(containsAll(<String>['user-server', 'user_codex', 'user_pi'])),
        );
        expect(all, isEmpty);
      });

      test('refuses to follow a linked native file', () {
        final target = fs.file(fs.path.join(sourceRoot, 'elsewhere.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'mcpServers': <String, Object?>{
                'linked': <String, Object?>{'command': 'npx'},
              },
            }),
          );
        fs.link(fs.path.join(sourceRoot, '.mcp.json')).createSync(target.path);

        expect(
          () => service().discoverNative(sourceRoot),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('link'),
            ),
          ),
        );
      });

      test('enforces the bounded byte cap on a native file', () {
        writeFile('.mcp.json', 'x' * (8 * 1024 * 1024 + 1));
        expect(
          () => service().discoverNative(sourceRoot),
          throwsA(isA<Exception>()),
        );
      });
    });

    group('collision handling (story 38)', () {
      test('refuses a native collision by default with a redacted account', () {
        writeFile(
          '.mcp.json',
          jsonEncode(<String, Object?>{
            'mcpServers': <String, Object?>{
              'github': <String, Object?>{'command': 'npx'},
            },
          }),
        );

        expect(
          () => service().admit(
            request(
              declarations: <PackMcpDeclaration>[declaration('github')],
              targets: const <McpHarness>[McpHarness.claude],
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('MCP_COLLISION_REVIEW_REQUIRED'),
                contains('github'),
                contains('nativeProject'),
                contains('credential-and-value-data-omitted'),
              ),
            ),
          ),
        );
      });

      test('refuses a managed-ledger collision by default', () {
        writeManaged('managed-server');

        expect(
          () => service().admit(
            request(
              declarations: <PackMcpDeclaration>[declaration('managed-server')],
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('MCP_COLLISION_REVIEW_REQUIRED'),
                contains('managed-server'),
                contains('managedLedger'),
              ),
            ),
          ),
        );
      });

      test('allows a collision only with explicit reviewed resolution', () {
        writeFile(
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

        final report = service().admit(
          request(
            declarations: <PackMcpDeclaration>[declaration('github')],
            targets: const <McpHarness>[McpHarness.claude],
            reviewed: const <String>{'github'},
          ),
        );

        expect(report.collisions, hasLength(1));
        expect(
          report.collisions.single.origin,
          PackMcpCollisionOrigin.nativeProject,
        );
        expect(
          report.toJson()['redaction'],
          'credential-and-value-data-omitted',
        );
        // The gate never silently replaces: the native file is untouched.
        expect(
          fs.file(fs.path.join(sourceRoot, '.mcp.json')).readAsStringSync(),
          before,
        );
      });

      test('never silently replaces on a default refusal', () {
        writeFile(
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
        try {
          service().admit(
            request(
              declarations: <PackMcpDeclaration>[declaration('github')],
              targets: const <McpHarness>[McpHarness.claude],
            ),
          );
        } on Exception {
          // Expected refusal.
        }
        expect(
          fs.file(fs.path.join(sourceRoot, '.mcp.json')).readAsStringSync(),
          before,
        );
      });
    });
  });
}
