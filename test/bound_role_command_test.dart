import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/bound_role_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/agent_lifecycle_service.dart';
import 'package:agent_resource/src/services/parent_config_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

final class _Fixture {
  const _Fixture(this.fs, this.root, this.project, this.home, this.codex);

  final fslib.FileSystem fs;
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

fslib.File _definition(_Fixture fixture) =>
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

fslib.File _config(_Fixture fixture) =>
    fixture.fs.file(
        fixture.fs.path.join(fixture.project.path, '.codex', 'config.toml'),
      )
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '[agents.reviewer]\n'
        'description = "Reviews."\n'
        'config_file = "roles/reviewer.toml"\n',
      );

fslib.File _request(
  _Fixture fixture,
  String operation,
  BoundOwnership ownership, {
  String? source,
  String? installationId,
  String? planId,
}) {
  final config = fixture.fs.path.join(
    fixture.project.path,
    '.codex',
    'config.toml',
  );
  return fixture.fs.file(
    fixture.fs.path.join(fixture.root.path, '$operation-request.json'),
  )..writeAsStringSync(
    jsonEncode({
      'schemaVersion': 1,
      'operation': operation,
      'source': {
        'kind': 'codex-role',
        'configFile': config,
        'roleKey': 'reviewer',
      },
      'ownership': ownership.name,
      'definition': {'source': ?source, 'installationId': ?installationId},
      'planId': ?planId,
      if (operation == 'remove') 'affected': ['agents.reviewer'],
      'clientsStopped': true,
    }),
  );
}

Future<MambaSuccessResult> _success(MambaExecutionResult result) async {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'status', 0)
        .having((value) => value.output, 'output', isNotNull),
    reason: result is MambaFailureResult ? result.message : null,
  );
  return result as MambaSuccessResult;
}

Future<String> _planId(
  _Fixture fixture,
  String command,
  fslib.File request,
) async {
  final result = await _success(
    await createExecutor(
      agentLifecycle: AgentLifecycleService(fileSystem: fixture.fs),
      parentConfig: ParentConfigService(fileSystem: fixture.fs),
    ).fake().execute([
      'agent',
      command,
      '--request',
      request.path,
      ..._context(fixture),
      if (command == 'adopt') ...['--harness', 'codex'],
      '--clients-stopped',
      '--dry-run',
      '--format',
      'json',
    ]),
  );
  final envelope = jsonDecode(result.output!) as Map<String, Object?>;
  expect(envelope['outcome'], 'planned');
  return (envelope['data']! as Map<String, Object?>)['planId']! as String;
}

Future<MambaSuccessResult> _apply(
  _Fixture fixture,
  String command,
  File request,
) async => _success(
  await createExecutor(
    agentLifecycle: AgentLifecycleService(fileSystem: fixture.fs),
    parentConfig: ParentConfigService(fileSystem: fixture.fs),
  ).fake().execute([
    'agent',
    command,
    '--request',
    request.path,
    ..._context(fixture),
    if (command == 'adopt') ...['--harness', 'codex'],
    '--yes',
    '--clients-stopped',
    '--format',
    'json',
  ]),
);

Future<String> _adopt(_Fixture fixture) async {
  _definition(fixture);
  final config = _config(fixture);
  final service = BoundRoleService(fileSystem: fixture.fs);
  final request = BoundRoleRequest(
    operation: BoundOperation.adopt,
    configFile: config.path,
    roleKey: 'reviewer',
    ownership: BoundOwnership.both,
    clientsStopped: true,
  );
  final options = _options(fixture);
  final planned = await service.run(request, options);
  final adopted = await service.run(
    BoundRoleRequest(
      operation: request.operation,
      configFile: request.configFile,
      roleKey: request.roleKey,
      ownership: request.ownership,
      planId: planned.data['planId']! as String,
      clientsStopped: true,
    ),
    options,
  );
  return adopted.data['installationId']! as String;
}

