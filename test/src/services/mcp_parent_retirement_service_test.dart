import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/mcp_parent_retirement_service.dart';
import 'package:agent_resource/src/services/parent_config_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

final class _Fixture {
  _Fixture() : fs = MemoryFileSystem(style: FileSystemStyle.posix) {
    project = fs.directory('/sandbox/project')..createSync(recursive: true);
    home = fs.directory('/sandbox/home')..createSync(recursive: true);
    codex = fs.directory('/sandbox/codex')..createSync(recursive: true);
    stateRoot = fs.path.join(project.path, '.agent-resource');
    native = fs.file(fs.path.join(project.path, '.codex', 'config.toml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# native harness file\n'
        'model = "gpt-5"\n'
        '[mcp_servers.github]\n'
        'command = "run"\n'
        '# TOKEN=ABC123-DO-NOT-PRINT\n',
      );
    nativeBytes = native.readAsBytesSync();
  }

  final FileSystem fs;
  late final Directory project;
  late final Directory home;
  late final Directory codex;
  late final String stateRoot;
  late final File native;
  late final List<int> nativeBytes;

  LifecycleOptions options() => LifecycleOptions(
    processWorkingDirectory: project.path,
    scope: LifecycleScope.project,
    cwd: project.path,
    projectRoot: project.path,
    home: home.path,
    codexHome: codex.path,
    stateDir: stateRoot,
  );

  // FolderPathOption requires separator-terminated folder paths.
  List<String> context() {
    final sep = fs.path.separator;
    return [
      '--scope',
      'project',
      '--cwd',
      '${project.path}$sep',
      '--project-root',
      '${project.path}$sep',
      '--home',
      '${home.path}$sep',
      '--codex-home',
      '${codex.path}$sep',
      '--state-dir',
      '$stateRoot$sep',
    ];
  }

  void _write(String path, Object? value) => fs.file(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(value));

  void ledger(List<Map<String, Object?>> records) => _write(
    fs.path.join(stateRoot, 'parent-units.json'),
    <String, Object?>{'schemaVersion': 1, 'records': records},
  );

  Map<String, Object?> record(
    String parentId,
    List<String> units,
    List<String> backupIds,
  ) => <String, Object?>{
    'schemaVersion': 1,
    'parentId': parentId,
    'harness': 'codex',
    'scope': 'project',
    'layer': 'project',
    'file': native.path,
    'fingerprint': 'fp',
    'lifecycle': 'live',
    'units': <Object?>[
      for (final unit in units)
        <String, Object?>{
          'unit': unit,
          'present': true,
          'value': 'LITERAL_SECRET_$unit',
          'digest': 'd',
        },
    ],
    'backupIds': backupIds,
  };

  void backup(String id, List<String> units) => _write(
    fs.path.join(stateRoot, 'parent-backups', id, 'backup.json'),
    <String, Object?>{
      'schemaVersion': 1,
      'backupId': id,
      'parentId': 'pid',
      'scope': 'project',
      'harness': 'codex',
      'layer': 'project',
      'file': native.path,
      'sourceFingerprint': 'fp',
      'retention': 'retained',
      'artifactDigest': 'ad',
      'units': <Object?>[
        for (final unit in units)
          <String, Object?>{
            'unit': unit,
            'present': true,
            'value': 'LITERAL_SECRET_$unit',
            'digest': 'd',
          },
      ],
    },
  );

  void transaction(
    String id, {
    Object? backupId,
    required String phase,
    String? file,
  }) => _write(
    fs.path.join(stateRoot, 'parent-transactions', '$id.json'),
    <String, Object?>{
      'schemaVersion': 1,
      'transactionId': id,
      'parentId': 'pid',
      'operation': 'config-apply',
      'file': file ?? native.path,
      'scope': 'project',
      'backupId': backupId,
      'phase': phase,
    },
  );

  bool exists(String relative) =>
      fs.file(fs.path.join(stateRoot, relative)).existsSync() ||
      fs.directory(fs.path.join(stateRoot, relative)).existsSync();
}

McpParentRetirementService _service(_Fixture fixture) =>
    McpParentRetirementService(fileSystem: fixture.fs);

void main() {
  group('McpParentRetirementService', () {
    test(
      'refuses to drain while MCP parent transactions are pending',
      () async {
        final fixture = _Fixture();
        fixture.ledger([
          fixture.record(
            'pid_mcp',
            ['mcp_servers.github.command'],
            ['pbk_mcp'],
          ),
        ]);
        fixture.backup('pbk_mcp', ['mcp_servers.github.command']);
        fixture.backup('pbk_nonmcp', ['model']);
        fixture.transaction(
          'ptr_published',
          backupId: 'pbk_mcp',
          phase: 'published',
        );
        fixture.transaction(
          'ptr_cleanup',
          backupId: 'pbk_mcp',
          phase: 'committedCleanupPending',
        );
        fixture.transaction(
          'ptr_recovery',
          backupId: 'pbk_mcp',
          phase: 'recoveryRequired',
        );
        fixture.transaction(
          'ptr_mcpfile',
          phase: 'prepared',
          file: '/sandbox/project/.mcp.json',
        );
        // Terminal MCP and pending non-MCP transactions must not block.
        fixture.transaction(
          'ptr_committed',
          backupId: 'pbk_mcp',
          phase: 'committed',
        );
        fixture.transaction(
          'ptr_failed',
          backupId: 'pbk_mcp',
          phase: 'failedRestored',
        );
        fixture.transaction(
          'ptr_nonmcp_pending',
          backupId: 'pbk_nonmcp',
          phase: 'prepared',
        );

        final service = _service(fixture);
        for (final apply in [false, true]) {
          await expectLater(
            service.drain(options: fixture.options(), apply: apply),
            throwsA(
              isA<MambaException>()
                  .having((e) => e.exitCode, 'status', 4)
                  .having(
                    (e) => e.message,
                    'message',
                    allOf([
                      contains('recovery'),
                      contains('restore'),
                      contains('cleanup'),
                      contains('ptr_published'),
                      contains('ptr_cleanup'),
                      contains('ptr_recovery'),
                      contains('ptr_mcpfile'),
                      isNot(contains('ptr_nonmcp_pending')),
                      isNot(contains('ptr_committed')),
                    ]),
                  ),
            ),
          );
        }
        // A refused drain removes nothing and mutates no native file.
        expect(fixture.exists('parent-units.json'), isTrue);
        expect(fixture.exists('parent-backups/pbk_mcp/backup.json'), isTrue);
        expect(
          fixture.exists('parent-transactions/ptr_published.json'),
          isTrue,
        );
        expect(fixture.native.readAsBytesSync(), fixture.nativeBytes);
      },
    );

    test(
      'drains only MCP evidence, preserves non-MCP, and reports redacted',
      () async {
        final fixture = _Fixture();
        fixture.ledger([
          fixture.record(
            'pid_mcp',
            ['mcp_servers.github.command'],
            ['pbk_mcp'],
          ),
          fixture.record(
            'pid_mixed',
            ['mcp_servers.github.command', 'model'],
            ['pbk_mcp', 'pbk_nonmcp'],
          ),
          fixture.record('pid_nonmcp', ['model'], ['pbk_nonmcp']),
        ]);
        fixture.backup('pbk_mcp', ['mcp_servers.github.command']);
        fixture.backup('pbk_nonmcp', ['model']);
        fixture.backup('pbk_mixed', ['mcp_servers.github.command', 'model']);
        fixture.transaction(
          'ptr_mcp_terminal',
          backupId: 'pbk_mcp',
          phase: 'committed',
        );
        fixture.transaction(
          'ptr_nonmcp_terminal',
          backupId: 'pbk_nonmcp',
          phase: 'committed',
        );

        final service = _service(fixture);
        final inventory = await service.drain(
          options: fixture.options(),
          apply: false,
        );
        expect(inventory.outcome, 'inventoried');
        expect(inventory.data['writes'], false);
        // Dry-run made no changes at all.
        expect(fixture.exists('parent-backups/pbk_mcp/backup.json'), isTrue);
        expect(
          fixture.exists('parent-transactions/ptr_mcp_terminal.json'),
          isTrue,
        );
        expect(fixture.native.readAsBytesSync(), fixture.nativeBytes);

        final drained = await service.drain(
          options: fixture.options(),
          apply: true,
        );
        expect(drained.outcome, 'drained');
        expect(drained.data['writes'], true);
        expect(drained.data['redaction'], 'credential-and-value-data-omitted');
        expect(drained.data['nativeFilesWritten'], isEmpty);
        final changed = drained.data['drained']! as Map<String, Object?>;
        final kept = drained.data['preserved']! as Map<String, Object?>;
        expect(changed['records'], ['pid_mcp']);
        expect(changed['backups'], ['pbk_mcp']);
        expect(changed['transactions'], ['ptr_mcp_terminal']);
        expect(changed['recordUnits'], contains('mcp_servers.github.command'));
        expect(kept['records'], containsAll(['pid_mixed', 'pid_nonmcp']));
        expect(kept['backups'], containsAll(['pbk_nonmcp', 'pbk_mixed']));
        expect(kept['transactions'], ['ptr_nonmcp_terminal']);

        // Deterministic, value-free account: no secret appears in output.
        final text = drained.renderText();
        final envelope = jsonEncode(drained.envelope());
        for (final output in [text, envelope]) {
          expect(output, isNot(contains('LITERAL_SECRET')));
          expect(output, isNot(contains('ABC123-DO-NOT-PRINT')));
        }

        // Only MCP-owned evidence was removed; everything else survives.
        expect(fixture.exists('parent-backups/pbk_mcp/backup.json'), isFalse);
        expect(fixture.exists('parent-backups/pbk_nonmcp/backup.json'), isTrue);
        expect(fixture.exists('parent-backups/pbk_mixed/backup.json'), isTrue);
        expect(
          fixture.exists('parent-transactions/ptr_mcp_terminal.json'),
          isFalse,
        );
        expect(
          fixture.exists('parent-transactions/ptr_nonmcp_terminal.json'),
          isTrue,
        );
        final ledger = jsonDecode(
          fixture.fs
              .file(
                fixture.fs.path.join(fixture.stateRoot, 'parent-units.json'),
              )
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final records = (ledger['records']! as List<Object?>)
            .cast<Map<String, Object?>>();
        final byId = <String, Map<String, Object?>>{
          for (final record in records) record['parentId']! as String: record,
        };
        expect(byId.containsKey('pid_mcp'), isFalse);
        final mixed = byId['pid_mixed']!;
        final mixedUnits = (mixed['units']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map((unit) => unit['unit'])
            .toList();
        expect(mixedUnits, ['model']);
        expect(mixed['backupIds'], ['pbk_nonmcp']);
        final nonMcp = byId['pid_nonmcp']!;
        final nonMcpUnits = (nonMcp['units']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .map((unit) => unit['unit'])
            .toList();
        expect(nonMcpUnits, ['model']);

        // Retirement never rewrites a native harness file.
        expect(fixture.native.readAsBytesSync(), fixture.nativeBytes);
      },
    );
  });

  group('agent_resource', () {
    group('agent', () {
      group('config', () {
        Future<MambaExecutionResult> run(_Fixture fixture, List<String> args) =>
            createExecutor(
              fileSystem: fixture.fs,
              parentConfig: ParentConfigService(fileSystem: fixture.fs),
            ).fake().execute(['agent', 'config', 'drain-mcp', ...args]);

        test('help lists the drain-mcp child', () async {
          final result = await createExecutor().fake().execute([
            'agent',
            'config',
            '--help',
          ]);
          expect(result, isA<MambaSuccessResult>());
          expect((result as MambaSuccessResult).output, contains('drain-mcp'));
        });

        test(
          'an unreviewed invocation only inventories without writes',
          () async {
            final fixture = _Fixture();
            fixture.ledger([
              fixture.record(
                'pid_mcp',
                ['mcp_servers.github.command'],
                ['pbk_mcp'],
              ),
            ]);
            fixture.backup('pbk_mcp', ['mcp_servers.github.command']);
            final result = await run(fixture, [
              ...fixture.context(),
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            final envelope = jsonDecode(
              (result as MambaSuccessResult).output!,
            ) as Map<String, Object?>;
            expect(envelope['outcome'], 'inventoried');
            final data = envelope['data']! as Map<String, Object?>;
            expect(data['writes'], false);
            expect(
              fixture.exists('parent-backups/pbk_mcp/backup.json'),
              isTrue,
            );
          },
        );

        test('a reviewed --yes drain is reachable from the CLI', () async {
          final fixture = _Fixture();
          fixture.ledger([
            fixture.record(
              'pid_mcp',
              ['mcp_servers.github.command'],
              ['pbk_mcp'],
            ),
          ]);
          fixture.backup('pbk_mcp', ['mcp_servers.github.command']);
          final result = await run(fixture, [
            ...fixture.context(),
            '--yes',
            '--format',
            'json',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final envelope = jsonDecode(
            (result as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          expect(envelope['outcome'], 'drained');
          expect(envelope['schemaVersion'], 1);
          final body = jsonEncode(envelope);
          expect(body, isNot(contains('LITERAL_SECRET')));
          expect(fixture.exists('parent-backups/pbk_mcp/backup.json'), isFalse);
          expect(fixture.native.readAsBytesSync(), fixture.nativeBytes);
        });

        test('pending MCP transactions refuse through the CLI', () async {
          final fixture = _Fixture();
          fixture.backup('pbk_mcp', ['mcp_servers.github.command']);
          fixture.transaction(
            'ptr_published',
            backupId: 'pbk_mcp',
            phase: 'published',
          );
          final result = await run(fixture, [...fixture.context(), '--yes']);
          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 4)
                .having(
                  (value) => value.message,
                  'message',
                  allOf(contains('ptr_published'), contains('restore')),
                )
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.error.commandPath,
                  'command path',
                  <String>['agent_resource', 'agent', 'config', 'drain-mcp'],
                ),
          );
          expect(fixture.exists('parent-backups/pbk_mcp/backup.json'), isTrue);
          expect(fixture.native.readAsBytesSync(), fixture.nativeBytes);
        });
      });
    });
  });
}
