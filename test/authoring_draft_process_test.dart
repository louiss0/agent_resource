import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/services/instruction_draft_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/local.dart';
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
    'native protected draft survives restart and has narrow explicit discard',
    () async {
      final sandbox = Directory(
        await createTrustedTempPath('instruction-draft-process-'),
      );
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final input = File(p.join(sandbox.path, 'original.txt'))
          ..writeAsStringSync('PRIVATE DRAFT BODY\r\nPreserve spaces.  \n');
        final original = input.readAsBytesSync();
        final environment = isolatedEnvironment(sandbox);
        final service = InstructionDraftService(
          fileSystem: const LocalFileSystem(),
        );
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          environment: environment,
          projectRoot: project.path,
          home: home.path,
          scope: LifecycleScope.project,
        );
        final draft = await service.prepare(
          options,
          parseAuthoringInputs(
            operation: AuthoringOperation.create,
            kind: AuthoringKind.skill,
            profile: AuthoringProfile.claude,
            bodyFile: input.path,
            output: p.join(project.path, 'source', 'demo'),
            fields: {'name': 'demo', 'description': 'A native draft fixture.'},
          ),
        );
        final working = await service.prepareWorkingCopy(
          options,
          draft.draftId,
        );
        expect(p.extension(working), '.txt');
        expect(File(working).readAsBytesSync(), original);
        final context = [
          '--cwd',
          '${project.path}${p.separator}',
          '--project-root',
          '${project.path}${p.separator}',
          '--home',
          '${home.path}${p.separator}',
          '--format',
          'json',
        ];
        Future<CliProcessResult> run(List<String> arguments) => runDartScript(
          script: entrypoint,
          packageConfig: packageConfig,
          arguments: ['authoring', 'draft', ...arguments, ...context],
          workingDirectory: project,
          environment: environment,
        );
        final files = Directory(draft.path)
            .listSync()
            .whereType<File>()
            .toList();
        final before = {
          for (final file in files) file.path: file.readAsBytesSync(),
        };
        for (final args in [
          <String>['list'],
          ['inspect', draft.draftId],
          ['resume', draft.draftId],
          ['discard', draft.draftId, '--dry-run'],
        ]) {
          final result = await run(args);
          expect(result.exitCode, 0, reason: result.stderr);
          expect(result.stderr, isEmpty);
          expect(result.stdout, isNot(contains('PRIVATE DRAFT BODY')));
          final envelope = jsonDecode(result.stdout) as Map;
          expect(envelope['data'], isA<Map<Object?, Object?>>());
          for (final entry in before.entries) {
            expect(File(entry.key).readAsBytesSync(), entry.value);
          }
          expect(input.readAsBytesSync(), original);
        }
        final refused = await run(['discard', draft.draftId, '--apply']);
        expect(refused.exitCode, 4);
        expect(refused.stdout, isEmpty);
        expect(Directory(draft.path).existsSync(), true);
        final discarded = await run([
          'discard',
          draft.draftId,
          '--apply',
          '--yes',
        ]);
        expect(discarded.exitCode, 0, reason: discarded.stderr);
        expect(discarded.stderr, isEmpty);
        expect(Directory(draft.path).existsSync(), false);
        expect(input.readAsBytesSync(), original);
        expect(
          Directory(p.join(project.path, 'source', 'demo')).existsSync(),
          false,
        );
        expect(
          File(p.join(project.path, '.agent-resource', 'installations.json'))
              .existsSync(),
          false,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
