import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('skill edit and clone commands', () {
    late FileSystem fs;
    late Directory source;
    late Directory project;
    late Directory home;
    late Directory gemini;
    late MambaExecutor<MambaExecutionResult> executor;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      final sandbox = fs.directory('/sandbox')..createSync();
      project = fs.directory(fs.path.join(sandbox.path, 'project'))
        ..createSync();
      home = fs.directory(fs.path.join(sandbox.path, 'home'))..createSync();
      gemini = fs.directory(fs.path.join(sandbox.path, 'gemini'))..createSync();
      fs.directory(fs.path.join(sandbox.path, 'state')).createSync();
      source = fs.directory(fs.path.join(sandbox.path, 'source'))
        ..createSync(recursive: true);
      fs
          .file(fs.path.join(source.path, 'SKILL.md'))
          .writeAsStringSync(
            '---\nname: source\ndescription: Source.\n---\nBody.\n',
          );
      executor = createExecutor(
        fileSystem: fs,
        guided: GuidedAuthoringService(fileSystem: fs, terminal: () => false),
      ).fake();
    });

    List<String> context() => <String>[
      '--cwd',
      '${project.path}${fs.path.separator}',
      '--project-root',
      '${project.path}${fs.path.separator}',
      '--home',
      '${home.path}${fs.path.separator}',
      '--gemini-dir',
      '${gemini.path}${fs.path.separator}',
      '--state-dir',
      '${fs.path.join(fs.directory('/sandbox').path, 'state')}${fs.path.separator}',
      '--format',
      'json',
    ];

    Map<String, Object?> dataOf(MambaExecutionResult result) {
      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      final report = jsonDecode(
        (result as MambaSuccessResult).output!,
      ) as Map<String, Object?>;
      return report['data']! as Map<String, Object?>;
    }

    test('registers edit and clone routes with their help', () async {
      final help =
          (await executor.execute(['skill', '--help'])) as MambaSuccessResult;
      expect(help.output, contains('edit'));
      expect(help.output, contains('clone'));

      for (final command in ['edit', 'clone']) {
        final leaf = (await executor.execute([
          'skill',
          command,
          '--help',
        ])) as MambaSuccessResult;
        expect(leaf.output, contains('--harness'));
        expect(leaf.output, contains('--source'));
      }
    });

    test('clones an Antigravity skill into the config skills root', () async {
      final planned = dataOf(
        await executor.execute([
          'skill',
          'clone',
          '--harness',
          'antigravity',
          '--source',
          source.path,
          '--name',
          'copied',
          '--description',
          'Copied skill.',
          '--scope',
          'user',
          ...context(),
        ]),
      );
      expect(planned['ready'], isTrue);
      final output = fs.file(
        fs.path.join(gemini.path, 'config', 'skills', 'copied', 'SKILL.md'),
      );
      expect(output.existsSync(), isFalse);
      final planId = planned['planId']! as String;
      final applied = dataOf(
        await executor.execute([
          'skill',
          'clone',
          '--harness',
          'antigravity',
          '--source',
          source.path,
          '--name',
          'copied',
          '--description',
          'Copied skill.',
          '--scope',
          'user',
          '--apply',
          '--plan-id',
          planId,
          '--yes',
          ...context(),
        ]),
      );
      expect(applied['published'], isTrue);
      expect(output.readAsStringSync(), contains('name: "copied"'));
      expect(
        fs.file(fs.path.join(source.path, 'SKILL.md')).readAsStringSync(),
        contains('name: source'),
      );
    });

    test('edits an Antigravity skill in place', () async {
      final planned = dataOf(
        await executor.execute([
          'skill',
          'edit',
          '--profile',
          'antigravity',
          '--source',
          source.path,
          '--name',
          'source',
          '--description',
          'Source.',
          '--body-text',
          'Edited body.',
          '--scope',
          'user',
          ...context(),
        ]),
      );
      expect(planned['ready'], isTrue);
      final target = planned['target']! as Map<String, Object?>;
      expect(target['output'], fs.path.join(source.path, 'SKILL.md'));
      final applied = dataOf(
        await executor.execute([
          'skill',
          'edit',
          '--profile',
          'antigravity',
          '--source',
          source.path,
          '--name',
          'source',
          '--description',
          'Source.',
          '--body-text',
          'Edited body.',
          '--scope',
          'user',
          '--apply',
          '--plan-id',
          planned['planId']! as String,
          '--yes',
          ...context(),
        ]),
      );
      expect(applied['published'], isTrue);
      expect(
        fs.file(fs.path.join(source.path, 'SKILL.md')).readAsStringSync(),
        contains('Edited body.'),
      );
    });

    test('create accepts the harness alias for the native profile', () async {
      final planned = dataOf(
        await executor.execute([
          'skill',
          'create',
          '--harness',
          'antigravity',
          '--name',
          'alias',
          '--description',
          'Alias skill.',
          '--body-text',
          'Body.',
          '--scope',
          'user',
          ...context(),
        ]),
      );
      expect(planned['profile'], 'antigravity');
      expect(planned['ready'], isTrue);
    });
  });
}
