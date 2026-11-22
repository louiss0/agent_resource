import 'dart:convert';
import 'dart:io' as dartio;

import 'package:agent_resource/src/services/configuration_publication_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart' show MambaException;
import 'package:test/test.dart';

void main() {
  group('ConfigurationPublicationService', () {
    test('refuses a stale source before building a proposal', () async {
      final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
      const target = '/sandbox/project/agent-resources.toml';
      _prepare(fileSystem, target, 'current source\n');
      final io = _RecordingIO(fs: fileSystem);
      final service = ConfigurationPublicationService(
        fileSystem: fileSystem,
        io: io,
        state: LifecycleStateService(io: io),
      );
      var proposed = false;

      await expectLater(
        service.publish(
          ConfigurationPublicationRequest(
            context: _context(fileSystem),
            targetPath: target,
            expectedSource: 'reviewed source\n',
            propose: (String source) {
              proposed = true;
              return '$source changed\n';
            },
          ),
        ),
        throwsA(
          isA<MambaException>()
              .having(
                (error) => error.message,
                'message',
                contains('Configuration changed after review'),
              )
              .having((error) => error.exitCode, 'exit code', 4),
        ),
      );
      expect(proposed, isFalse);
      expect(fileSystem.file(target).readAsStringSync(), 'current source\n');
      expect(io.operations.where((event) => event == 'write:$target'), isEmpty);
      expect(
        io.operations.where((event) => event == 'delete:$target'),
        isEmpty,
      );
    });

    test('publishes through staged rename with retained evidence', () async {
      final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
      const target = '/sandbox/project/agent-resources.toml';
      const original = '# original\nschema_version = 1\n';
      const proposed = '# proposed\nschema_version = 1\n';
      _prepare(fileSystem, target, original);
      final io = _RecordingIO(fs: fileSystem);
      final service = ConfigurationPublicationService(
        fileSystem: fileSystem,
        io: io,
        state: LifecycleStateService(io: io),
      );

      final result = await service.publish(
        ConfigurationPublicationRequest(
          context: _context(fileSystem),
          targetPath: target,
          expectedSource: original,
          propose: (String source) {
            expect(source, original);
            return proposed;
          },
        ),
      );

      expect(result.publishedSource, proposed);
      expect(fileSystem.file(target).readAsStringSync(), proposed);
      expect(
        utf8.decode(fileSystem.file(result.backupPath!).readAsBytesSync()),
        original,
      );
      final transaction = jsonDecode(
        utf8.decode(fileSystem.file(result.transactionPath).readAsBytesSync()),
      ) as Map<String, dynamic>;
      expect(transaction['phase'], 'committed');
      expect(io.operations.where((event) => event == 'write:$target'), isEmpty);
      expect(
        io.operations.where((event) => event == 'delete:$target'),
        isEmpty,
      );
      expect(
        fileSystem
            .directory('/sandbox/project')
            .listSync()
            .where((entity) => entity.path.contains('agent-resource-prefer-')),
        isEmpty,
      );
    });

    test('refuses a symlink replacement race without overwriting it', () async {
      final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
      const target = '/sandbox/project/agent-resources.toml';
      const real = '/sandbox/project/real.toml';
      const original = '# original\nschema_version = 1\n';
      _prepare(fileSystem, target, original);
      fileSystem.file(real).writeAsStringSync('real bytes\n');
      final io = _RecordingIO(fs: fileSystem)
        ..createSymlinkAtTargetOnStagedWrite = target
        ..symlinkTarget = real;
      final service = ConfigurationPublicationService(
        fileSystem: fileSystem,
        io: io,
        state: LifecycleStateService(io: io),
      );

      await expectLater(
        service.publish(
          ConfigurationPublicationRequest(
            context: _context(fileSystem),
            targetPath: target,
            expectedSource: original,
            propose: (String source) => '# proposed\nschema_version = 1\n',
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('Cannot safely publish'),
          ),
        ),
      );
      expect(
        fileSystem.typeSync(target, followLinks: false),
        dartio.FileSystemEntityType.link,
      );
      expect(fileSystem.file(real).readAsStringSync(), 'real bytes\n');
      expect(io.operations.where((event) => event == 'write:$target'), isEmpty);
      expect(
        io.operations.where((event) => event == 'delete:$target'),
        isEmpty,
      );
      expect(
        io.operations.where((event) => event.contains('config.toml')),
        isNot(contains(contains('rename'))),
      );
    });

    test('refuses a creation race and leaves the new file unchanged', () async {
      final fileSystem = MemoryFileSystem(style: FileSystemStyle.posix);
      const target = '/sandbox/project/agent-resources.toml';
      _prepare(fileSystem, target, null);
      final io = _RecordingIO(fs: fileSystem)
        ..createFileAtTargetOnStagedWrite = target
        ..externalSource = 'external update\n';
      final service = ConfigurationPublicationService(
        fileSystem: fileSystem,
        io: io,
        state: LifecycleStateService(io: io),
      );

      await expectLater(
        service.publish(
          ConfigurationPublicationRequest(
            context: _context(fileSystem),
            targetPath: target,
            expectedSource: '',
            propose: (String source) {
              expect(source, isEmpty);
              return 'schema_version = 1\n';
            },
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('target changed'),
          ),
        ),
      );
      expect(fileSystem.file(target).readAsStringSync(), 'external update\n');
      expect(io.operations.where((event) => event == 'write:$target'), isEmpty);
      expect(
        io.operations.where((event) => event == 'delete:$target'),
        isEmpty,
      );
    });
  });
}

void _prepare(MemoryFileSystem fileSystem, String target, String? source) {
  fileSystem.directory('/sandbox/project').createSync(recursive: true);
  if (source != null) {
    fileSystem.file(target).writeAsStringSync(source);
  }
}

LifecycleContext _context(fslib.FileSystem fileSystem) =>
    LifecycleContext.resolve(
      LifecycleOptions(
        processWorkingDirectory: '/',
        environment: const <String, String>{'HOME': '/sandbox/home'},
        scope: LifecycleScope.project,
        cwd: '/sandbox/project/',
        projectRoot: '/sandbox/project/',
      ),
      fileSystem: fileSystem,
    );

final class _RecordingIO extends LifecycleIO {
  _RecordingIO({required super.fs});

  final List<String> operations = <String>[];
  String? createSymlinkAtTargetOnStagedWrite;
  String? symlinkTarget;
  String? createFileAtTargetOnStagedWrite;
  String? externalSource;
  var _raced = false;

  @override
  void before(String operation, String path) {
    operations.add('$operation:$path');
    if (_raced || operation != 'write' || !path.endsWith('config.toml')) {
      return;
    }
    _raced = true;
    final linkTarget = createSymlinkAtTargetOnStagedWrite;
    if (linkTarget != null && symlinkTarget != null) {
      if (fs.typeSync(linkTarget, followLinks: false) ==
          dartio.FileSystemEntityType.notFound) {
        fs.link(linkTarget).createSync(symlinkTarget!);
      }
    }
    final createdTarget = createFileAtTargetOnStagedWrite;
    if (createdTarget != null && externalSource != null) {
      if (fs.typeSync(createdTarget, followLinks: false) ==
          dartio.FileSystemEntityType.notFound) {
        fs.file(createdTarget).writeAsStringSync(externalSource!);
      }
    }
  }
}
