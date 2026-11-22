import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/mcp/mcp_native.dart';
import 'package:agent_resource/src/mcp/mcp_recovery_evidence.dart';
import 'package:agent_resource/src/services/mcp_mutation_service.dart';
import 'package:agent_resource/src/services/mcp_recovery_service.dart';
import 'package:agent_resource/src/services/mcp_validation_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

/// LifecycleIO-style fault injection: fails the nth transaction state write
/// so an interrupted reviewed mutation leaves a recorded phase behind.
final class FailingRecoveryIO extends McpRecoveryIO {
  FailingRecoveryIO({required super.fs, required this.failAt});

  final int failAt;
  var writes = 0;

  @override
  void before(String operation, String path) {
    if (operation == 'write' && path.contains('/mcp-transactions/')) {
      writes++;
      if (writes == failAt) {
        throw FileSystemException('injected interruption', path);
      }
    }
  }
}

void main() {
  group('agent_resource', () {
    group('mcp', () {
      late fslib.FileSystem fs;
      late List<String> previews;
      late Future<bool> Function(String) approval;

      const codexPath = '/sandbox/codex/config.toml';
      const stateDir = '/sandbox/state';
      const hiddenValue = 'LITERAL-VALUE-TO-HIDE';

      final tomlWithComment = <String>[
        '[mcp_servers.github]',
        'command = "github-mcp-old" # inline comment',
        'env = { TOKEN = "$hiddenValue" }',
        '',
        '# keep this comment',
        '[unrelated]',
        'other = "unchanged"',
        '',
      ].join('\n');

      List<String> ctx() => <String>[
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
        '$stateDir/',
      ];

      List<String> sel() => const <String>[
        '--name',
        'github',
        '--harness',
        'codex',
        '--scope',
        'user',
      ];

      List<String> cmd(String verb, List<String> extra) => <String>[
        'mcp',
        ...verb.split(' '),
        ...extra,
        ...ctx(),
      ];

      Future<MambaExecutionResult> exec(
        List<String> tokens, {
        McpRecoveryService? recovery,
      }) => createExecutor(
        fileSystem: fs,
        mcpRecovery: recovery,
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
          reason: result is MambaFailureResult ? result.message : '',
        );
        return jsonDecode((result as MambaSuccessResult).output!)
            as Map<String, dynamic>;
      }

      void failure(
        MambaExecutionResult result, {
        required int exitCode,
        required String token,
        String command = 'recover',
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
                <String>['agent_resource', 'mcp', ...command.split(' ')],
              ),
        );
      }

      void writeText(String path, String text) {
        fs.file(path)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);
      }

      String readText(String path) => fs.file(path).readAsStringSync();

      void seedManaged(Map<String, Object?> entry) => writeText(
        '$stateDir/mcp-registrations.json',
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'records': <Object?>[
            <String, Object?>{
              'harness': 'codex',
              'scope': 'user',
              'location': codexPath,
              'name': 'github',
              'baselineDigest': mcpCanonicalDigest(entry),
            },
          ],
        }),
      );

      Future<String> replaceCommand(String value) async {
        final result = success(
          await exec(
            cmd('replace', <String>[
              ...sel(),
              '--command',
              value,
              '--format',
              'json',
            ]),
          ),
        );
        return result['data']['planId'] as String;
      }

      List<String> stateFiles(String relativeDir) {
        final dir = fs.directory('$stateDir/$relativeDir');
        if (!dir.existsSync()) return <String>[];
        return dir
            .listSync()
            .whereType<fslib.File>()
            .map((entity) => entity.path)
            .toList()
          ..sort();
      }

      String onlyId(String directory, String prefix) {
        final paths = stateFiles(directory);
        expect(paths, hasLength(1), reason: paths.toString());
        final name = paths.single.split('/').last;
        expect(name, startsWith(prefix));
        return name.substring(0, name.length - '.json'.length);
      }

      Map<String, Object?> readEvidenceJson(String path) =>
          jsonDecode(readText(path)) as Map<String, Object?>;

      setUp(() {
        fs = MemoryFileSystem(style: FileSystemStyle.posix);
        for (final dir in const <String>[
          '/sandbox/project',
          '/sandbox/home',
          '/sandbox/claude',
          '/sandbox/codex',
          '/sandbox/pi',
          stateDir,
        ]) {
          fs.directory(dir).createSync(recursive: true);
        }
        writeText(codexPath, tomlWithComment);
        previews = <String>[];
        approval = (String preview) async {
          previews.add(preview);
          return true;
        };
      });

      test('backup group declares its three children', () async {
        final result = await exec(<String>['mcp', 'backup', '--help']);
        expect(result, isA<MambaSuccessResult>());
        final output = (result as MambaSuccessResult).output!;
        for (final child in <String>['list', 'restore', 'cleanup']) {
          expect(output, contains(child), reason: child);
        }
      });

      test('recover declares its review flags', () async {
        final result = await exec(<String>['mcp', 'recover', '--help']);
        final output = (result as MambaSuccessResult).output!;
        for (final flag in <String>[
          '--transaction-id',
          '--action',
          '--plan-id',
          '--dry-run',
          '--yes',
          '--ack-mcp-risk',
          '--format',
          '--gemini-dir',
          '--state-dir',
        ]) {
          expect(output, contains(flag), reason: flag);
        }
        expect(output, contains('antigravity'));
      });

      test('undeclared inputs are rejected before any effect', () async {
        final result = await exec(<String>[
          'mcp',
          'backup',
          'cleanup',
          '--not-an-input',
        ]);
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
                <String>['agent_resource', 'mcp', 'backup', 'cleanup'],
              ),
        );
        expect(stateFiles(mcpBackupDirectoryName), isEmpty);
      });

      group('backup', () {
        test('reviews one entry, preserves unrelated TOML bytes, and lists redacted evidence', () async {
          final oldEntry = <String, Object?>{
            'command': 'github-mcp-old',
            'env': <String, Object?>{'TOKEN': hiddenValue},
          };
          seedManaged(oldEntry);

          final applied = await exec(
            cmd('replace', <String>[
              ...sel(),
              '--command',
              'github-mcp-v2',
              '--format',
              'json',
            ]),
          );
          final body = success(applied);
          expect(body['outcome'], 'replaced');
          expect(jsonEncode(body), isNot(contains(hiddenValue)));
          for (final preview in previews) {
            expect(preview, isNot(contains(hiddenValue)));
          }

          final native = readText(codexPath);
          expect(
            native,
            contains('command = "github-mcp-v2" # inline comment'),
          );
          expect(native, contains('# keep this comment'));
          expect(native, contains('other = "unchanged"'));
          expect(native, isNot(contains(hiddenValue)));

          final backups = stateFiles(mcpBackupDirectoryName);
          expect(backups, hasLength(1));
          final rawBackup = readText(backups.single);
          expect(rawBackup, isNot(contains('keep this comment')));
          expect(rawBackup, isNot(contains('other = "unchanged"')));
          final evidence = McpBackupEvidence.decode(rawBackup);
          expect(evidence.fields, oldEntry);
          expect(evidence.identity.name, 'github');
          expect(evidence.retention, mcpEvidenceRetention);

          final listed = success(
            await exec(cmd('backup list', <String>['--format', 'json'])),
          );
          final listJson = jsonEncode(listed);
          expect(listed['data']['count'], 1);
          expect(listJson, isNot(contains(hiddenValue)));
          expect(listJson, contains('mbk_'));
          expect(listJson, contains(mcpEvidenceRetention));

          final text = (await exec(
            cmd('backup list', <String>[]),
          )) as MambaSuccessResult;
          expect(text.output, isNot(contains(hiddenValue)));
          expect(text.output, contains('backups:'));
        });
      });

      group('backup', () {
        test('restores only the selected entry after a fresh review and refuses a stale plan', () async {
          final oldEntry = <String, Object?>{
            'command': 'github-mcp-old',
            'env': <String, Object?>{'TOKEN': hiddenValue},
          };
          seedManaged(oldEntry);
          await replaceCommand('github-mcp-v2');
          final backupId = onlyId(mcpBackupDirectoryName, 'mbk_');

          writeText(
            codexPath,
            '${readText(codexPath)}# later unrelated edit\n',
          );
          final firstPlan =
              success(
                    await exec(
                      cmd('backup restore', <String>[
                        ...sel(),
                        '--backup-id',
                        backupId,
                        '--format',
                        'json',
                        '--dry-run',
                      ]),
                    ),
                  )['data']['planId']
                  as String;

          writeText(
            codexPath,
            '${readText(codexPath)}# second unrelated edit\n',
          );
          failure(
            await exec(
              cmd('backup restore', <String>[
                ...sel(),
                '--backup-id',
                backupId,
                '--plan-id',
                firstPlan,
                '--yes',
                '--ack-mcp-risk',
                '--format',
                'json',
              ]),
            ),
            exitCode: 4,
            token: 'Stale or mismatched --plan-id',
            command: 'backup restore',
          );
          expect(readText(codexPath), contains('# second unrelated edit'));

          final secondPlan =
              success(
                    await exec(
                      cmd('backup restore', <String>[
                        ...sel(),
                        '--backup-id',
                        backupId,
                        '--format',
                        'json',
                        '--dry-run',
                      ]),
                    ),
                  )['data']['planId']
                  as String;
          expect(secondPlan, isNot(firstPlan));

          final restored = success(
            await exec(
              cmd('backup restore', <String>[
                ...sel(),
                '--backup-id',
                backupId,
                '--plan-id',
                secondPlan,
                '--yes',
                '--ack-mcp-risk',
                '--format',
                'json',
              ]),
            ),
          );
          expect(jsonEncode(restored), isNot(contains(hiddenValue)));
          final native = readText(codexPath);
          expect(
            native,
            contains('command = "github-mcp-old" # inline comment'),
          );
          expect(native, contains('env = { "TOKEN" = "$hiddenValue" }'));
          expect(native, contains('# keep this comment'));
          expect(native, contains('other = "unchanged"'));
          expect(native, contains('# later unrelated edit'));
          expect(native, contains('# second unrelated edit'));
        });
      });

      group('backup', () {
        test('removes only the explicitly selected eligible backup', () async {
          seedManaged(<String, Object?>{
            'command': 'github-mcp-old',
            'env': <String, Object?>{'TOKEN': hiddenValue},
          });
          await replaceCommand('github-mcp-v2');
          final firstId = onlyId(mcpBackupDirectoryName, 'mbk_');
          await replaceCommand('github-mcp-v3');
          expect(stateFiles(mcpBackupDirectoryName), hasLength(2));
          final nativeBefore = readText(codexPath);

          final plan =
              success(
                    await exec(
                      cmd('backup cleanup', <String>[
                        ...sel(),
                        '--backup-id',
                        firstId,
                        '--format',
                        'json',
                        '--dry-run',
                      ]),
                    ),
                  )['data']['planId']
                  as String;
          expect(stateFiles(mcpBackupDirectoryName), hasLength(2));

          final cleaned = success(
            await exec(
              cmd('backup cleanup', <String>[
                ...sel(),
                '--backup-id',
                firstId,
                '--plan-id',
                plan,
                '--yes',
                '--ack-mcp-risk',
                '--format',
                'json',
              ]),
            ),
          );
          expect(jsonEncode(cleaned), isNot(contains(hiddenValue)));
          final remaining = stateFiles(mcpBackupDirectoryName);
          expect(remaining, hasLength(1));
          expect(remaining.single, isNot(contains(firstId)));
          expect(readText(codexPath), nativeBefore);

          failure(
            await exec(
              cmd('backup cleanup', <String>[
                ...sel(),
                '--backup-id',
                firstId,
                '--format',
                'json',
                '--dry-run',
              ]),
            ),
            exitCode: 4,
            token: 'No retained MCP backup evidence',
            command: 'backup cleanup',
          );
        });
      });

      group('recover', () {
        Future<McpRecoveryService> interruptedService(int failAt) async =>
            McpRecoveryService(
              fileSystem: fs,
              mutation: McpMutationService(
                fileSystem: fs,
                validation: McpValidationService(fileSystem: fs),
                approve: approval,
              ),
              approve: approval,
              io: FailingRecoveryIO(fs: fs, failAt: failAt),
            );

        test(
          'rolls back an interrupted mutation with unrelated content untouched',
          () async {
            seedManaged(<String, Object?>{
              'command': 'github-mcp-old',
              'env': <String, Object?>{'TOKEN': hiddenValue},
            });
            await exec(
              cmd('replace', <String>[
                ...sel(),
                '--command',
                'github-mcp-v2',
                '--format',
                'json',
              ]),
              recovery: await interruptedService(2),
            ).then((result) {
              failure(
                result,
                exitCode: 6,
                token: 'recovery is required',
                command: 'replace',
              );
              expect((result as MambaFailureResult).output, isNull);
            });

            final transactionId = onlyId(mcpTransactionDirectoryName, 'mtx_');
            final transactionPath =
                '$stateDir/$mcpTransactionDirectoryName/$transactionId.json';
            expect(
              (readEvidenceJson(transactionPath)['phase'] as String),
              'recoveryRequired',
            );
            expect(readText(codexPath), contains('command = "github-mcp-v2"'));

            final pending = success(
              await exec(cmd('recover', <String>['--format', 'json'])),
            );
            expect(pending['data']['count'], 1);
            expect(jsonEncode(pending), isNot(contains(hiddenValue)));
            expect(
              (pending['data']['transactions'] as List)
                  .single['availableActions'],
              <String>['rollback'],
            );

            failure(
              await exec(
                cmd('recover', <String>[
                  ...sel(),
                  '--transaction-id',
                  transactionId,
                  '--action',
                  'complete',
                  '--format',
                  'json',
                  '--dry-run',
                ]),
              ),
              exitCode: 4,
              token: 'not provable from phase',
              command: 'recover',
            );

            final plan =
                success(
                      await exec(
                        cmd('recover', <String>[
                          ...sel(),
                          '--transaction-id',
                          transactionId,
                          '--action',
                          'rollback',
                          '--format',
                          'json',
                          '--dry-run',
                        ]),
                      ),
                    )['data']['planId']
                    as String;

            final recovered = success(
              await exec(
                cmd('recover', <String>[
                  ...sel(),
                  '--transaction-id',
                  transactionId,
                  '--action',
                  'rollback',
                  '--plan-id',
                  plan,
                  '--yes',
                  '--ack-mcp-risk',
                  '--format',
                  'json',
                ]),
              ),
            );
            expect(jsonEncode(recovered), isNot(contains(hiddenValue)));
            final native = readText(codexPath);
            expect(
              native,
              contains('command = "github-mcp-old" # inline comment'),
            );
            expect(native, contains('env = { "TOKEN" = "$hiddenValue" }'));
            expect(native, contains('# keep this comment'));
            expect(native, contains('other = "unchanged"'));
            expect(
              (readEvidenceJson(transactionPath)['phase'] as String),
              'failedRestored',
            );
            final after = success(
              await exec(cmd('recover', <String>['--format', 'json'])),
            );
            expect(after['data']['count'], 0);
          },
        );

        test(
          'completes a published mutation after a fresh reviewed action',
          () async {
            seedManaged(<String, Object?>{
              'command': 'github-mcp-old',
              'env': <String, Object?>{'TOKEN': hiddenValue},
            });
            await exec(
              cmd('replace', <String>[
                ...sel(),
                '--command',
                'github-mcp-v2',
                '--format',
                'json',
              ]),
              recovery: await interruptedService(3),
            ).then((result) {
              failure(
                result,
                exitCode: 6,
                token: 'recovery is required',
                command: 'replace',
              );
            });

            final transactionId = onlyId(mcpTransactionDirectoryName, 'mtx_');
            final transactionPath =
                '$stateDir/$mcpTransactionDirectoryName/$transactionId.json';
            expect(
              (readEvidenceJson(transactionPath)['phase'] as String),
              'published',
            );
            final backupId = onlyId(mcpBackupDirectoryName, 'mbk_');
            failure(
              await exec(
                cmd('backup cleanup', <String>[
                  ...sel(),
                  '--backup-id',
                  backupId,
                  '--format',
                  'json',
                  '--dry-run',
                ]),
              ),
              exitCode: 4,
              token: 'still referenced by recoverable transaction',
              command: 'backup cleanup',
            );
            final nativeBefore = readText(codexPath);

            final plan =
                success(
                      await exec(
                        cmd('recover', <String>[
                          ...sel(),
                          '--transaction-id',
                          transactionId,
                          '--action',
                          'complete',
                          '--format',
                          'json',
                          '--dry-run',
                        ]),
                      ),
                    )['data']['planId']
                    as String;
            final recovered = success(
              await exec(
                cmd('recover', <String>[
                  ...sel(),
                  '--transaction-id',
                  transactionId,
                  '--action',
                  'complete',
                  '--plan-id',
                  plan,
                  '--yes',
                  '--ack-mcp-risk',
                  '--format',
                  'json',
                ]),
              ),
            );
            expect(jsonEncode(recovered), isNot(contains(hiddenValue)));
            expect(readText(codexPath), nativeBefore);
            expect(
              (readEvidenceJson(transactionPath)['phase'] as String),
              'committed',
            );
          },
        );

        test(
          'refuses restore while a recoverable transaction holds the backup',
          () async {
            seedManaged(<String, Object?>{
              'command': 'github-mcp-old',
              'env': <String, Object?>{'TOKEN': hiddenValue},
            });
            await exec(
              cmd('replace', <String>[
                ...sel(),
                '--command',
                'github-mcp-v2',
                '--format',
                'json',
              ]),
              recovery: await interruptedService(3),
            ).then((result) {
              failure(
                result,
                exitCode: 6,
                token: 'recovery is required',
                command: 'replace',
              );
            });
            final backupId = onlyId(mcpBackupDirectoryName, 'mbk_');

            failure(
              await exec(
                cmd('backup restore', <String>[
                  ...sel(),
                  '--backup-id',
                  backupId,
                  '--format',
                  'json',
                  '--dry-run',
                ]),
              ),
              exitCode: 4,
              token: 'still referenced by recoverable transaction',
              command: 'backup restore',
            );
            expect(readText(codexPath), contains('command = "github-mcp-v2"'));
          },
        );

        test('refuses substituted or corrupt recovery evidence', () async {
          seedManaged(<String, Object?>{
            'command': 'github-mcp-old',
            'env': <String, Object?>{'TOKEN': hiddenValue},
          });
          await exec(
            cmd('replace', <String>[
              ...sel(),
              '--command',
              'github-mcp-v2',
              '--format',
              'json',
            ]),
            recovery: await interruptedService(3),
          ).then((result) {
            failure(
              result,
              exitCode: 6,
              token: 'recovery is required',
              command: 'replace',
            );
          });
          final transactionId = onlyId(mcpTransactionDirectoryName, 'mtx_');
          final transactionPath =
              '$stateDir/$mcpTransactionDirectoryName/$transactionId.json';

          final corrupt = readEvidenceJson(transactionPath);
          corrupt['artifactDigest'] = 'corrupted';
          writeText(transactionPath, jsonEncode(corrupt));
          failure(
            await exec(
              cmd('recover', <String>[
                ...sel(),
                '--transaction-id',
                transactionId,
                '--action',
                'rollback',
                '--format',
                'json',
                '--dry-run',
              ]),
            ),
            exitCode: 4,
            token: 'inconsistent or substituted',
            command: 'recover',
          );

          final backupId = onlyId(mcpBackupDirectoryName, 'mbk_');
          final backupPath = '$stateDir/$mcpBackupDirectoryName/$backupId.json';
          for (final path in <String>[transactionPath, backupPath]) {
            final json = readEvidenceJson(path)
              ..['identity'] = <String, Object?>{
                ...(readEvidenceJson(path)['identity'] as Map<String, Object?>),
                'location': '/sandbox/elsewhere/config.toml',
              }
              ..remove('artifactDigest');
            writeText(
              path,
              jsonEncode(<String, Object?>{
                ...json,
                'artifactDigest': mcpCanonicalDigest(json),
              }),
            );
          }
          failure(
            await exec(
              cmd('recover', <String>[
                ...sel(),
                '--transaction-id',
                transactionId,
                '--action',
                'rollback',
                '--format',
                'json',
                '--dry-run',
              ]),
            ),
            exitCode: 4,
            token: 'substituted',
            command: 'recover',
          );
        });
      });
    });
  });
}
