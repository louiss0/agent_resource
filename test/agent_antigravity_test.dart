import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/agent_graph_service.dart';
import 'package:agent_resource/src/services/agent_lifecycle_service.dart';
import 'package:file/file.dart' as fs;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

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
  });
}
