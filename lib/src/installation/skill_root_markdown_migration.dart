import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

/// The inert staged form of a Skill and its safe migration diagnostics.
final class StagedSkill {
  StagedSkill._(
    this.path,
    this._temporaryRoot,
    this.movedMarkdown,
    this.movedImages,
    this.rewritten,
  );

  final String path;
  final fslib.Directory _temporaryRoot;

  /// Root-relative Markdown paths moved into `references/`, sorted by name.
  final List<String> movedMarkdown;

  /// Root-relative image paths moved into `assets/`, sorted by name.
  final List<String> movedImages;

  /// Whether at least one literal reference in SKILL.md was rewritten.
  final bool rewritten;

  bool get migrated => movedMarkdown.isNotEmpty || movedImages.isNotEmpty;

  Future<void> close() async {
    if (await _temporaryRoot.exists()) {
      await _temporaryRoot.delete(recursive: true);
    }
  }
}

/// Migrates loose root files only in a disposable copy of a Skill source.
final class SkillRootMarkdownMigration {
  const SkillRootMarkdownMigration({
    this.fileSystem = const local.LocalFileSystem(),
  });

  final fslib.FileSystem fileSystem;

  static const _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.ico',
    '.svg',
    '.avif',
    '.tif',
    '.tiff',
  };

  Future<StagedSkill> stage(String sourcePath) async {
    final temporaryRoot = await fileSystem.systemTempDirectory.createTemp(
      'agent-resource-skill-root-files-',
    );
    final stagedPath = fileSystem.path.join(temporaryRoot.path, 'skill');
    try {
      final entries = <int>[0];
      _copyTree(sourcePath, stagedPath, 0, entries);
      final moved = _rootFiles(stagedPath);
      final markdown = moved
          .where(
            (file) =>
                fileSystem.path.extension(file.path).toLowerCase() == '.md',
          )
          .toList();
      final images = moved
          .where(
            (file) =>
                _imageExtensions.contains(fileSystem.path.extension(file.path)),
          )
          .toList();
      moved.removeWhere(
        (file) => !markdown.contains(file) && !images.contains(file),
      );
      if (moved.isNotEmpty) {
        _prepareDestination(stagedPath, 'references', markdown);
        _prepareDestination(stagedPath, 'assets', images);
        var rewritten = false;
        final marker = fileSystem.file(
          fileSystem.path.join(stagedPath, 'SKILL.md'),
        );
        var text = marker.readAsStringSync(encoding: utf8);
        for (final file in moved) {
          final basename = fileSystem.path.basename(file.path);
          final folder =
              fileSystem.path.extension(file.path).toLowerCase() == '.md'
              ? 'references'
              : 'assets';
          file.renameSync(fileSystem.path.join(stagedPath, folder, basename));
          final reference = RegExp(
            '(?<![A-Za-z0-9_/.\\\\:-])(?:\\./)?${RegExp.escape(basename)}(?![A-Za-z0-9_./\\\\-])',
          );
          final updated = text.replaceAll(reference, '$folder/$basename');
          rewritten = rewritten || updated != text;
          text = updated;
        }
        if (rewritten) marker.writeAsStringSync(text, encoding: utf8);
        return StagedSkill._(
          stagedPath,
          temporaryRoot,
          List.unmodifiable([
            for (final file in markdown)
              'references/${fileSystem.path.basename(file.path)}',
          ]),
          List.unmodifiable([
            for (final file in images)
              'assets/${fileSystem.path.basename(file.path)}',
          ]),
          rewritten,
        );
      }
      return StagedSkill._(
        stagedPath,
        temporaryRoot,
        const [],
        const [],
        false,
      );
    } on FormatException {
      await temporaryRoot.delete(recursive: true);
      throw _failure('Skill SKILL.md must contain valid UTF-8 text.');
    } on FileSystemException catch (error) {
      await temporaryRoot.delete(recursive: true);
      throw _failure(
        'Could not stage Skill root files safely: ${error.message}',
      );
    } catch (_) {
      await temporaryRoot.delete(recursive: true);
      rethrow;
    }
  }

  List<fslib.File> _rootFiles(String root) {
    final files =
        <fslib.File>[
          for (final entity
              in fileSystem.directory(root).listSync(followLinks: false))
            if (fileSystem.path.basename(entity.path) != 'SKILL.md' &&
                fileSystem.typeSync(entity.path, followLinks: false) ==
                    FileSystemEntityType.file)
              entity as fslib.File,
        ]..sort(
          (left, right) => fileSystem.path
              .basename(left.path)
              .compareTo(fileSystem.path.basename(right.path)),
        );
    return files;
  }

  void _prepareDestination(String root, String folder, List<fslib.File> files) {
    if (files.isEmpty) return;
    final destination = fileSystem.path.join(root, folder);
    final type = fileSystem.typeSync(destination, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      fileSystem.directory(destination).createSync();
    } else if (type != FileSystemEntityType.directory) {
      throw _failure('Skill $folder must be a real directory.');
    }
    for (final file in files) {
      final basename = fileSystem.path.basename(file.path);
      if (fileSystem.typeSync(
            fileSystem.path.join(destination, basename),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw _failure('Skill root file cannot overwrite $folder/$basename.');
      }
    }
  }

  void _copyTree(
    String source,
    String destination,
    int depth,
    List<int> entries,
  ) {
    if (depth > 32) {
      throw _failure('The Skill tree exceeds the depth-32 budget.');
    }
    final type = fileSystem.typeSync(source, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        fileSystem.directory(destination).createSync();
        final children =
            fileSystem.directory(source).listSync(followLinks: false)
              ..sort((left, right) => left.path.compareTo(right.path));
        for (final entity in children) {
          if (++entries[0] > 10000) {
            throw _failure('The Skill tree exceeds the 10,000-entry budget.');
          }
          _copyTree(
            entity.path,
            fileSystem.path.join(
              destination,
              fileSystem.path.basename(entity.path),
            ),
            depth + 1,
            entries,
          );
        }
      case FileSystemEntityType.file:
        fileSystem.file(source).copySync(destination);
      case FileSystemEntityType.link:
        fileSystem
            .link(destination)
            .createSync(fileSystem.link(source).targetSync());
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        throw _failure(
          'Skill source contains an unsupported filesystem entry.',
        );
    }
  }

  MambaException _failure(String message) =>
      MambaException(message, exitCode: 4);
}
