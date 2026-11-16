import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/compiled_cli_test_support.dart';
import 'support/process_test_support.dart';
import 'support/trusted_temp.dart';

Future<void> main() async {
  final packageRoot = Directory.current.path;
  final packageConfig = p.join(
    packageRoot,
    '.dart_tool',
    'package_config.json',
  );
  final entrypoint = await compileTestCli(
    script: p.join(packageRoot, 'bin', 'agent_resource.dart'),
    packageConfig: packageConfig,
  );
  test(
    'production prompt inventory succeeds and fails without body or state',
    () async {
      final root = Directory(await createTrustedTempPath('prompt-process-'));
      try {
        final project = Directory(p.join(root.path, 'project'))..createSync();
        final home = Directory(p.join(root.path, 'home'))..createSync();
        final skill = Directory(
          p.join(project.path, '.agents', 'skills', 'manual'),
        )..createSync(recursive: true);
        final marker = File(p.join(skill.path, 'SKILL.md'))
          ..writeAsStringSync(
            '---\nname: manual\ndescription: Manual.\ndisable-model-invocation: true\n---\nPRIVATE INSTRUCTION BODY\n',
          );
        final before = marker.readAsBytesSync();
        Future<CliProcessResult> run([List<String>? arguments]) =>
            runDartScript(
              script: entrypoint,
              packageConfig: packageConfig,
              arguments:
                  arguments ??
                  [
                    'prompt',
                    'list',
                    '--scope',
                    'project',
                    '--cwd',
                    '${project.path}${p.separator}',
                    '--project-root',
                    '${project.path}${p.separator}',
                    '--home',
                    '${home.path}${p.separator}',
                    '--format',
                    'json',
                  ],
              workingDirectory: project,
              environment: isolatedEnvironment(root),
            );
        final success = await run();
        expect(success.exitCode, 0, reason: success.stderr);
        expect(success.stderr, isEmpty);
        expect(success.stdout, isNot(contains('PRIVATE INSTRUCTION BODY')));
        expect((jsonDecode(success.stdout) as Map)['entries'], hasLength(1));
        expect(marker.readAsBytesSync(), before);
        expect(
          Directory(p.join(project.path, '.agent-resource')).existsSync(),
          isFalse,
        );
        final inspected = await run([
          'skill',
          'inspect',
          '--skill',
          skill.path,
        ]);
        expect(inspected.exitCode, 0, reason: inspected.stderr);
        expect(inspected.stderr, isEmpty);
        expect(inspected.stdout, isNot(contains('PRIVATE INSTRUCTION BODY')));
        final native = jsonDecode(inspected.stdout) as Map;
        expect(native['views'], hasLength(3));
        expect(native, isNot(contains('content')));
        final invalidTarget = await run([
          'prompt',
          'validate',
          '--path',
          skill.path,
          '--target',
          'codex',
        ]);
        expect(invalidTarget.exitCode, 2);
        expect(invalidTarget.stdout, isEmpty);
        expect(
          invalidTarget.stderr,
          isNot(contains('PRIVATE INSTRUCTION BODY')),
        );
        final explicitContent = await run([
          'skill',
          'inspect',
          '--skill',
          skill.path,
          '--content',
        ]);
        expect(explicitContent.exitCode, 0);
        expect(
          (jsonDecode(explicitContent.stdout) as Map)['content'],
          marker.readAsStringSync(),
        );
        final badRoot = File(p.join(project.path, '.claude', 'skills'));
        badRoot.parent.createSync(recursive: true);
        badRoot.writeAsStringSync('sentinel');
        final failed = await run();
        expect(failed.exitCode, 3);
        expect(failed.stdout, isEmpty);
        expect(failed.stderr, contains('not a directory'));
        expect(failed.stderr, isNot(contains('PRIVATE INSTRUCTION BODY')));
        expect(marker.readAsBytesSync(), before);
        expect(badRoot.readAsStringSync(), 'sentinel');
        expect(
          Directory(p.join(project.path, '.agent-resource')).existsSync(),
          isFalse,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
