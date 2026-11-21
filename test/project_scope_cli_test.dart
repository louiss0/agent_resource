import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('agent', () {
      group('list', () {
        test(
          'offers user inventory when project context is unavailable',
          () async {
            final fs = MemoryFileSystem(style: FileSystemStyle.posix);
            fs.directory('/project').createSync();
            fs.directory('/home/.claude/agents').createSync(recursive: true);
            fs
                .file('/home/.claude/agents/reviewer.md')
                .writeAsStringSync(
                  '---\nname: reviewer\ndescription: Reviews.\n---\nBody.\n',
                );
            var asked = 0;
            final result =
                await createExecutor(
                  fileSystem: fs,
                  guided: GuidedAuthoringService(
                    fileSystem: fs,
                    terminal: () => true,
                    ask: (_) async {
                      asked++;
                      return 'user';
                    },
                  ),
                ).fake().execute([
                  'agent',
                  'list',
                  '--cwd',
                  '/project/',
                  '--project-root',
                  '/missing/',
                  '--home',
                  '/home/',
                ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(asked, 1);
            expect((result as MambaSuccessResult).output, contains('reviewer'));
          },
        );
      });
    });
    for (final kind in ['skill', 'prompt']) {
      group(kind, () {
        group('list', () {
          test(
            'offers user inventory when project context is unavailable',
            () async {
              final fs = MemoryFileSystem(style: FileSystemStyle.posix);
              fs.directory('/project').createSync();
              fs
                  .directory('/home/.agents/skills/example')
                  .createSync(recursive: true);
              fs
                  .file('/home/.agents/skills/example/SKILL.md')
                  .writeAsStringSync(
                    '---\nname: example\ndescription: Example.\ndisable-model-invocation: true\n---\nBody.\n',
                  );
              var asked = 0;
              final result =
                  await createExecutor(
                    fileSystem: fs,
                    guided: GuidedAuthoringService(
                      fileSystem: fs,
                      terminal: () => true,
                      ask: (_) async {
                        asked++;
                        return 'user';
                      },
                    ),
                  ).fake().execute([
                    kind,
                    'list',
                    '--cwd',
                    '/project/',
                    '--project-root',
                    '/missing/',
                    '--home',
                    '/home/',
                  ]);
              expect(
                result,
                isA<MambaSuccessResult>(),
                reason: result is MambaFailureResult ? result.message : null,
              );
              expect(asked, 1);
              expect(
                (result as MambaSuccessResult).output,
                contains('/home/.agents/skills/example'),
              );
            },
          );
          test('defaults to project inventory', () async {
            final fs = MemoryFileSystem(style: FileSystemStyle.posix);
            fs
                .directory('/project/.agents/skills/example')
                .createSync(recursive: true);
            fs.directory('/home').createSync();
            fs
                .file('/project/.agents/skills/example/SKILL.md')
                .writeAsStringSync(
                  '---\nname: example\ndescription: Example.\ndisable-model-invocation: true\n---\nBody.\n',
                );
            final result = await createExecutor(fileSystem: fs).fake().execute([
              kind,
              'list',
              '--cwd',
              '/project/',
              '--home',
              '/home/',
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(
              (result as MambaSuccessResult).output,
              contains('/project/.agents/skills/example'),
            );
          });
        });
      });
    }
  });
}
