import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../skill_files.dart';
import '../skill_validation.dart';
import 'pack_models.dart';

final class SkillAdmissionReport {
  const SkillAdmissionReport({
    required this.name,
    required this.approvedExtraFolders,
  });

  final String name;
  final Set<String> approvedExtraFolders;
}

/// Validates the complete native Skill root without executing its contents.
final class SkillAdmission {
  const SkillAdmission({this.fileSystem = const local.LocalFileSystem()});

  final fslib.FileSystem fileSystem;
  static const _supportedFolders = <String>{
    'references',
    'scripts',
    'assets',
    'agents',
  };

  SkillAdmissionReport inspect(
    String path, {
    Set<String> approvedExtraFolders = const <String>{},
  }) {
    for (final folder in approvedExtraFolders) {
      if (folder.isEmpty ||
          folder == '.' ||
          folder == '..' ||
          fileSystem.path.basename(folder) != folder ||
          folder == 'SKILL.md' ||
          _supportedFolders.contains(folder)) {
        throw MambaException(
          'An extra-folder approval must name one non-native root folder: $folder',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
    if (skillEntityType(path, followLinks: false, fs: fileSystem) !=
        FileSystemEntityType.directory) {
      throw MambaException(
        'A Skill pack entry must be a real directory: $path',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }

    final extras = <String>{};
    for (final entity in listSkillDirectory(path, fs: fileSystem)) {
      final name = fileSystem.path.basename(entity.path);
      final type = skillEntityType(
        entity.path,
        followLinks: false,
        fs: fileSystem,
      );
      if (name == 'SKILL.md') {
        if (type != FileSystemEntityType.file) {
          throw MambaException(
            'Skill root entry SKILL.md must be a regular file.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        continue;
      }
      if (type == FileSystemEntityType.file) {
        throw MambaException(
          'Unexpected loose Skill root file $name; the complete Skill is rejected.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      if (type != FileSystemEntityType.directory) {
        throw MambaException(
          'Unsupported or linked Skill root entry: $name',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      if (!_supportedFolders.contains(name) &&
          !approvedExtraFolders.contains(name)) {
        throw MambaException(
          'Skill root folder $name requires approval for this managed installation.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      if (!_supportedFolders.contains(name)) extras.add(name);
    }

    _checkRecursiveEntries(path);
    return SkillAdmissionReport(
      name: readDeclaredSkillName(path, fs: fileSystem),
      approvedExtraFolders: Set<String>.unmodifiable(extras),
    );
  }

  void _checkRecursiveEntries(String root) {
    var count = 0;
    void visit(String path, int depth) {
      if (depth > 32) {
        throw MambaException(
          'The Skill tree exceeds the depth-32 budget.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      for (final entity in listSkillDirectory(path, fs: fileSystem)) {
        count++;
        if (count > 10000) {
          throw MambaException(
            'The Skill tree exceeds the 10,000-entry budget.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        final type = skillEntityType(
          entity.path,
          followLinks: false,
          fs: fileSystem,
        );
        if (type == FileSystemEntityType.link) {
          throw MambaException(
            'Linked Skill entries are not admitted: ${fileSystem.path.relative(entity.path, from: root)}',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        if (type == FileSystemEntityType.directory) {
          visit(entity.path, depth + 1);
        } else if (type != FileSystemEntityType.file) {
          throw MambaException(
            'Unsupported Skill entry: ${fileSystem.path.relative(entity.path, from: root)}',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
      }
    }

    visit(root, 0);
  }
}
