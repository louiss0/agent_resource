import 'package:agent_resource/agent_resource.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('context', () {
      group('inject', () {
        late fslib.FileSystem fs;

        List<String> command(List<String> extra) => <String>[
          'context',
          'inject',
          ...extra,
          '--harness',
          'claude',
          '--apply',
          '--yes',
          '--unattended',
          '--scope',
          'project',
          '--cwd',
          '/sandbox/project/',
          '--project-root',
          '/sandbox/project/',
          '--home',
          '/sandbox/home/',
          '--state-dir',
          '/sandbox/state/',
        ];

        void writeTemplate(String content) {
          fs.file('/sandbox/state/context-templates/notes.md')
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(content);
        }

        Future<MambaExecutionResult> inject() =>
            createExecutor(fileSystem: fs)
                .fake()
                .execute(command(const <String>['notes']));

        setUp(() {
          fs = MemoryFileSystem(style: FileSystemStyle.posix);
          for (final directory in [
            '/sandbox/project',
            '/sandbox/home',
            '/sandbox/state',
          ]) {
            fs.directory(directory).createSync(recursive: true);
          }
        });

        test('creates a target with exactly one trailing newline', () async {
          writeTemplate('fresh rules');

          final result = await inject();
          expect(result, isA<MambaSuccessResult>());
          expect(
            fs.file('/sandbox/project/CLAUDE.md').readAsStringSync(),
            'fresh rules\n',
          );
        });

        test('appends with exactly one blank-line separator', () async {
          writeTemplate('\nnew rules');
          fs
              .file('/sandbox/project/CLAUDE.md')
              .writeAsStringSync('old rules\n\n\n');

          final result = await inject();
          expect(result, isA<MambaSuccessResult>());
          expect(
            fs.file('/sandbox/project/CLAUDE.md').readAsStringSync(),
            'old rules\n\nnew rules\n',
          );
        });

        test('replaces the target bytes when requested', () async {
          writeTemplate('fresh rules');
          fs
              .file('/sandbox/project/CLAUDE.md')
              .writeAsStringSync('old rules\n');

          final result = await createExecutor(fileSystem: fs)
              .fake()
              .execute(command(const <String>['notes', '--replace']));
          expect(result, isA<MambaSuccessResult>());
          expect(
            fs.file('/sandbox/project/CLAUDE.md').readAsStringSync(),
            'fresh rules\n',
          );
        });

        test('creates a zero-byte target from an empty template', () async {
          writeTemplate('');

          final result = await inject();
          expect(result, isA<MambaSuccessResult>());
          expect(
            fs.file('/sandbox/project/CLAUDE.md').readAsBytesSync(),
            isEmpty,
          );
        });
      });
    });
  });
}
