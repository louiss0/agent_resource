import 'dart:convert';

import 'package:agent_resource/src/mcp/mcp_recovery_evidence.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/services/mcp_mutation_service.dart';
import 'package:agent_resource/src/services/mcp_recovery_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('McpRecoveryService', () {
    late fslib.FileSystem fs;
    late McpRecoveryService service;

    const ctx = <String, String>{
      'cwd': '/sandbox/project/',
      'project-root': '/sandbox/project/',
      'home': '/sandbox/home/',
      'codex-home': '/sandbox/codex/',
      'state-dir': '/sandbox/state/',
    };

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      for (final dir in const <String>[
        '/sandbox/project',
        '/sandbox/home',
        '/sandbox/codex',
        '/sandbox/state',
      ]) {
        fs.directory(dir).createSync(recursive: true);
      }
      service = McpRecoveryService(
        fileSystem: fs,
        mutation: McpMutationService(
          fileSystem: fs,
          approve: (_) async => true,
        ),
        approve: (_) async => true,
      );
    });

    Future<MambaException> refusal(Future<Object?> Function() action) async {
      try {
        await action();
        fail('Expected a refusal');
      } on MambaException catch (error) {
        return error;
      }
    }

    test('a dry-run reviewed mutation retains no evidence', () async {
      final envelope = await service.execute(
        McpMutationRequest(
          operation: McpMutationOperation.register,
          environment: ctx,
          harness: McpHarness.codex,
          scope: McpScope.user,
          name: 'github',
          command: 'github-mcp',
          home: '/sandbox/home/',
          stateDir: '/sandbox/state/',
          dryRun: true,
        ),
      );
      expect(envelope.data['writes'], false);
      expect(
        fs.directory('/sandbox/state/$mcpBackupDirectoryName').existsSync(),
        isFalse,
      );
      expect(
        fs
            .directory('/sandbox/state/$mcpTransactionDirectoryName')
            .existsSync(),
        isFalse,
      );
    });

    test('an invalid evidence identifier cannot select a state path', () async {
      final error = await refusal(
        () => service.cleanupBackup(
          McpRecoveryRequest(
            environment: ctx,
            cwd: '/sandbox/project/',
            backupId: '../escape',
            projectRoot: '/sandbox/project/',
            codexHome: '/sandbox/codex/',
            stateDir: '/sandbox/state/',
          ),
        ),
      );
      expect(error.exitCode, 2);
      expect(error.message, contains('--backup-id'));
    });

    test('corrupt protected evidence is refused by list and cleanup', () async {
      final path =
          '/sandbox/state/$mcpBackupDirectoryName/'
          'mbk_0123456789abcdef0123456789abcdef.json';
      fs.file(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{'artifactDigest': 'bad'}),
        );

      final listError = await refusal(
        () => service.listBackups(
          McpRecoveryRequest(
            environment: ctx,
            cwd: '/sandbox/project/',
            projectRoot: '/sandbox/project/',
            codexHome: '/sandbox/codex/',
            stateDir: '/sandbox/state/',
          ),
        ),
      );
      expect(listError.exitCode, 4, reason: listError.message);
      expect(listError.message, contains('inconsistent or substituted'));

      final cleanupError = await refusal(
        () => service.cleanupBackup(
          McpRecoveryRequest(
            environment: ctx,
            cwd: '/sandbox/project/',
            backupId: 'mbk_0123456789abcdef0123456789abcdef',
            projectRoot: '/sandbox/project/',
            codexHome: '/sandbox/codex/',
            stateDir: '/sandbox/state/',
          ),
        ),
      );
      expect(cleanupError.exitCode, 4);
    });
  });
}
