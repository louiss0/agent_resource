import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

const _maxSkillFileBytes = 1048576;

final class InspectCommand(final String Function(String) _inspect)
    extends Command {
  this
    : super(
        options: [_skill],
        longDescription:
            'Reads only the immediate SKILL.md entry as strict UTF-8. '
            'Regular files are returned verbatim up to 1,048,576 bytes; '
            'larger files fail. Linked markers, nested markers, and other '
            'entries are not read. This is read-only inspection, not '
            'validation, frontmatter parsing, ownership, scope, or harness '
            'compatibility checking.',
      );

  static final _skill = StringOption.required(
    'skill',
    description: 'Skill directory to inspect.',
  );

  @override
  String get name => 'inspect';

  @override
  String get shortDescription => 'Inspect one explicit skill directory.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final skill = valueOf(_skill);
    if (skill.trim().isEmpty) {
      throw MambaException('The --skill directory must not be blank.');
    }

    return _inspect(skill);
  }
}

String inspectSkill(String skill) {
  final skillPath = p.normalize(Directory(skill).absolute.path);
  _requireSkillDirectory(skillPath);

  final markerPath = p.join(skillPath, 'SKILL.md');
  final markerType = _fileSystemType(markerPath, followLinks: false);
  if (markerType != FileSystemEntityType.file) {
    return jsonEncode({
      'path': skillPath,
      'hasSkillFile': false,
      'content': null,
    });
  }

  final content = _readSkillFile(markerPath);
  return jsonEncode({
    'path': skillPath,
    'hasSkillFile': true,
    'content': content,
  });
}

void _requireSkillDirectory(String skillPath) {
  final type = _fileSystemType(skillPath, followLinks: true);
  if (type == FileSystemEntityType.directory) {
    return;
  }

  if (type == FileSystemEntityType.notFound) {
    throw MambaException('Skill directory does not exist: $skillPath');
  }
  throw MambaException('Skill path is not a directory: $skillPath');
}

String _readSkillFile(String markerPath) {
  RandomAccessFile? file;
  try {
    file = File(markerPath).openSync();
    final bytes = file.readSync(_maxSkillFileBytes + 1);
    if (bytes.length > _maxSkillFileBytes) {
      throw MambaException(
        'SKILL.md exceeds the maximum size of $_maxSkillFileBytes bytes.',
      );
    }

    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException catch (error) {
      throw MambaException('SKILL.md is not valid UTF-8: ${error.message}');
    }
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not read skill marker $markerPath: ${error.message}',
    );
  } finally {
    try {
      file?.closeSync();
    } on FileSystemException catch (error) {
      throw MambaException(
        'Could not close skill marker $markerPath: ${error.message}',
      );
    }
  }
}

FileSystemEntityType _fileSystemType(String path, {required bool followLinks}) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: followLinks);
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not inspect filesystem path $path: ${error.message}',
    );
  }
}
