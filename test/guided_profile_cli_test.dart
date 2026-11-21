import 'dart:convert';
import 'dart:io' show Platform, Process;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart' show ProcessedStandardInput;
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
        test('offers user scope when the project root is unusable', () async {
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
                    return 'user';
                  },
                ),
              ).fake().execute([
                'skill',
                'create',
                '--cwd',
                '/project/',
                '--project-root',
                '/missing/',
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
                '--dry-run',
              ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          expect(questions.single, contains('user'));
          expect((result as MambaSuccessResult).output, contains('/home/'));
          expect(fs.directory('/home/.claude').existsSync(), isFalse);
        });
        test(
          'does not fall back without consent or override explicit scope',
          () async {
            for (final explicit in [false, true]) {
              final fs = MemoryFileSystem(style: FileSystemStyle.posix);
              fs.directory('/project').createSync();
              fs.directory('/home').createSync();
              var questions = 0;
              final result =
                  await createExecutor(
                    fileSystem: fs,
                    guided: GuidedAuthoringService(
                      fileSystem: fs,
                      terminal: () => true,
                      ask: (_) async {
                        questions++;
                        return null;
                      },
                    ),
                  ).fake().execute([
                    'skill',
                    'create',
                    '--cwd',
                    '/project/',
                    '--project-root',
                    '/missing/',
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
                    '--dry-run',
                    if (explicit) ...['--scope', 'project'],
                  ]);
              expect(result, isA<MambaFailureResult>());
              expect(questions, explicit ? 0 : 1);
              expect(fs.directory('/home/.claude').existsSync(), isFalse);
            }
          },
        );
        test('re-prompts with the choices after an invalid profile', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          fs.directory('/project').createSync();
          fs.directory('/home').createSync();
          final answers = ['invalid', 'claude'].iterator;
          final questions = <String>[];
          final result =
              await createExecutor(
                fileSystem: fs,
                guided: GuidedAuthoringService(
                  fileSystem: fs,
                  terminal: () => true,
                  ask: (question) async {
                    questions.add(question);
                    answers.moveNext();
                    return answers.current;
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
          expect(questions, hasLength(2));
          expect(questions.last, contains('claude'));
        });
        test('prints a replayable command including a guided field', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          fs.directory('/project').createSync();
          fs.directory('/home').createSync();
          fs.file('/project/body file.txt').writeAsStringSync('SECRET BODY');
          final result =
              await createExecutor(
                fileSystem: fs,
                guided: GuidedAuthoringService(
                  fileSystem: fs,
                  terminal: () => true,
                  ask: (_) async => "Reviewer's work",
                ),
              ).fake().execute([
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
                '--body-file',
                '/project/body file.txt',
              ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final output = (result as MambaSuccessResult).output!;
          expect(output, contains('Explicit command'));
          expect(output, isNot(contains('SECRET BODY')));
          final command = output.split('\n').last.split('): ').last;
          final shell = await Process.run(
            Platform.isWindows ? 'powershell.exe' : 'sh',
            Platform.isWindows
                ? [
                    '-NoProfile',
                    '-Command',
                    'function agent_resource { \$args | ConvertTo-Json -Compress }; $command',
                  ]
                : [
                    '-c',
                    'agent_resource() { printf "%s\\n" "\$@"; }; $command',
                  ],
          );
          expect(shell.exitCode, 0, reason: '${shell.stderr}');
          final args = Platform.isWindows
              ? (jsonDecode(shell.stdout as String) as List).cast<String>()
              : (shell.stdout as String).trimRight().split('\n');
          expect(
            args,
            containsAllInOrder(['--description', "Reviewer's work"]),
          );
          final replay = await createExecutor(
            fileSystem: fs,
            guided: GuidedAuthoringService(
              fileSystem: fs,
              terminal: () => false,
            ),
          ).fake().execute(args);
          expect(
            replay,
            isA<MambaSuccessResult>(),
            reason: replay is MambaFailureResult ? replay.message : null,
          );
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
          final output = (result as MambaSuccessResult).output!;
          expect(output, contains('planned'));
          expect(output, contains('--body-stdin'));
          expect(
            output,
            contains('provide the original instruction text on stdin'),
          );
          expect(output, isNot(contains('--body-text Body.')));
          final command = output.split('\n').last.split('): ').last;
          final shell = await Process.run(
            Platform.isWindows ? 'powershell.exe' : 'sh',
            Platform.isWindows
                ? [
                    '-NoProfile',
                    '-Command',
                    'function agent_resource { \$args | ConvertTo-Json -Compress }; $command',
                  ]
                : [
                    '-c',
                    'agent_resource() { printf "%s\\n" "\$@"; }; $command',
                  ],
          );
          expect(shell.exitCode, 0, reason: '${shell.stderr}');
          final args = Platform.isWindows
              ? (jsonDecode(shell.stdout as String) as List).cast<String>()
              : (shell.stdout as String).trimRight().split('\n');
          final replay =
              await createExecutor(
                    fileSystem: fs,
                    guided: GuidedAuthoringService(
                      fileSystem: fs,
                      terminal: () => false,
                    ),
                  )
                  .fake(
                    standardInput: ProcessedStandardInput(utf8.encode('Body.')),
                  )
                  .execute(args);
          expect(
            replay,
            isA<MambaSuccessResult>(),
            reason: replay is MambaFailureResult ? replay.message : null,
          );
        });
      });
    });
  });
}
