import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('Antigravity Skill lifecycle', () {
    late MemoryFileSystem fs;
    late String source;

    setUp(() {
      fs = MemoryFileSystem.test(style: FileSystemStyle.posix);
      for (final path in const [
        '/sandbox/project',
        '/sandbox/home',
        '/sandbox/state',
        '/sandbox/gemini',
        '/sandbox/gemini/config',
        '/sandbox/review',
      ]) {
        fs.directory(path).createSync(recursive: true);
      }
      source = '/sandbox/review';
      fs
          .file('$source/SKILL.md')
          .writeAsStringSync(
            '---\nname: review\ndescription: Reviews code.\n---\nReview body.\n',
          );
    });

    Future<MambaExecutionResult> run(List<String> args) =>
        createExecutor(fileSystem: fs).fake().execute(args);

    List<String> roots({String scope = 'project'}) => <String>[
      '--scope',
      scope,
      '--cwd',
      '/sandbox/project/',
      '--project-root',
      '/sandbox/project/',
      '--home',
      '/sandbox/home/',
      '--state-dir',
      '/sandbox/state/',
      '--gemini-dir',
      '/sandbox/gemini/',
    ];

    Future<MambaExecutionResult> install(String scope) => run(<String>[
      'skill',
      'install',
      source,
      '--target',
      'antigravity',
      '--source-kind',
      'resource',
      '--method',
      'copy',
      '--yes',
      '--format',
      'json',
      ...roots(scope: scope),
    ]);

    test('project install uses the unified Shared directory once', () async {
      final result = await install('project');
      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      expect(
        fs.file('/sandbox/project/.agents/skills/review/SKILL.md').existsSync(),
        isTrue,
      );
      expect(
        fs.directory('/sandbox/gemini/config/skills/review').existsSync(),
        isFalse,
      );
      final list = await run(<String>[
        'skill',
        'list',
        '--format',
        'json',
        ...roots(),
      ]);
      expect(list, isA<MambaSuccessResult>());
      final occurrences =
          (jsonDecode(
                    (list as MambaSuccessResult).output!,
                  )['data']['occurrences']
                  as List)
              .where(
                (occurrence) =>
                    occurrence['path'] ==
                    '/sandbox/project/.agents/skills/review',
              )
              .toList();
      expect(occurrences, hasLength(1));
      expect(occurrences.single['destination'], 'shared');
    });

    test('user install manages Antigravity config skills', () async {
      final result = await install('user');
      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      expect(
        fs.file('/sandbox/gemini/config/skills/review/SKILL.md').existsSync(),
        isTrue,
      );
      expect(
        fs.directory('/sandbox/project/.agents/skills/review').existsSync(),
        isFalse,
      );
    });

    test(
      'validate and inspect understand the Antigravity Skill view',
      () async {
        final valid = await run(<String>[
          'skill',
          'validate',
          '--skill',
          source,
          '--target',
          'antigravity',
        ]);
        expect(
          valid,
          isA<MambaSuccessResult>(),
          reason: valid is MambaFailureResult ? valid.message : null,
        );
        final report = jsonDecode((valid as MambaSuccessResult).output!) as Map;
        final view = (report['views'] as List).single;
        expect(view['consumer'], 'antigravity');
        expect(view['classification'], 'nonPrompt');
        expect(view['valid'], isTrue);

        fs
            .file('$source/SKILL.md')
            .writeAsStringSync(
              '---\nname: review\ndescription: Reviews code.\nallowed-tools: Bash\n---\nBody.\n',
            );
        final invalid = await run(<String>[
          'skill',
          'validate',
          '--skill',
          source,
          '--target',
          'antigravity',
        ]);
        expect(
          invalid,
          isA<MambaFailureResult>()
              .having((result) => result.exitCode, 'exit code', 2)
              .having(
                (result) => result.message,
                'message',
                contains('allowed-tools'),
              ),
        );
      },
    );

    test(
      'canonical install records Antigravity without a second copy',
      () async {
        final result = await run(<String>[
          'skill',
          'install',
          source,
          '--target',
          'antigravity',
          '--source-kind',
          'resource',
          '--method',
          'canonical',
          '--yes',
          '--format',
          'json',
          ...roots(),
        ]);
        expect(
          result,
          isA<MambaSuccessResult>(),
          reason: result is MambaFailureResult ? result.message : null,
        );
        final list = await run(<String>[
          'skill',
          'list',
          '--format',
          'json',
          ...roots(),
        ]);
        final occurrences =
            (jsonDecode(
                      (list as MambaSuccessResult).output!,
                    )['data']['occurrences']
                    as List)
                .where(
                  (occurrence) =>
                      occurrence['path'] ==
                      '/sandbox/project/.agents/skills/review',
                )
                .toList();
        expect(occurrences, hasLength(1));
        expect(occurrences.single['artifactKind'], 'skill-canonical');
        expect(occurrences.single['directConsumers'], contains('antigravity'));
      },
    );

    test(
      'user discovery observes documented Antigravity skill locations',
      () async {
        final legacy = fs.directory('/sandbox/gemini/skills/legacy')
          ..createSync(recursive: true);
        fs
            .file('${legacy.path}/SKILL.md')
            .writeAsStringSync(
              '---\nname: legacy\ndescription: Legacy CLI skill.\n---\nBody.\n',
            );
        final result = await run(<String>[
          'skill',
          'list',
          '--scope',
          'user',
          '--destination',
          'antigravity',
          '--format',
          'json',
          ...roots(scope: 'user'),
        ]);
        expect(
          result,
          isA<MambaSuccessResult>(),
          reason: result is MambaFailureResult ? result.message : null,
        );
        final paths =
            (jsonDecode(
                      (result as MambaSuccessResult).output!,
                    )['data']['occurrences']
                    as List)
                .map((occurrence) => occurrence['path'])
                .toList();
        expect(paths, contains(legacy.path));
      },
    );

    test('adopt replace and remove a user Antigravity Skill', () async {
      final managed = fs.directory('/sandbox/gemini/config/skills/adopted')
        ..createSync(recursive: true);
      fs
          .file('${managed.path}/SKILL.md')
          .writeAsStringSync(
            '---\nname: adopted\ndescription: Initial.\n---\nInitial body.\n',
          );
      final adopt = await run(<String>[
        'skill',
        'adopt',
        '${managed.path}/',
        '--destination',
        'antigravity',
        '--scope',
        'user',
        '--format',
        'json',
        ...roots(scope: 'user'),
      ]);
      expect(
        adopt,
        isA<MambaSuccessResult>(),
        reason: adopt is MambaFailureResult ? adopt.message : null,
      );
      final list = await run(<String>[
        'skill',
        'list',
        '--scope',
        'user',
        '--format',
        'json',
        ...roots(scope: 'user'),
      ]);
      final occurrence =
          (jsonDecode(
                        (list as MambaSuccessResult).output!,
                      )['data']['occurrences']
                      as List)
                  .firstWhere((item) => item['path'] == managed.path)
              as Map;
      final id = occurrence['installationId'] as String;

      final replacement = fs.directory('/sandbox/replacement')..createSync();
      fs
          .file('${replacement.path}/SKILL.md')
          .writeAsStringSync(
            '---\nname: adopted\ndescription: Replaced.\n---\nNew body.\n',
          );
      final replaced = await run(<String>[
        'skill',
        'replace',
        id,
        '${replacement.path}/',
        '--scope',
        'user',
        '--yes',
        '--format',
        'json',
        ...roots(scope: 'user'),
      ]);
      expect(
        replaced,
        isA<MambaSuccessResult>(),
        reason: replaced is MambaFailureResult ? replaced.message : null,
      );
      expect(
        fs.file('${managed.path}/SKILL.md').readAsStringSync(),
        contains('New body.'),
      );

      final removed = await run(<String>[
        'skill',
        'remove',
        id,
        '--scope',
        'user',
        '--yes',
        '--format',
        'json',
        ...roots(scope: 'user'),
      ]);
      expect(
        removed,
        isA<MambaSuccessResult>(),
        reason: removed is MambaFailureResult ? removed.message : null,
      );
      expect(fs.directory(managed.path).existsSync(), isFalse);
    });

    test('skill create writes the Antigravity native field matrix', () async {
      final result = await run(<String>[
        'skill',
        'create',
        '--profile',
        'antigravity',
        '--name',
        'review',
        '--description',
        'Reviews code.',
        '--body-text',
        'Review body.',
        '--apply',
        '--yes',
        '--scope',
        'user',
        '--format',
        'json',
        ...roots(scope: 'user'),
      ]);
      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      final content = fs
          .file('/sandbox/gemini/config/skills/review/SKILL.md')
          .readAsStringSync();
      expect(content, contains('name: "review"'));
      expect(content, contains('description: "Reviews code."'));
      expect(content, isNot(contains('allowed-tools')));
    });
  });
}