void main() {
  group('agent_resource', () {
    group('agent', () {
      group('adopt', () {
        test(
          'request publishes a referenced definition and registration',
          () async {
            final fixture = await _fixture();
            try {
              _definition(fixture);
              _config(fixture);
              final request = _request(fixture, 'adopt', BoundOwnership.both);
              final id = await _planId(fixture, 'adopt', request);
              final applied = await _apply(
                fixture,
                'adopt',
                _request(fixture, 'adopt', BoundOwnership.both, planId: id),
              );
              final envelope =
                  jsonDecode(applied.output!) as Map<String, Object?>;
              expect(envelope['outcome'], 'adopted');
              expect(
                fixture.fs
                    .file(
                      fixture.fs.path.join(
                        fixture.project.path,
                        '.codex',
                        'roles',
                        'reviewer.toml',
                      ),
                    )
                    .existsSync(),
                isTrue,
              );
            } finally {
              await fixture.root.delete(recursive: true);
            }
          },
        );
      });

      group('replace', () {
        test(
          'request replaces only the selected definition and registration',
          () async {
            final fixture = await _fixture();
            try {
              final id = await _adopt(fixture);
              final replacement =
                  fixture.fs.file(
                    fixture.fs.path.join(fixture.root.path, 'replacement.toml'),
                  )..writeAsStringSync(
                    'name = "reviewer"\ndescription = "Replacement."\n'
                    'developer_instructions = "Replacement body."\n',
                  );
              final idPlan = await _planId(
                fixture,
                'replace',
                _request(
                  fixture,
                  'replace',
                  BoundOwnership.both,
                  source: replacement.path,
                  installationId: id,
                ),
              );
              final applied = await _apply(
                fixture,
                'replace',
                _request(
                  fixture,
                  'replace',
                  BoundOwnership.both,
                  source: replacement.path,
                  installationId: id,
                  planId: idPlan,
                ),
              );
              final envelope =
                  jsonDecode(applied.output!) as Map<String, Object?>;
              expect(envelope['outcome'], 'replaced');
              final definition = fixture.fs.file(
                fixture.fs.path.join(
                  fixture.project.path,
                  '.codex',
                  'roles',
                  'reviewer.toml',
                ),
              );
              expect(
                definition.readAsStringSync(),
                contains('Replacement body'),
              );
              expect(
                fixture.fs
                    .file(
                      fixture.fs.path.join(
                        fixture.project.path,
                        '.codex',
                        'config.toml',
                      ),
                    )
                    .readAsStringSync(),
                contains('description = "Replacement."'),
              );
            } finally {
              await fixture.root.delete(recursive: true);
            }
          },
        );
      });

      group('remove', () {
        test(
          'request removes registration but preserves the definition',
          () async {
            final fixture = await _fixture();
            try {
              final id = await _adopt(fixture);
              final idPlan = await _planId(
                fixture,
                'remove',
                _request(
                  fixture,
                  'remove',
                  BoundOwnership.registration,
                  installationId: id,
                ),
              );
              final applied = await _apply(
                fixture,
                'remove',
                _request(
                  fixture,
                  'remove',
                  BoundOwnership.registration,
                  installationId: id,
                  planId: idPlan,
                ),
              );
              final envelope =
                  jsonDecode(applied.output!) as Map<String, Object?>;
              expect(envelope['outcome'], 'removed');
              final definition = fixture.fs.file(
                fixture.fs.path.join(
                  fixture.project.path,
                  '.codex',
                  'roles',
                  'reviewer.toml',
                ),
              );
              expect(definition.existsSync(), isTrue);
              expect(definition.readAsStringSync(), contains('Original.'));
              expect(
                fixture.fs
                    .file(
                      fixture.fs.path.join(
                        fixture.project.path,
                        '.codex',
                        'config.toml',
                      ),
                    )
                    .readAsStringSync(),
                isNot(contains('[agents.reviewer]')),
              );
            } finally {
              await fixture.root.delete(recursive: true);
            }
          },
        );
      });
    });
  });
}
