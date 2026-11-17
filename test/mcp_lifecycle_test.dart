import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/mcp/mcp_native.dart';
import 'package:agent_resource/src/mcp/mcp_ownership_ledger.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/services/mcp_inspection_service.dart';
import 'package:agent_resource/src/services/mcp_mutation_service.dart';
import 'package:agent_resource/src/services/mcp_validation_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

/// Builds a whole-value `${NAME}` reference without Dart interpolation.
String ref(String name) => [String.fromCharCode(36), '{', name, '}'].join();

/// A KEY=REFERENCE CLI token built by interpolation.
String kvRef(String key, String name) => '$key=${ref(name)}';

const String jsonSecret = 'sk-LIVE-SECRET-PROJECT';
const String tomlSecret = 'sk-LIVE-SECRET-CODEX';
final List<String> secrets = <String>[
  jsonSecret,
  tomlSecret,
  'LITERAL-INTRODUCED-SECRET',
  'BEARER-LITERAL-SECRET',
];

void main() {
  group('agent_resource', () {
    group('mcp lifecycle', () {
      late fslib.FileSystem fs;
      late List<String> previews;
      late Future<bool> Function(String) approval;

      const String claudeProjectPath = '/sandbox/project/.mcp.json';
      const String codexUserPath = '/sandbox/codex/config.toml';
      const String ledgerPath = '/sandbox/state/mcp-registrations.json';

      McpNativeLocation claudeProject() => McpNativeLocation(
        harness: McpHarness.claude,
        scope: McpScope.project,
        path: claudeProjectPath,
        format: McpNativeFormat.json,
        section: McpNativeSection.mcpServers,
      );

      McpNativeLocation codexUser() => McpNativeLocation(
        harness: McpHarness.codex,
        scope: McpScope.user,
        path: codexUserPath,
        format: McpNativeFormat.toml,
        section: McpNativeSection.codexMcpServers,
      );

      void writeText(String path, String text) {
        fs.file(path)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);
      }

      void writeJson(String path, Map<String, Object?> document) =>
          writeText(path, jsonEncode(document));

      String readText(String path) => fs.file(path).readAsStringSync();

      bool fileExists(String path) => fs.file(path).existsSync();

      Map<String, Object?>? entryAt(McpNativeLocation location, String name) =>
          McpNativeReader(fs).read(location)[name];

      void writeLedger(List<McpRegistrationRecord> records) =>
          writeJson(ledgerPath, <String, Object?>{
            'schemaVersion': mcpRegistrationLedgerSchemaVersion,
            'records': <Object?>[for (final record in records) record.toJson()],
          });

      List<dynamic> ledgerRecords() {
        if (!fileExists(ledgerPath)) return <dynamic>[];
        return (jsonDecode(readText(ledgerPath))
                as Map<String, dynamic>)['records']
            as List<dynamic>;
      }

      String digestOf(McpNativeLocation location, String name) =>
          mcpCanonicalDigest(entryAt(location, name));

      /// Seeds a matching ownership baseline for an already-written native
      /// entry, using the same canonical digest the discovery service uses.
      void seedManaged(McpNativeLocation location, String name) => writeLedger([
        McpRegistrationRecord(
          identity: McpRegistrationIdentity(
            harness: location.harness,
            scope: location.scope,
            location: location.path,
            name: name,
          ),
          baselineDigest: digestOf(location, name),
        ),
      ]);

      List<String> ctx() => const <String>[
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

      List<String> sel(
        String name, {
        String harness = 'claude',
        String scope = 'project',
      }) => <String>['--name', name, '--harness', harness, '--scope', scope];

      List<String> cmd(String verb, List<String> extra) => <String>[
        'mcp',
        verb,
        ...extra,
        ...ctx(),
      ];

      Future<MambaExecutionResult> exec(List<String> tokens) => createExecutor(
        fileSystem: fs,
        mcpInspection: McpInspectionService(fileSystem: fs),
        mcpValidation: McpValidationService(fileSystem: fs),
        mcpMutation: McpMutationService(
          fileSystem: fs,
          validation: McpValidationService(fileSystem: fs),
          approve: approval,
        ),
      ).fake().execute(tokens);

      Map<String, dynamic> success(MambaExecutionResult result) {
        expect(
          result,
          isA<MambaSuccessResult>().having(
            (value) => value.exitCode,
            'exit code',
            0,
          ),
        );
        return jsonDecode((result as MambaSuccessResult).output!)
            as Map<String, dynamic>;
      }

      void failure(
        MambaExecutionResult result, {
        required int exitCode,
        required String token,
        MambaExecutionPhase? phase,
      }) {
        expect(result, isA<MambaFailureResult>());
        final value = result as MambaFailureResult;
        expect(value.exitCode, exitCode);
        expect(value.message, contains(token));
        // Story 43: a failure never emits success JSON on stdout.
        expect(value.output, isNull);
        if (phase != null) expect(value.error.phase, phase);
      }

      void expectNoSecrets(String output) {
        for (final secret in secrets) {
          expect(output, isNot(contains(secret)), reason: secret);
        }
      }

      setUp(() {
        fs = MemoryFileSystem(style: FileSystemStyle.posix);
        for (final dir in const <String>[
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
        previews = <String>[];
        approval = (String preview) async {
          previews.add(preview);
          return true;
        };
      });

      group('help and selection', () {
        test('register declares every typed input', () async {
          final result = await exec(<String>['mcp', 'register', '--help']);
          expect(result, isA<MambaSuccessResult>());
          final output = (result as MambaSuccessResult).output!;
          for (final flag in const <String>[
            '--name',
            '--harness',
            '--scope',
            '--command',
            '--args',
            '--env',
            '--url',
            '--header',
            '--type',
            '--format',
            '--dry-run',
            '--yes',
            '--interactive',
            '--plan-id',
            '--ack-mcp-risk',
            '--allow-drift',
            '--cwd',
            '--state-dir',
          ]) {
            expect(output, contains(flag), reason: flag);
          }
        });

        test('occurrences and paths are never selectors', () async {
          for (final tokens in <List<String>>[
            cmd('register', <String>[
              ...sel('svc'),
              '--command',
              'node',
              '--occurrence',
              '1',
            ]),
            cmd('register', <String>[
              ...sel('svc'),
              '--command',
              'node',
              '--path',
              claudeProjectPath,
            ]),
          ]) {
            final result = await exec(tokens);
            expect(result, isA<MambaFailureResult>());
            expect(
              (result as MambaFailureResult).error.phase,
              MambaExecutionPhase.parse,
            );
            expect(result.output, isNull);
          }
        });

        test('requires the explicit name, harness and scope', () async {
          for (final extra in <List<String>>[
            <String>['--command', 'node'],
            <String>['--name', 'svc', '--command', 'node'],
            <String>[
              '--name',
              'svc',
              '--harness',
              'claude',
              '--command',
              'node',
            ],
            <String>[
              '--name',
              'svc',
              '--scope',
              'project',
              '--command',
              'node',
            ],
          ]) {
            final result = await exec(cmd('register', extra));
            expect(result, isA<MambaFailureResult>());
            expect(
              (result as MambaFailureResult).error.phase,
              MambaExecutionPhase.parse,
            );
            expect(result.output, isNull);
          }
        });
      });

      group('interactive register (stories 12, 13, 14, 42)', () {
        test('stdio review then approval writes only the new entry', () async {
          writeJson(claudeProjectPath, <String, Object?>{
            'mcpServers': <String, Object?>{
              'existing': <String, Object?>{'command': 'keep'},
            },
            'unrelatedTopLevel': 'keep-me',
          });

          final result = await exec(
            cmd('register', <String>[
              ...sel('new-svc'),
              '--command',
              'node',
              '--args',
              'server.js',
              '--env',
              kvRef('API_KEY', 'PROJECT_TOKEN'),
              '--format',
              'json',
            ]),
          );

          final envelope = success(result);
          expect(envelope['schemaVersion'], 1);
          expect(envelope['command'], 'mcp.register');
          expect(envelope['outcome'], 'registered');
          final data = envelope['data'] as Map<String, dynamic>;
          expect(data['planId'], isA<String>());
          expect((data['planId'] as String).isNotEmpty, isTrue);
          expect(data['nativeWritten'], isTrue);
          expect(data['transport'], 'stdio');
          expectNoSecrets((result as MambaSuccessResult).output!);

          // The complete plan was disclosed to the reviewer, redacted.
          expect(previews, hasLength(1));
          expect(previews.single, contains('claude'));
          expect(previews.single, contains('project'));
          expect(previews.single, contains('new-svc'));
          expect(previews.single, contains('stdio'));
          expect(previews.single, contains('node'));
          expect(previews.single, contains(ref('PROJECT_TOKEN')));
          expectNoSecrets(previews.single);

          // Native effects: only the new named entry was added.
          final text = readText(claudeProjectPath);
          expect(text, contains('"existing"'));
          expect(text, contains('unrelatedTopLevel'));
          expect(text, contains('"new-svc"'));
          expect(text, contains(ref('PROJECT_TOKEN')));
          final document = jsonDecode(text) as Map<String, dynamic>;
          final servers = document['mcpServers'] as Map<String, dynamic>;
          // The unrelated existing entry and top-level key survive untouched.
          expect((servers['existing'] as Map)['command'], 'keep');
          expect(document['unrelatedTopLevel'], 'keep-me');
          final added = servers['new-svc'] as Map<String, dynamic>;
          expect(added['command'], 'node');
          expect(added['args'], ['server.js']);
          expect((added['env'] as Map)['API_KEY'], ref('PROJECT_TOKEN'));

          // Ownership ledger baseline is in sync: list sees it as managed.
          final listed = success(
            await exec(cmd('list', <String>['--format', 'json'])),
          );
          final regs =
              (listed['data'] as Map<String, dynamic>)['registrations'] as List;
          final found = regs.cast<Map<String, dynamic>>().firstWhere(
            (r) => r['name'] == 'new-svc',
          );
          expect(found['ownership'], 'managed');
        });

        test(
          'HTTP review then approval writes url, references and type',
          () async {
            writeJson(claudeProjectPath, <String, Object?>{
              'mcpServers': <String, Object?>{},
              'unrelatedTopLevel': 'keep-me',
            });

            final result = await exec(
              cmd('register', <String>[
                ...sel('remote'),
                '--url',
                'https://example.com/mcp?token=BEARER-LITERAL-SECRET',
                '--header',
                kvRef('Authorization', 'AUTH_TOKEN'),
                '--format',
                'json',
              ]),
            );

            success(result);
            expectNoSecrets((result as MambaSuccessResult).output!);
            expect(previews.single, contains('https://example.com/mcp'));
            // The endpoint is sanitized: query secret is never disclosed.
            expect(previews.single, isNot(contains('token=')));
            expect(previews.single, contains(ref('AUTH_TOKEN')));
            expectNoSecrets(previews.single);

            final document =
                jsonDecode(readText(claudeProjectPath)) as Map<String, dynamic>;
            final added =
                (document['mcpServers'] as Map<String, dynamic>)['remote']
                    as Map<String, dynamic>;
            expect(
              added['url'],
              'https://example.com/mcp?token=BEARER-LITERAL-SECRET',
            );
            expect(added['type'], 'http');
            expect(
              (added['headers'] as Map)['Authorization'],
              ref('AUTH_TOKEN'),
            );
            expect(readText(claudeProjectPath), contains('unrelatedTopLevel'));
          },
        );
      });

      group('credentials (stories 17, 18)', () {
        test(
          'refuses a literal --env secret and accepts a reference',
          () async {
            // Literal secret is refused before any write.
            failure(
              await exec(
                cmd('register', <String>[
                  ...sel('svc'),
                  '--command',
                  'node',
                  '--env',
                  'API_KEY=LITERAL-INTRODUCED-SECRET',
                ]),
              ),
              exitCode: 2,
              token: 'references',
            );
            expect(fileExists(claudeProjectPath), isFalse);

            // A reference is accepted.
            final result = await exec(
              cmd('register', <String>[
                ...sel('svc'),
                '--command',
                'node',
                '--env',
                kvRef('API_KEY', 'API_KEY'),
                '--format',
                'json',
              ]),
            );
            success(result);
            expect(readText(claudeProjectPath), contains(ref('API_KEY')));
            expect(
              readText(claudeProjectPath),
              isNot(contains('LITERAL-INTRODUCED-SECRET')),
            );
          },
        );

        test('refuses a literal --header secret', () async {
          failure(
            await exec(
              cmd('register', <String>[
                ...sel('remote'),
                '--url',
                'https://example.com/mcp',
                '--header',
                'Authorization=Bearer BEARER-LITERAL-SECRET',
              ]),
            ),
            exitCode: 2,
            token: 'references',
          );
          expect(fileExists(claudeProjectPath), isFalse);
        });
      });

      group('plan, dry-run, unattended (stories 16, 20, 21)', () {
        List<String> registerStdio(List<String> extra) =>
            cmd('register', <String>[
              ...sel('svc'),
              '--command',
              'node',
              '--format',
              'json',
              ...extra,
            ]);

        test('--dry-run discloses a plan and writes nothing', () async {
          writeJson(claudeProjectPath, <String, Object?>{
            'mcpServers': <String, Object?>{},
            'unrelatedTopLevel': 'v1',
          });
          final before = readText(claudeProjectPath);
          final envelope = success(
            await exec(registerStdio(<String>['--dry-run'])),
          );
          expect(envelope['outcome'], 'planned');
          final data = envelope['data'] as Map<String, dynamic>;
          expect(data['planId'], isA<String>());
          expect(data['writes'], isFalse);
          expect(data['reviewRequired'], isTrue);
          expect(readText(claudeProjectPath), before);
          expect(ledgerRecords(), isEmpty);
          expect(previews, isEmpty); // no approval on a dry-run
        });

        test('unattended requires --ack-mcp-risk', () async {
          failure(
            await exec(registerStdio(<String>['--yes'])),
            exitCode: 2,
            token: '--ack-mcp-risk',
          );
          expect(fileExists(claudeProjectPath), isFalse);
        });

        test('unattended requires complete explicit inputs', () async {
          failure(
            await exec(
              cmd('register', <String>[
                ...sel('svc'),
                '--yes',
                '--ack-mcp-risk',
              ]),
            ),
            exitCode: 2,
            token: 'exactly one transport',
          );
          expect(fileExists(claudeProjectPath), isFalse);
        });

        test('unattended succeeds with complete inputs and risk ack', () async {
          final result = await exec(
            registerStdio(<String>['--yes', '--ack-mcp-risk']),
          );
          success(result);
          expect(previews, isEmpty); // unattended: no interactive prompt
          expect(readText(claudeProjectPath), contains('"svc"'));
          expect(ledgerRecords(), hasLength(1));
        });

        test(
          'an unrelated shared-file edit invalidates a reviewed --plan-id',
          () async {
            writeJson(claudeProjectPath, <String, Object?>{
              'mcpServers': <String, Object?>{},
              'unrelatedTopLevel': 'v1',
            });
            final plan = success(
              await exec(registerStdio(<String>['--dry-run'])),
            );
            final planId =
                (plan['data'] as Map<String, dynamic>)['planId'] as String;

            // External edit of an unrelated key in the shared file.
            writeJson(claudeProjectPath, <String, Object?>{
              'mcpServers': <String, Object?>{},
              'unrelatedTopLevel': 'v2',
            });

            failure(
              await exec(
                registerStdio(<String>[
                  '--yes',
                  '--ack-mcp-risk',
                  '--plan-id',
                  planId,
                ]),
              ),
              exitCode: 4,
              token: 'Stale or mismatched --plan-id',
            );
            final document =
                jsonDecode(readText(claudeProjectPath)) as Map<String, dynamic>;
            expect(
              (document['mcpServers'] as Map<String, dynamic>).containsKey(
                'svc',
              ),
              isFalse,
            );
            expect(ledgerRecords(), isEmpty);
          },
        );

        test(
          'interactive re-read refuses when the source changed during review',
          () async {
            writeJson(claudeProjectPath, <String, Object?>{
              'mcpServers': <String, Object?>{},
              'unrelatedTopLevel': 'v1',
            });
            approval = (String preview) async {
              previews.add(preview);
              // Simulate an external shared-file edit during the review await.
              writeJson(claudeProjectPath, <String, Object?>{
                'mcpServers': <String, Object?>{
                  'other': <String, Object?>{'command': 'concurrent'},
                },
                'unrelatedTopLevel': 'v1',
              });
              return true;
            };
            failure(
              await exec(registerStdio(<String>[])),
              exitCode: 4,
              token: 'changed after review',
            );
            expect(readText(claudeProjectPath), isNot(contains('"svc"')));
            expect(ledgerRecords(), isEmpty);
          },
        );
      });

      group('byte-preserving replace (stories 15, 18, 23)', () {
        test(
          'JSON: existing literal retained, only the changed field moves',
          () async {
            final projectRef = ref('PROJECT_TOKEN');
            final before =
                '{\n'
                '  "mcpServers": {\n'
                '    "svc": {\n'
                '      "type": "stdio",\n'
                '      "command": "node",\n'
                '      "args": ["server.js"],\n'
                '      "env": {\n'
                '        "API_KEY": "$jsonSecret",\n'
                '        "REF": "$projectRef"\n'
                '      }\n'
                '    }\n'
                '  },\n'
                '  "unrelatedTopLevel": "keep-me"\n'
                '}\n';
            writeText(claudeProjectPath, before);
            seedManaged(claudeProject(), 'svc');

            final result = await exec(
              cmd('replace', <String>[
                ...sel('svc'),
                '--command',
                'node2',
                '--format',
                'json',
              ]),
            );
            success(result);
            expectNoSecrets((result as MambaSuccessResult).output!);
            expectNoSecrets(previews.single);

            // Byte-for-byte: only the command value changed.
            final after = readText(claudeProjectPath);
            expect(
              after,
              before.replaceFirst('"command": "node"', '"command": "node2"'),
            );
            expect(after, contains(jsonSecret)); // literal retained in place
            expect(after, contains(projectRef));
            expect(after, contains('unrelatedTopLevel'));
          },
        );

        test(
          'TOML: comments, unrelated keys and literal preserved verbatim',
          () async {
            final codexRef = ref('CODEX_TOKEN');
            final before =
                '# keep this comment\n'
                'model = "o3"\n'
                '\n'
                '[mcp_servers.svc]\n'
                'command = "gh-mcp"  # inline command comment\n'
                'args = ["serve"]\n'
                'env = { API_KEY = "$tomlSecret", REF = "$codexRef" }\n';
            writeText(codexUserPath, before);
            seedManaged(codexUser(), 'svc');

            final result = await exec(
              cmd('replace', <String>[
                ...sel('svc', harness: 'codex', scope: 'user'),
                '--command',
                'gh-mcp-v2',
                '--format',
                'json',
              ]),
            );
            success(result);
            expectNoSecrets((result as MambaSuccessResult).output!);
            expectNoSecrets(previews.single);

            final after = readText(codexUserPath);
            expect(
              after,
              before.replaceFirst(
                'command = "gh-mcp"  # inline command comment',
                'command = "gh-mcp-v2"  # inline command comment',
              ),
            );
            expect(after, contains('# keep this comment'));
            expect(after, contains('model = "o3"'));
            expect(after, contains(tomlSecret));
            expect(after, contains(codexRef));
          },
        );
      });

      group('adoption (story 19)', () {
        test(
          'records a reviewed baseline without rewriting the native file',
          () async {
            final before =
                '{\n'
                '  "mcpServers": {\n'
                '    "svc": { "command": "node" }\n'
                '  },\n'
                '  "unrelatedTopLevel": "keep-me"\n'
                '}\n';
            writeText(claudeProjectPath, before);

            final result = await exec(
              cmd('adopt', <String>[...sel('svc'), '--format', 'json']),
            );
            final envelope = success(result);
            final data = envelope['data'] as Map<String, dynamic>;
            expect(envelope['outcome'], 'adopted');
            expect(data['nativeWritten'], isFalse);
            expect(data['ownership'], 'adopted');
            expect(previews, hasLength(1)); // reviewed + approved

            // Native bytes are completely untouched.
            expect(readText(claudeProjectPath), before);

            // Ledger baseline matches the current native entry digest exactly.
            expect(ledgerRecords(), hasLength(1));
            final record = ledgerRecords().single as Map<String, dynamic>;
            expect(record['baselineDigest'], digestOf(claudeProject(), 'svc'));

            final listed = success(
              await exec(cmd('list', <String>['--format', 'json'])),
            );
            final regs =
                (listed['data'] as Map<String, dynamic>)['registrations']
                    as List;
            expect(
              regs.cast<Map<String, dynamic>>().firstWhere(
                (r) => r['name'] == 'svc',
              )['ownership'],
              'managed',
            );
          },
        );
      });

      group('drift (stories 20, 21)', () {
        const String managedText =
            '{\n'
            '  "mcpServers": {\n'
            '    "svc": { "command": "node" }\n'
            '  },\n'
            '  "unrelatedTopLevel": "keep-me"\n'
            '}\n';

        void seedThenDrift() {
          writeText(claudeProjectPath, managedText);
          seedManaged(claudeProject(), 'svc');
          // External edit of the managed entry (baseline no longer matches).
          writeText(
            claudeProjectPath,
            managedText.replaceFirst(
              '"command": "node"',
              '"command": "external-edit"',
            ),
          );
        }

        test(
          'an externally changed managed entry refuses without resolution',
          () async {
            seedThenDrift();
            final before = readText(claudeProjectPath);
            failure(
              await exec(
                cmd('replace', <String>[...sel('svc'), '--command', 'node2']),
              ),
              exitCode: 4,
              token: 'drifted externally',
            );
            expect(readText(claudeProjectPath), before);
          },
        );

        test(
          'explicit reviewed drift resolution applies and re-baselines',
          () async {
            seedThenDrift();
            final plan = success(
              await exec(
                cmd('replace', <String>[
                  ...sel('svc'),
                  '--command',
                  'node2',
                  '--allow-drift',
                  '--dry-run',
                  '--format',
                  'json',
                ]),
              ),
            );
            final data = plan['data'] as Map<String, dynamic>;
            expect(data['drift'], isTrue);
            final planId = data['planId'] as String;

            final result = await exec(
              cmd('replace', <String>[
                ...sel('svc'),
                '--command',
                'node2',
                '--allow-drift',
                '--yes',
                '--ack-mcp-risk',
                '--plan-id',
                planId,
                '--format',
                'json',
              ]),
            );
            success(result);
            expect(readText(claudeProjectPath), contains('"command": "node2"'));

            final listed = success(
              await exec(cmd('list', <String>['--format', 'json'])),
            );
            final regs =
                (listed['data'] as Map<String, dynamic>)['registrations']
                    as List;
            expect(
              regs.cast<Map<String, dynamic>>().firstWhere(
                (r) => r['name'] == 'svc',
              )['ownership'],
              'managed',
            );
          },
        );

        test(
          'a deleted managed entry requires reviewed drift resolution',
          () async {
            writeText(claudeProjectPath, managedText);
            seedManaged(claudeProject(), 'svc');
            // External deletion of the entry (ledger record remains).
            writeText(
              claudeProjectPath,
              '{\n  "mcpServers": {},\n'
              '  "unrelatedTopLevel": "keep-me"\n}\n',
            );
            final before = readText(claudeProjectPath);

            failure(
              await exec(cmd('unregister', <String>[...sel('svc')])),
              exitCode: 4,
              token: 'drifted externally',
            );
            expect(readText(claudeProjectPath), before);

            final plan = success(
              await exec(
                cmd('unregister', <String>[
                  ...sel('svc'),
                  '--allow-drift',
                  '--dry-run',
                  '--format',
                  'json',
                ]),
              ),
            );
            final planId =
                (plan['data'] as Map<String, dynamic>)['planId'] as String;
            final result = await exec(
              cmd('unregister', <String>[
                ...sel('svc'),
                '--allow-drift',
                '--yes',
                '--ack-mcp-risk',
                '--plan-id',
                planId,
                '--format',
                'json',
              ]),
            );
            success(result);
            expect(readText(claudeProjectPath), before); // no native rewrite
            expect(ledgerRecords(), isEmpty);
          },
        );
      });

      group('inspect-only refusal (story 22)', () {
        test(
          'Claude user/local mutations are refused for every operation',
          () async {
            for (final verb in const <String>[
              'register',
              'replace',
              'adopt',
              'unregister',
            ]) {
              for (final scope in const <String>['user', 'local']) {
                final result = await exec(
                  cmd(verb, <String>[
                    ...sel('svc', scope: scope),
                    '--command',
                    'node',
                  ]),
                );
                failure(result, exitCode: 2, token: 'inspect-only');
              }
            }
            // No native home file or ledger was ever written.
            expect(fileExists('/sandbox/home/.claude.json'), isFalse);
            expect(ledgerRecords(), isEmpty);
          },
        );
      });

      group('unregister (story 23)', () {
        test(
          'removes only the selected entry and its ownership record',
          () async {
            final before =
                '{\n'
                '  "mcpServers": {\n'
                '    "svc": { "command": "node" },\n'
                '    "keep": { "command": "stay" }\n'
                '  },\n'
                '  "unrelatedTopLevel": "keep-me"\n'
                '}\n';
            writeText(claudeProjectPath, before);
            seedManaged(claudeProject(), 'svc');

            final result = await exec(
              cmd('unregister', <String>[...sel('svc'), '--format', 'json']),
            );
            final envelope = success(result);
            expect(envelope['outcome'], 'unregistered');
            expect(
              (envelope['data'] as Map<String, dynamic>)['ownership'],
              'removed',
            );

            final after = readText(claudeProjectPath);
            expect(after, isNot(contains('"svc"')));
            expect(after, contains('"keep"'));
            expect(after, contains('"command": "stay"'));
            expect(after, contains('unrelatedTopLevel'));
            // Still valid strict JSON.
            expect(jsonDecode(after), isA<Map<String, dynamic>>());
            // Ledger no longer records svc.
            expect(ledgerRecords(), isEmpty);
          },
        );
      });

      group('validation and cancellation (stories 44, 43)', () {
        test(
          'a validation failure blocks the write with no success JSON',
          () async {
            final result = await exec(
              cmd('register', <String>[
                ...sel('svc'),
                '--command',
                'node',
                '--type',
                'bogus',
                '--format',
                'json',
              ]),
            );
            failure(result, exitCode: 2, token: 'MCP_TYPE_UNSUPPORTED');
            expect(fileExists(claudeProjectPath), isFalse);
            expect(ledgerRecords(), isEmpty);
          },
        );

        test(
          'declining the review cancels with everything unchanged',
          () async {
            approval = (String preview) async {
              previews.add(preview);
              return false;
            };
            failure(
              await exec(
                cmd('register', <String>[...sel('svc'), '--command', 'node']),
              ),
              exitCode: 7,
              token: 'cancelled',
            );
            expect(fileExists(claudeProjectPath), isFalse);
            expect(fileExists(ledgerPath), isFalse);
          },
        );
      });

      group('native format robustness', () {
        test(
          'TOML register inserts the entry and syncs the TOML baseline',
          () async {
            writeText(codexUserPath, 'model = "o3"\n');
            final result = await exec(
              cmd('register', <String>[
                ...sel('remote', harness: 'codex', scope: 'user'),
                '--url',
                'https://codex.example.com/mcp',
                '--header',
                kvRef('Authorization', 'CODEX_TOKEN'),
                '--format',
                'json',
              ]),
            );
            success(result);
            final text = readText(codexUserPath);
            expect(text, contains('model = "o3"'));
            expect(text, contains('[mcp_servers.remote]'));
            expect(text, contains('url = "https://codex.example.com/mcp"'));
            expect(text, contains(ref('CODEX_TOKEN')));
            expectNoSecrets((result as MambaSuccessResult).output!);

            // The ledger baseline must match the TOML-parsed digest exactly.
            final listed = success(
              await exec(cmd('list', <String>['--format', 'json'])),
            );
            final regs =
                (listed['data'] as Map<String, dynamic>)['registrations']
                    as List;
            expect(
              regs.cast<Map<String, dynamic>>().firstWhere(
                (r) => r['name'] == 'remote',
              )['ownership'],
              'managed',
            );
          },
        );

        test(
          'TOML replace preserves CRLF newline style byte-for-byte',
          () async {
            final crlf =
                '# keep this comment\r\n'
                'model = "o3"\r\n'
                '\r\n'
                '[mcp_servers.svc]\r\n'
                'command = "gh-mcp"\r\n'
                'args = ["serve"]\r\n';
            writeText(codexUserPath, crlf);
            seedManaged(codexUser(), 'svc');
            final result = await exec(
              cmd('replace', <String>[
                ...sel('svc', harness: 'codex', scope: 'user'),
                '--command',
                'gh-mcp-v2',
                '--format',
                'json',
              ]),
            );
            success(result);
            expect(
              readText(codexUserPath),
              crlf.replaceFirst('command = "gh-mcp"', 'command = "gh-mcp-v2"'),
            );
            expect(
              readText(codexUserPath),
              contains('# keep this comment\r\n'),
            );
          },
        );

        test('--interactive forces a review even alongside --yes', () async {
          final result = await exec(
            cmd('register', <String>[
              ...sel('svc'),
              '--command',
              'node',
              '--yes',
              '--interactive',
              '--format',
              'json',
            ]),
          );
          success(result);
          expect(previews, hasLength(1));
        });
      });
    });
  });
}
