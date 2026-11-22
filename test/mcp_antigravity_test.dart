import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/mcp/mcp_native.dart';
import 'package:agent_resource/src/mcp/mcp_ownership_ledger.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/services/mcp_conversion_service.dart';
import 'package:agent_resource/src/services/mcp_inspection_service.dart';
import 'package:agent_resource/src/services/mcp_mutation_service.dart';
import 'package:agent_resource/src/services/mcp_recovery_service.dart';
import 'package:agent_resource/src/services/mcp_validation_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

/// Builds a whole-value `${NAME}` reference without Dart interpolation.
String ref(String name) => [String.fromCharCode(36), '{', name, '}'].join();

String kvRef(String key, String name) => '$key=${ref(name)}';

const List<String> secrets = <String>[
  'ANTIGRAVITY_LITERAL_SECRET',
  'ANTIGRAVITY_QUERY_SECRET',
];

void main() {
  group('agent_resource', () {
    group('mcp', () {
      late fslib.FileSystem fs;
      late List<String> previews;
      late Future<bool> Function(String) approval;

      const projectPath = '/sandbox/project/.agents/mcp_config.json';
      const userPath = '/sandbox/gemini/config/mcp_config.json';
      const defaultUserPath = '/sandbox/home/.gemini/config/mcp_config.json';
      const ledgerPath = '/sandbox/state/mcp-registrations.json';

      void writeJson(String path, Map<String, Object?> document) =>
          fs.file(path)
            ..createSync(recursive: true)
            ..writeAsStringSync(jsonEncode(document));

      String readText(String path) => fs.file(path).readAsStringSync();

      McpNativeLocation location(McpScope scope, [String? path]) =>
          McpNativeLocation(
            harness: McpHarness.antigravity,
            scope: scope,
            path: path ?? (scope == McpScope.project ? projectPath : userPath),
            format: McpNativeFormat.json,
            section: McpNativeSection.mcpServers,
          );

      Map<String, Object?>? entryAt(
        McpScope scope,
        String name, [
        String? path,
      ]) => McpNativeReader(fs).read(location(scope, path))[name];

      void seedManaged(
        McpScope scope,
        String name,
        Map<String, Object?> entry,
      ) => writeJson(ledgerPath, <String, Object?>{
        'schemaVersion': mcpRegistrationLedgerSchemaVersion,
        'records': <Object?>[
          McpRegistrationRecord(
            identity: McpRegistrationIdentity(
              harness: McpHarness.antigravity,
              scope: scope,
              location: location(scope).path,
              name: name,
            ),
            baselineDigest: mcpCanonicalDigest(entry),
          ).toJson(),
        ],
      });

      List<Map<String, Object?>> ledgerRecords() {
        if (!fs.file(ledgerPath).existsSync()) {
          return <Map<String, Object?>>[];
        }
        final document =
            jsonDecode(readText(ledgerPath)) as Map<String, dynamic>;
        return (document['records'] as List<Object?>)
            .cast<Map<String, Object?>>();
      }

      List<String> context({bool geminiDir = true}) => <String>[
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
        if (geminiDir) '--gemini-dir',
        if (geminiDir) '/sandbox/gemini/',
        '--state-dir',
        '/sandbox/state/',
      ];

      Future<MambaExecutionResult> exec(List<String> tokens) {
        final validation = McpValidationService(fileSystem: fs);
        final mutation = McpMutationService(
          fileSystem: fs,
          validation: validation,
          approve: approval,
        );
        return createExecutor(
          fileSystem: fs,
          mcpInspection: McpInspectionService(fileSystem: fs),
          mcpValidation: validation,
          mcpMutation: mutation,
          mcpRecovery: McpRecoveryService(
            fileSystem: fs,
            mutation: mutation,
            approve: approval,
          ),
          mcpConversion: McpConversionService(
            fileSystem: fs,
            approve: approval,
          ),
        ).fake().execute(tokens);
      }

      Map<String, dynamic> success(MambaExecutionResult result) {
        expect(
          result,
          isA<MambaSuccessResult>().having(
            (value) => value.exitCode,
            'exit code',
            0,
          ),
          reason: result is MambaFailureResult ? result.message : '',
        );
        return jsonDecode((result as MambaSuccessResult).output!)
            as Map<String, dynamic>;
      }

      void failure(
        MambaExecutionResult result, {
        required int exitCode,
        required String token,
        required List<String> commandPath,
      }) {
        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', exitCode)
              .having((value) => value.message, 'message', contains(token))
              .having((value) => value.output, 'output', isNull)
              .having(
                (value) => value.error.commandPath,
                'command path',
                commandPath,
              ),
        );
      }

      void expectNoSecrets(String output) {
        for (final secret in secrets) {
          expect(output, isNot(contains(secret)), reason: secret);
        }
      }

      setUp(() {
        fs = MemoryFileSystem(style: FileSystemStyle.posix);
        for (final directory in const <String>[
          '/sandbox/project',
          '/sandbox/home',
          '/sandbox/claude',
          '/sandbox/codex',
          '/sandbox/pi',
          '/sandbox/gemini',
          '/sandbox/state',
        ]) {
          fs.directory(directory).createSync(recursive: true);
        }
        writeJson(projectPath, <String, Object?>{
          'mcpServers': <String, Object?>{},
          'unrelatedTopLevel': 'keep-me',
        });
        writeJson(userPath, <String, Object?>{
          'mcpServers': <String, Object?>{},
        });
        previews = <String>[];
        approval = (String preview) async {
          previews.add(preview);
          return true;
        };
      });

      test('discovers an Antigravity project registration', () async {
        writeJson(projectPath, <String, Object?>{
          'mcpServers': <String, Object?>{
            'search': <String, Object?>{'command': 'search-mcp'},
          },
        });
        final result = await exec(<String>[
          'mcp',
          'list',
          '--harness',
          'antigravity',
          '--scope',
          'project',
          '--format',
          'json',
          ...context(),
        ]);
        final envelope = success(result);
        final registrations =
            (envelope['data'] as Map<String, dynamic>)['registrations']
                as List<Object?>;
        final found = registrations.cast<Map<String, dynamic>>().firstWhere(
          (registration) => registration['name'] == 'search',
        );
        expect(found['harness'], 'antigravity');
        expect(found['scope'], 'project');
        expect(found['location'], projectPath);
      });

      test(
        'discovers the user configuration root and refuses local scope',
        () async {
          writeJson(defaultUserPath, <String, Object?>{
            'mcpServers': <String, Object?>{
              'docs': <String, Object?>{'command': 'docs-mcp'},
            },
          });
          final listed = success(
            await exec(<String>[
              'mcp',
              'list',
              '--harness',
              'antigravity',
              '--scope',
              'user',
              '--format',
              'json',
              ...context(geminiDir: false),
            ]),
          );
          final registrations =
              (listed['data'] as Map<String, dynamic>)['registrations']
                  as List<Object?>;
          final found = registrations.cast<Map<String, dynamic>>().firstWhere(
            (registration) => registration['name'] == 'docs',
          );
          expect(found['location'], defaultUserPath);

          failure(
            await exec(<String>[
              'mcp',
              'list',
              '--harness',
              'antigravity',
              '--scope',
              'local',
              '--format',
              'json',
              ...context(),
            ]),
            exitCode: 2,
            token: 'MCP scope',
            commandPath: const <String>['agent_resource', 'mcp', 'list'],
          );
        },
      );

      test('inspects redacted native fields and validates the Antigravity contract', () async {
        final entry = <String, Object?>{
          'serverUrl':
              'https://docs.example.test/mcp?token=ANTIGRAVITY_QUERY_SECRET',
          'headers': <String, Object?>{
            'Authorization': 'Bearer ANTIGRAVITY_LITERAL_SECRET',
            'X-Ref': ref('DOCS_TOKEN'),
          },
        };
        writeJson(projectPath, <String, Object?>{
          'mcpServers': <String, Object?>{'remote': entry},
        });

        final inspected = await exec(<String>[
          'mcp',
          'inspect',
          '--name',
          'remote',
          '--harness',
          'antigravity',
          '--scope',
          'project',
          '--format',
          'json',
          ...context(),
        ]);
        final inspectEnvelope = success(inspected);
        expectNoSecrets((inspected as MambaSuccessResult).output!);
        final registration =
            (inspectEnvelope['data'] as Map<String, dynamic>)['registration']
                as Map<String, dynamic>;
        expect(registration['transport'], 'http');
        final fields = registration['fields'] as Map<String, dynamic>;
        expect(fields['serverUrl'], 'https://docs.example.test/mcp');
        expect((fields['headers'] as Map)['Authorization'], '<redacted>');
        expect((fields['headers'] as Map)['X-Ref'], ref('DOCS_TOKEN'));

        final validated = success(
          await exec(<String>[
            'mcp',
            'validate',
            '--name',
            'remote',
            '--harness',
            'antigravity',
            '--scope',
            'project',
            '--format',
            'json',
            ...context(),
          ]),
        );
        final report =
            (validated['data'] as Map<String, dynamic>)['report']
                as Map<String, dynamic>;
        expect(report['valid'], isTrue);
        expect(report['profile'], 'mcp-antigravity-native-static-v1');
        expect(
          jsonEncode(report['baseline']),
          contains('antigravity-mcp/2.12.0'),
        );
      });

      test(
        'reports value-free validation diagnostics for invalid native fields',
        () async {
          writeJson(projectPath, <String, Object?>{
            'mcpServers': <String, Object?>{
              'bad': <String, Object?>{
                'serverUrl': 'https://docs.example.test/mcp',
                'url': 'https://other.example.test/mcp',
                'unexpected': 'ANTIGRAVITY_LITERAL_SECRET',
              },
            },
          });
          final result = await exec(<String>[
            'mcp',
            'validate',
            '--name',
            'bad',
            '--harness',
            'antigravity',
            '--scope',
            'project',
            '--format',
            'json',
            ...context(),
          ]);
          failure(
            result,
            exitCode: 2,
            token: 'MCP_TRANSPORT_CONFLICT',
            commandPath: const <String>['agent_resource', 'mcp', 'validate'],
          );
          final message = (result as MambaFailureResult).message;
          expect(message, contains('UNKNOWN_FIELD'));
          expectNoSecrets(message);
        },
      );

      for (final scope in McpScope.values) {
        if (scope == McpScope.local) continue;
        test('registers a reviewed $scope entry with ownership', () async {
          final result = await exec(<String>[
            'mcp',
            'register',
            '--name',
            'build',
            '--harness',
            'antigravity',
            '--scope',
            scope.wireName,
            '--command',
            'npx',
            '--args',
            'serve',
            '--format',
            'json',
            ...context(),
          ]);
          final envelope = success(result);
          expectNoSecrets((result as MambaSuccessResult).output!);
          expect(envelope['outcome'], 'registered');
          final data = envelope['data'] as Map<String, dynamic>;
          final expectedPath = scope == McpScope.project
              ? projectPath
              : userPath;
          expect(data['location'], expectedPath);
          final entry = entryAt(scope, 'build');
          expect(entry, isNotNull);
          expect(entry!['command'], 'npx');
          expect(entry['args'], <Object?>['serve']);
          final records = ledgerRecords();
          expect(records, hasLength(1));
          expect(records.single['harness'], 'antigravity');
          expect(records.single['scope'], scope.wireName);
          expect(records.single['location'], expectedPath);
          expect(records.single['baselineDigest'], mcpCanonicalDigest(entry));
          expect(previews.single, contains('antigravity'));
          expectNoSecrets(previews.single);
        });
      }

      test('refuses undocumented Antigravity credential substitutions before writing', () async {
        final before = readText(projectPath);
        for (final args in [
          ['--command', 'node', '--env', kvRef('TOKEN', 'TOKEN')],
          [
            '--url',
            'https://example.com/mcp',
            '--header',
            kvRef('Authorization', 'TOKEN'),
          ],
        ]) {
          final result = await exec([
            'mcp',
            'register',
            '--name',
            'svc',
            '--harness',
            'antigravity',
            '--scope',
            'project',
            ...args,
            ...context(),
          ]);
          failure(
            result,
            exitCode: 2,
            token: 'Unsupported credential reference',
            commandPath: ['agent_resource', 'mcp', 'register'],
          );
          expect(readText(projectPath), before);
          expect(ledgerRecords(), isEmpty);
        }
      });

      test('writes the native HTTP endpoint key', () async {
        final result = await exec(<String>[
          'mcp',
          'register',
          '--name',
          'remote',
          '--harness',
          'antigravity',
          '--scope',
          'project',
          '--url',
          'https://docs.example.test/mcp',
          '--format',
          'json',
          ...context(),
        ]);
        success(result);
        final entry = entryAt(McpScope.project, 'remote');
        expect(entry, isNotNull);
        expect(entry!['serverUrl'], 'https://docs.example.test/mcp');
        expect(entry.containsKey('url'), isFalse);
        expect(entry.containsKey('headers'), isFalse);
      });

      test('replaces, adopts and unregisters managed entries without rewriting unrelated bytes', () async {
        final original = <String, Object?>{
          'command': 'search-old',
          'env': <String, Object?>{'TOKEN': 'ANTIGRAVITY_LITERAL_SECRET'},
        };
        writeJson(projectPath, <String, Object?>{
          'mcpServers': <String, Object?>{
            'search': original,
            'unmanaged': <String, Object?>{'command': 'keep-svc'},
          },
          'unrelatedTopLevel': 'keep-me',
        });
        seedManaged(McpScope.project, 'search', original);
        final before = readText(projectPath);

        final replaced = success(
          await exec(<String>[
            'mcp',
            'replace',
            '--name',
            'search',
            '--harness',
            'antigravity',
            '--scope',
            'project',
            '--command',
            'search-v2',
            '--format',
            'json',
            ...context(),
          ]),
        );
        expect(replaced['outcome'], 'replaced');
        expect(entryAt(McpScope.project, 'search')!['command'], 'search-v2');
        expect(readText(projectPath), contains('unrelatedTopLevel'));
        expect(readText(projectPath), contains('"unmanaged"'));
        expectNoSecrets(jsonEncode(replaced));

        final adopted = success(
          await exec(<String>[
            'mcp',
            'adopt',
            '--name',
            'unmanaged',
            '--harness',
            'antigravity',
            '--scope',
            'project',
            '--format',
            'json',
            ...context(),
          ]),
        );
        expect(adopted['outcome'], 'adopted');
        expect(
          ledgerRecords().any((record) => record['name'] == 'unmanaged'),
          isTrue,
        );

        final unregistered = success(
          await exec(<String>[
            'mcp',
            'unregister',
            '--name',
            'unmanaged',
            '--harness',
            'antigravity',
            '--scope',
            'project',
            '--format',
            'json',
            ...context(),
          ]),
        );
        expect(unregistered['outcome'], 'unregistered');
        expect(entryAt(McpScope.project, 'unmanaged'), isNull);
        expect(
          ledgerRecords().any((record) => record['name'] == 'unmanaged'),
          isFalse,
        );
        expect(readText(projectPath), isNot(before));
        expect(readText(projectPath), contains('unrelatedTopLevel'));
      });

      test(
        'restores an Antigravity entry from protected backup evidence',
        () async {
          final original = <String, Object?>{
            'command': 'backup-old',
            'env': <String, Object?>{'TOKEN': 'ANTIGRAVITY_LITERAL_SECRET'},
          };
          writeJson(projectPath, <String, Object?>{
            'mcpServers': <String, Object?>{'backup-svc': original},
            'unrelatedTopLevel': 'keep-me',
          });
          seedManaged(McpScope.project, 'backup-svc', original);

          success(
            await exec(<String>[
              'mcp',
              'replace',
              '--name',
              'backup-svc',
              '--harness',
              'antigravity',
              '--scope',
              'project',
              '--command',
              'backup-v2',
              '--format',
              'json',
              ...context(),
            ]),
          );

          final listed = success(
            await exec(<String>[
              'mcp',
              'backup',
              'list',
              '--harness',
              'antigravity',
              '--scope',
              'project',
              '--format',
              'json',
              ...context(),
            ]),
          );
          expectNoSecrets(jsonEncode(listed));
          final backups =
              (listed['data'] as Map<String, dynamic>)['backups']
                  as List<Object?>;
          expect(backups, hasLength(1));
          final backupId =
              (backups.single! as Map<String, dynamic>)['backupId'] as String;

          final planned = success(
            await exec(<String>[
              'mcp',
              'backup',
              'restore',
              '--name',
              'backup-svc',
              '--harness',
              'antigravity',
              '--scope',
              'project',
              '--backup-id',
              backupId,
              '--dry-run',
              '--format',
              'json',
              ...context(),
            ]),
          );
          final planId =
              (planned['data'] as Map<String, dynamic>)['planId'] as String;
          final restored = success(
            await exec(<String>[
              'mcp',
              'backup',
              'restore',
              '--name',
              'backup-svc',
              '--harness',
              'antigravity',
              '--scope',
              'project',
              '--backup-id',
              backupId,
              '--plan-id',
              planId,
              '--yes',
              '--ack-mcp-risk',
              '--format',
              'json',
              ...context(),
            ]),
          );
          expectNoSecrets(jsonEncode(restored));
          expect(
            entryAt(McpScope.project, 'backup-svc')!['command'],
            'backup-old',
          );
          expect(readText(projectPath), contains('unrelatedTopLevel'));
        },
      );

      test('validates Antigravity timeout and tool-setting shapes', () async {
        writeJson(projectPath, <String, Object?>{
          'mcpServers': <String, Object?>{
            'valid': <String, Object?>{
              'command': 'npx',
              'disabled': false,
              'timeoutSeconds': -1,
              'enabledTools': <Object?>['read'],
              'tools': <String, Object?>{
                'read': <String, Object?>{
                  'eager': true,
                  'background': 'always',
                },
              },
            },
            'invalid': <String, Object?>{
              'command': 'npx',
              'timeoutSeconds': -2,
              'tools': <String, Object?>{
                'read': <String, Object?>{'background': 'sometimes'},
              },
              'unexpected': 'ANTIGRAVITY_LITERAL_SECRET',
            },
          },
        });

        final valid = success(
          await exec(<String>[
            'mcp',
            'validate',
            '--name',
            'valid',
            '--harness',
            'antigravity',
            '--scope',
            'project',
            '--format',
            'json',
            ...context(),
          ]),
        );
        expect(
          ((valid['data'] as Map<String, dynamic>)['report']
              as Map<String, dynamic>)['valid'],
          isTrue,
        );

        final result = await exec(<String>[
          'mcp',
          'validate',
          '--name',
          'invalid',
          '--harness',
          'antigravity',
          '--scope',
          'project',
          '--format',
          'json',
          ...context(),
        ]);
        failure(
          result,
          exitCode: 2,
          token: 'FIELD_VALUE',
          commandPath: const <String>['agent_resource', 'mcp', 'validate'],
        );
        final message = (result as MambaFailureResult).message;
        expect(message, contains('UNKNOWN_FIELD'));
        expectNoSecrets(message);
      });
    });
  });
}
