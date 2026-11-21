import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('agent', () {
      group('create', () {
        test(
          'unattended bound-role publication requires explicit scope',
          () async {
            final fs = MemoryFileSystem(style: FileSystemStyle.posix);
            fs.directory('/project').createSync();
            fs.directory('/home').createSync();
            final result = await createExecutor(fileSystem: fs).fake().execute([
              'agent',
              'create',
              '--cwd',
              '/project/',
              '--home',
              '/home/',
              '--role-key',
              'reviewer',
              '--apply',
              '--yes',
              '--unattended',
            ]);
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((v) => v.exitCode, 'exit code', 4)
                  .having(
                    (v) => v.message,
                    'message',
                    'Unattended publication requires explicit --scope project|user.',
                  )
                  .having((v) => v.output, 'output', isNull),
            );
            expect(fs.directory('/project/.codex').existsSync(), isFalse);
          },
        );
      });
    });
    group('skill', () {
      group('create', () {
        test('unattended publication requires an explicit scope', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          fs.directory('/project').createSync();
          fs.directory('/home').createSync();
          final result = await createExecutor(fileSystem: fs).fake().execute([
            'skill',
            'create',
            '--cwd',
            '/project/',
            '--home',
            '/home/',
            '--profile',
            'claude',
            '--name',
            'demo',
            '--description',
            'Demo.',
            '--body-text',
            'Body.',
            '--apply',
            '--yes',
            '--unattended',
          ]);
          expect(result, isA<MambaFailureResult>());
          expect((result as MambaFailureResult).message, contains('--scope'));
          expect(fs.directory('/project/.claude').existsSync(), isFalse);
        });
        test('guides the missing native profile', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          fs.directory('/project').createSync();
          fs.directory('/home').createSync();
          final questions = <String>[];
          final result =
              await createExecutor(
                fileSystem: fs,
                guided: GuidedAuthoringService(
                  fileSystem: fs,
                  terminal: () => true,
                  ask: (question) async {
                    questions.add(question);
                    return 'claude';
                  },
                ),
              ).fake().execute([
                'skill',
                'create',
                '--cwd',
                '/project/',
                '--home',
                '/home/',
                '--name',
                'demo',
                '--description',
                'Demo.',
                '--body-text',
                'Body.',
              ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          expect(questions.single, contains('claude'));
          expect(questions.single, contains('codex'));
          expect(questions.single, contains('pi'));
          expect(questions.single, contains('antigravity'));
          expect((result as MambaSuccessResult).output, contains('planned'));
        });
      });
    });
  });
}
