import 'dart:io';

import 'package:agent_resource/src/services/native_link_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

bool _tryDirectoryLink(String path, String target) {
  try {
    Link(path).createSync(target);
    return true;
  } on FileSystemException {
    return false;
  }
}

void main() {
  group('NativeLinkService', () {
    test('refuses ordinary files, directories, and missing entries', () async {
      final sandbox = await Directory.systemTemp.createTemp('native-link-');
      try {
        final service = const NativeLinkService();
        final directory = Directory(p.join(sandbox.path, 'ordinary'))
          ..createSync();
        final file = File(p.join(sandbox.path, 'file'))..writeAsStringSync('x');
        for (final path in [
          directory.path,
          file.path,
          p.join(sandbox.path, 'missing'),
        ]) {
          expect(
            () => service.inspectKind(path),
            throwsA(
              isA<MambaException>().having(
                (error) => error.exitCode,
                'exit code',
                4,
              ),
            ),
          );
        }
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test('inspects a supported directory link and target representation', () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'native-link-real-',
      );
      try {
        final target = Directory(p.join(sandbox.path, 'target'))..createSync();
        final linkPath = p.join(sandbox.path, 'link');
        if (!_tryDirectoryLink(linkPath, target.path)) {
          // The host cannot establish a true directory symlink. This is a real
          // capability refusal, not a Junction/copy fallback.
          return;
        }
        const service = NativeLinkService();
        final kind = service.inspectKind(linkPath);
        expect(
          kind,
          anyOf('posix-directory-symlink', 'windows-directory-symlink'),
        );
        expect(service.readTarget(linkPath), target.path);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'distinguishes dangling directory and file links on Windows',
      () async {
        if (!Platform.isWindows) {
          markTestSkipped('Windows reparse behavior is Windows-only');
          return;
        }
        final sandbox = await Directory.systemTemp.createTemp(
          'native-link-dangling-',
        );
        try {
          const service = NativeLinkService();
          final missingTarget = p.join(sandbox.path, 'missing-target');
          final directoryLink = p.join(sandbox.path, 'directory-link');
          try {
            service.createDirectoryLink(directoryLink, missingTarget);
          } on MambaException {
            markTestSkipped('true directory-symlink creation is unavailable');
            return;
          }
          expect(
            service.inspectKind(directoryLink),
            'windows-directory-symlink',
          );

          final fileLink = p.join(sandbox.path, 'file-link');
          Link(fileLink).createSync(missingTarget);
          expect(
            () => service.inspectKind(fileLink),
            throwsA(
              isA<MambaException>()
                  .having((error) => error.exitCode, 'exit code', 4)
                  .having(
                    (error) => error.message,
                    'message',
                    contains('not a directory'),
                  ),
            ),
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
