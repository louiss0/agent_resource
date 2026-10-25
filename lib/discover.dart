import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

final class DiscoverCommand(final String Function(String) _discover)
    extends Command {
  this : super(options: [_project]);

  static final _project = StringOption.required(
    'project',
    description: 'Project directory to inspect.',
  );

  @override
  String get name => 'discover';

  @override
  String get shortDescription => 'Discover project-local skills.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final project = valueOf(_project);
    if (project.trim().isEmpty) {
      throw MambaException('The --project directory must not be blank.');
    }

    return _discover(project);
  }
}

String discoverProjectSkills(String project) {
  final projectPath = p.normalize(Directory(project).absolute.path);
  _requireProjectDirectory(projectPath);

  final occurrences = <Map<String, Object>>[];
  for (final destination in _destinations) {
    occurrences.addAll(_discoverDestination(projectPath, destination));
  }

  return jsonEncode({'occurrences': occurrences});
}

const _destinations =
    <({String name, String harnessDirectory, String skillsDirectory})>[
      (name: 'shared', harnessDirectory: '.agents', skillsDirectory: 'skills'),
      (name: 'claude', harnessDirectory: '.claude', skillsDirectory: 'skills'),
      (name: 'codex', harnessDirectory: '.codex', skillsDirectory: 'skills'),
    ];

void _requireProjectDirectory(String projectPath) {
  final type = _fileSystemType(projectPath, followLinks: true);
  if (type == FileSystemEntityType.directory) {
    return;
  }

  if (type == FileSystemEntityType.notFound) {
    throw MambaException('Project directory does not exist: $projectPath');
  }
  throw MambaException('Project path is not a directory: $projectPath');
}

List<Map<String, Object>> _discoverDestination(
  String projectPath,
  ({String name, String harnessDirectory, String skillsDirectory}) destination,
) {
  final harnessPath = p.normalize(
    p.join(projectPath, destination.harnessDirectory),
  );
  final harnessType = _fileSystemType(harnessPath, followLinks: false);
  if (harnessType == FileSystemEntityType.notFound ||
      harnessType == FileSystemEntityType.link) {
    return <Map<String, Object>>[];
  }
  if (harnessType != FileSystemEntityType.directory) {
    throw MambaException(
      'Expected a directory for ${destination.harnessDirectory}, '
      'but found a file at $harnessPath.',
    );
  }

  final skillsPath = p.normalize(
    p.join(harnessPath, destination.skillsDirectory),
  );
  final skillsType = _fileSystemType(skillsPath, followLinks: false);

  if (skillsType == FileSystemEntityType.notFound ||
      skillsType == FileSystemEntityType.link) {
    return <Map<String, Object>>[];
  }
  if (skillsType != FileSystemEntityType.directory) {
    throw MambaException(
      'Expected a directory for ${destination.harnessDirectory}/'
      '${destination.skillsDirectory}, but found a file at $skillsPath.',
    );
  }

  final candidates =
      _listDirectory(skillsPath)
          .where(
            (entity) =>
                _fileSystemType(entity.path, followLinks: false) ==
                FileSystemEntityType.directory,
          )
          .toList()
        ..sort((left, right) {
          final leftName = p.basename(left.path);
          final rightName = p.basename(right.path);
          return leftName.compareTo(rightName);
        });

  return [
    for (final candidate in candidates)
      <String, Object>{
        'path': p.normalize(candidate.absolute.path),
        'destination': destination.name,
        'installationScope': 'project',
        'hasSkillFile': _hasRegularSkillFile(candidate.path),
      },
  ];
}

bool _hasRegularSkillFile(String candidatePath) {
  final skillFilePath = p.join(candidatePath, 'SKILL.md');
  return _fileSystemType(skillFilePath, followLinks: false) ==
      FileSystemEntityType.file;
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

List<FileSystemEntity> _listDirectory(String path) {
  try {
    return Directory(path).listSync(followLinks: false);
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not read skills directory $path: ${error.message}',
    );
  }
}
