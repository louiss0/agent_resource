import 'package:agent_resource/src/skill_files.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('createStagingDirectory', () {
    test('creates a distinct directory on every call', () {
      final fs = MemoryFileSystem(style: FileSystemStyle.posix);

      final first = createStagingDirectorySync('staging-', fs: fs);
      final second = createStagingDirectorySync('staging-', fs: fs);

      expect(fs.path.equals(first.path, second.path), isFalse);
      expect(first.existsSync(), isTrue);
      expect(second.existsSync(), isTrue);
    });

    test('an ordinary temporary root keeps its own path', () {
      final fs = MemoryFileSystem(style: FileSystemStyle.posix);

      final staged = createStagingDirectorySync('staging-', fs: fs);

      expect(staged.path, startsWith(fs.systemTempDirectory.path));
      expect(staged.existsSync(), isTrue);
    });

    test(
      'reports the real path of a staging directory behind an alias',
      () async {
        const fs = LocalFileSystem();
        // A host reaches its temporary root through an OS-level alias: macOS
        // resolves /var to /private/var, and a container or runner may mount
        // /tmp the same way. The link-aware guards walk a path from the
        // filesystem root, so content staged behind the alias would be refused
        // before any guard reached the managed area.
        final real = fs.systemTempDirectory.createTempSync('staging-real-');
        // The real directory itself may sit behind a host alias, so the
        // expectation is its resolved path, not the reported one.
        final realPath = real.resolveSymbolicLinksSync();
        final alias = fs.directory(p.join(real.parent.path, 'staging-alias'));
        try {
          await fs.link(alias.path).create(real.path);
        } on FileSystemException {
          markTestSkipped('directory link creation is unavailable');
          return;
        }
        addTearDown(() {
          try {
            alias.deleteSync();
          } on FileSystemException {
            // The link is removed with its target below.
          }
          if (real.existsSync()) real.deleteSync(recursive: true);
        });
        final aliasedFs = _AliasedTempFileSystem(alias.path);

        final staged = await createStagingDirectory('staging-', fs: aliasedFs);
        final stagedSync = createStagingDirectorySync(
          'staging-',
          fs: aliasedFs,
        );

        expect(staged.path, startsWith(realPath));
        expect(stagedSync.path, startsWith(realPath));
        expect(staged.existsSync(), isTrue);
        fs.file(p.join(staged.path, 'entry')).writeAsStringSync('body');
        expect(
          fs.file(p.join(staged.path, 'entry')).readAsStringSync(),
          'body',
        );
      },
    );
  });
}

/// A filesystem whose temporary root is reached through an alias.
final class _AliasedTempFileSystem extends ForwardingFileSystem {
  _AliasedTempFileSystem(this.alias) : super(const LocalFileSystem());

  final String alias;

  @override
  Directory get systemTempDirectory => directory(alias);
}
