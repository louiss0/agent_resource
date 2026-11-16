import 'dart:convert';
import 'dart:io' as io;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart' show ProcessedStandardInput;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/compiled_cli_test_support.dart';
import 'support/process_test_support.dart';
import 'support/trusted_temp.dart';

Future<void> main() async {
  final root = _findProjectRoot();
  final packageConfig = p.join(root, '.dart_tool', 'package_config.json');
  final entrypoint = await compileTestCli(
    script: p.join(root, 'bin', 'agent_resource.dart'),
    packageConfig: packageConfig,
  );

  group('skill create', () {
    late FileSystem fs;
    late Directory sandbox;
    late Directory project;
    late Directory home;
    late MambaExecutor<MambaExecutionResult> executor;
    late List<String> questions;
    late List<String> confirmations;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      sandbox = fs.directory('/sandbox')..createSync();
      project = fs.directory('/sandbox/project')..createSync();
      home = fs.directory('/sandbox/home')..createSync();
      questions = <String>[];
      confirmations = <String>[];
      executor = createExecutor(
        fileSystem: fs,
        guided: GuidedAuthoringService(
          fileSystem: fs,
          terminal: () => false,
          ask: (label) async {
            questions.add(label);
            return null;
          },
          confirm: (summary) async {
            confirmations.add(summary);
            return true;
          },
        ),
      ).fake();
    });

    List<String> contextArguments({bool withState = false}) => [
      '--cwd',
      '${project.path}${fs.path.separator}',
      '--project-root',
      '${project.path}${fs.path.separator}',
      '--home',
      '${home.path}${fs.path.separator}',
      if (withState) ...[
        '--state-dir',
        '${fs.path.join(sandbox.path, 'state')}${fs.path.separator}',
      ],
    ];

    test('registers the create route and its help', () async {
      final help = await executor.execute(['skill', 'create', '--help']);

      expect(help, isA<MambaSuccessResult>());
      final output = (help as MambaSuccessResult).output!;
      expect(output, contains('--profile'));
      expect(output, contains('--body-file'));
      expect(output, contains('--body-stdin'));
      expect(output, contains('--body-text'));
      expect(output, contains('--manage'));
      expect(output, contains('--apply'));
    });

    test('plans an author-only output without writing it', () async {
      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--body-text',
        'Follow the selected task.',
        '--format',
        'json',
        ...contextArguments(),
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
      expect(report['command'], 'skill create');
      expect(report['outcome'], 'planned');
      expect(data['published'], isFalse);
      expect(data['ownership'], 'authorOnly');
      expect(data['ready'], isTrue);
      final target = data['target']! as Map<String, Object?>;
      expect(target['output'], endsWith('demo/SKILL.md'));
      expect(
        fs.file(target['output']! as String).existsSync(),
        isFalse,
        reason: 'A plan must not write the proposed output.',
      );
    });

    test(
      'publishes an author-only output without a management record',
      () async {
        final result = await executor.execute([
          'skill',
          'create',
          '--profile',
          'claude',
          '--name',
          'demo',
          '--description',
          'Demo resource.',
          '--body-text',
          'Follow the selected task.',
          '--apply',
          '--yes',
          '--format',
          'json',
          ...contextArguments(withState: true),
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
        expect(report['outcome'], 'published');
        expect(data['published'], isTrue);
        expect(data['ownership'], 'authorOnly');
        expect(data['managed'], isFalse);
        expect(data['installationId'], isNull);
        final marker = fs.file(
          fs.path.join(project.path, '.claude', 'skills', 'demo', 'SKILL.md'),
        );
        expect(marker.existsSync(), isTrue);
        expect(
          marker.readAsStringSync(),
          contains('Follow the selected task.'),
        );
        expect(
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.agent-resource',
                  'installations.json',
                ),
              )
              .existsSync(),
          isFalse,
          reason: 'An author-only output owns no installation record.',
        );
      },
    );

    test('a dry run never prepares a draft or writes an output', () async {
      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--body-text',
        'Follow the selected task.',
        '--dry-run',
        '--format',
        'json',
        ...contextArguments(withState: true),
      ]);

      expect(result, isA<MambaSuccessResult>());
      final report = jsonDecode(
        (result as MambaSuccessResult).output!,
      ) as Map<String, Object?>;
      expect(report['outcome'], 'planned');
      expect(
        fs
            .directory(fs.path.join(project.path, '.agent-resource'))
            .existsSync(),
        isFalse,
        reason: 'A dry run writes no management artifact.',
      );
    });

    test('a session without a usable terminal never prompts', () async {
      // A usable terminal means that the input and the output streams are
      // both a terminal. Without that capability the guided flow is not
      // available: every value is supplied explicitly and nothing is asked.
      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--body-text',
        'Follow the selected task.',
        '--apply',
        '--yes',
        '--format',
        'json',
        ...contextArguments(withState: true),
      ]);

      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      expect(questions, isEmpty);
      expect(confirmations, isEmpty);
    });

    test('refuses an unattended run without an instruction body', () async {
      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--unattended',
        ...contextArguments(),
      ]);

      expect(
        result,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          4,
        ),
      );
      expect((result as MambaFailureResult).message, contains('--body-file'));
      expect(questions, isEmpty);
    });

    test('refuses two body selectors', () async {
      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--body-text',
        'Body.',
        '--body-stdin',
        ...contextArguments(),
      ]);

      expect(result, isA<MambaFailureResult>());
      expect((result as MambaFailureResult).message, contains('conflicts'));
    });

    test('refuses a native field the profile does not support', () async {
      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--model',
        'provider/model',
        '--body-text',
        'Body.',
        ...contextArguments(),
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
        contains('does not support'),
      );
    });

    test('refuses an occupied native target', () async {
      final occupied = fs.directory(
        fs.path.join(project.path, '.claude', 'skills', 'demo'),
      )..createSync(recursive: true);
      fs.file(fs.path.join(occupied.path, 'SKILL.md')).writeAsStringSync('old');

      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--body-text',
        'Body.',
        '--apply',
        '--yes',
        '--format',
        'json',
        ...contextArguments(withState: true),
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
        fs.file(fs.path.join(occupied.path, 'SKILL.md')).readAsStringSync(),
        'old',
        reason: 'An occupied target is never taken over.',
      );
    });

    test(
      'refuses a managed publication that the profile does not support',
      () async {
        final result = await executor.execute([
          'skill',
          'create',
          '--profile',
          'pi',
          '--name',
          'demo',
          '--description',
          'Demo resource.',
          '--body-text',
          'Body.',
          '--manage',
          '--apply',
          '--yes',
          '--format',
          'json',
          ...contextArguments(withState: true),
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
          contains('MANAGEMENT_UNSUPPORTED'),
        );
      },
    );

    test('publishes the body supplied on standard input', () async {
      final executor =
          createExecutor(
            fileSystem: fs,
            guided: GuidedAuthoringService(
              fileSystem: fs,
              terminal: () => false,
              ask: (label) async => null,
              confirm: (summary) async => true,
            ),
          ).fake(
            standardInput: ProcessedStandardInput(
              utf8.encode('Body from stdin.\n'),
            ),
          );

      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--body-stdin',
        '--apply',
        '--yes',
        '--format',
        'json',
        ...contextArguments(withState: true),
      ]);

      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      final report = jsonDecode(
        (result as MambaSuccessResult).output!,
      ) as Map<String, Object?>;
      expect(report['outcome'], 'published');
      final marker = fs.file(
        fs.path.join(project.path, '.claude', 'skills', 'demo', 'SKILL.md'),
      );
      expect(marker.readAsStringSync(), contains('Body from stdin.'));
    });

    test(
      'refuses the standard input when the invocation supplied none',
      () async {
        final result = await executor.execute([
          'skill',
          'create',
          '--profile',
          'claude',
          '--name',
          'demo',
          '--description',
          'Demo resource.',
          '--body-stdin',
          '--unattended',
          ...contextArguments(),
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
          contains('Standard input was not supplied'),
        );
      },
    );

    test('publishes the native Skill declarations', () async {
      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--allowed-tools',
        'Read',
        '--allowed-tools',
        'Write',
        '--metadata',
        'owner=platform',
        '--body-text',
        'Follow the selected task.',
        '--apply',
        '--yes',
        '--format',
        'json',
        ...contextArguments(withState: true),
      ]);

      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      final marker = fs.file(
        fs.path.join(project.path, '.claude', 'skills', 'demo', 'SKILL.md'),
      );
      final content = marker.readAsStringSync();
      expect(content, contains('allowed-tools'));
      expect(content, contains('Read, Write'));
      expect(content, contains('owner'));
      expect(content, contains('platform'));
    });

    test('refuses a metadata entry that is not one name=value pair', () async {
      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--metadata',
        'owner',
        '--body-text',
        'Body.',
        ...contextArguments(),
      ]);

      expect(
        result,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          4,
        ),
      );
      expect((result as MambaFailureResult).message, contains('name=value'));
    });

    test('refuses a publication without an approval', () async {
      final result = await executor.execute([
        'skill',
        'create',
        '--profile',
        'claude',
        '--name',
        'demo',
        '--description',
        'Demo resource.',
        '--body-text',
        'Body.',
        '--apply',
        '--unattended',
        ...contextArguments(withState: true),
      ]);

      expect(
        result,
        isA<MambaFailureResult>().having(
          (value) => value.exitCode,
          'exit code',
          4,
        ),
      );
      expect((result as MambaFailureResult).message, contains('--yes'));
    });
  });

  group('skill create in the production CLI', () {
    test('publishes the reviewed output and reports it', () async {
      final sandbox = io.Directory(createTrustedTempPathSync('skill-create-'));
      try {
        final project = io.Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = io.Directory(p.join(sandbox.path, 'home'))..createSync();
        final result = await runDartScript(
          script: entrypoint,
          packageConfig: packageConfig,
          workingDirectory: project,
          environment: io.Platform.environment,
          arguments: [
            'skill',
            'create',
            '--profile',
            'claude',
            '--name',
            'demo',
            '--description',
            'Demo resource.',
            '--body-text',
            'Follow the selected task.',
            '--apply',
            '--yes',
            '--unattended',
            '--format',
            'json',
            '--cwd',
            '${project.path}${io.Platform.pathSeparator}',
            '--project-root',
            '${project.path}${io.Platform.pathSeparator}',
            '--home',
            '${home.path}${io.Platform.pathSeparator}',
          ],
        );

        expect(result.exitCode, 0, reason: result.stderr);
        final report = jsonDecode(result.stdout) as Map<String, Object?>;
        final data = report['data']! as Map<String, Object?>;
        expect(report['command'], 'skill create');
        expect(report['outcome'], 'published');
        expect(data['published'], isTrue);
        expect(data['ownership'], 'authorOnly');
        final marker = io.File(
          p.join(project.path, '.claude', 'skills', 'demo', 'SKILL.md'),
        );
        expect(marker.existsSync(), isTrue);
        expect(
          marker.readAsStringSync(),
          contains('Follow the selected task.'),
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
    test('reads the body from the piped standard input', () async {
      final sandbox = io.Directory(createTrustedTempPathSync('skill-stdin-'));
      try {
        final project = io.Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = io.Directory(p.join(sandbox.path, 'home'))..createSync();
        final result = await runDartScript(
          script: entrypoint,
          packageConfig: packageConfig,
          workingDirectory: project,
          environment: io.Platform.environment,
          standardInput: 'Body from the pipe.\n',
          arguments: [
            'skill',
            'create',
            '--profile',
            'claude',
            '--name',
            'demo',
            '--description',
            'Demo resource.',
            '--body-stdin',
            '--apply',
            '--yes',
            '--unattended',
            '--format',
            'json',
            '--cwd',
            '${project.path}${io.Platform.pathSeparator}',
            '--project-root',
            '${project.path}${io.Platform.pathSeparator}',
            '--home',
            '${home.path}${io.Platform.pathSeparator}',
          ],
        );

        expect(result.exitCode, 0, reason: result.stderr);
        final report = jsonDecode(result.stdout) as Map<String, Object?>;
        expect(report['outcome'], 'published');
        final marker = io.File(
          p.join(project.path, '.claude', 'skills', 'demo', 'SKILL.md'),
        );
        expect(marker.readAsStringSync(), contains('Body from the pipe.'));
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
  });
}

/// The package root of the running suite.
String _findProjectRoot() {
  var candidate = io.Directory.current.absolute;
  while (true) {
    if (io.File(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
      return candidate.path;
    }
    final parent = candidate.parent;
    if (parent.path == candidate.path) {
      throw StateError('Could not locate the package root.');
    }
    candidate = parent;
  }
}
