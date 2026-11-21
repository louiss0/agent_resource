import 'package:agent_resource/agent_resource.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    for (final kind in ['skill', 'prompt']) {
      group(kind, () {
        group('list', () {
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
