import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
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
  });
}
