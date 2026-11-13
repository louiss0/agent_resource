import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'support/compiled_cli_test_support.dart';
import 'support/process_test_support.dart';

Future<void> main() async {
  final project = const LocalFileSystem().currentDirectory.path;
  final packageConfig = path.join(project, '.dart_tool', 'package_config.json');
  final entrypoint = await compileTestCli(
    script: path.join(project, 'bin', 'agent_resource.dart'),
    packageConfig: packageConfig,
  );
  group('agent_resource skill validate', () {
    late MemoryFileSystem fs;
    late String skill;

    setUp(() {
      fs = MemoryFileSystem.test(style: FileSystemStyle.posix);
      skill = '/valid-skill';
      fs.directory(skill).createSync();
      fs
          .file('$skill/SKILL.md')
          .writeAsStringSync(
            '---\nname: valid-skill\ndescription: valid\n---\nsecret body\n',
          );
    });

    Future<MambaExecutionResult> run(List<String> args) =>
        createExecutor(fileSystem: fs)
            .fake()
            .execute(['skill', 'validate', ...args]);

    test('help advertises native target and selected directory', () async {
      final result = await run(['--help']);
      expect(
        result,
        isA<MambaSuccessResult>().having(
          (r) => r.output,
          'help',
          allOf(
            contains('--skill'),
            contains('--target'),
            contains('SKILL.md'),
          ),
        ),
      );
    });

    for (final args in <List<String>>[
      [],
      ['--skill'],
      ['--skill', ''],
      ['--unknown'],
      ['--skill', '/valid-skill', 'extra'],
      ['--skill', '/valid-skill', '--target', 'unknown'],
    ]) {
      test('rejects invalid arguments $args before execution', () async {
        final result = await run(args);
        expect(
          result,
          isA<MambaFailureResult>()
              .having((r) => r.error.phase, 'phase', MambaExecutionPhase.parse)
              .having((r) => r.output, 'output', isNull),
        );
      });
    }

    test(
      'reports three native views without universal validity or body',
      () async {
        final result = await run(['--skill', skill]);
        expect(
          result,
          isA<MambaSuccessResult>().having((r) => r.exitCode, 'exit', 0),
        );
        final output = (result as MambaSuccessResult).output!;
        expect(output, isNot(contains('secret body')));
        final report = jsonDecode(output) as Map;
        expect(report['path'], skill);
        expect(report, isNot(contains('valid')));
        expect(report, isNot(contains('classification')));
        final views = (report['views'] as List).cast<Map<Object?, Object?>>();
        expect(views.map((v) => v['consumer']), ['claude', 'codex', 'pi']);
        expect(
          views.every(
            (v) => v['classification'] == 'nonPrompt' && v['valid'] == true,
          ),
          isTrue,
        );
      },
    );

    test(
      'reused adapter reflects invalid then valid source without mutation',
      () async {
        final marker = fs.file('$skill/SKILL.md');
        final adapter = createExecutor(fileSystem: fs).fake();
        final valid = marker.readAsStringSync();
        expect(
          await adapter.execute(['skill', 'validate', '--skill', skill]),
          isA<MambaSuccessResult>(),
        );
        marker.writeAsStringSync('---\nname: [\n---\nsecret body');
        final invalidBytes = marker.readAsBytesSync();
        final failure = await adapter.execute([
          'skill',
          'validate',
          '--skill',
          skill,
        ]);
        expect(
          failure,
          isA<MambaFailureResult>().having((r) => r.exitCode, 'exit', 2),
        );
        expect(
          (failure as MambaFailureResult).message,
          isNot(contains('secret body')),
        );
        expect(marker.readAsBytesSync(), invalidBytes);
        marker.writeAsStringSync(valid);
        expect(
          await adapter.execute(['skill', 'validate', '--skill', skill]),
          isA<MambaSuccessResult>(),
        );
        expect(marker.readAsStringSync(), valid);
      },
    );

    test('missing and file roots fail operationally', () async {
      fs.file('/file').writeAsStringSync('file');
      for (final root in ['/missing', '/file']) {
        final result = await run(['--skill', root]);
        expect(
          result,
          isA<MambaFailureResult>()
              .having((r) => r.exitCode, 'exit', 1)
              .having((r) => r.error.phase, 'phase', MambaExecutionPhase.run),
        );
      }
    });

    group('production process', () {
      test('valid stdout and invalid stderr carry body-free native reports', () async {
        const local = LocalFileSystem();
        final root = await local.systemTempDirectory.createTemp(
          'agent-resource-native-validate-',
        );
        try {
          final dir = local.directory(path.join(root.path, 'valid-skill'))
            ..createSync();
          final marker = local.file(path.join(dir.path, 'SKILL.md'))
            ..writeAsStringSync(
              '---\nname: valid-skill\ndescription: valid\n---\nsecret body\n',
            );
          Future<CliProcessResult> invoke(List<String> args) => runDartScript(
            script: entrypoint,
            packageConfig: packageConfig,
            arguments: args,
            workingDirectory: root,
            environment: isolatedEnvironment(root),
          );
          final valid = await invoke([
            'skill',
            'validate',
            '--skill',
            dir.path,
            '--target',
            'codex',
          ]);
          expect(valid.exitCode, 0);
          expect(valid.stderr, isEmpty);
          expect(valid.stdout, isNot(contains('secret body')));
          final success = jsonDecode(valid.stdout) as Map;
          expect(
            (success['views'] as List).single['classification'],
            'nonPrompt',
          );
          expect((success['views'] as List).single['valid'], true);

          marker.writeAsStringSync('---\nname: [\n---\nsecret body\n');
          final invalid = await invoke([
            'skill',
            'validate',
            '--skill',
            dir.path,
            '--target',
            'claude',
          ]);
          expect(invalid.exitCode, 2);
          expect(invalid.stdout, isEmpty);
          expect(invalid.stderr, isNot(contains('secret body')));
          final plain = invalid.stderr.replaceAll(
            RegExp(r'\x1B\[[0-9;]*m'),
            '',
          );
          final failure = jsonDecode(plain) as Map;
          expect((failure['views'] as List).single['valid'], false);
          expect(failure, isNot(contains('valid')));

          final missing = await invoke([
            'skill',
            'validate',
            '--skill',
            path.join(root.path, 'missing'),
          ]);
          expect(missing.exitCode, 1);
          expect(missing.stdout, isEmpty);
          expect(missing.stderr, contains('missing'));
        } finally {
          await root.delete(recursive: true);
        }
      });
    });
  });
}
