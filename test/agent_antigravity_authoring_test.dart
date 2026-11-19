import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

final class _Fixture {
  const _Fixture(this.fs, this.root, this.project, this.home, this.config);

  final FileSystem fs;
  final Directory root;
  final Directory project;
  final Directory home;
  final Directory config;
}

Future<_Fixture> _fixture() async {
  final fs = MemoryFileSystem(style: FileSystemStyle.posix);
  final root = fs.directory('/sandbox')..createSync();
  final project = fs.directory(fs.path.join(root.path, 'project'))
    ..createSync();
  final home = fs.directory(fs.path.join(root.path, 'home'))..createSync();
  final config = fs.directory(fs.path.join(root.path, 'gemini-config'))
    ..createSync();
  return _Fixture(fs, root, project, home, config);
}

List<String> _context(_Fixture fixture) => <String>[
  '--scope',
  'project',
  '--cwd',
  '${fixture.project.path}${fixture.fs.path.separator}',
  '--project-root',
  '${fixture.project.path}${fixture.fs.path.separator}',
  '--home',
  '${fixture.home.path}${fixture.fs.path.separator}',
  '--gemini-dir',
  '${fixture.config.path}${fixture.fs.path.separator}',
  '--state-dir',
  '${fixture.fs.path.join(fixture.root.path, 'state')}${fixture.fs.path.separator}',
];

Map<String, Object?> _successData(MambaExecutionResult result) {
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

void main() {
  group('Antigravity Agent authoring', () {
    late _Fixture fixture;
    late MambaExecutor<MambaExecutionResult> executor;

    setUp(() async {
      fixture = await _fixture();
      executor = createExecutor(
        fileSystem: fixture.fs,
        guided: GuidedAuthoringService(
          fileSystem: fixture.fs,
          terminal: () => false,
          ask: (label) async => null,
          confirm: (summary) async => true,
        ),
      ).fake();
    });

    tearDown(() async {
      await fixture.root.delete(recursive: true);
    });

    test('plans and publishes a flat native Agent definition', () async {
      final args = <String>[
        'agent',
        'create',
        '--profile',
        'antigravity',
        '--name',
        'reviewer',
        '--description',
        'Reviews changes.',
        '--tools',
        'read',
        '--tools',
        'grep',
        '--main-agent',
        '--body-text',
        'Review carefully.',
        '--format',
        'json',
        ..._context(fixture),
      ];
      final output = fixture.fs.file(
        fixture.fs.path.join(
          fixture.project.path,
          '.agents',
          'agents',
          'reviewer.md',
        ),
      );
      final planned = await executor.execute(args);
      final planData = _successData(planned);
      expect(planData['ready'], isTrue);
      expect(planData['profile'], 'antigravity');
      final target = planData['target']! as Map<String, Object?>;
      expect(target['output'], output.path);
      expect(output.existsSync(), isFalse);

      final applied = await executor.execute(<String>[
        ...args,
        '--apply',
        '--plan-id',
        planData['planId']! as String,
        '--yes',
      ]);
      _successData(applied);
      expect(output.existsSync(), isTrue);
      final content = output.readAsStringSync();
      expect(content, contains('name: "reviewer"'));
      expect(content, contains('description: "Reviews changes."'));
      expect(content, contains('tools: ["read","grep"]'));
      expect(content, contains('mainAgent: true'));
      expect(content, endsWith('Review carefully.'));
    });
  });
}
