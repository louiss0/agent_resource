import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
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
