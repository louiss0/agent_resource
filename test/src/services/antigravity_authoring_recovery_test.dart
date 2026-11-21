import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/authoring_publication_service.dart';
import 'package:agent_resource/src/services/authoring_recovery_service.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

final class _FaultyIO extends LifecycleIO {
  _FaultyIO(MemoryFileSystem memory) : super(fs: memory);

  String? failingPath;

  @override
  void before(String operation, String path) {
    if (operation == 'write' &&
        failingPath != null &&
        path.contains(failingPath!)) {
      throw FileSystemException('Injected failure', path);
    }
    super.before(operation, path);
  }
}

void main() {
  group('Antigravity Authoring transaction recovery', () {
    late MemoryFileSystem fs;
    late _FaultyIO io;
    late LifecycleStateService state;
    late AuthoringRecoveryService recovery;
    late MambaExecutor<MambaExecutionResult> executor;
    late List<String> context;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      fs.directory('/sandbox/project').createSync(recursive: true);
      fs.directory('/sandbox/home').createSync(recursive: true);
      fs.directory('/sandbox/state').createSync(recursive: true);
      fs.directory('/sandbox/gemini/config').createSync(recursive: true);
      io = _FaultyIO(fs);
      state = LifecycleStateService(io: io);
      recovery = AuthoringRecoveryService(fileSystem: fs, state: state);
      final publication = AuthoringPublicationService(
        fileSystem: fs,
        state: state,
        recovery: recovery,
      );
      executor = createExecutor(
        fileSystem: fs,
        authoringRecovery: recovery,
        guided: GuidedAuthoringService(
          fileSystem: fs,
          publication: publication,
          terminal: () => false,
          ask: (label) async => null,
          confirm: (summary) async => true,
        ),
      ).fake();
      context = <String>[
        '--cwd',
        '/sandbox/project/',
        '--project-root',
        '/sandbox/project/',
        '--home',
        '/sandbox/home/',
        '--gemini-dir',
        '/sandbox/gemini/',
        '--state-dir',
        '/sandbox/state/',
        '--format',
        'json',
      ];
    });

    test('lists, inspects and rolls back an interrupted publication', () async {
      final authoringContext = <String>[
        for (final value in context)
          if (value != '--gemini-dir' && value != '/sandbox/gemini/') value,
      ];
      io.failingPath = 'authoring-receipts';
      final interrupted = await executor.execute(<String>[
        'agent',
        'create',
        '--scope',
        'project',
        '--profile',
        'antigravity',
        '--name',
        'reviewer',
        '--description',
        'Reviews changes.',
        '--body-text',
        'Review carefully.',
        '--apply',
        '--yes',
        ...context,
      ]);
      expect(
        interrupted,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          6,
        ),
        reason: interrupted is MambaSuccessResult ? interrupted.output : null,
      );
      io.failingPath = null;

      final listed = await executor.execute(<String>[
        'authoring',
        'list',
        ...authoringContext,
      ]);
      final listData = _data(listed);
      final transactions = listData['transactions']! as List<Object?>;
      expect(transactions, hasLength(1));
      final transaction = transactions.single! as Map<String, Object?>;
      final id = transaction['transactionId']! as String;
      expect(transaction['kind'], 'agent');
      expect(transaction['target'], contains('reviewer.md'));

      final inspected = await executor.execute(<String>[
        'authoring',
        'inspect',
        id,
        ...authoringContext,
      ]);
      final reviewId = _data(inspected)['reviewId']! as String;

      final recovered = await executor.execute(<String>[
        'authoring',
        'recover',
        id,
        '--apply',
        '--yes',
        '--plan-id',
        reviewId,
        ...authoringContext,
      ]);
      final recoveredData = _data(recovered);
      expect(recoveredData['phase'], 'rolledBack');
      expect(
        fs.file('/sandbox/project/.agents/agents/reviewer.md').existsSync(),
        isFalse,
      );
    });
  });
}

Map<String, Object?> _data(MambaExecutionResult result) {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', isNotNull),
    reason: result is MambaFailureResult ? result.message : null,
  );
  final report = jsonDecode(
    (result as MambaSuccessResult).output!,
  ) as Map<String, Object?>;
  return report['data']! as Map<String, Object?>;
}
