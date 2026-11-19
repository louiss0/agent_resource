import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/agent_inspection.dart';
import 'package:agent_resource/src/services/agent_graph_service.dart';
import 'package:agent_resource/src/services/agent_installation_service.dart';
import 'package:agent_resource/src/services/agent_lifecycle_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:file/file.dart' as fs;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

import 'support/installation_test_support.dart';

const _privateBody = 'ANTIGRAVITY-PRIVATE-BODY-2b17 keep me private.';

String _definition(
  String name, {
  String description = 'Reviews changes.',
  String tools = '[read, grep]',
  String? mainAgent = 'false',
  String extra = '',
  String body = _privateBody,
}) {
  final buffer = StringBuffer('---\n')
    ..write('name: $name\n')
    ..write('description: $description\n')
    ..write('tools: $tools\n');
  if (mainAgent != null) buffer.write('mainAgent: $mainAgent\n');
  buffer
    ..write(extra)
    ..write('---\n')
    ..write(body);
  return buffer.toString();
}

Future<T> _withSandbox<T>(Future<T> Function(fs.FileSystem) body) async {
  final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
  for (final path in [
    '/sandbox',
    '/sandbox/project',
    '/sandbox/home',
    '/sandbox/state',
    '/sandbox/source',
  ]) {
    fileSystem.directory(path).createSync(recursive: true);
  }
  return body(fileSystem);
}

