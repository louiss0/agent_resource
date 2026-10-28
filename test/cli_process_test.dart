import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/process_test_support.dart';

late final String _entrypoint;
late final String _packageConfig;

final class _Sandbox {
  _Sandbox(this.root)
    : work = Directory('${root.path}${Platform.pathSeparator}work'),
      home = Directory('${root.path}${Platform.pathSeparator}home'),
      config = Directory('${root.path}${Platform.pathSeparator}config'),
      temp = Directory('${root.path}${Platform.pathSeparator}temp') {
    work.createSync(recursive: true);
    home.createSync(recursive: true);
    config.createSync(recursive: true);
    temp.createSync(recursive: true);
    Directory('${config.path}${Platform.pathSeparator}nested').createSync();
    File('${work.path}${Platform.pathSeparator}sentinel.txt')
        .writeAsStringSync('do not change');
    File(
      '${config.path}${Platform.pathSeparator}nested${Platform.pathSeparator}config.json',
    ).writeAsStringSync('{"sentinel":true}');
  }

  final Directory root;
  final Directory work;
  final Directory home;
  final Directory config;
  final Directory temp;

  Map<String, String> snapshot() {
    final entries = <String, String>{'.': 'directory'};

    void visit(Directory directory) {
      for (final entity in directory.listSync(followLinks: false)) {
        final relative = _relativePath(root.path, entity.path);
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        entries[relative] = switch (type) {
          FileSystemEntityType.file =>
            'file:${base64Encode(File(entity.path).readAsBytesSync())}',
          FileSystemEntityType.directory => 'directory',
          FileSystemEntityType.link => 'link:${Link(entity.path).targetSync()}',
          FileSystemEntityType.notFound => 'not-found',
          _ => 'other',
        };
        if (type == FileSystemEntityType.directory) {
          visit(Directory(entity.path));
        }
      }
    }

    visit(root);
    final keys = entries.keys.toList()..sort();
    return <String, String>{for (final key in keys) key: entries[key]!};
  }
}

Future<T> _withSandbox<T>(Future<T> Function(_Sandbox) body) async {
  final root = await Directory.systemTemp.createTemp('agent-resource-cli-');
  final sandbox = _Sandbox(root);
  try {
    return await body(sandbox);
  } finally {
    await root.delete(recursive: true);
  }
}

Future<MambaSuccessResult> _fakeSuccess(
  List<String> arguments, {
  Executor? executor,
}) async {
  final result = await (executor ?? createExecutor()).fake().execute(arguments);
  return switch (result) {
    MambaSuccessResult success => success,
    MambaFailureResult failure => fail(
      'Expected success for ${arguments.join(' ')}, got ${failure.message}',
    ),
  };
}

Future<CliProcessResult> _runCli(
  _Sandbox sandbox,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 20),
  String? standardInput,
}) => runDartScript(
  script: _entrypoint,
  packageConfig: _packageConfig,
  arguments: arguments,
  workingDirectory: sandbox.work,
  environment: isolatedEnvironment(sandbox.root),
  timeout: timeout,
  standardInput: standardInput,
);

String _normalizePresentation(String value) => value
    .replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '')
    .replaceFirst(RegExp(r'(?:\r\n|\r|\n)+$'), '');

bool _containsToken(String text, String token) =>
    RegExp(r'(?<![A-Za-z0-9_-])' + RegExp.escape(token) + r'(?![A-Za-z0-9_-])')
        .hasMatch(text);

String _relativePath(String root, String child) {
  final normalizedRoot = root.replaceAll('\\', '/');
  final normalizedChild = child.replaceAll('\\', '/');
  final prefix = normalizedRoot.endsWith('/')
      ? normalizedRoot
      : '$normalizedRoot/';
  return normalizedChild.startsWith(prefix)
      ? normalizedChild.substring(prefix.length)
      : normalizedChild;
}

