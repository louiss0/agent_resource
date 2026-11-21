import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/authoring/editor_process.dart';
import 'package:agent_resource/src/services/editor_interaction_service.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:agent_resource/src/services/instruction_draft_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

final class _Fixture {
  const _Fixture(this.fs, this.root, this.project, this.home, this.codex);

  final FileSystem fs;
  final Directory root;
  final Directory project;
  final Directory home;
  final Directory codex;
}

Future<_Fixture> _fixture() async {
  final fs = MemoryFileSystem(style: FileSystemStyle.posix);
  final root = fs.directory('/sandbox')..createSync();
  final project = fs.directory(fs.path.join(root.path, 'project'))
    ..createSync();
  final home = fs.directory(fs.path.join(root.path, 'home'))..createSync();
  final codex = fs.directory(fs.path.join(root.path, 'codex'))..createSync();
  return _Fixture(fs, root, project, home, codex);
}

List<String> _context(_Fixture fixture) => [
  '--scope',
  'project',
  '--cwd',
  '${fixture.project.path}${fixture.fs.path.separator}',
  '--project-root',
  '${fixture.project.path}${fixture.fs.path.separator}',
  '--home',
  '${fixture.home.path}${fixture.fs.path.separator}',
  '--codex-home',
  '${fixture.codex.path}${fixture.fs.path.separator}',
];

File _definition(_Fixture fixture) =>
    fixture.fs.file(
        fixture.fs.path.join(
          fixture.project.path,
          '.codex',
          'roles',
          'reviewer.toml',
        ),
      )
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'name = "reviewer"\ndescription = "Reviews."\n'
        'developer_instructions = "Original."\n',
      );

File _config(_Fixture fixture) {
  final other = fixture.fs.file(
    fixture.fs.path.join(fixture.project.path, '.codex', 'roles', 'other.toml'),
  )..createSync(recursive: true);
  other.writeAsStringSync(
    'name = "other"\ndescription = "Other."\n'
    'developer_instructions = "Other body."\n',
  );
  return fixture.fs.file(
      fixture.fs.path.join(fixture.project.path, '.codex', 'config.toml'),
    )
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '[agents.other]\ndescription = "Other."\nconfig_file = "roles/other.toml"\n',
    );
}