void _write(fs.FileSystem fileSystem, String path, String content) {
  final file = fileSystem.file(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

List<String> _context(fs.FileSystem fileSystem) => [
  '--cwd',
  '/sandbox/project/',
  '--project-root',
  '/sandbox/project/',
  '--home',
  '/sandbox/home/',
  '--state-dir',
  '/sandbox/state/',
];

List<String> _lifecycleArgs() => const <String>[
  '--scope',
  'project',
  '--cwd',
  '/sandbox/project/',
  '--project-root',
  '/sandbox/project/',
  '--home',
  '/sandbox/home/',
  '--state-dir',
  '/sandbox/state/',
];

Executor _installationExecutor(
  fs.FileSystem fileSystem, {
  LifecycleStateService? state,
}) {
  final lifecycle = AgentLifecycleService(fileSystem: fileSystem, state: state);
  return createExecutor(
    fileSystem: fileSystem,
    agentLifecycle: lifecycle,
    agentInstallation: AgentInstallationService(
      fileSystem: fileSystem,
      lifecycle: lifecycle,
      interaction: ScriptedInstallationInteraction(),
      progress: noInstallationProgress,
    ),
  );
}

Map<String, Object?> _successData(MambaExecutionResult result) {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', isNotNull),
    reason: result is MambaFailureResult ? result.message : null,
  );
  return (jsonDecode(
    (result as MambaSuccessResult).output!,
  ) as Map<Object?, Object?>).cast<String, Object?>();
}

void main() {
  group('agent_resource Antigravity agents', () {
    test(
      'discovers flat and one-level nested definitions in both scopes',
      () async {
        await _withSandbox((fileSystem) async {
          final p = fileSystem.path;
          _write(
            fileSystem,
            p.join('/sandbox/project', '.agents', 'agents', 'reviewer.md'),
            _definition('reviewer'),
          );
          _write(
            fileSystem,
            p.join(
              '/sandbox/project',
              '.agents',
              'agents',
              'helper',
              'agent.md',
            ),
            _definition('helper'),
          );
          _write(
            fileSystem,
            p.join(
              '/sandbox/project',
              '.agents',
              'agents',
              'helper',
              'notes.md',
            ),
            _definition('ignored-note'),
          );
          _write(
            fileSystem,
            p.join(
              '/sandbox/project',
              '.agents',
              'agents',
              'too-deep',
              'nested',
              'agent.md',
            ),
            _definition('ignored-deep'),
          );
          _write(
            fileSystem,
            p.join('/sandbox/home', '.gemini', 'config', 'agents', 'user.md'),
            _definition('user'),
          );
          _write(
            fileSystem,
            p.join(
              '/sandbox/home',
              '.gemini',
              'config',
              'agents',
              'user-nested',
              'agent.md',
            ),
            _definition('user-nested'),
          );
          final result =
              await createExecutor(
                fileSystem: fileSystem,
                agentLifecycle: AgentLifecycleService(fileSystem: fileSystem),
              ).fake().execute([
                'agent',
                'list',
                '--scope',
                'all',
                '--harness',
                'antigravity',
                '--format',
                'json',
                ..._context(fileSystem),
              ]);
          final envelope = _successData(result);
          final data = envelope['data']! as Map<Object?, Object?>;
          final occurrences = (data['occurrences']! as List<Object?>)
              .cast<Map<Object?, Object?>>();
          expect(occurrences.map((occurrence) => occurrence['path']), <String>[
            '/sandbox/home/.gemini/config/agents/user-nested/agent.md',
            '/sandbox/home/.gemini/config/agents/user.md',
            '/sandbox/project/.agents/agents/helper/agent.md',
            '/sandbox/project/.agents/agents/reviewer.md',
          ]);
          expect(
            occurrences.map((occurrence) => occurrence['layout']),
            <String>['nested', 'flat', 'nested', 'flat'],
          );
          expect(
            occurrences.every(
              (occurrence) =>
                  occurrence['harness'] == 'antigravity' &&
                  (occurrence['validation']!
                          as Map<Object?, Object?>)['status'] ==
                      'passed',
            ),
            isTrue,
          );
          expect(data['collisions'], isEmpty);
          expect(envelope['diagnostics'], isEmpty);
        });
      },
    );

    test(
      'flags same-target layout collisions without leaking unknown values',
      () async {
        await _withSandbox((fileSystem) async {
          const secret = 'SECRET-UNKNOWN-9f2b';
          final p = fileSystem.path;
          _write(
            fileSystem,
            p.join('/sandbox/project', '.agents', 'agents', 'same.md'),
            _definition(
              'alpha',
              extra: 'internalNote: $secret\n',
              body: 'PRIVATE-FLAT-BODY\n',
            ),
          );
          _write(
            fileSystem,
            p.join('/sandbox/project', '.agents', 'agents', 'same', 'agent.md'),
            _definition('beta', body: 'PRIVATE-NESTED-BODY\n'),
          );
          final result =
              await createExecutor(
                fileSystem: fileSystem,
                agentLifecycle: AgentLifecycleService(fileSystem: fileSystem),
              ).fake().execute([
                'agent',
                'list',
                '--scope',
                'project',
                '--harness',
                'antigravity',
                '--format',
                'json',
                ..._context(fileSystem),
              ]);
          final envelope = _successData(result);
          final output = (result as MambaSuccessResult).output!;
          final data = envelope['data']! as Map<Object?, Object?>;
          final collisions = (data['collisions']! as List<Object?>)
              .cast<Map<Object?, Object?>>();
          expect(collisions, hasLength(1));
          expect(collisions.single['harness'], 'antigravity');
          expect(collisions.single['comparisonName'], 'same');
          expect(collisions.single['layouts'], ['flat', 'nested']);
          expect(collisions.single['occurrenceIds'], hasLength(2));
          final diagnostics = (envelope['diagnostics']! as List<Object?>)
              .cast<Map<Object?, Object?>>();
          expect(
            diagnostics.map((diagnostic) => diagnostic['code']),
            contains('AGENT_NAME_COLLISION'),
          );
          expect(
            diagnostics.map((diagnostic) => diagnostic['field']),
            contains('internalNote'),
          );
          expect(output, isNot(contains(secret)));
          expect(output, isNot(contains('PRIVATE-FLAT-BODY')));
          expect(output, isNot(contains('PRIVATE-NESTED-BODY')));
        });
      },
    );

    test(
      'inspection validates the schema, graphs tools, and withholds body',
      () async {
        await _withSandbox((fileSystem) async {
          const hiddenValue = 'UNREPORTED-FRONTMATTER-VALUE-7c11';
          const body = 'PRIVATE-INSPECTION-BODY\n';
          final source = fileSystem.file('/sandbox/source/reviewer.md');
          source.writeAsStringSync(
            _definition(
              'reviewer',
              tools: '[read, grep]',
              mainAgent: 'true',
              extra: 'privateSetting: $hiddenValue\n',
              body: body,
            ),
          );
          final result =
              await createExecutor(
                fileSystem: fileSystem,
                agentGraph: AgentGraphService(fileSystem: fileSystem),
              ).fake().execute([
                'agent',
                'inspect',
                source.path,
                '--harness',
                'antigravity',
                '--format',
                'json',
                '--cwd',
                '/sandbox/project/',
              ]);
          final envelope = _successData(result);
          final output = (result as MambaSuccessResult).output!;
          final data = envelope['data']! as Map<Object?, Object?>;
          expect(data['form'], 'antigravity-agent-file');
          expect(data['profile'], 'antigravity-agent-native-v1');
          expect(
            (data['validation']! as Map<Object?, Object?>)['status'],
            'passed',
          );
          expect(
            (data['instructions']! as Map<Object?, Object?>)['present'],
            isTrue,
          );
          expect(
            (data['instructions']! as Map<Object?, Object?>)['text'],
            isNull,
          );
          final diagnostics = (envelope['diagnostics']! as List<Object?>)
              .cast<Map<Object?, Object?>>();
          expect(
            diagnostics.map((diagnostic) => diagnostic['code']),
            contains('UNKNOWN_FIELD'),
          );
          final graph = data['graph']! as Map<Object?, Object?>;
          expect(graph['ready'], isTrue);
          final edges = (graph['edges']! as List<Object?>)
              .cast<Map<Object?, Object?>>();
          expect(
            edges.map((edge) => edge['kind']),
            contains('tool-capability'),
          );
          final capabilities = (graph['capabilities']! as List<Object?>)
              .cast<Map<Object?, Object?>>();
          expect(
            capabilities.map((capability) => capability['kind']),
            containsAll(<String>['tool-allowlist', 'main-agent']),
          );
          expect(output, isNot(contains(hiddenValue)));
          expect(output, isNot(contains(body.trim())));
        });
      },
    );

    test(
      'show-instructions is inspect-only and validation stays private',
      () async {
        await _withSandbox((fileSystem) async {
          const body = 'SHOWN-ONLY-ON-INSPECT-4a91\n';
          final source = fileSystem.file('/sandbox/source/reviewer.md');
          source.writeAsStringSync(
            _definition('reviewer', mainAgent: null, body: body),
          );
          final shown =
              await createExecutor(
                fileSystem: fileSystem,
                agentGraph: AgentGraphService(fileSystem: fileSystem),
              ).fake().execute([
                'agent',
                'inspect',
                source.path,
                '--harness',
                'antigravity',
                '--show-instructions',
                '--format',
                'json',
                '--cwd',
                '/sandbox/project/',
              ]);
          final shownEnvelope = _successData(shown);
          final shownInstructions =
              ((shownEnvelope['data']!
                      as Map<Object?, Object?>)['instructions']!
                  as Map<Object?, Object?>)['text'];
          expect(shownInstructions, body);
          expect((shown as MambaSuccessResult).output, contains(body.trim()));

          final validated = await createExecutor(fileSystem: fileSystem)
              .fake()
              .execute([
                'agent',
                'validate',
                source.path,
                '--harness',
                'antigravity',
                '--format',
                'json',
                '--cwd',
                '/sandbox/project/',
              ]);
          final validatedEnvelope = _successData(validated);
          expect(
            ((validatedEnvelope['data']!
                    as Map<Object?, Object?>)['instructions']!
                as Map<Object?, Object?>)['text'],
            isNull,
          );
          expect(
            (validated as MambaSuccessResult).output,
            isNot(contains(body.trim())),
          );

          final rejected = await createExecutor(fileSystem: fileSystem)
              .fake()
              .execute([
                'agent',
                'validate',
                source.path,
                '--harness',
                'antigravity',
                '--show-instructions',
              ]);
          expect(
            rejected,
            isA<MambaFailureResult>()
                .having(
                  (value) => value.error.phase,
                  'phase',
                  MambaExecutionPhase.parse,
                )
                .having((value) => value.output, 'output', isNull),
          );
        });
      },
    );

    test('validation refuses malformed tools and boolean fields', () async {
      await _withSandbox((fileSystem) async {
        const hiddenValue = 'UNREPORTED-SCHEMA-VALUE-2d31';
        const body = 'PRIVATE-VALIDATION-BODY\n';
        final source = fileSystem.file('/sandbox/source/broken.md');
        source.writeAsStringSync(
          _definition(
            'broken',
            tools: 'read, grep',
            mainAgent: 'perhaps',
            extra: 'privateSetting: $hiddenValue\n',
            body: body,
          ),
        );
        final result = await createExecutor(fileSystem: fileSystem)
            .fake()
            .execute([
              'agent',
              'validate',
              source.path,
              '--harness',
              'antigravity',
              '--format',
              'json',
              '--cwd',
              '/sandbox/project/',
            ]);
        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', 2)
              .having((value) => value.output, 'output', isNull),
        );
        final message = (result as MambaFailureResult).message;
        expect(message, contains('TOOLS_FORM'));
        expect(message, contains('MAIN_AGENT_TYPE'));
        expect(message, contains('UNKNOWN_FIELD'));
        expect(message, isNot(contains(hiddenValue)));
        expect(message, isNot(contains(body.trim())));
      });
    });

    for (final layout in const ['flat', 'nested']) {
      test(
        'agent install publishes the $layout layout as a regular file',
        () async {
          await _withSandbox((fileSystem) async {
            final sourcePath = layout == 'flat'
                ? '/sandbox/source/reviewer.md'
                : '/sandbox/source/reviewer/agent.md';
            _write(fileSystem, sourcePath, _definition('reviewer'));
            final source = fileSystem.file(sourcePath);
            final result = await _installationExecutor(fileSystem)
                .fake()
                .execute([
                  'agent',
                  'install',
                  source.path,
                  '--source-kind',
                  'resource',
                  '--profile',
                  'antigravity',
                  '--target',
                  'antigravity',
                  ..._lifecycleArgs(),
                  '--yes',
                  '--format',
                  'json',
                ]);
            final envelope = _successData(result);
            final unit =
                ((envelope['data']! as Map<Object?, Object?>)['units']!
                            as List<Object?>)
                        .single
                    as Map<Object?, Object?>;
            expect(unit['profile'], 'antigravity');
            expect(unit['nativeName'], 'reviewer');
            final destination = fileSystem.file(
              '/sandbox/project/.agents/agents/reviewer.md',
            );
            expect(destination.existsSync(), isTrue);
            expect(destination.readAsBytesSync(), source.readAsBytesSync());
          });
        },
      );
    }

    test('installation refuses a strict same-target name collision', () async {
      await _withSandbox((fileSystem) async {
        final root = '/sandbox/project/.agents/agents';
        _write(fileSystem, '$root/taken.md', _definition('reviewer'));
        _write(fileSystem, '$root/taken/agent.md', _definition('reviewer'));
        final source = '/sandbox/source/reviewer.md';
        _write(fileSystem, source, _definition('reviewer'));
        final result = await _installationExecutor(fileSystem).fake().execute([
          'agent',
          'install',
          source,
          '--source-kind',
          'resource',
          '--profile',
          'antigravity',
          '--target',
          'antigravity',
          ..._lifecycleArgs(),
          '--dry-run',
          '--format',
          'json',
        ]);
        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'exit code', 4)
              .having((value) => value.output, 'output', isNull)
              .having(
                (value) => value.message,
                'message',
                contains('conflicts'),
              ),
        );
        expect(fileSystem.file('$root/reviewer.md').existsSync(), isFalse);
      });
    });

    test(
      'adopt, replace, remove, and retained backups support nested files',
      () async {
        await _withSandbox((fileSystem) async {
          final nested = '/sandbox/project/.agents/agents/team/agent.md';
          final first = _definition('team', body: 'FIRST-BODY\n');
          _write(fileSystem, nested, first);
          final adopted = await _installationExecutor(fileSystem)
              .fake()
              .execute([
                'agent',
                'adopt',
                nested,
                '--harness',
                'antigravity',
                '--destination',
                'native',
                ..._lifecycleArgs(),
                '--yes',
                '--format',
                'json',
              ]);
          final adoptedData =
              _successData(adopted)['data']! as Map<Object?, Object?>;
          final installationId = adoptedData['installationId']! as String;
          expect(installationId, isNotEmpty);

          final replacement = '/sandbox/source/replacement.md';
          final second = _definition('team', body: 'SECOND-BODY\n');
          _write(fileSystem, replacement, second);
          final replaced = await _installationExecutor(fileSystem)
              .fake()
              .execute([
                'agent',
                'replace',
                installationId,
                replacement,
                '--harness',
                'antigravity',
                ..._lifecycleArgs(),
                '--yes',
                '--format',
                'json',
              ]);
          final replacedData =
              _successData(replaced)['data']! as Map<Object?, Object?>;
          expect(replacedData['backupRetained'], isTrue);
          final backupId = replacedData['backupId']! as String;
          expect(fileSystem.file(nested).readAsStringSync(), second);

          final backups = await _installationExecutor(fileSystem)
              .fake()
              .execute([
                'agent',
                'backup',
                'list',
                ..._lifecycleArgs(),
                '--format',
                'json',
              ]);
          final backupData =
              _successData(backups)['data']! as Map<Object?, Object?>;
          expect(
            (backupData['backups']! as List<Object?>)
                .cast<Map<Object?, Object?>>()
                .map((backup) => backup['backupId']),
            contains(backupId),
          );

          final removed = await _installationExecutor(fileSystem)
              .fake()
              .execute([
                'agent',
                'remove',
                installationId,
                ..._lifecycleArgs(),
                '--yes',
                '--format',
                'json',
              ]);
          expect(_successData(removed)['outcome'], 'removed');
          expect(fileSystem.file(nested).existsSync(), isFalse);
        });
      },
    );

    test(
      'pack Agent installation publishes nested sources in the flat layout',
      () async {
        await _withSandbox((fileSystem) async {
          final p = fileSystem.path;
          for (final path in [
            '/sandbox/home/AppData/Roaming',
            '/sandbox/home/AppData/Local',
          ]) {
            fileSystem.directory(path).createSync(recursive: true);
          }
          _write(
            fileSystem,
            '/sandbox/source/agent-resources.toml',
            'schema_version = 1\n'
                '[[catalog.agents]]\n'
                'path = "agents/nested/agent.md"\n'
                'profile = "antigravity"\n',
          );
          final source = _definition('nested', body: 'PACK-BODY\n');
          _write(fileSystem, '/sandbox/source/agents/nested/agent.md', source);
          _write(
            fileSystem,
            '/sandbox/project/agent-resources.toml',
            'schema_version = 1\n'
                '[packs."local/demo".source]\n'
                'kind = "local"\n'
                'path = "../source"\n'
                '[packs."local/demo".update]\n'
                'track = { kind = "local" }\n',
          );
          final result = await PackLifecycleService(fileSystem: fileSystem)
              .execute(
                PackLifecycleRequest(
                  operation: PackOperation.install,
                  resourceType: PackResourceType.agent,
                  resourceTypes: const <PackResourceType>[],
                  pack: 'local/demo',
                  processWorkingDirectory: '/sandbox',
                  environment: <String, String>{
                    'HOME': '/sandbox/home',
                    'USERPROFILE': '/sandbox/home',
                    'APPDATA': p.join('/sandbox/home', 'AppData', 'Roaming'),
                    'LOCALAPPDATA': p.join('/sandbox/home', 'AppData', 'Local'),
                  },
                  scope: LifecycleScope.project,
                  cwd: '/sandbox/project',
                  projectRoot: '/sandbox/project',
                  home: '/sandbox/home',
                  stateDir: '/sandbox/state',
                  yes: true,
                ),
              );
          expect(result.resources.single.disposition.wireName, 'installed');
          final destination = fileSystem.file(
            '/sandbox/project/.agents/agents/nested.md',
          );
          expect(destination.existsSync(), isTrue);
          expect(destination.readAsStringSync(), source);
        });
      },
    );

    test(
      'an interrupted installation is recoverable for Antigravity',
      () async {
        await _withSandbox((fileSystem) async {
          final source = '/sandbox/source/recovery.md';
          _write(fileSystem, source, _definition('recovery'));
          final io = _InterruptingIO(fileSystem);
          final state = LifecycleStateService(io: io);
          final service = AgentLifecycleService(
            fileSystem: fileSystem,
            state: state,
          );
          final options = LifecycleOptions(
            processWorkingDirectory: '/sandbox/project',
            scope: LifecycleScope.project,
            cwd: '/sandbox/project',
            projectRoot: '/sandbox/project',
            home: '/sandbox/home',
            stateDir: '/sandbox/state',
          );
          await expectLater(
            service.install(
              AgentInstallInput(
                options: options,
                source: source,
                harness: AgentHarness.antigravity,
              ),
            ),
            throwsA(
              isA<MambaException>().having(
                (error) => error.exitCode,
                'exit code',
                6,
              ),
            ),
          );
          io.armed = false;
          final transactions = fileSystem
              .directory('/sandbox/project/.agent-resource/transactions')
              .listSync()
              .whereType<fs.File>()
              .toList();
          expect(transactions, hasLength(1));
          final transactionId = fileSystem.path.basenameWithoutExtension(
            transactions.single.path,
          );
          final recovered = await service.recover(
            options.copyWith(approved: true),
            transactionId: transactionId,
            action: 'rollback',
          );
          expect(recovered.outcome, 'recovered');
          expect(
            fileSystem
                .file('/sandbox/project/.agents/agents/recovery.md')
                .existsSync(),
            isFalse,
          );
        });
      },
    );
  });
}

final class _InterruptingIO extends LifecycleIO {
  _InterruptingIO(fs.FileSystem fileSystem) : super(fs: fileSystem);

  bool armed = true;
  var interrupted = false;
  var ledgerWrites = 0;

  @override
  void before(String operation, String path) {
    if (!armed || operation != 'write') return;
    if (interrupted) throw Exception('Simulated process interruption');
    if (path.contains('installations.json')) {
      ledgerWrites++;
      if (ledgerWrites == 2) {
        interrupted = true;
        throw Exception('Simulated ledger interruption');
      }
    }
  }
}
