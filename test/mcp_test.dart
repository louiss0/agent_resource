import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/mcp/mcp_native.dart';
import 'package:agent_resource/src/mcp/mcp_ownership_ledger.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/services/mcp_inspection_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

/// Builds a literal `${NAME}` reference without triggering Dart interpolation.
String ref(String name) => [String.fromCharCode(36), '{', name, '}'].join();

const List<String> secretLiterals = <String>[
  'sk-LIVE-SECRET-PROJECT',
  'USER_SECRET_TOKEN',
  'CODEX_LITERAL_SECRET',
  'URL_SECRET_QUERY',
  'LOCAL_SECRET_VALUE',
  'PI_USER_SECRET',
  'PI_PROJECT_SECRET',
];

void main() {
  group('agent_resource', () {
    group('mcp', () {
      late fslib.FileSystem fs;
      late Map<String, Object?> claudeProjectEntry;

      void writeJson(String path, Map<String, Object?> document) {
        fs.file(path)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(jsonEncode(document));
      }

      void writeText(String path, String text) {
        fs.file(path)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);
      }

      setUp(() {
        fs = MemoryFileSystem(style: FileSystemStyle.posix);
        for (final dir in <String>[
          '/sandbox/project/.codex',
          '/sandbox/project/.pi',
          '/sandbox/home',
          '/sandbox/claude',
          '/sandbox/codex',
          '/sandbox/pi',
          '/sandbox/state',
        ]) {
          fs.directory(dir).createSync(recursive: true);
        }

        claudeProjectEntry = <String, Object?>{
          'type': 'stdio',
          'command': 'node',
          'args': <Object?>['server.js'],
          'env': <String, Object?>{
            'API_KEY': 'sk-LIVE-SECRET-PROJECT',
            'REF': ref('PROJECT_TOKEN'),
          },
        };
        writeJson('/sandbox/project/.mcp.json', <String, Object?>{
          'mcpServers': <String, Object?>{
            'claude-project-svc': claudeProjectEntry,
          },
          'unrelatedTopLevel': 'keep-me',
        });

        writeJson('/sandbox/home/.claude.json', <String, Object?>{
          'mcpServers': <String, Object?>{
            'claude-user-svc': <String, Object?>{
              'type': 'http',
              'url': 'https://user.example.com/mcp',
              'headers': <String, Object?>{
                'Authorization': 'Bearer USER_SECRET_TOKEN',
              },
            },
          },
          'projects': <String, Object?>{
            '/sandbox/project': <String, Object?>{
              'mcpServers': <String, Object?>{
                'claude-local-svc': <String, Object?>{
                  'command': 'local-bin',
                  'env': <String, Object?>{'TOKEN': 'LOCAL_SECRET_VALUE'},
                },
              },
              'allowedTools': <Object?>['Bash'],
            },
          },
          'account': <String, Object?>{'email': 'user@example.com'},
        });

        writeText(
          '/sandbox/codex/config.toml',
          '# keep this comment\n'
              'model = "o3"\n'
              '\n'
              '[mcp_servers.codex-user-svc]\n'
              'command = "gh-mcp"\n'
              'args = ["serve"]\n'
              'bearer_token_env_var = "CODEX_TOKEN"\n'
              'http_headers = { Authorization = "Bearer CODEX_LITERAL_SECRET" }\n',
        );

        writeText(
          '/sandbox/project/.codex/config.toml',
          '[mcp_servers.codex-project-svc]\n'
              'url = "https://codex.example.com/mcp?token=URL_SECRET_QUERY"\n'
              'enabled = true\n',
        );

        writeJson('/sandbox/pi/mcp.json', <String, Object?>{
          'mcpServers': <String, Object?>{
            'pi-user-svc': <String, Object?>{
              'command': 'pi-mcp',
              'env': <String, Object?>{
                'KEY': 'PI_USER_SECRET',
                'REF': ref('PI_REF'),
              },
            },
          },
          'autoEnableCodemode': false,
        });

        writeJson('/sandbox/project/.pi/mcp.json', <String, Object?>{
          'mcpServers': <String, Object?>{
            'pi-project-svc': <String, Object?>{
              'url': 'https://pi.example.com/mcp',
              'headers': <String, Object?>{'X-Api-Key': 'PI_PROJECT_SECRET'},
            },
          },
        });

        // Ownership ledger: one matching baseline (managed), one drifted
        // baseline (ownership-unverified), one missing native entry
        // (ownership-unverified).
        writeJson('/sandbox/state/mcp-registrations.json', <String, Object?>{
          'schemaVersion': 1,
          'records': <Object?>[
            McpRegistrationRecord(
              identity: McpRegistrationIdentity(
                harness: McpHarness.claude,
                scope: McpScope.project,
                location: '/sandbox/project/.mcp.json',
                name: 'claude-project-svc',
              ),
              baselineDigest: mcpCanonicalDigest(claudeProjectEntry),
            ).toJson(),
            McpRegistrationRecord(
              identity: McpRegistrationIdentity(
                harness: McpHarness.codex,
                scope: McpScope.user,
                location: '/sandbox/codex/config.toml',
                name: 'codex-user-svc',
              ),
              baselineDigest: 'deadbeef-wrong-digest',
            ).toJson(),
            McpRegistrationRecord(
              identity: McpRegistrationIdentity(
                harness: McpHarness.pi,
                scope: McpScope.user,
                location: '/sandbox/pi/mcp.json',
                name: 'ghost-svc',
              ),
              baselineDigest: 'cafebabe',
            ).toJson(),
          ],
        });
      });

      // FolderPathOption requires a separator-terminated path, matching the
      // existing injected-executor memory-filesystem tests.
      List<String> context() => <String>[
        '--cwd',
        '/sandbox/project/',
        '--project-root',
        '/sandbox/project/',
        '--home',
        '/sandbox/home/',
        '--claude-config-dir',
        '/sandbox/claude/',
        '--codex-home',
        '/sandbox/codex/',
        '--pi-agent-dir',
        '/sandbox/pi/',
        '--state-dir',
        '/sandbox/state/',
      ];

      Future<MambaExecutionResult> exec(List<String> tokens) => createExecutor(
        fileSystem: fs,
        mcpInspection: McpInspectionService(fileSystem: fs),
      ).fake().execute(tokens);

      List<String> listArgs([List<String> extra = const <String>[]]) =>
          <String>['mcp', 'list', ...extra, ...context()];

      List<String> inspectArgs(List<String> extra) => <String>[
        'mcp',
        'inspect',
        ...extra,
        ...context(),
      ];

      Map<String, dynamic> successEnvelope(MambaExecutionResult result) {
        expect(
          result,
          isA<MambaSuccessResult>().having(
            (value) => value.exitCode,
            'exit code',
            0,
          ),
        );
        final output = (result as MambaSuccessResult).output!;
        return jsonDecode(output) as Map<String, dynamic>;
      }

      List<Map<String, dynamic>> registrations(Map<String, dynamic> envelope) =>
          ((envelope['data'] as Map<String, dynamic>)['registrations'] as List)
              .cast<Map<String, dynamic>>();

      Map<String, dynamic> named(Map<String, dynamic> envelope, String name) =>
          registrations(envelope).firstWhere((r) => r['name'] == name);

      void expectNoSecrets(String output) {
        for (final secret in secretLiterals) {
          expect(output, isNot(contains(secret)), reason: secret);
        }
      }

      Map<String, String> snapshot() {
        final result = <String, String>{};
        void walk(String dir) {
          final entities = fs.directory(dir).listSync(followLinks: false)
            ..sort((a, b) => a.path.compareTo(b.path));
          for (final entity in entities) {
            final type = fs.typeSync(entity.path, followLinks: false);
            if (type == FileSystemEntityType.directory) {
              result['${entity.path}/'] = 'dir';
              walk(entity.path);
            } else if (type == FileSystemEntityType.file) {
              result[entity.path] =
                  'file:${base64Encode(fs.file(entity.path).readAsBytesSync())}';
            } else if (type == FileSystemEntityType.link) {
              result[entity.path] = 'link:${fs.link(entity.path).targetSync()}';
            } else {
              result[entity.path] = 'other:$type';
            }
          }
        }

        walk('/');
        return result;
      }

      void expectFailure(
        MambaExecutionResult result, {
        required int exitCode,
        required String token,
        MambaExecutionPhase? phase,
      }) {
        expect(result, isA<MambaFailureResult>());
        final failure = result as MambaFailureResult;
        expect(failure.exitCode, exitCode);
        expect(failure.message, contains(token));
        expect(failure.output, isNull);
        if (phase != null) expect(failure.error.phase, phase);
      }

      group('help', () {
        test('shows the list and inspect children', () async {
          final result = await exec(<String>['mcp', '--help']);
          expect(result, isA<MambaSuccessResult>());
          final output = (result as MambaSuccessResult).output!;
          expect(output, contains('list'));
          expect(output, contains('inspect'));
        });

        test('list declares its typed inputs', () async {
          final result = await exec(<String>['mcp', 'list', '--help']);
          expect(result, isA<MambaSuccessResult>());
          final output = (result as MambaSuccessResult).output!;
          for (final flag in <String>[
            '--harness',
            '--scope',
            '--format',
            '--verify',
            '--cwd',
            '--state-dir',
          ]) {
            expect(output, contains(flag), reason: flag);
          }
        });

        test('inspect declares its selection inputs', () async {
          final result = await exec(<String>['mcp', 'inspect', '--help']);
          expect(result, isA<MambaSuccessResult>());
          final output = (result as MambaSuccessResult).output!;
          for (final flag in <String>['--name', '--harness', '--scope']) {
            expect(output, contains(flag), reason: flag);
          }
        });
      });

      group('list', () {
        test(
          'discovers all three harnesses and the requested scopes',
          () async {
            final envelope = successEnvelope(
              await exec(listArgs(<String>['--format', 'json'])),
            );
            expect(envelope['schemaVersion'], 1);
            expect(envelope['command'], 'mcp.list');
            expect(envelope['outcome'], 'listed');
            final combos = registrations(envelope)
                .map((r) => '${r['harness']}/${r['scope']}')
                .toSet();
            for (final combo in <String>{
              'claude/project',
              'claude/user',
              'claude/local',
              'codex/user',
              'codex/project',
              'pi/user',
              'pi/project',
            }) {
              expect(combos, contains(combo), reason: combo);
            }
            final data = envelope['data'] as Map<String, dynamic>;
            expect(data['claim'], contains('not verified'));
            final diagnostics = envelope['diagnostics'] as List;
            expect(
              diagnostics.map((d) => (d as Map)['code']),
              contains('STATIC_CONFIGURATION_ONLY'),
            );
          },
        );

        test(
          'classifies managed, unmanaged and ownership-unverified entries',
          () async {
            final envelope = successEnvelope(
              await exec(listArgs(<String>['--format', 'json'])),
            );
            expect(
              named(envelope, 'claude-project-svc')['ownership'],
              'managed',
            );
            expect(named(envelope, 'claude-project-svc')['present'], isTrue);
            expect(named(envelope, 'pi-project-svc')['ownership'], 'unmanaged');
            expect(
              named(envelope, 'codex-user-svc')['ownership'],
              'ownership-unverified',
            );
            expect(named(envelope, 'codex-user-svc')['present'], isTrue);
            expect(
              named(envelope, 'ghost-svc')['ownership'],
              'ownership-unverified',
            );
            expect(named(envelope, 'ghost-svc')['present'], isFalse);
          },
        );

        test(
          'never prints literals but discloses references and endpoints',
          () async {
            final jsonOutput = (await exec(
              listArgs(<String>['--format', 'json']),
            ) as MambaSuccessResult).output!;
            final textOutput =
                (await exec(listArgs()) as MambaSuccessResult).output!;
            for (final output in <String>[jsonOutput, textOutput]) {
              expectNoSecrets(output);
              expect(output, contains(ref('PROJECT_TOKEN')));
              expect(output, contains(ref('PI_REF')));
              expect(output, contains('CODEX_TOKEN'));
              expect(output, contains('https://codex.example.com/mcp'));
              expect(output, isNot(contains('token=')));
            }
          },
        );

        test(
          'is read-only and preserves unrelated keys and comments',
          () async {
            final before = snapshot();
            expect(
              await exec(listArgs(<String>['--format', 'json'])),
              isA<MambaSuccessResult>(),
            );
            expect(
              await exec(
                inspectArgs(<String>[
                  '--name',
                  'claude-project-svc',
                  '--harness',
                  'claude',
                  '--scope',
                  'project',
                  '--format',
                  'json',
                ]),
              ),
              isA<MambaSuccessResult>(),
            );
            expect(snapshot(), equals(before));
            expect(
              fs.file('/sandbox/codex/config.toml').readAsStringSync(),
              contains('# keep this comment'),
            );
            expect(
              fs.file('/sandbox/project/.mcp.json').readAsStringSync(),
              contains('unrelatedTopLevel'),
            );
            expect(
              fs.file('/sandbox/home/.claude.json').readAsStringSync(),
              contains('allowedTools'),
            );
            expect(
              fs.file('/sandbox/pi/mcp.json').readAsStringSync(),
              contains('autoEnableCodemode'),
            );
          },
        );

        test('renders deterministic text', () async {
          final first = (await exec(listArgs()) as MambaSuccessResult).output!;
          final second = (await exec(listArgs()) as MambaSuccessResult).output!;
          expect(first, equals(second));
        });

        test('--verify discloses baseline digests', () async {
          final plain = successEnvelope(
            await exec(listArgs(<String>['--format', 'json'])),
          );
          final verified = successEnvelope(
            await exec(listArgs(<String>['--format', 'json', '--verify'])),
          );
          expect((plain['data'] as Map)['verified'], isFalse);
          expect(registrations(plain).first.containsKey('digest'), isFalse);
          expect((verified['data'] as Map)['verified'], isTrue);
          expect(registrations(verified).first.containsKey('digest'), isTrue);
        });

        test('rejects an unsupported harness/scope combination', () async {
          final result = await exec(
            listArgs(<String>['--harness', 'codex', '--scope', 'local']),
          );
          expectFailure(result, exitCode: 2, token: 'MCP scope');
        });

        test('rejects undeclared and invalid inputs at parse time', () async {
          for (final tokens in <List<String>>[
            <String>['mcp', 'list', '--not-an-input'],
            <String>['mcp', 'list', '--harness', 'nope'],
            <String>['mcp', 'list', '--format', 'bogus'],
          ]) {
            final result = await exec(tokens);
            expect(result, isA<MambaFailureResult>(), reason: '$tokens');
            final failure = result as MambaFailureResult;
            expect(failure.output, isNull);
            expect(failure.error.phase, MambaExecutionPhase.parse);
            expect(failure.exitCode, isNonZero);
          }
        });
      });

      group('inspect', () {
        test('renders one native shape with redaction', () async {
          final envelope = successEnvelope(
            await exec(
              inspectArgs(<String>[
                '--name',
                'claude-project-svc',
                '--harness',
                'claude',
                '--scope',
                'project',
                '--format',
                'json',
              ]),
            ),
          );
          expect(envelope['command'], 'mcp.inspect');
          expect(envelope['schemaVersion'], 1);
          final registration =
              (envelope['data'] as Map<String, dynamic>)['registration']
                  as Map<String, dynamic>;
          expect(registration['name'], 'claude-project-svc');
          expect(registration['ownership'], 'managed');
          expect(registration['transport'], 'stdio');
          final fields = registration['fields'] as Map<String, dynamic>;
          expect(fields['command'], 'node');
          expect((fields['env'] as Map)['REF'], ref('PROJECT_TOKEN'));
          expect((fields['env'] as Map)['API_KEY'], '<redacted>');
          expect(jsonEncode(envelope), isNot(contains('sk-LIVE')));
        });

        test('renders redacted text too', () async {
          final result = await exec(
            inspectArgs(<String>[
              '--name',
              'claude-user-svc',
              '--harness',
              'claude',
              '--scope',
              'user',
            ]),
          );
          expect(result, isA<MambaSuccessResult>());
          final output = (result as MambaSuccessResult).output!;
          expectNoSecrets(output);
          expect(output, contains('<redacted>'));
          expect(output, contains('https://user.example.com/mcp'));
        });

        test('requires explicit name, harness and scope', () async {
          for (final extra in <List<String>>[
            <String>['--name', 'svc'],
            <String>['--name', 'svc', '--harness', 'claude'],
            <String>['--name', 'svc', '--scope', 'project'],
            <String>['--harness', 'claude', '--scope', 'project'],
          ]) {
            final result = await exec(inspectArgs(extra));
            expectFailure(result, exitCode: 2, token: 'requires');
          }
        });

        test('reports a missing registration as a product error', () async {
          final result = await exec(
            inspectArgs(<String>[
              '--name',
              'does-not-exist',
              '--harness',
              'claude',
              '--scope',
              'project',
            ]),
          );
          expectFailure(result, exitCode: 2, token: 'No MCP registration');
        });
      });

      group('operational failures', () {
        test(
          'malformed/duplicate-key JSON yields status 1 and no success JSON',
          () async {
            fs
                .file('/sandbox/project/.mcp.json')
                .writeAsStringSync('{"mcpServers":{},"mcpServers":{}}');
            final result = await exec(listArgs(<String>['--format', 'json']));
            expectFailure(
              result,
              exitCode: 1,
              token: 'MCP configuration',
              phase: MambaExecutionPhase.run,
            );
            expect(
              (result as MambaFailureResult).message,
              isNot(contains('schemaVersion')),
            );
          },
        );

        test(
          'a linked native file yields status 1 and no success JSON',
          () async {
            fs.file('/sandbox/pi/mcp.json').deleteSync();
            fs.directory('/sandbox/pi/target').createSync();
            fs.link('/sandbox/pi/mcp.json').createSync('/sandbox/pi/target');
            final result = await exec(listArgs(<String>['--format', 'json']));
            expectFailure(
              result,
              exitCode: 1,
              token: 'link',
              phase: MambaExecutionPhase.run,
            );
          },
        );
      });
    });
  });
}
