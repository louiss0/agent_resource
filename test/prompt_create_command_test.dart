import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('prompt create', () {
    late FileSystem fs;
    late Directory project;
    late Directory home;
    late MambaExecutor<MambaExecutionResult> executor;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      fs.directory('/sandbox').createSync();
      project = fs.directory('/sandbox/project')..createSync();
      home = fs.directory('/sandbox/home')..createSync();
      executor = createExecutor(
        fileSystem: fs,
        guided: GuidedAuthoringService(
          fileSystem: fs,
          terminal: () => false,
          ask: (label) async => null,
          confirm: (summary) async => true,
        ),
      ).fake();
    });

    List<String> contextArguments() => [
      '--cwd',
      '${project.path}${fs.path.separator}',
      '--project-root',
      '${project.path}${fs.path.separator}',
      '--home',
      '${home.path}${fs.path.separator}',
    ];

    test('registers the create route and its help', () async {
      final help = await executor.execute(['prompt', 'create', '--help']);

      expect(help, isA<MambaSuccessResult>());
      final output = (help as MambaSuccessResult).output!;
      expect(output, contains('--profile'));
      expect(output, contains('--manage'));
    });

    test('publishes a native Pi template as an author-only output', () async {
      final result = await executor.execute([
        'prompt',
        'create',
        '--profile',
        'pi',
        '--name',
        'demo',
        '--description',
        'Demo prompt.',
        '--body-text',
        'Answer the selected question.',
        '--apply',
        '--yes',
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
      expect(report['command'], 'prompt create');
      expect(data['ownership'], 'authorOnly');
      final template = fs.file(
        fs.path.join(project.path, '.pi', 'prompts', 'demo.md'),
      );
      expect(template.existsSync(), isTrue);
      expect(
        template.readAsStringSync(),
        contains('Answer the selected question.'),
      );
    });

    test(
      'refuses a managed Prompt without falling back to author-only',
      () async {
        final result = await executor.execute([
          'prompt',
          'create',
          '--profile',
          'claude',
          '--name',
          'demo',
          '--description',
          'Demo prompt.',
          '--body-text',
          'Body.',
          '--manage',
          '--apply',
          '--yes',
          '--format',
          'json',
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
          contains('MANAGEMENT_UNSUPPORTED'),
        );
        expect(
          fs
              .directory(
                fs.path.join(project.path, '.claude', 'skills', 'demo'),
              )
              .existsSync(),
          isFalse,
          reason: 'A refused publication writes nothing.',
        );
      },
    );

    test(
      'refuses an explicit output outside the native roots for management',
      () async {
        final result = await executor.execute([
          'prompt',
          'create',
          '--profile',
          'claude',
          '--name',
          'demo',
          '--description',
          'Demo prompt.',
          '--body-text',
          'Body.',
          '--output',
          fs.path.join(project.path, 'sources', 'demo'),
          '--apply',
          '--yes',
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
        expect(data['ownership'], 'authorOnly');
        expect(
          fs
              .file(fs.path.join(project.path, 'sources', 'demo', 'SKILL.md'))
              .existsSync(),
          isTrue,
        );
      },
    );
  });
}
