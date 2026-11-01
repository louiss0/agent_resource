import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

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
  final Directory _temporaryRoot;

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
  const SkillRootMarkdownMigration();

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
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'agent-resource-skill-root-files-',
    );
    final stagedPath = p.join(temporaryRoot.path, 'skill');
    try {
      final entries = <int>[0];
      _copyTree(sourcePath, stagedPath, 0, entries);
      final moved = _rootFiles(stagedPath);
      final markdown = moved
          .where((file) => p.extension(file.path).toLowerCase() == '.md')
          .toList();
      final images = moved
          .where(
            (file) =>
                _imageExtensions.contains(p.extension(file.path).toLowerCase()),
          )
          .toList();
      moved.removeWhere(
        (file) => !markdown.contains(file) && !images.contains(file),
      );
      if (moved.isNotEmpty) {
        _prepareDestination(stagedPath, 'references', markdown);
        _prepareDestination(stagedPath, 'assets', images);
        var rewritten = false;
        final marker = File(p.join(stagedPath, 'SKILL.md'));
        var text = marker.readAsStringSync(encoding: utf8);
        for (final file in moved) {
          final basename = p.basename(file.path);
          final folder = p.extension(file.path).toLowerCase() == '.md'
              ? 'references'
              : 'assets';
          file.renameSync(p.join(stagedPath, folder, basename));
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
            for (final file in markdown) 'references/${p.basename(file.path)}',
          ]),
          List.unmodifiable([
            for (final file in images) 'assets/${p.basename(file.path)}',
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

  List<File> _rootFiles(String root) {
    final files =
        <File>[
          for (final entity in Directory(root).listSync(followLinks: false))
            if (p.basename(entity.path) != 'SKILL.md' &&
                FileSystemEntity.typeSync(entity.path, followLinks: false) ==
                    FileSystemEntityType.file)
              entity as File,
        ]..sort(
          (left, right) =>
              p.basename(left.path).compareTo(p.basename(right.path)),
        );
    return files;
  }

  void _prepareDestination(String root, String folder, List<File> files) {
    if (files.isEmpty) return;
    final destination = p.join(root, folder);
    final type = FileSystemEntity.typeSync(destination, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      Directory(destination).createSync();
    } else if (type != FileSystemEntityType.directory) {
      throw _failure('Skill $folder must be a real directory.');
    }
    for (final file in files) {
      final basename = p.basename(file.path);
      if (FileSystemEntity.typeSync(
            p.join(destination, basename),
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
    final type = FileSystemEntity.typeSync(source, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        Directory(destination).createSync();
        final children = Directory(source).listSync(followLinks: false)
          ..sort((left, right) => left.path.compareTo(right.path));
        for (final entity in children) {
          if (++entries[0] > 10000) {
            throw _failure('The Skill tree exceeds the 10,000-entry budget.');
          }
          _copyTree(
            entity.path,
            p.join(destination, p.basename(entity.path)),
            depth + 1,
            entries,
          );
        }
      case FileSystemEntityType.file:
        File(source).copySync(destination);
      case FileSystemEntityType.link:
        Link(destination).createSync(Link(source).targetSync());
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