void main() {
  group('agent create', () {
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

    test('registers the create route and its help', () async {
      final help = await executor.execute(['agent', 'create', '--help']);

      expect(help, isA<MambaSuccessResult>());
      final output = (help as MambaSuccessResult).output!;
      expect(output, contains('--profile'));
      expect(output, contains('--body-text'));
      expect(output, contains('--role-key'));
      expect(output, contains('--definition-source'));
    });

    test('refuses the retired positional operation request', () async {
      final request =
          fixture.fs.file(
            fixture.fs.path.join(fixture.root.path, 'create.json'),
          )..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'create',
              'target': <String, Object?>{'harness': 'claude'},
            }),
          );

      final result = await executor.execute([
        'agent',
        'create',
        request.path,
        ..._context(fixture),
      ]);

      expect(
        result,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          4,
        ),
      );
      final message = (result as MambaFailureResult).message;
      expect(message, contains('retired'));
      expect(message, contains('--profile'));
      expect(message, contains('--role-key'));
    });

    test('refuses the retired --request alias', () async {
      final request =
          fixture.fs.file(
            fixture.fs.path.join(fixture.root.path, 'create.json'),
          )..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'create',
              'target': <String, Object?>{'harness': 'claude'},
            }),
          );

      final result = await executor.execute([
        'agent',
        'create',
        '--request',
        request.path,
        ..._context(fixture),
      ]);

      expect(
        result,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          4,
        ),
      );
      expect((result as MambaFailureResult).message, contains('retired'));
    });

    test('publishes an author-only Agent without a parent change', () async {
      final config = _config(fixture);
      final before = config.readAsStringSync();

      final result = await executor.execute([
        'agent',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo agent.',
        '--body-text',
        'Complete the selected task.',
        '--apply',
        '--yes',
        '--format',
        'json',
        ..._context(fixture),
      ]);

      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      final report = jsonDecode(
        (result as MambaSuccessResult).output!,
      ) as Map<String, Object?>;
      final data = report['data']! as Map<String, Object?>;
      expect(report['command'], 'agent create');
      expect(data['ownership'], 'authorOnly');
      expect(data['managed'], isFalse);
      final definition = fixture.fs.file(
        fixture.fs.path.join(
          fixture.project.path,
          '.claude',
          'agents',
          'demo.md',
        ),
      );
      expect(definition.existsSync(), isTrue);
      expect(
        definition.readAsStringSync(),
        contains('Complete the selected task.'),
      );
      expect(
        config.readAsStringSync(),
        before,
        reason: 'A standalone creation never changes a declaring config.',
      );
    });

    test(
      'publishes a bound role and registers it in the declaring config',
      () async {
        final definition = _definition(fixture);
        final config = _config(fixture);

        final result = await executor.execute([
          'agent',
          'create',
          '--role-key',
          'reviewer',
          '--config-file',
          config.path,
          '--ownership',
          'both',
          '--definition-source',
          definition.path,
          '--definition-output',
          fixture.fs.path.join(
            fixture.project.path,
            '.codex',
            'agents',
            'reviewer.toml',
          ),
          '--ack-clients-stopped',
          '--apply',
          '--yes',
          '--format',
          'json',
          ..._context(fixture),
        ]);

        expect(
          result,
          isA<MambaSuccessResult>(),
          reason: result is MambaFailureResult ? result.message : null,
        );
        final report = jsonDecode(
          (result as MambaSuccessResult).output!,
        ) as Map<String, Object?>;
        expect(report['outcome'], 'created');
        final data = report['data']! as Map<String, Object?>;
        expect(data['roleKey'], 'reviewer');
        expect(data['registrationCommitted'], isTrue);
        expect(
          fixture.fs
              .file(
                fixture.fs.path.join(
                  fixture.project.path,
                  '.codex',
                  'agents',
                  'reviewer.toml',
                ),
              )
              .existsSync(),
          isTrue,
        );
        expect(config.readAsStringSync(), contains('agents.reviewer'));
      },
    );

    test('shows the bound-role plan before requesting approval', () async {
      final definition = _definition(fixture);
      final config = _config(fixture);
      final output = fixture.fs.path.join(
        fixture.project.path,
        '.codex',
        'agents',
        'reviewer.toml',
      );
      String? review;
      final interactiveExecutor = createExecutor(
        fileSystem: fixture.fs,
        guided: GuidedAuthoringService(
          fileSystem: fixture.fs,
          terminal: () => true,
          confirm: (summary) async {
            review = summary;
            expect(fixture.fs.file(output).existsSync(), isFalse);
            expect(
              config.readAsStringSync(),
              isNot(contains('agents.reviewer')),
            );
            return false;
          },
        ),
      ).fake();
      final result = await interactiveExecutor.execute([
        'agent',
        'create',
        '--role-key',
        'reviewer',
        '--config-file',
        config.path,
        '--ownership',
        'both',
        '--definition-source',
        definition.path,
        '--definition-output',
        output,
        '--ack-clients-stopped',
        '--apply',
        ..._context(fixture),
      ]);
      expect(
        result,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          7,
        ),
      );
      expect(review, contains(output));
      expect(review, contains('planId'));
      expect(fixture.fs.file(output).existsSync(), isFalse);
    });

    test('refuses a stale plan identity on the bound-role route', () async {
      final definition = _definition(fixture);
      final config = _config(fixture);

      final result = await executor.execute([
        'agent',
        'create',
        '--role-key',
        'reviewer',
        '--config-file',
        config.path,
        '--ownership',
        'both',
        '--definition-source',
        definition.path,
        '--ack-clients-stopped',
        '--apply',
        '--yes',
        '--plan-id',
        'stale-plan-identity',
        '--format',
        'json',
        ..._context(fixture),
      ]);

      expect(
        result,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          4,
        ),
      );
      expect((result as MambaFailureResult).message, contains('stale'));
      expect(config.readAsStringSync(), isNot(contains('agents.reviewer')));
    });

    test('refuses the standalone selections on the bound-role route', () async {
      final definition = _definition(fixture);
      final config = _config(fixture);

      final result = await executor.execute([
        'agent',
        'create',
        '--role-key',
        'reviewer',
        '--config-file',
        config.path,
        '--ownership',
        'both',
        '--definition-source',
        definition.path,
        '--profile',
        'codex',
        '--body-text',
        'Body.',
        ..._context(fixture),
      ]);

      expect(
        result,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          4,
        ),
      );
      expect(
        (result as MambaFailureResult).message,
        contains('does not accept the standalone authoring selections'),
      );
    });

    test(
      'refuses a bound-role registration without the acknowledgement',
      () async {
        final definition = _definition(fixture);
        final config = _config(fixture);

        final result = await executor.execute([
          'agent',
          'create',
          '--role-key',
          'reviewer',
          '--config-file',
          config.path,
          '--ownership',
          'both',
          '--definition-source',
          definition.path,
          '--apply',
          '--yes',
          '--format',
          'json',
          ..._context(fixture),
        ]);

        expect(
          result,
          isA<MambaFailureResult>().having(
            (value) => value.exitCode,
            'exit code',
            4,
          ),
        );
        expect(
          (result as MambaFailureResult).message,
          contains('clients-stopped'),
        );
        expect(config.readAsStringSync(), isNot(contains('agents.reviewer')));
      },
    );

    test(
      'refuses every standalone selection on the bound-role route',
      () async {
        final definition = _definition(fixture);
        final config = _config(fixture);
        final selections = <List<String>>[
          ['--model', 'provider/model'],
          ['--tools', 'read'],
          ['--skills', 'alpha'],
          ['--argument-hint', '<file>'],
          ['--license', 'MIT'],
          ['--compatibility', 'claude'],
          ['--editor', 'code --wait'],
          ['--show-instructions'],
        ];

        for (final selection in selections) {
          final result = await executor.execute([
            'agent',
            'create',
            '--role-key',
            'reviewer',
            '--config-file',
            config.path,
            '--ownership',
            'both',
            '--definition-source',
            definition.path,
            ...selection,
            ..._context(fixture),
          ]);

          expect(
            result,
            isA<MambaFailureResult>().having(
              (value) => value.exitCode,
              'exit code',
              4,
            ),
            reason: 'The selection ${selection.first} must not be ignored.',
          );
          expect(
            (result as MambaFailureResult).message,
            contains('does not accept the standalone authoring selections'),
          );
          expect(config.readAsStringSync(), isNot(contains('agents.reviewer')));
        }
      },
    );

    test('the lifecycle request route cannot create a bound role', () async {
      final config = _config(fixture);
      final request =
          fixture.fs.file(
            fixture.fs.path.join(fixture.root.path, 'create.json'),
          )..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'create',
              'source': <String, Object?>{
                'kind': 'codex-role',
                'configFile': config.path,
                'roleKey': 'reviewer',
              },
              'ownership': 'both',
            }),
          );

      final result = await executor.execute([
        'agent',
        'adopt',
        '--request',
        request.path,
        '--harness',
        'codex',
        ..._context(fixture),
      ]);

      expect(result, isA<MambaFailureResult>());
      expect(
        (result as MambaFailureResult).message,
        contains('must match the selected command'),
      );
      expect(config.readAsStringSync(), isNot(contains('agents.reviewer')));
    });

    test(
      'the guided Codex creation collects the required description',
      () async {
        final answers = <String>[];
        final guided = GuidedAuthoringService(
          fileSystem: fixture.fs,
          terminal: () => true,
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
                  .writeAsStringSync('Review the selected change.\n');
              return const EditorProcessOutcome(started: true, exitCode: 0);
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
          ask: (label) async {
            answers.add(label);
            return 'Reviews the selected change.';
          },
          confirm: (summary) async => true,
        );
        final interactive = createExecutor(
          fileSystem: fixture.fs,
          guided: guided,
        ).fake();

        final result = await interactive.execute([
          'agent',
          'create',
          '--profile',
          'codex',
          '--name',
          'reviewer',
          '--body-text',
          'Review the selected change.',
          '--apply',
          '--yes',
          ..._context(fixture),
        ]);

        expect(
          result,
          isA<MambaSuccessResult>(),
          reason: result is MambaFailureResult ? result.message : null,
        );
        expect(answers, hasLength(1));
        expect(answers.single, contains('description'));
        expect((result as MambaSuccessResult).output, contains('published'));
        final definition = fixture.fs.file(
          fixture.fs.path.join(
            fixture.project.path,
            '.codex',
            'agents',
            'reviewer.toml',
          ),
        );
        expect(definition.existsSync(), isTrue);
        expect(
          definition.readAsStringSync(),
          contains('Reviews the selected change.'),
        );
      },
    );

    test('refuses a registration-only bound-role ownership', () async {
      final definition = _definition(fixture);
      final config = _config(fixture);

      final result = await executor.execute([
        'agent',
        'create',
        '--role-key',
        'reviewer',
        '--config-file',
        config.path,
        '--ownership',
        'registration',
        '--definition-source',
        definition.path,
        ..._context(fixture),
      ]);

      expect(
        result,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          4,
        ),
      );
      expect(
        (result as MambaFailureResult).message,
        contains('publishes a definition'),
      );
    });
  });
}

/// A resolver that finds every editor program.
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
