import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/mcp/mcp_conversion_lineage.dart';
import 'package:agent_resource/src/mcp/mcp_native.dart';
import 'package:agent_resource/src/mcp/mcp_ownership_ledger.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/services/mcp_conversion_service.dart';
import 'package:agent_resource/src/services/mcp_validation_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

/// Builds a whole-value `${NAME}` reference without Dart interpolation.
String ref(String name) => [String.fromCharCode(36), '{', name, '}'].join();

const String secretEnv = 'LITERAL-ENV-SECRET';
const String secretOAuth = 'OAUTH-CLIENT-SECRET';
const String secretHeader = 'LITERAL-HEADER-SECRET';
const String secretQuery = 'QUERY-SECRET';
const List<String> secretLiterals = <String>[
  secretEnv,
  secretOAuth,
  secretHeader,
  secretQuery,
  'CLIENT-ID-SECRET',
  'PROVIDER-CREDENTIAL-SELECTION',
];

void main() {
  group('agent_resource', () {
    group('mcp', () {
      group('convert', () {
        late fslib.FileSystem fs;
        late List<String> previews;
        late Future<bool> Function(String) approval;

        const String sourceName = 'convert-svc';
        const String stateRoot = '/sandbox/state';

        McpNativeLocation location(McpHarness harness, McpScope scope) =>
            switch (harness) {
              McpHarness.claude => McpNativeLocation(
                harness: harness,
                scope: scope,
                path: scope == McpScope.project
                    ? '/sandbox/project/.mcp.json'
                    : '/sandbox/home/.claude.json',
                format: McpNativeFormat.json,
                section: scope == McpScope.local
                    ? McpNativeSection.claudeLocalProjects
                    : McpNativeSection.mcpServers,
                projectKey: scope == McpScope.local ? '/sandbox/project' : null,
              ),
              McpHarness.codex => McpNativeLocation(
                harness: harness,
                scope: scope,
                path: scope == McpScope.project
                    ? '/sandbox/project/.codex/config.toml'
                    : '/sandbox/codex/config.toml',
                format: McpNativeFormat.toml,
                section: McpNativeSection.codexMcpServers,
              ),
              McpHarness.pi => McpNativeLocation(
                harness: harness,
                scope: scope,
                path: scope == McpScope.project
                    ? '/sandbox/project/.pi/mcp.json'
                    : '/sandbox/pi/mcp.json',
                format: McpNativeFormat.json,
                section: McpNativeSection.mcpServers,
              ),
              McpHarness.antigravity => McpNativeLocation(
                harness: harness,
                scope: scope,
                path: scope == McpScope.project
                    ? '/sandbox/project/.agents/mcp_config.json'
                    : '/sandbox/gemini/config/mcp_config.json',
                format: McpNativeFormat.json,
                section: McpNativeSection.mcpServers,
              ),
            };

        void writeText(String path, String text) {
          fs.file(path)
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(text);
        }

        void writeJson(String path, Map<String, Object?> document) =>
            writeText(path, jsonEncode(document));

        String readText(String path) => fs.file(path).readAsStringSync();

        Map<String, Object?>? entryAt(McpNativeLocation where, String name) =>
            McpNativeReader(fs).read(where)[name];

        void writeLedger(List<McpRegistrationRecord> records) => writeJson(
          '$stateRoot/mcp-registrations.json',
          <String, Object?>{
            'schemaVersion': mcpRegistrationLedgerSchemaVersion,
            'records': <Object?>[for (final record in records) record.toJson()],
          },
        );

        void seedManaged(
          McpNativeLocation where,
          String name,
          Map<String, Object?> entry,
        ) => writeLedger(<McpRegistrationRecord>[
          McpRegistrationRecord(
            identity: McpRegistrationIdentity(
              harness: where.harness,
              scope: where.scope,
              location: where.path,
              name: name,
            ),
            baselineDigest: mcpCanonicalDigest(entry),
          ),
        ]);

        Map<String, Object?> sourceEntry(McpHarness harness, String transport) {
          if (harness == McpHarness.antigravity) {
            return transport == 'stdio'
                ? <String, Object?>{
                    'command': 'node',
                    'args': <Object?>['server.js'],
                    'env': <String, Object?>{'TOKEN': ref('TOKEN')},
                  }
                : <String, Object?>{
                    'serverUrl': 'https://source.example.test/mcp',
                    'headers': <String, Object?>{
                      'X-Token': ref('SOURCE_HEADER'),
                    },
                  };
          }
          if (transport == 'stdio') {
            return <String, Object?>{
              'type': 'stdio',
              'command': 'node',
              'args': <Object?>['server.js'],
              'env': <String, Object?>{'TOKEN': ref('TOKEN')},
            };
          }
          return <String, Object?>{
            'type': 'http',
            'url': 'https://source.example.test/mcp',
            (harness == McpHarness.codex ? 'http_headers' : 'headers'):
                <String, Object?>{'X-Token': ref('SOURCE_HEADER')},
          };
        }

        void seedSource(
          McpNativeLocation where,
          Map<String, Object?> entry, {
          String? unrelatedText,
        }) {
          switch (where.format) {
            case McpNativeFormat.json:
              writeJson(where.path, <String, Object?>{
                'mcpServers': <String, Object?>{sourceName: entry},
                'unrelatedTopLevel': 'keep-me',
              });
            case McpNativeFormat.toml:
              writeText(
                where.path,
                '# keep this comment\n'
                'model = "o3"\n'
                '\n'
                '[mcp_servers.$sourceName]\n'
                '${_tomlEntry(entry)}'
                '\n'
                '${unrelatedText ?? ''}',
              );
          }
          seedManaged(where, sourceName, entry);
        }

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
          '--gemini-dir',
          '/sandbox/gemini/',
          '--state-dir',
          '$stateRoot/',
        ];

        List<String> convertArgs(
          McpHarness source,
          McpHarness target, {
          McpScope scope = McpScope.project,
          List<String> extra = const <String>[],
        }) => <String>[
          'mcp',
          'convert',
          '--name',
          sourceName,
          '--harness',
          source.wireName,
          '--scope',
          scope.wireName,
          '--target-harness',
          target.wireName,
          ...extra,
          ...ctx(),
        ];

        Future<MambaExecutionResult> exec(List<String> tokens) =>
            createExecutor(
              fileSystem: fs,
              mcpConversion: McpConversionService(
                fileSystem: fs,
                approve: approval,
              ),
            ).fake().execute(tokens);

        Map<String, dynamic> success(MambaExecutionResult result) {
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
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
        }) {
          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', exitCode)
                .having((value) => value.message, 'message', contains(token))
                // story 43: no success envelope
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.error.commandPath,
                  'command path',
                  <String>['agent_resource', 'mcp', 'convert'],
                ),
          );
        }

        void expectNoSecrets(String output) {
          for (final secret in secretLiterals) {
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
            '/sandbox/gemini',
            stateRoot,
          ]) {
            fs.directory(dir).createSync(recursive: true);
          }
          previews = <String>[];
          approval = (String preview) async {
            previews.add(preview);
            return true;
          };
        });

        test('refuses Codex native references for unsupported targets without writes', () async {
          final source = location(McpHarness.codex, McpScope.project);
          final target = location(McpHarness.antigravity, McpScope.project);
          seedSource(source, {
            'url': 'https://example.com/mcp',
            'env_http_headers': {'Authorization': 'TOKEN'},
          });
          final result = await exec(
            convertArgs(
              McpHarness.codex,
              McpHarness.antigravity,
              extra: const ['--apply', '--format', 'json'],
            ),
          );
          expect(result, isA<MambaFailureResult>());
          expect(fs.file(target.path).existsSync(), isFalse);
        });

        test(
          'converts Codex native HTTP header names to Claude references',
          () async {
            final source = location(McpHarness.codex, McpScope.project);
            final target = location(McpHarness.claude, McpScope.project);
            seedSource(source, {
              'url': 'https://example.com/mcp',
              'env_http_headers': {'Authorization': 'TOKEN'},
            });
            success(
              await exec(
                convertArgs(
                  McpHarness.codex,
                  McpHarness.claude,
                  extra: const ['--apply', '--format', 'json'],
                ),
              ),
            );
            expect(entryAt(target, sourceName), {
              'type': 'http',
              'url': 'https://example.com/mcp',
              'headers': {'Authorization': ref('TOKEN')},
            });
          },
        );

        test(
          'converts Codex native environment names to Claude references',
          () async {
            final source = location(McpHarness.codex, McpScope.project);
            final target = location(McpHarness.claude, McpScope.project);
            seedSource(source, {
              'command': 'node',
              'env_vars': ['TOKEN'],
            });
            success(
              await exec(
                convertArgs(
                  McpHarness.codex,
                  McpHarness.claude,
                  extra: const ['--apply', '--format', 'json'],
                ),
              ),
            );
            expect(entryAt(target, sourceName), {
              'command': 'node',
              'env': {'TOKEN': ref('TOKEN')},
            });
          },
        );

        test(
          'converts HTTP references to Codex native environment headers',
          () async {
            final source = location(McpHarness.claude, McpScope.project);
            final target = location(McpHarness.codex, McpScope.project);
            seedSource(source, {
              'url': 'https://example.com/mcp',
              'headers': {'Authorization': ref('TOKEN')},
            });
            success(
              await exec(
                convertArgs(
                  McpHarness.claude,
                  McpHarness.codex,
                  extra: const ['--apply', '--format', 'json'],
                ),
              ),
            );
            expect(entryAt(target, sourceName), {
              'url': 'https://example.com/mcp',
              'env_http_headers': {'Authorization': 'TOKEN'},
            });
          },
        );

        test(
          'refuses unsupported Antigravity substitutions without writes',
          () async {
            final source = location(McpHarness.claude, McpScope.project);
            final target = location(McpHarness.antigravity, McpScope.project);
            seedSource(source, {
              'url': 'https://example.com/mcp',
              'headers': {'Authorization': ref('TOKEN')},
            });
            final result = await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.antigravity,
                extra: const ['--apply', '--format', 'json'],
              ),
            );
            expect(result, isA<MambaFailureResult>());
            expect(fs.file(target.path).existsSync(), isFalse);
            expect(
              (result as MambaFailureResult).message,
              isNot(contains('TOKEN')),
            );
          },
        );

        test('declares every conversion input', () async {
          final result = await exec(<String>['mcp', 'convert', '--help']);
          expect(result, isA<MambaSuccessResult>());
          final output = (result as MambaSuccessResult).output!;
          for (final flag in const <String>[
            '--name',
            '--harness',
            '--scope',
            '--target-harness',
            '--target-scope',
            '--omit-field',
            '--plan-id',
            '--apply',
            '--yes',
            '--dry-run',
            '--interactive',
            '--format',
            '--cwd',
            '--gemini-dir',
            '--state-dir',
          ]) {
            expect(output, contains(flag), reason: flag);
          }
          expect(output, contains('antigravity'));
        });

        test(
          'rejects occurrence/path selectors and missing selectors',
          () async {
            for (final tokens in <List<String>>[
              convertArgs(
                McpHarness.claude,
                McpHarness.codex,
                extra: const <String>['--occurrence', '1'],
              ),
              convertArgs(
                McpHarness.claude,
                McpHarness.codex,
                extra: const <String>['--path', '/sandbox/project/.mcp.json'],
              ),
              <String>[
                'mcp',
                'convert',
                '--name',
                sourceName,
                '--harness',
                'claude',
                ...ctx(),
              ],
            ]) {
              final result = await exec(tokens);
              expect(
                result,
                isA<MambaFailureResult>()
                    .having((value) => value.message, 'message', isNotEmpty)
                    .having(
                      (value) => value.error.phase,
                      'phase',
                      MambaExecutionPhase.parse,
                    )
                    .having((value) => value.output, 'output', isNull)
                    .having(
                      (value) => value.error.commandPath,
                      'command path',
                      <String>['agent_resource', 'mcp', 'convert'],
                    ),
                reason: '$tokens',
              );
            }
          },
        );

        final List<({McpHarness source, McpHarness target})> directions =
            <({McpHarness source, McpHarness target})>[
              for (final source in McpHarness.values)
                for (final target in McpHarness.values)
                  if (source != target) (source: source, target: target),
            ];

        for (final direction in directions) {
          for (final transport in const <String>['stdio', 'http']) {
            test('${direction.source.wireName} → '
                '${direction.target.wireName} ($transport) produces a '
                'valid native target entry', () async {
              final source = location(direction.source, McpScope.project);
              final target = location(direction.target, McpScope.project);
              final entry = sourceEntry(direction.source, transport);
              if (direction.target == McpHarness.antigravity) {
                entry.remove('type');
                entry.remove(transport == 'stdio' ? 'env' : 'headers');
                entry.remove('http_headers');
              }
              if (direction.target == McpHarness.codex &&
                  transport == 'stdio') {
                entry['env'] = <String, Object?>{'TOKEN': ref('TOKEN')};
              }
              seedSource(source, entry);
              final sourceBefore = readText(source.path);

              final envelope = success(
                await exec(
                  convertArgs(
                    direction.source,
                    direction.target,
                    extra: const <String>['--apply', '--format', 'json'],
                  ),
                ),
              );
              final data = envelope['data'] as Map<String, dynamic>;
              expect(envelope['schemaVersion'], 1);
              expect(envelope['command'], 'mcp.convert');
              expect(envelope['outcome'], 'converted');
              expect(data['sourceHarness'], direction.source.wireName);
              expect(data['targetHarness'], direction.target.wireName);
              expect(data['sourceScope'], 'project');
              expect(data['targetScope'], 'project');
              expect(data['transport'], transport);
              expect(data['sourcePreserved'], isTrue);
              expect(data['nativeWritten'], isTrue);
              expect(previews, hasLength(1));

              final written = entryAt(target, sourceName);
              expect(written, isNotNull);
              final report = McpValidationService(fileSystem: fs).validate(
                harness: direction.target,
                fields: written!,
                scope: McpScope.project,
              );
              expect(report.valid, isTrue, reason: report.renderText());
              final endpointKeys = <String>{'url', 'serverUrl'};
              expect(
                written.containsKey('command'),
                transport == 'stdio' ? isTrue : isFalse,
              );
              expect(
                endpointKeys.any(written.containsKey),
                transport == 'http' ? isTrue : isFalse,
              );
              expect(
                written['command'] ?? written['url'] ?? written['serverUrl'],
                isNotNull,
              );

              // Story 27: transport and scope are preserved, not inferred.
              expect(data['transport'], transport);
              expect(data['scopeChanged'], isFalse);

              // Story 32: the source entry stays managed and byte-identical.
              expect(readText(source.path), sourceBefore);
              final records = McpOwnershipLedger(
                fs: fs,
                stateRoot: stateRoot,
              ).read();
              expect(
                records.containsKey(
                  McpRegistrationIdentity(
                    harness: direction.source,
                    scope: McpScope.project,
                    location: source.path,
                    name: sourceName,
                  ).storageKey,
                ),
                isTrue,
              );
              expect(
                records.values.any(
                  (record) =>
                      record.identity.harness == direction.target &&
                      record.identity.name == sourceName,
                ),
                isTrue,
              );
              expect(
                (data['lineage'] as Map<String, dynamic>)['lineageId'],
                isA<String>(),
              );
            });
          }
        }

        test('a Codex tool control refuses by default with a value-free '
            'diagnostic naming the field', () async {
          final source = location(McpHarness.codex, McpScope.project);
          seedSource(source, <String, Object?>{
            'type': 'stdio',
            'command': 'node',
            'tools': <String, Object?>{
              'search': <String, Object?>{'approval_mode': 'prompt'},
            },
          });
          final before = readText(source.path);

          failure(
            await exec(
              convertArgs(
                McpHarness.codex,
                McpHarness.pi,
                extra: const <String>['--apply'],
              ),
            ),
            exitCode: 2,
            token: 'tools.search.approval_mode',
          );
          final message = (await exec(
            convertArgs(
              McpHarness.codex,
              McpHarness.pi,
              extra: const <String>['--apply'],
            ),
          ) as MambaFailureResult).message;
          expect(message, contains('MCP_CONVERSION_UNREPRESENTABLE'));
          expect(message, isNot(contains('prompt')));
          expect(message, isNot(contains('schemaVersion')));
          expect(previews, isEmpty);
          expect(readText(source.path), before);
          expect(
            fs
                .file(location(McpHarness.pi, McpScope.project).path)
                .existsSync(),
            isFalse,
          );
        });

        test(
          'an explicit reviewed omission yields omitted-after-review',
          () async {
            final source = location(McpHarness.codex, McpScope.project);
            final target = location(McpHarness.pi, McpScope.project);
            seedSource(source, <String, Object?>{
              'type': 'stdio',
              'command': 'node',
              'tools': <String, Object?>{
                'search': <String, Object?>{'approval_mode': 'prompt'},
              },
            });

            final envelope = success(
              await exec(
                convertArgs(
                  McpHarness.codex,
                  McpHarness.pi,
                  extra: const <String>[
                    '--apply',
                    '--omit-field',
                    'tools.search.approval_mode',
                    '--format',
                    'json',
                  ],
                ),
              ),
            );
            final fields = ((envelope['data'] as Map)['fields'] as List)
                .cast<Map<String, dynamic>>();
            final omitted = fields.firstWhere(
              (field) => field['sourcePath'] == 'tools.search.approval_mode',
            );
            expect(omitted['outcome'], 'omitted-after-review');
            expect(omitted['decision'], 'omit:tools.search.approval_mode');
            final written = entryAt(target, sourceName);
            expect(written, isNotNull);
            expect(written!.containsKey('tools'), isFalse);
          },
        );

        test('OAuth, provider credentials and literal secrets are never '
            'copied or printed', () async {
          final source = location(McpHarness.claude, McpScope.project);
          final target = location(McpHarness.codex, McpScope.project);
          seedSource(source, <String, Object?>{
            'type': 'http',
            'url': 'https://source.example.test/mcp?token=$secretQuery',
            'headers': <String, Object?>{
              'Authorization': 'Bearer $secretHeader',
              'X-Ref': ref('HEADER_REF'),
            },
            'oauth': <String, Object?>{
              'clientId': 'CLIENT-ID-SECRET',
              'clientSecret': secretOAuth,
            },
            'auth': <String, Object?>{
              'provider': 'PROVIDER-CREDENTIAL-SELECTION',
            },
          });

          final result = await exec(
            convertArgs(
              McpHarness.claude,
              McpHarness.codex,
              extra: const <String>['--apply', '--format', 'json'],
            ),
          );
          final envelope = success(result);
          final output = (result as MambaSuccessResult).output!;
          expectNoSecrets(output);
          expectNoSecrets(previews.single);
          final written = entryAt(target, sourceName);
          expect(written, isNotNull);
          final targetText = readText(target.path);
          for (final secret in secretLiterals) {
            expect(targetText, isNot(contains(secret)), reason: secret);
          }
          for (final forbidden in const <String>[
            'oauth',
            'clientSecret',
            'client_secret',
            'provider',
            'mcp-auth.json',
          ]) {
            expect(targetText, isNot(contains(forbidden)), reason: forbidden);
          }
          expect(written!.containsKey('env_http_headers'), isTrue);
          expect(
            (written['env_http_headers'] as Map).containsKey('Authorization'),
            isFalse,
          );
          expect((written['env_http_headers'] as Map)['X-Ref'], 'HEADER_REF');
          final data = envelope['data'] as Map<String, dynamic>;
          final refusals = (data['credentialRefusals'] as List)
              .cast<Map<String, dynamic>>();
          expect(
            refusals.map((item) => item['sourcePath']),
            containsAll(<String>['oauth', 'auth', 'headers.Authorization']),
          );
          final fields = (data['fields'] as List).cast<Map<String, dynamic>>();
          expect(
            fields
                .where((field) => field['outcome'] == 'omitted-after-review')
                .map((field) => field['decision']),
            contains('policy:credentials-not-copied'),
          );
        });

        test('text and JSON accounts are deterministic and complete', () async {
          final source = location(McpHarness.claude, McpScope.project);
          seedSource(source, <String, Object?>{
            'type': 'stdio',
            'command': 'node',
            'args': <Object?>['server.js'],
            'env': <String, Object?>{'REF': ref('TOKEN')},
          });

          final first = success(
            await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.pi,
                extra: const <String>['--format', 'json'],
              ),
            ),
          );
          final second = success(
            await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.pi,
                extra: const <String>['--format', 'json'],
              ),
            ),
          );
          expect(first['data'], equals(second['data']));

          final fields = ((first['data'] as Map)['fields'] as List)
              .cast<Map<String, dynamic>>();
          expect(fields, isNotEmpty);
          for (final field in fields) {
            for (final key in const <String>[
              'sourcePath',
              'targetPath',
              'sourceProfile',
              'outcome',
              'decision',
            ]) {
              expect(field.containsKey(key), isTrue, reason: '$key: $field');
            }
            expect(const <String>[
              'represented',
              'altered',
              'omitted-after-review',
              'refused',
            ], contains(field['outcome']));
          }
          expect(
            fields.map((field) => field['sourcePath']),
            containsAll(<String>['command', 'args', 'env.REF']),
          );
          final text = (await exec(
            convertArgs(McpHarness.claude, McpHarness.pi),
          ) as MambaSuccessResult).output!;
          final secondText = (await exec(
            convertArgs(McpHarness.claude, McpHarness.pi),
          ) as MambaSuccessResult).output!;
          expect(text, secondText);
          for (final token in const <String>[
            'sourcePath',
            'targetPath',
            'outcome',
            'decision',
            'represented',
          ]) {
            expect(text, contains(token), reason: token);
          }
        });

        test('stale --plan-id is refused and writes nothing', () async {
          final source = location(McpHarness.claude, McpScope.project);
          final target = location(McpHarness.codex, McpScope.project);
          final entry = sourceEntry(McpHarness.claude, 'stdio');
          seedSource(source, entry);
          final plan = success(
            await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.codex,
                extra: const <String>['--dry-run', '--format', 'json'],
              ),
            ),
          );
          final planId =
              (plan['data'] as Map<String, dynamic>)['planId'] as String;
          expect(previews, isEmpty);

          // An unrelated shared-file edit invalidates the reviewed identity.
          writeJson(source.path, <String, Object?>{
            'mcpServers': <String, Object?>{sourceName: entry},
            'unrelatedTopLevel': 'changed',
          });

          failure(
            await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.codex,
                extra: <String>[
                  '--apply',
                  '--yes',
                  '--plan-id',
                  planId,
                  '--format',
                  'json',
                ],
              ),
            ),
            exitCode: 4,
            token: 'Stale or mismatched --plan-id',
          );
          expect(fs.file(target.path).existsSync(), isFalse);
          expect(
            fs.file('$stateRoot/$mcpConversionLineageFileName').existsSync(),
            isFalse,
          );
        });

        test('a target validation failure blocks the write', () async {
          final source = location(McpHarness.claude, McpScope.project);
          final target = location(McpHarness.pi, McpScope.project);
          seedSource(source, <String, Object?>{
            'type': 'stdio',
            'command': 'node',
            'args': <Object?>[42],
          });

          failure(
            await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.pi,
                extra: const <String>['--apply', '--format', 'json'],
              ),
            ),
            exitCode: 2,
            token: 'FIELD_TYPE',
          );
          expect(fs.file(target.path).existsSync(), isFalse);
          expect(
            McpOwnershipLedger(fs: fs, stateRoot: stateRoot)
                .read()
                .values
                .where((record) => record.identity.harness == McpHarness.pi),
            isEmpty,
          );
        });

        test('a reviewed scope change is explicit and recorded', () async {
          final source = location(McpHarness.claude, McpScope.project);
          final target = location(McpHarness.codex, McpScope.user);
          seedSource(source, sourceEntry(McpHarness.claude, 'stdio'));

          final plan = success(
            await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.codex,
                extra: const <String>[
                  '--target-scope',
                  'user',
                  '--dry-run',
                  '--format',
                  'json',
                ],
              ),
            ),
          );
          final data = plan['data'] as Map<String, dynamic>;
          expect(data['targetScope'], 'user');
          expect(data['scopeChanged'], isTrue);
          expect(
            ((plan['diagnostics'] as List).cast<Map<String, dynamic>>()).map(
              (item) => item['code'],
            ),
            contains('MCP_CONVERSION_SCOPE_CHANGE'),
          );
          final preserved = success(
            await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.codex,
                extra: const <String>['--dry-run', '--format', 'json'],
              ),
            ),
          );
          expect((preserved['data'] as Map)['planId'], isNot(data['planId']));

          final applied = success(
            await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.codex,
                extra: const <String>[
                  '--target-scope',
                  'user',
                  '--apply',
                  '--format',
                  'json',
                ],
              ),
            ),
          );
          expect((applied['data'] as Map)['targetScope'], 'user');
          expect(entryAt(target, sourceName), isNotNull);
        });

        test(
          'lineage is recorded in local state and the target ledger',
          () async {
            final source = location(McpHarness.pi, McpScope.project);
            final target = location(McpHarness.claude, McpScope.project);
            seedSource(source, sourceEntry(McpHarness.pi, 'stdio'));
            expect(entryAt(target, sourceName), isNull);

            final envelope = success(
              await exec(
                convertArgs(
                  McpHarness.pi,
                  McpHarness.claude,
                  extra: const <String>['--apply', '--format', 'json'],
                ),
              ),
            );
            final data = envelope['data'] as Map<String, dynamic>;
            final lineage = data['lineage'] as Map<String, dynamic>;
            final lineageId = lineage['lineageId'] as String;
            expect(lineageId, startsWith('mcp-lineage-'));
            expect(lineage['convertedFromId'], isA<String>());
            expect(lineage['sourceIdentity'], isA<Map<String, dynamic>>());
            expect(lineage['targetIdentity'], isA<Map<String, dynamic>>());

            final records = McpConversionLineageStore(
              fs: fs,
              stateRoot: stateRoot,
            ).read();
            expect(records, hasLength(1));
            expect(records.single.identity.lineageId, lineageId);
            expect(
              McpOwnershipLedger(
                fs: fs,
                stateRoot: stateRoot,
              ).read().values.any(
                (record) => record.identity.harness == McpHarness.claude,
              ),
              isTrue,
            );
          },
        );

        test(
          'target shared bytes unrelated to the entry are preserved',
          () async {
            final source = location(McpHarness.claude, McpScope.project);
            final target = location(McpHarness.codex, McpScope.project);
            seedSource(source, sourceEntry(McpHarness.claude, 'stdio'));
            const targetBefore =
                '# keep this comment\n'
                'model = "o3"\n'
                '\n'
                '[other.table]\n'
                'keep = "yes"\n';
            writeText(target.path, targetBefore);

            success(
              await exec(
                convertArgs(
                  McpHarness.claude,
                  McpHarness.codex,
                  extra: const <String>['--apply', '--format', 'json'],
                ),
              ),
            );
            final after = readText(target.path);
            expect(after, contains('# keep this comment'));
            expect(after, contains('model = "o3"'));
            expect(after, contains('[other.table]'));
            expect(after, contains('keep = "yes"'));
            expect(after, contains('[mcp_servers.$sourceName]'));
          },
        );

        test('declining review cancels with everything unchanged', () async {
          final source = location(McpHarness.claude, McpScope.project);
          seedSource(source, sourceEntry(McpHarness.claude, 'stdio'));
          final before = readText(source.path);
          approval = (String preview) async {
            previews.add(preview);
            return false;
          };

          failure(
            await exec(
              convertArgs(
                McpHarness.claude,
                McpHarness.pi,
                extra: const <String>['--apply'],
              ),
            ),
            exitCode: 7,
            token: 'cancelled',
          );
          expect(readText(source.path), before);
          expect(previews, hasLength(1));
          expect(
            fs
                .file(location(McpHarness.pi, McpScope.project).path)
                .existsSync(),
            isFalse,
          );
        });

        test(
          'Antigravity dry-run binds provenance to a reviewed apply',
          () async {
            final source = location(McpHarness.antigravity, McpScope.project);
            final target = location(McpHarness.codex, McpScope.project);
            seedSource(source, sourceEntry(McpHarness.antigravity, 'stdio'));
            final sourceBefore = readText(source.path);

            final plan = success(
              await exec(
                convertArgs(
                  McpHarness.antigravity,
                  McpHarness.codex,
                  extra: const <String>['--dry-run', '--format', 'json'],
                ),
              ),
            );
            final planData = plan['data'] as Map<String, dynamic>;
            final planId = planData['planId'] as String;
            final provenance = planData['provenance'] as Map<String, dynamic>;
            expect(provenance['sourceHarness'], 'antigravity');
            expect(jsonEncode(provenance), contains('command'));
            expect(previews, isEmpty);
            expect(fs.file(target.path).existsSync(), isFalse);
            expect(readText(source.path), sourceBefore);

            final applied = success(
              await exec(
                convertArgs(
                  McpHarness.antigravity,
                  McpHarness.codex,
                  extra: <String>[
                    '--apply',
                    '--yes',
                    '--plan-id',
                    planId,
                    '--format',
                    'json',
                  ],
                ),
              ),
            );
            expect(applied['outcome'], 'converted');
            expect(entryAt(target, sourceName), isNotNull);
            expect(readText(source.path), sourceBefore);
            final lineage = McpConversionLineageStore(
              fs: fs,
              stateRoot: stateRoot,
            ).read();
            expect(lineage, hasLength(1));
            expect(
              McpOwnershipLedger(fs: fs, stateRoot: stateRoot)
                  .read()
                  .values
                  .any((record) => record.identity.harness == McpHarness.codex),
              isTrue,
            );
          },
        );

        test(
          'an Antigravity target requires reviewed field-loss approval',
          () async {
            final source = location(McpHarness.codex, McpScope.project);
            final target = location(McpHarness.antigravity, McpScope.project);
            seedSource(source, <String, Object?>{
              'type': 'stdio',
              'command': 'node',
              'tools': <String, Object?>{
                'search': <String, Object?>{'approval_mode': 'prompt'},
              },
            });
            final plan = success(
              await exec(
                convertArgs(
                  McpHarness.codex,
                  McpHarness.antigravity,
                  extra: const <String>[
                    '--dry-run',
                    '--omit-field',
                    'type',
                    '--omit-field',
                    'tools.search.approval_mode',
                    '--format',
                    'json',
                  ],
                ),
              ),
            );
            final fields = ((plan['data'] as Map)['fields'] as List)
                .cast<Map<String, dynamic>>();
            for (final path in const <String>[
              'type',
              'tools.search.approval_mode',
            ]) {
              final row = fields.firstWhere(
                (field) => field['sourcePath'] == path,
              );
              expect(row['outcome'], 'omitted-after-review');
              expect(row['decision'], 'omit:$path');
            }
            expect(fs.file(target.path).existsSync(), isFalse);
          },
        );

        test('Antigravity credential literals and endpoint secrets are never copied', () async {
          final source = location(McpHarness.antigravity, McpScope.project);
          final target = location(McpHarness.pi, McpScope.project);
          seedSource(source, <String, Object?>{
            'serverUrl': 'https://source.example.test/mcp?token=$secretQuery',
            'headers': <String, Object?>{
              'Authorization': 'Bearer $secretHeader',
              'X-Ref': ref('HEADER_REF'),
            },
            'oauth': <String, Object?>{
              'clientId': 'CLIENT-ID-SECRET',
              'clientSecret': secretOAuth,
            },
          });

          final result = await exec(
            convertArgs(
              McpHarness.antigravity,
              McpHarness.pi,
              extra: const <String>['--apply', '--format', 'json'],
            ),
          );
          final envelope = success(result);
          final output = (result as MambaSuccessResult).output!;
          expectNoSecrets(output);
          expectNoSecrets(previews.single);
          final written = entryAt(target, sourceName);
          expect(written, isNotNull);
          expect(written!['url'], 'https://source.example.test/mcp');
          expect((written['headers'] as Map)['X-Ref'], ref('HEADER_REF'));
          expect(
            (written['headers'] as Map).containsKey('Authorization'),
            isFalse,
          );
          expect(written.containsKey('serverUrl'), isFalse);
          final targetText = readText(target.path);
          expectNoSecrets(targetText);
          for (final forbidden in const <String>[
            'oauth',
            'clientSecret',
            'clientId',
          ]) {
            expect(targetText, isNot(contains(forbidden)), reason: forbidden);
          }
          final data = envelope['data'] as Map<String, dynamic>;
          final refusals = (data['credentialRefusals'] as List)
              .cast<Map<String, dynamic>>();
          expect(
            refusals.map((item) => item['sourcePath']),
            containsAll(<String>[
              'serverUrl',
              'headers.Authorization',
              'oauth',
            ]),
          );
          final fields = (data['fields'] as List).cast<Map<String, dynamic>>();
          expect(
            fields
                .where((field) => field['outcome'] == 'omitted-after-review')
                .map((field) => field['decision']),
            contains('policy:credentials-not-copied'),
          );
        });
      });
    });
  });
}

/// Renders a small representable entry into TOML source text.
String _tomlEntry(Map<String, Object?> entry) {
  final buffer = StringBuffer();
  for (final field in entry.entries) {
    buffer.writeln('${field.key} = ${_tomlValue(field.value)}');
  }
  return buffer.toString();
}

String _tomlValue(Object? value) => switch (value) {
  String() => '"$value"',
  num() || bool() => '$value',
  Map() =>
    '{ ${value.entries.map((item) => '${item.key} = ${_tomlValue(item.value)}').join(', ')} }',
  List() => '[${value.map(_tomlValue).join(', ')}]',
  _ => '"$value"',
};