void main() {
  final projectRoot = _findProjectRoot();
  _entrypoint = File(
    '${projectRoot.path}${Platform.pathSeparator}bin${Platform.pathSeparator}agent_resource.dart',
  ).absolute.path;
  _packageConfig = File(
    '${projectRoot.path}${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}package_config.json',
  ).absolute.path;

  group('agent_resource', () {
    test('production version output matches the fake adapter', () async {
      await _withSandbox((sandbox) async {
        final process = await _runCli(sandbox, ['--version']);
        final fake = await _fakeSuccess(['--version']);
        expect(fake.exitCode, 0);
        expect(fake.output, allOf(isNotNull, isNotEmpty, contains('0.0.0')));

        expect(process.exitCode, 0);
        expect(process.stderr, isEmpty);
        expect(
          _normalizePresentation(process.stdout),
          equals(_normalizePresentation(fake.output!)),
        );
      });
    });

    test('production help exits zero on stdout with empty stderr', () async {
      await _withSandbox((sandbox) async {
        final result = await _runCli(sandbox, ['--help']);

        expect(result.exitCode, 0);
        expect(result.stdout, isNotEmpty);
        expect(result.stderr, isEmpty);
      });
    });

    test('production version exits zero on stdout with empty stderr', () async {
      await _withSandbox((sandbox) async {
        final result = await _runCli(sandbox, ['--version']);

        expect(result.exitCode, 0);
        expect(result.stdout, contains('0.0.0'));
        expect(result.stderr, isEmpty);
      });
    });

    final rejectedProcessCases =
        <({String name, List<String> arguments, String token})>[
          (
            name: 'unknown command',
            arguments: ['unsupported-command'],
            token: 'unsupported-command',
          ),
          (
            name: 'unknown option',
            arguments: ['--unsupported'],
            token: '--unsupported',
          ),
        ];
    for (final testCase in rejectedProcessCases) {
      test('${testCase.name} uses stderr and a nonzero exit status', () async {
        await _withSandbox((sandbox) async {
          final result = await _runCli(sandbox, testCase.arguments);

          expect(result.exitCode, isNot(0));
          expect(result.stdout, isEmpty);
          expect(_containsToken(result.stderr, testCase.token), isTrue);
        });
      });
    }

    test('production failures retain normal Mamba stderr coloring', () async {
      await _withSandbox((sandbox) async {
        final result = await _runCli(sandbox, ['unsupported-command']);
        expect(result.exitCode, isNot(0));
        expect(result.stdout, isEmpty);
        expect(result.stderr, contains('\x1B[31m'));
        expect(result.stderr, contains('unsupported-command'));
      });
    });

    test(
      'the informational and rejected sequence does not mutate sentinels',
      () async {
        await _withSandbox((sandbox) async {
          final before = sandbox.snapshot();
          final invocations = <List<String>>[
            const [],
            ['--help'],
            ['-h'],
            ['--version'],
            ['-v'],
            ['unsupported-command'],
            ['--unsupported'],
          ];
          final results = <CliProcessResult>[];
          for (final arguments in invocations) {
            results.add(await _runCli(sandbox, arguments));
          }

          expect(results[0].exitCode, 0);
          expect(results[1].exitCode, 0);
          expect(results[2].exitCode, 0);
          expect(results[3].exitCode, 0);
          expect(results[4].exitCode, 0);
          expect(results[5].exitCode, isNot(0));
          expect(results[6].exitCode, isNot(0));
          expect(results[5].stdout, isEmpty);
          expect(results[6].stdout, isEmpty);
          expect(sandbox.snapshot(), equals(before));
        });
      },
      // Seven sequential subprocesses each have a 20-second deadline.
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'production lifecycle smoke preserves streams, bytes, and approval gates',
      () async {
        await _withSandbox((sandbox) async {
          final separator = Platform.pathSeparator;
          final skill = Directory(p.join(sandbox.root.path, 'skill-source'))
            ..createSync();
          final skillMarker = File(p.join(skill.path, 'SKILL.md'))
            ..writeAsStringSync(
              '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
            );
          final originalSkillBytes = skillMarker.readAsBytesSync();
          final contextArgs = [
            '--scope',
            'project',
            '--cwd',
            '${sandbox.work.path}$separator',
            '--project-root',
            '${sandbox.work.path}$separator',
            '--home',
            '${sandbox.home.path}$separator',
            '--format',
            'json',
          ];
          final installed = await _runCli(sandbox, [
            'skill',
            'install',
            '${skill.path}$separator',
            '--source-kind',
            'resource',
            '--target',
            'claude',
            '--method',
            'copy',
            ...contextArgs,
            '--yes',
          ]);
          expect(installed.exitCode, 0, reason: installed.stderr);
          expect(installed.stderr, isEmpty);
          final envelope = jsonDecode(installed.stdout) as Map<String, Object?>;
          expect(envelope['command'], 'skill install');
          expect(envelope['outcome'], 'installed');
          expect(skillMarker.readAsBytesSync(), originalSkillBytes);
          final liveMarker = File(
            p.join(
              sandbox.work.path,
              '.claude',
              'skills',
              'review',
              'SKILL.md',
            ),
          );
          expect(liveMarker.readAsBytesSync(), originalSkillBytes);
          final installedUnit =
              ((envelope['data']! as Map<String, Object?>)['units']!
                          as List<Object?>)
                      .single!
                  as Map<String, Object?>;
          final installationId =
              (installedUnit['installationIds']! as List<Object?>).single!
                  as String;

          final refused = await _runCli(sandbox, [
            'skill',
            'remove',
            installationId,
            ...contextArgs,
          ]);
          expect(refused.exitCode, 4);
          expect(refused.stdout, isEmpty);
          expect(refused.stderr, contains('approval'));
          expect(liveMarker.existsSync(), isTrue);

          final cancelled = await _runCli(sandbox, [
            'skill',
            'remove',
            installationId,
            '--interactive',
            ...contextArgs.take(contextArgs.length - 2),
          ], standardInput: 'n\n');
          expect(cancelled.exitCode, 7);
          // Clix Confirm renders its prompt on stdout; Mamba's cancellation
          // diagnostic remains on stderr. No resource or management mutation
          // is permitted by declining.
          expect(cancelled.stdout, contains('reviewed destructive operation'));
          expect(cancelled.stdout, contains('No'));
          expect(cancelled.stderr, contains('cancelled'));
          expect(liveMarker.existsSync(), isTrue);

          final agent = File(p.join(sandbox.root.path, 'reviewer.md'))
            ..writeAsStringSync(
              '---\nname: reviewer\ndescription: Reviews.\n---\nAgent body.\n',
            );
          final agentInstalled = await _runCli(sandbox, [
            'agent',
            'install',
            agent.path,
            '--source-kind',
            'resource',
            '--profile',
            'claude',
            '--target',
            'claude',
            ...contextArgs,
            '--yes',
          ]);
          expect(agentInstalled.exitCode, 0, reason: agentInstalled.stderr);
          expect(agentInstalled.stderr, isEmpty);
          expect(
            File(p.join(sandbox.work.path, '.claude', 'agents', 'reviewer.md'))
                .readAsBytesSync(),
            agent.readAsBytesSync(),
          );
          expect(
            File(p.join(sandbox.work.path, 'sentinel.txt')).readAsStringSync(),
            'do not change',
          );
        });
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('timeout kills the child, drains streams, and permits cleanup', () async {
      late String rootPath;
      await _withSandbox((sandbox) async {
        rootPath = sandbox.root.path;
        final fixture =
            File(
              '${sandbox.root.path}${Platform.pathSeparator}timeout_fixture.dart',
            )..writeAsStringSync('''
import 'dart:async';
import 'dart:io';

Future<void> main() async {
  stdout.write('before-timeout');
  stderr.write('diagnostic');
  await Future<void>.delayed(const Duration(minutes: 5));
}
''');

        late CliProcessTimeout timeout;
        try {
          await runDartScript(
            script: fixture.path,
            packageConfig: _packageConfig,
            arguments: const [],
            workingDirectory: sandbox.work,
            environment: isolatedEnvironment(sandbox.root),
            timeout: const Duration(seconds: 5),
          );
          fail('the fixture unexpectedly exited before the timeout');
        } on CliProcessTimeout catch (error) {
          timeout = error;
        }

        expect(timeout.stdout, contains('before-timeout'));
        expect(timeout.stderr, contains('diagnostic'));
      });
      expect(Directory(rootPath).existsSync(), isFalse);
    });
  });
}

Directory _findProjectRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File('${candidate.path}${Platform.pathSeparator}pubspec.yaml')
        .existsSync()) {
      return candidate;
    }
    final parent = candidate.parent;
    if (parent.path == candidate.path) {
      throw StateError(
        'Could not locate the package root from ${Directory.current.path}.',
      );
    }
    candidate = parent;
  }
}
