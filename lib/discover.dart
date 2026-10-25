import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

enum DiscoveryScope { project, user }

typedef DiscoverOperation = String Function(String root, DiscoveryScope scope);

final class DiscoverCommand(final DiscoverOperation _discover) extends Command {
  this
    : super(
        selectedOptions: [_selection],
        longDescription:
            'Select exactly one explicit root: --project for project-local '
            'skills or --home for user-wide skills. Neither root is '
            'inferred from the environment. Beneath the selected root, scan '
            '.agents/skills (shared), .claude/skills (claude), and '
            '.codex/skills (codex). Home occurrences report installationScope '
            'user; project occurrences report project. Only immediate ordinary '
            'directories are candidates; ordinary files and linked scan or '
            'candidate directories are excluded. SKILL.md presence requires a '
            'regular file, not a link. Discovery is read-only, non-recursive, '
            'and does not claim validation, ownership, or consuming-harness '
            'compatibility.',
      );

  static final _selection = SelectedOptions<String>.required(
    [
      PairStringOption('project', description: 'Project directory to inspect.'),
      PairStringOption('home', description: 'User home directory to inspect.'),
    ],
    description: 'Select exactly one discovery root.',
    single: true,
  );

  @override
  String get name => 'discover';

  @override
  String get shortDescription => 'Discover project-local and user-wide skills.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final selection = valueOf(_selection);
    final entry = selection.entries.single;
    final root = entry.value;
    if (root.trim().isEmpty) {
      throw MambaException('The --${entry.key} directory must not be blank.');
    }

    final scope = switch (entry.key) {
      'project' => DiscoveryScope.project,
      'home' => DiscoveryScope.user,
      _ => throw StateError('Unknown discovery selection: ${entry.key}'),
    };
    return _discover(root, scope);
  }
}

String discoverSkills(String root, DiscoveryScope scope) {
  final rootPath = p.normalize(Directory(root).absolute.path);
  _requireRootDirectory(rootPath, scope);

  final occurrences = <Map<String, Object>>[];
  for (final destination in _destinations) {
    occurrences.addAll(_discoverDestination(rootPath, destination, scope));
  }

  return jsonEncode({'occurrences': occurrences});
}

const _destinations =
    <({String name, String harnessDirectory, String skillsDirectory})>[
      (name: 'shared', harnessDirectory: '.agents', skillsDirectory: 'skills'),
      (name: 'claude', harnessDirectory: '.claude', skillsDirectory: 'skills'),
      (name: 'codex', harnessDirectory: '.codex', skillsDirectory: 'skills'),
    ];

void _requireRootDirectory(String rootPath, DiscoveryScope scope) {
  final type = _fileSystemType(rootPath, followLinks: true);
  if (type == FileSystemEntityType.directory) {
    return;
  }

  final label = switch (scope) {
    DiscoveryScope.project => 'Project',
    DiscoveryScope.user => 'Home',
  };
  if (type == FileSystemEntityType.notFound) {
    throw MambaException('$label directory does not exist: $rootPath');
  }
  throw MambaException('$label path is not a directory: $rootPath');
}

List<Map<String, Object>> _discoverDestination(
  String rootPath,
  ({String name, String harnessDirectory, String skillsDirectory}) destination,
  DiscoveryScope scope,
) {
  final harnessPath = p.normalize(
    p.join(rootPath, destination.harnessDirectory),
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

  final installationScope = scope.name;
  return [
    for (final candidate in candidates)
      <String, Object>{
        'path': p.normalize(candidate.absolute.path),
        'destination': destination.name,
        'installationScope': installationScope,
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
