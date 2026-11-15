import 'package:agent_resource/src/authoring/bound_role_authoring_inputs.dart';
import 'package:agent_resource/src/services/agent_authoring_service.dart';
import 'package:agent_resource/src/services/bound_role_authoring_service.dart';
import 'package:agent_resource/src/services/bound_role_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

final class _Fixture {
  const _Fixture(this.fs, this.root, this.project, this.home, this.codex);

  final fslib.FileSystem fs;
  final fslib.Directory root;
  final fslib.Directory project;
  final fslib.Directory home;
  final fslib.Directory codex;

  String path(String relative) => fs.path.join(project.path, relative);
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

fslib.File _config(_Fixture fixture, {String content = 'model = "gpt-5"\n'}) =>
    fixture.fs.file(fixture.path('.codex/config.toml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);

fslib.File _definition(_Fixture fixture) =>
    fixture.fs.file(fixture.path('roles/reviewer.toml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'name = "reviewer"\ndescription = "Reviews changes."\n'
        'developer_instructions = "Review the diff."\n',
      );

LifecycleOptions _options(_Fixture fixture, {bool approved = true}) =>
    LifecycleOptions(
      processWorkingDirectory: fixture.project.path,
      scope: LifecycleScope.project,
      cwd: fixture.project.path,
      projectRoot: fixture.project.path,
      home: fixture.home.path,
      codexHome: fixture.codex.path,
      approved: approved,
    );

BoundRoleAuthoringInputs _inputs(
  _Fixture fixture, {
  BoundOwnership ownership = BoundOwnership.both,
  bool clientsStopped = true,
  String? definitionSource,
  String? definitionOutput,
}) => parseBoundRoleAuthoringInputs(
  roleKey: 'reviewer',
  configFile: fixture.path('.codex/config.toml'),
  ownership: ownership.name,
  definitionSource: definitionSource ?? fixture.path('roles/reviewer.toml'),
  definitionOutput:
      definitionOutput ?? fixture.path('.codex/agents/reviewer.toml'),
  clientsStopped: clientsStopped,
);

void main() {
  group('bound-role authoring', () {
    test(
      'an explicit create publishes the definition and registers the role',
      () async {
        final fixture = await _fixture();
        try {
          _config(fixture);
          _definition(fixture);
          final service = BoundRoleAuthoringService(fileSystem: fixture.fs);
          final inputs = _inputs(fixture);

          final planned = await service.plan(inputs, _options(fixture));
          expect(planned.outcome, 'planned');
          expect(planned.data['writes'], isFalse);
          expect(
            fixture.fs
                .file(fixture.path('.codex/agents/reviewer.toml'))
                .existsSync(),
            isFalse,
            reason: 'planning must not publish the definition',
          );
          expect(
            fixture.fs
                .file(fixture.path('.codex/config.toml'))
                .readAsStringSync(),
            isNot(contains('[agents.reviewer]')),
            reason: 'planning must not register the role',
          );

          final applied = await service.apply(
            inputs,
            _options(fixture),
            planId: planned.data['planId']! as String,
          );
          expect(applied.outcome, 'created');
          expect(
            fixture.fs
                .file(fixture.path('.codex/agents/reviewer.toml'))
                .readAsStringSync(),
            contains('Review the diff.'),
          );
          final config = fixture.fs
              .file(fixture.path('.codex/config.toml'))
              .readAsStringSync();
          expect(config, contains('[agents.reviewer]'));
          expect(config, contains('config_file = "agents/reviewer.toml"'));
          expect(config, contains('model = "gpt-5"'));
        } finally {
          await fixture.root.delete(recursive: true);
        }
      },
    );

    test('a registration without the stopped-client acknowledgement is refused '
        'before any effect', () async {
      final fixture = await _fixture();
      try {
        _config(fixture);
        _definition(fixture);
        final service = BoundRoleAuthoringService(fileSystem: fixture.fs);
        final inputs = _inputs(fixture, clientsStopped: false);
        final planned = await service.plan(inputs, _options(fixture));

        await expectLater(
          service.apply(
            inputs,
            _options(fixture),
            planId: planned.data['planId']! as String,
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'exit code', 4)
                .having(
                  (error) => error.message,
                  'message',
                  contains('clients-stopped acknowledgement'),
                ),
          ),
        );
        expect(
          fixture.fs
              .file(fixture.path('.codex/agents/reviewer.toml'))
              .existsSync(),
          isFalse,
        );
        expect(
          fixture.fs
              .file(fixture.path('.codex/config.toml'))
              .readAsStringSync(),
          isNot(contains('[agents.reviewer]')),
        );
      } finally {
        await fixture.root.delete(recursive: true);
      }
    });

    test('a stale plan identity is refused before any effect', () async {
      final fixture = await _fixture();
      try {
        _config(fixture);
        _definition(fixture);
        final service = BoundRoleAuthoringService(fileSystem: fixture.fs);
        final inputs = _inputs(fixture);

        await expectLater(
          service.apply(inputs, _options(fixture), planId: 'stale-plan'),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'exit code', 4)
                .having(
                  (error) => error.message,
                  'message',
                  contains('does not match current evidence'),
                ),
          ),
        );
        expect(
          fixture.fs
              .file(fixture.path('.codex/agents/reviewer.toml'))
              .existsSync(),
          isFalse,
        );
        expect(
          fixture.fs
              .file(fixture.path('.codex/config.toml'))
              .readAsStringSync(),
          isNot(contains('[agents.reviewer]')),
        );
      } finally {
        await fixture.root.delete(recursive: true);
      }
    });

    test(
      'a changed reviewed candidate is refused by the plan identity',
      () async {
        final fixture = await _fixture();
        try {
          _config(fixture);
          _definition(fixture);
          final service = BoundRoleAuthoringService(fileSystem: fixture.fs);
          fixture.fs.file(fixture.path('roles/other.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              'name = "other"\ndescription = "Other."\n'
              'developer_instructions = "Other body."\n',
            );
          final planned = await service.plan(
            _inputs(fixture),
            _options(fixture),
          );

          await expectLater(
            service.apply(
              _inputs(
                fixture,
                definitionSource: fixture.path('roles/other.toml'),
              ),
              _options(fixture),
              planId: planned.data['planId']! as String,
            ),
            throwsA(
              isA<MambaException>().having(
                (error) => error.message,
                'message',
                contains('does not match current evidence'),
              ),
            ),
          );
          expect(
            fixture.fs
                .file(fixture.path('.codex/agents/reviewer.toml'))
                .existsSync(),
            isFalse,
          );
        } finally {
          await fixture.root.delete(recursive: true);
        }
      },
    );

    test('an operation document is refused as a definition source', () async {
      final fixture = await _fixture();
      try {
        _config(fixture);
        final request = fixture.fs.file(fixture.path('request.json'))
          ..writeAsStringSync('{"schemaVersion": 1, "operation": "create"}');
        final service = BoundRoleAuthoringService(fileSystem: fixture.fs);
        final inputs = _inputs(fixture, definitionSource: request.path);

        await expectLater(
          service.plan(inputs, _options(fixture)),
          throwsA(isA<MambaException>()),
        );
        expect(
          fixture.fs
              .file(fixture.path('.codex/agents/reviewer.toml'))
              .existsSync(),
          isFalse,
        );
        expect(
          fixture.fs
              .file(fixture.path('.codex/config.toml'))
              .readAsStringSync(),
          isNot(contains('[agents.reviewer]')),
        );
      } finally {
        await fixture.root.delete(recursive: true);
      }
    });

    test('an existing role registration is not adopted implicitly', () async {
      final fixture = await _fixture();
      try {
        _config(
          fixture,
          content:
              'model = "gpt-5"\n\n'
              '[agents.reviewer]\n'
              'description = "Existing."\n'
              'config_file = "agents/other.toml"\n',
        );
        _definition(fixture);
        fixture.fs.file(fixture.path('.codex/agents/other.toml'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'name = "other"\ndescription = "Existing."\n'
            'developer_instructions = "Existing role."\n',
          );
        final service = BoundRoleAuthoringService(fileSystem: fixture.fs);
        final inputs = _inputs(fixture);

        await expectLater(
          service.plan(inputs, _options(fixture)),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('requires explicit adoption'),
            ),
          ),
        );
        expect(
          fixture.fs
              .file(fixture.path('.codex/config.toml'))
              .readAsStringSync(),
          contains('config_file = "agents/other.toml"'),
        );
        expect(
          fixture.fs
              .file(fixture.path('.codex/agents/reviewer.toml'))
              .existsSync(),
          isFalse,
        );
      } finally {
        await fixture.root.delete(recursive: true);
      }
    });

    test(
      'a definition-only ownership publishes no parent registration',
      () async {
        final fixture = await _fixture();
        try {
          _config(fixture);
          _definition(fixture);
          final service = BoundRoleAuthoringService(fileSystem: fixture.fs);
          final inputs = _inputs(
            fixture,
            ownership: BoundOwnership.definition,
            clientsStopped: false,
          );
          final planned = await service.plan(inputs, _options(fixture));
          final applied = await service.apply(
            inputs,
            _options(fixture),
            planId: planned.data['planId']! as String,
          );

          expect(applied.outcome, 'created');
          expect(
            fixture.fs
                .file(fixture.path('.codex/agents/reviewer.toml'))
                .existsSync(),
            isTrue,
          );
          expect(
            fixture.fs
                .file(fixture.path('.codex/config.toml'))
                .readAsStringSync(),
            isNot(contains('[agents.reviewer]')),
          );
        } finally {
          await fixture.root.delete(recursive: true);
        }
      },
    );
  });

  group('shared guided integration', () {
    test(
      'a reviewed shared definition is published and registered as a role',
      () async {
        final fixture = await _fixture();
        try {
          _config(fixture);
          final shared = AgentAuthoringService(fileSystem: fixture.fs);
          final request = AuthoringRequest(
            operation: AuthoringOperation.create,
            source: null,
            base: null,
            target: <String, Object?>{
              'harness': 'codex',
              'destination': 'native',
            },
            definition: const <String, Object?>{
              'name': 'reviewer',
              'description': 'Reviews changes.',
            },
            instructions: const <String>['Review the diff.'],
            baseInstructions: 'include',
            decisions: const <String>{},
            references: const <String, String>{},
            context: fixture.project.path,
          );
          final reviewed = await shared.plan(request, _options(fixture));
          final candidate = fixture.fs.file(fixture.path('draft/reviewer.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync(reviewed.content);

          final service = BoundRoleAuthoringService(fileSystem: fixture.fs);
          final inputs = parseBoundRoleAuthoringInputs(
            roleKey: 'reviewer',
            configFile: fixture.path('.codex/config.toml'),
            ownership: 'both',
            definitionSource: candidate.path,
            definitionOutput: reviewed.output,
            clientsStopped: true,
          );
          final planned = await service.plan(inputs, _options(fixture));
          final applied = await service.apply(
            inputs,
            _options(fixture),
            planId: planned.data['planId']! as String,
          );

          expect(applied.outcome, 'created');
          expect(
            fixture.fs.file(reviewed.output).readAsStringSync(),
            contains('Review the diff.'),
          );
          final config = fixture.fs
              .file(fixture.path('.codex/config.toml'))
              .readAsStringSync();
          expect(config, contains('[agents.reviewer]'));
          expect(config, contains('config_file = "agents/reviewer.toml"'));
        } finally {
          await fixture.root.delete(recursive: true);
        }
      },
    );
  });

  group('standalone authoring', () {
    test('an ordinary create leaves the declaring config unchanged', () async {
      final fixture = await _fixture();
      try {
        _config(fixture);
        final service = AgentAuthoringService(fileSystem: fixture.fs);
        final request = AuthoringRequest(
          operation: AuthoringOperation.create,
          source: null,
          base: null,
          target: <String, Object?>{
            'harness': 'codex',
            'output': fixture.path('.codex/agents/reviewer.toml'),
            'destination': 'native',
          },
          definition: const <String, Object?>{
            'name': 'reviewer',
            'description': 'Reviews changes.',
          },
          instructions: const <String>['Review the diff.'],
          baseInstructions: 'include',
          decisions: const <String>{},
          references: const <String, String>{},
          context: fixture.project.path,
        );

        final planned = await service.plan(request, _options(fixture));
        final applied = await service.run(
          request,
          _options(fixture),
          apply: true,
          planId: planned.result.data['planId']! as String,
        );

        expect(applied.outcome, isNotNull);
        expect(
          fixture.fs
              .file(fixture.path('.codex/agents/reviewer.toml'))
              .existsSync(),
          isTrue,
        );
        expect(
          fixture.fs
              .file(fixture.path('.codex/config.toml'))
              .readAsStringSync(),
          isNot(contains('[agents.reviewer]')),
        );
      } finally {
        await fixture.root.delete(recursive: true);
      }
    });
  });
}
