import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/skill.dart';
import 'package:agent_resource/src/services/prompt_read_service.dart';
import 'package:agent_resource/src/services/prompt_inspection_service.dart';
import 'package:agent_resource/src/prompt/prompt_native_view.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

final class CountingRead implements PromptReadService {
  CountingRead(this.delegate);
  final PromptReadService delegate;
  int calls = 0;
  @override
  Future<PromptNativeViews> inspect(String path, {PromptConsumer? consumer}) {
    calls++;
    return delegate.inspect(path, consumer: consumer);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('skill native views', () {
    late MemoryFileSystem fs;
    late String directory;
    setUp(() {
      fs = MemoryFileSystem.test(style: FileSystemStyle.posix);
      directory = '/prompt';
      fs.directory(directory).createSync();
      fs
          .file('$directory/SKILL.md')
          .writeAsStringSync(
            '---\nname: prompt\ndescription: example\ndisable-model-invocation: true\nargument-hint: example\n---\nsecret body\n',
          );
    });
    Future<MambaExecutionResult> run(List<String> args) =>
        createExecutor(fileSystem: fs).fake().execute(['skill', ...args]);

    test('inspect defaults to body-free differing native views', () async {
      final result = await run(['inspect', '--skill', directory]);
      expect(result, isA<MambaSuccessResult>());
      final output = (result as MambaSuccessResult).output!;
      expect(output, isNot(contains('secret body')));
      final report = jsonDecode(output) as Map<String, dynamic>;
      final views = {
        for (final view in report['views'] as List)
          view['consumer']: view['classification'],
      };
      expect(views, {'claude': 'prompt', 'codex': 'nonPrompt', 'pi': 'prompt'});
      expect(report, isNot(contains('classification')));
    });

    test('inspect target and explicit verbatim content', () async {
      final selected = await run([
        'inspect',
        '--skill',
        directory,
        '--target',
        'codex',
      ]);
      final report =
          jsonDecode((selected as MambaSuccessResult).output!) as Map;
      expect((report['views'] as List).single['consumer'], 'codex');
      final content = await run(['inspect', '--skill', directory, '--content']);
      expect((content as MambaSuccessResult).output, contains('secret body'));
    });

    test(
      'content and target conflict before reads or injected operation',
      () async {
        var calls = 0;
        final read = CountingRead(PromptReadService(fileSystem: fs));
        final executor = Executor('test', 'test', '1.0.0', [
          SkillCommand(
            fileSystem: fs,
            read: read,
            inspect: (_) {
              calls++;
              return 'secret';
            },
          ),
        ]).fake();
        final result = await executor.execute([
          'skill',
          'inspect',
          '--skill',
          '/missing',
          '--target',
          'claude',
          '--content',
        ]);
        expect(
          result,
          isA<MambaFailureResult>()
              .having((r) => r.exitCode, 'exit', 2)
              .having((r) => r.message, 'message', contains('--content')),
        );
        expect(calls, 0);
        expect(read.calls, 0);
      },
    );

    test('injected reader is shared by inspection and validation', () async {
      final read = CountingRead(PromptReadService(fileSystem: fs));
      final executor = Executor('test', 'test', '1.0.0', [
        SkillCommand(fileSystem: fs, read: read),
      ]).fake();
      expect(
        await executor.execute(['skill', 'inspect', '--skill', directory]),
        isA<MambaSuccessResult>(),
      );
      expect(
        await executor.execute([
          'skill',
          'validate',
          '--skill',
          directory,
          '--target',
          'claude',
        ]),
        isA<MambaSuccessResult>(),
      );
      expect(read.calls, 2);
    });

    test('validation applies Prompt rules only to Prompt views', () async {
      final prompt = await run([
        'validate',
        '--skill',
        directory,
        '--target',
        'claude',
      ]);
      expect(prompt, isA<MambaSuccessResult>());
      final ordinary = await run([
        'validate',
        '--skill',
        directory,
        '--target',
        'codex',
      ]);
      expect(ordinary, isA<MambaFailureResult>());
      final report =
          jsonDecode((ordinary as MambaFailureResult).message) as Map;
      expect((report['views'] as List).single['classification'], 'nonPrompt');
      expect((report['views'] as List).single['valid'], false);
      final all = await run(['validate', '--skill', directory]);
      expect(all, isA<MambaFailureResult>());
      final allReport = jsonDecode((all as MambaFailureResult).message) as Map;
      expect((allReport['views'] as List), hasLength(3));
      expect(allReport, isNot(contains('valid')));
    });

    test('ordinary Skill validation reports native facts per view', () async {
      fs
          .file('$directory/SKILL.md')
          .writeAsStringSync(
            '---\nname: prompt\ndescription: ordinary\n---\nbody\n',
          );
      final result = await run([
        'validate',
        '--skill',
        directory,
        '--target',
        'codex',
      ]);
      expect(result, isA<MambaSuccessResult>());
      final report = jsonDecode((result as MambaSuccessResult).output!) as Map;
      final view = (report['views'] as List).single as Map;
      expect(view['classification'], 'nonPrompt');
      expect(view['valid'], true);
      expect(view, isNot(contains('skillValidation')));
      expect(report, isNot(contains('valid')));
      expect(report['installationAdmission'], {
        'eligible': true,
        'scope': 'source-only',
        'methods': {'copy': true, 'canonical': true, 'source-link': true},
        'diagnostics': isEmpty,
      });
    });

    test(
      'ordinary Claude view accepts native fields outside strict core',
      () async {
        fs
            .file('$directory/SKILL.md')
            .writeAsStringSync(
              '---\nname: prompt\ndescription: example\nargument-hint: input\n---\nbody\n',
            );
        final result = await run([
          'validate',
          '--skill',
          directory,
          '--target',
          'claude',
        ]);
        expect(result, isA<MambaSuccessResult>());
        final report =
            jsonDecode((result as MambaSuccessResult).output!) as Map;
        final view = (report['views'] as List).single as Map;
        expect(view['classification'], 'nonPrompt');
        expect(view['valid'], true);
        final admission = report['installationAdmission'] as Map;
        expect(admission['eligible'], false);
        expect(admission['diagnostics'], isNotEmpty);
        expect('${admission['diagnostics']}', contains('argument-hint'));
      },
    );

    test(
      'reports unsafe source trees separately from native validity',
      () async {
        fs
            .file('$directory/SKILL.md')
            .writeAsStringSync(
              '---\nname: prompt\ndescription: ordinary\n---\nbody\n',
            );
        fs.directory('$directory/unexpected').createSync();
        fs.file('$directory/unexpected/file.txt').writeAsStringSync('content');
        final result = await run([
          'validate',
          '--skill',
          directory,
          '--target',
          'claude',
        ]);
        expect(result, isA<MambaSuccessResult>());
        final report =
            jsonDecode((result as MambaSuccessResult).output!) as Map;
        expect((report['views'] as List).single['valid'], true);
        final admission = report['installationAdmission'] as Map;
        expect(admission['eligible'], false);
        expect(admission['diagnostics'], isNotEmpty);
      },
    );

    test('reports migration eligibility by installation method', () async {
      fs
          .file('$directory/SKILL.md')
          .writeAsStringSync(
            '---\nname: prompt\ndescription: ordinary\n---\nSee guide.md.\n',
          );
      fs.file('$directory/guide.md').writeAsStringSync('Guide');
      final result = await run([
        'validate',
        '--skill',
        directory,
        '--target',
        'claude',
      ]);
      expect(result, isA<MambaSuccessResult>());
      final report = jsonDecode((result as MambaSuccessResult).output!) as Map;
      final admission = report['installationAdmission'] as Map;
      expect(admission['eligible'], true);
      expect((admission['methods'] as Map)['copy'], true);
      expect((admission['methods'] as Map)['canonical'], true);
      expect((admission['methods'] as Map)['source-link'], false);
      expect('${admission['diagnostics']}', contains('source-link'));
    });

    test('inspect reports installation admission separately from native '
        'validity', () async {
      fs
          .file('$directory/SKILL.md')
          .writeAsStringSync(
            '---\nname: prompt\ndescription: ordinary\n---\nSee guide.md.\n',
          );
      fs.file('$directory/guide.md').writeAsStringSync('Guide');
      final result = await run(['inspect', '--skill', directory]);
      expect(result, isA<MambaSuccessResult>());
      final report = jsonDecode(
        (result as MambaSuccessResult).output!,
      ) as Map<String, Object?>;
      final views = report['views'] as List;
      expect(views, isNotEmpty);
      final admission = report['installationAdmission'] as Map;
      expect(admission['scope'], 'source-only');
      expect(admission['eligible'], true);
      expect((admission['methods'] as Map)['source-link'], false);
      expect('${admission['diagnostics']}', contains('source-link'));
    });

    test('rejects malformed controls and unknown targets', () async {
      fs
          .file('$directory/SKILL.md')
          .writeAsStringSync(
            '---\nname: prompt\ndescription: example\ndisable-model-invocation: [\n---\n',
          );
      final invalid = await run([
        'validate',
        '--skill',
        directory,
        '--target',
        'claude',
      ]);
      expect(
        invalid,
        isA<MambaFailureResult>().having((r) => r.exitCode, 'exit', 2),
      );
      final target = await run([
        'inspect',
        '--skill',
        directory,
        '--target',
        'other',
      ]);
      expect(
        target,
        isA<MambaFailureResult>().having(
          (r) => r.error.phase,
          'phase',
          MambaExecutionPhase.parse,
        ),
      );
    });
  });
}
