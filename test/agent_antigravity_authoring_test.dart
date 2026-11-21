import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/authoring/editor_process.dart';
import 'package:agent_resource/src/services/agent_authoring_service.dart';
import 'package:agent_resource/src/services/agent_installation_service.dart';
import 'package:agent_resource/src/services/agent_lifecycle_service.dart';
import 'package:agent_resource/src/services/authoring_recovery_service.dart';
import 'package:agent_resource/src/services/editor_interaction_service.dart';
import 'package:agent_resource/src/services/instruction_draft_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
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
  final gemini = fs.directory(fs.path.join(root.path, 'gemini'))..createSync();
  final config = fs.directory(fs.path.join(gemini.path, 'config'))
    ..createSync();
  return _Fixture(fs, root, project, home, config);
}

List<String> _context(_Fixture fixture) => <String>[
  '--cwd',
  '${fixture.project.path}${fixture.fs.path.separator}',
  '--project-root',
  '${fixture.project.path}${fixture.fs.path.separator}',
  '--home',
  '${fixture.home.path}${fixture.fs.path.separator}',
  '--gemini-dir',
  '${fixture.fs.path.dirname(fixture.config.path)}${fixture.fs.path.separator}',
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
      final lifecycle = AgentLifecycleService(fileSystem: fixture.fs);
      final state = LifecycleStateService(io: LifecycleIO(fs: fixture.fs));
      executor = createExecutor(
        fileSystem: fixture.fs,
        authoringRecovery: AuthoringRecoveryService(
          fileSystem: fixture.fs,
          state: state,
        ),
        agentAuthoring: AgentAuthoringService(
          fileSystem: fixture.fs,
          lifecycle: lifecycle,
        ),
        agentLifecycle: lifecycle,
        agentInstallation: AgentInstallationService(fileSystem: fixture.fs),
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
        '--scope',
        'project',
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

    test(
      'publishes a managed user-scope definition below Gemini config',
      () async {
        final result = await executor.execute(<String>[
          'agent',
          'create',
          '--profile',
          'antigravity',
          '--name',
          'helper',
          '--description',
          'Helps.',
          '--body-text',
          'Help the user.',
          '--manage',
          '--apply',
          '--yes',
          '--scope',
          'user',
          '--format',
          'json',
          ..._context(fixture),
        ]);
        final data = _successData(result);
        if (data['managed'] != true) fail(jsonEncode(data));
        final output = fixture.fs.file(
          fixture.fs.path.join(fixture.config.path, 'agents', 'helper.md'),
        );
        expect(output.existsSync(), isTrue);
        expect(output.readAsStringSync(), contains('name: "helper"'));
      },
    );

    test('clones a native definition without changing its source', () async {
      final source =
          fixture.fs.file(fixture.fs.path.join(fixture.root.path, 'source.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
tools: [read, grep]
mainAgent: true
---
Review carefully.''');
      final sourceBytes = source.readAsBytesSync();
      final request =
          fixture.fs.file(fixture.fs.path.join(fixture.root.path, 'clone.json'))
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'schemaVersion': 1,
                'operation': 'clone',
                'source': <String, Object?>{
                  'kind': 'native-file',
                  'path': source.path,
                  'harness': 'antigravity',
                },
                'target': <String, Object?>{
                  'harness': 'antigravity',
                  'output': '.agents/agents/copy.md',
                },
                'context': <String, Object?>{'workingDirectory': './'},
              }),
            );
      final output = fixture.fs.file(
        fixture.fs.path.join(
          fixture.project.path,
          '.agents',
          'agents',
          'copy.md',
        ),
      );
      final context = <String>[
        '--cwd',
        '${fixture.project.path}${fixture.fs.path.separator}',
        '--project-root',
        '${fixture.project.path}${fixture.fs.path.separator}',
        '--home',
        '${fixture.home.path}${fixture.fs.path.separator}',
        '--gemini-dir',
        '${fixture.fs.path.dirname(fixture.config.path)}${fixture.fs.path.separator}',
        '--state-dir',
        '${fixture.fs.path.join(fixture.root.path, 'state')}${fixture.fs.path.separator}',
        '--format',
        'json',
      ];
      final planned = await executor.execute([
        'agent',
        'clone',
        request.path,
        ...context,
      ]);
      final planData = _successData(planned);
      expect(planData['ready'], isTrue);
      expect(output.existsSync(), isFalse);

      final applied = await executor.execute([
        'agent',
        'clone',
        request.path,
        '--apply',
        '--plan-id',
        planData['planId']! as String,
        '--yes',
        ...context,
      ]);
      _successData(applied);
      final content = output.readAsStringSync();
      expect(content, contains('tools: ["read","grep"]'));
      expect(content, contains('mainAgent: true'));
      expect(content, endsWith('Review carefully.'));
      expect(source.readAsBytesSync(), sourceBytes);
    });

    test('composes a native definition with explicit instruction parts', () async {
      final source =
          fixture.fs.file(fixture.fs.path.join(fixture.root.path, 'source.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews changes.
tools: [read]
---
Review carefully.''');
      final sourceBytes = source.readAsBytesSync();
      final request =
          fixture.fs.file(
            fixture.fs.path.join(fixture.root.path, 'compose.json'),
          )..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'compose',
              'source': <String, Object?>{
                'kind': 'native-file',
                'path': source.path,
                'harness': 'antigravity',
              },
              'target': <String, Object?>{
                'harness': 'antigravity',
                'output': '.agents/agents/composed.md',
              },
              'context': <String, Object?>{'workingDirectory': './'},
              'definition': <String, Object?>{
                'description': 'Composed review.',
              },
              'instructions': <Object?>['Check the lease.'],
              'baseInstructions': 'include',
              'decisions': <Object?>['field:description'],
            }),
          );
      final output = fixture.fs.file(
        fixture.fs.path.join(
          fixture.project.path,
          '.agents',
          'agents',
          'composed.md',
        ),
      );
      final context = <String>[
        '--cwd',
        '${fixture.project.path}${fixture.fs.path.separator}',
        '--project-root',
        '${fixture.project.path}${fixture.fs.path.separator}',
        '--home',
        '${fixture.home.path}${fixture.fs.path.separator}',
        '--gemini-dir',
        '${fixture.fs.path.dirname(fixture.config.path)}${fixture.fs.path.separator}',
        '--state-dir',
        '${fixture.fs.path.join(fixture.root.path, 'state')}${fixture.fs.path.separator}',
        '--format',
        'json',
      ];
      final planned = await executor.execute([
        'agent',
        'compose',
        request.path,
        ...context,
      ]);
      final planData = _successData(planned);
      expect(planData['ready'], isTrue);
      final applied = await executor.execute([
        'agent',
        'compose',
        request.path,
        '--apply',
        '--plan-id',
        planData['planId']! as String,
        '--yes',
        ...context,
      ]);
      _successData(applied);
      final content = output.readAsStringSync();
      expect(content, contains('description: "Composed review."'));
      expect(content, contains('Review carefully.\nCheck the lease.'));
      expect(source.readAsBytesSync(), sourceBytes);
    });

    test('edits a managed definition through its reviewed baseline', () async {
      final source =
          fixture.fs.file(fixture.fs.path.join(fixture.root.path, 'source.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Original description.
tools: [read]
---
Original instructions.''');
      final context = <String>[
        '--cwd',
        '${fixture.project.path}${fixture.fs.path.separator}',
        '--project-root',
        '${fixture.project.path}${fixture.fs.path.separator}',
        '--home',
        '${fixture.home.path}${fixture.fs.path.separator}',
        '--gemini-dir',
        '${fixture.fs.path.dirname(fixture.config.path)}${fixture.fs.path.separator}',
        '--state-dir',
        '${fixture.fs.path.join(fixture.root.path, 'state')}${fixture.fs.path.separator}',
        '--format',
        'json',
      ];
      final installed = await executor.execute([
        'agent',
        'install',
        source.path,
        '--source-kind',
        'resource',
        '--profile',
        'antigravity',
        '--target',
        'antigravity',
        '--scope',
        'project',
        '--yes',
        ...context,
      ]);
      final installedData = _successData(installed);
      final unit =
          (installedData['units']! as List<Object?>).single!
              as Map<String, Object?>;
      final installationId =
          (unit['installationIds']! as List<Object?>).single! as String;
      final location =
          ((unit['entries']! as List<Object?>).single!
                  as Map<String, Object?>)['path']!
              as String;
      final request =
          fixture.fs.file(fixture.fs.path.join(fixture.root.path, 'edit.json'))
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'schemaVersion': 1,
                'operation': 'edit',
                'source': <String, Object?>{
                  'kind': 'managed-agent',
                  'installationId': installationId,
                },
                'target': <String, Object?>{
                  'harness': 'antigravity',
                  'installationId': installationId,
                  'output': location,
                },
                'context': <String, Object?>{'workingDirectory': './'},
                'definition': <String, Object?>{
                  'description': 'Edited description.',
                },
                'instructions': <Object?>['Edited instructions.'],
              }),
            );
      final before = fixture.fs.file(location).readAsBytesSync();
      final planned = await executor.execute([
        'agent',
        'edit',
        request.path,
        ...context,
      ]);
      final planData = _successData(planned);
      expect(planData['ready'], isTrue);
      expect(fixture.fs.file(location).readAsBytesSync(), before);
      final applied = await executor.execute([
        'agent',
        'edit',
        request.path,
        '--apply',
        '--plan-id',
        planData['planId']! as String,
        '--yes',
        ...context,
      ]);
      final appliedData = _successData(applied);
      expect(appliedData['backupId'], isA<String>());
      final content = fixture.fs.file(location).readAsStringSync();
      expect(content, contains('description: "Edited description."'));
      expect(content, contains('Original instructions.\nEdited instructions.'));
    });

    test('collects an editor-led instruction draft before a review', () async {
      final guided = GuidedAuthoringService(
        fileSystem: fixture.fs,
        terminal: () => true,
        drafts: InstructionDraftService(
          fileSystem: fixture.fs,
          state: LifecycleStateService(io: LifecycleIO(fs: fixture.fs)),
          privacy: (_) {},
          verifier: (_) {},
        ),
        editor: EditorInteractionService(
          drafts: InstructionDraftService(
            fileSystem: fixture.fs,
            state: LifecycleStateService(io: LifecycleIO(fs: fixture.fs)),
            privacy: (_) {},
            verifier: (_) {},
          ),
          processRunner: (request) async {
            fixture.fs
                .file(request.arguments.last)
                .writeAsStringSync('Drafted instructions.\n');
            return const EditorProcessOutcome(started: true, exitCode: 0);
          },
          platformLauncher: (request) async {
            fixture.fs
                .file(request.path)
                .writeAsStringSync('Drafted instructions.\n');
            return const EditorPlatformOutcome(launched: true);
          },
          environment: const EditorSessionEnvironment(
            hasTerminal: true,
            hasDisplay: true,
          ),
          acknowledge: (request) async => true,
          recover: (request) async => const EditorRecoveryCancel(),
          executables: const _FakeResolver(),
          fileSystem: fixture.fs,
        ),
        ask: (label) async => null,
        confirm: (summary) async => true,
      );
      final result =
          await createExecutor(
            fileSystem: fixture.fs,
            guided: guided,
          ).fake().execute(<String>[
            'agent',
            'create',
            '--profile',
            'antigravity',
            '--name',
            'drafted',
            '--description',
            'Drafted agent.',
            '--apply',
            '--yes',
            ..._context(fixture),
          ]);
      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      final output = fixture.fs.file(
        fixture.fs.path.join(
          fixture.project.path,
          '.agents',
          'agents',
          'drafted.md',
        ),
      );
      expect(output.readAsStringSync(), contains('Drafted instructions.'));
    });
  });
}

final class _FakeResolver implements EditorProgramResolver {
  const _FakeResolver();

  @override
  EditorExecutableResolution resolve(
    String executable, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) => EditorExecutableResolution(
    requested: executable,
    resolvedPath: '/programs/$executable',
    isBatchLauncher: false,
  );
}
