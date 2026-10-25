import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import 'src/skill_files.dart';
import 'src/skill_validation.dart';

/// The scope reported for a discovered skill occurrence.
enum DiscoveryScope { project, user }

typedef DiscoverOperation = String Function(String root, DiscoveryScope scope);
typedef InspectOperation = String Function(String skill);
typedef ValidateOperation = ValidationReport Function(String skill);

/// The `skill` command group and its discovery, inspection, and validation
/// children.
final class SkillCommand extends GroupCommand {
  SkillCommand({
    DiscoverOperation discover = discoverSkills,
    InspectOperation inspect = inspectSkill,
    ValidateOperation validate = validateSkill,
  }) : super([
         DiscoverCommand(discover),
         InspectCommand(inspect),
         ValidateCommand(validate),
       ]);

  @override
  String get name => 'skill';

  @override
  String get shortDescription => 'Manage skills.';
}

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
  _requireDiscoveryRoot(rootPath, scope);

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

void _requireDiscoveryRoot(String rootPath, DiscoveryScope scope) {
  final type = skillEntityType(rootPath, followLinks: true);
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
  final harnessType = skillEntityType(harnessPath, followLinks: false);
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
  final skillsType = skillEntityType(skillsPath, followLinks: false);

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
      listSkillDirectory(skillsPath)
          .where(
            (entity) =>
                skillEntityType(entity.path, followLinks: false) ==
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
  return skillEntityType(skillFilePath, followLinks: false) ==
      FileSystemEntityType.file;
}

const _maxSkillFileBytes = 1048576;

final class InspectCommand(final InspectOperation _inspect) extends Command {
  this
    : super(
        options: [_inspectSkill],
        longDescription:
            'Reads only the immediate SKILL.md entry as strict UTF-8. '
            'Regular files are returned verbatim up to 1,048,576 bytes; '
            'larger files fail. Linked markers, nested markers, and other '
            'entries are not read. This is read-only inspection, not '
            'validation, frontmatter parsing, ownership, scope, or harness '
            'compatibility checking.',
      );

  static final _inspectSkill = StringOption.required(
    'skill',
    description: 'Skill directory to inspect.',
  );

  @override
  String get name => 'inspect';

  @override
  String get shortDescription => 'Inspect one explicit skill directory.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final skill = valueOf(_inspectSkill);
    if (skill.trim().isEmpty) {
      throw MambaException('The --skill directory must not be blank.');
    }

    return _inspect(skill);
  }
}

String inspectSkill(String skill) {
  final skillPath = p.normalize(Directory(skill).absolute.path);
  _requireInspectDirectory(skillPath);

  final markerPath = p.join(skillPath, 'SKILL.md');
  final markerType = skillEntityType(markerPath, followLinks: false);
  if (markerType != FileSystemEntityType.file) {
    return jsonEncode({
      'path': skillPath,
      'hasSkillFile': false,
      'content': null,
    });
  }

  final bytes = readBoundedSkillMarker(
    markerPath,
    maxBytes: _maxSkillFileBytes,
  );
  if (bytes.length > _maxSkillFileBytes) {
    throw MambaException(
      'SKILL.md exceeds the maximum size of $_maxSkillFileBytes bytes.',
    );
  }

  final String content;
  try {
    content = utf8.decode(bytes, allowMalformed: false);
  } on FormatException catch (error) {
    throw MambaException('SKILL.md is not valid UTF-8: ${error.message}');
  }
  return jsonEncode({
    'path': skillPath,
    'hasSkillFile': true,
    'content': content,
  });
}

void _requireInspectDirectory(String skillPath) {
  final type = skillEntityType(skillPath, followLinks: true);
  if (type == FileSystemEntityType.directory) {
    return;
  }

  if (type == FileSystemEntityType.notFound) {
    throw MambaException('Skill directory does not exist: $skillPath');
  }
  throw MambaException('Skill path is not a directory: $skillPath');
}

final class ValidateCommand(final ValidateOperation _validate) extends Command {
  this
    : super(
        options: [_validateSkill],
        longDescription:
            'Validate one explicit skill directory against the pinned '
            'agentskills-core-ascii-v1 profile. Reads only immediate SKILL.md '
            'as strict UTF-8, up to 1,048,576 bytes with at most 65,536 '
            'frontmatter bytes. Linked markers are rejected. The ASCII-only '
            'name rule is product policy, not a universal specification rule; '
            'unknown fields are advisory warnings. Passing this profile is '
            'not universal compliance, security, or harness compatibility. '
            'The report is JSON. A valid '
            'report is written to stdout with status 0; an invalid report is '
            'written as JSON to stderr with status 2. Filesystem and other '
            'operational failures are human-readable status-1 errors. '
            'Validation is read-only: it does not execute scripts, follow '
            'references or network links, fetch dependencies, or mutate the '
            'skill directory.',
      );

  static final _validateSkill = StringOption.required(
    'skill',
    description: 'Skill directory to validate.',
  );

  @override
  String get name => 'validate';

  @override
  String get shortDescription => 'Validate one skill directory.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final skill = valueOf(_validateSkill);
    if (skill.trim().isEmpty) {
      throw MambaException('The --skill directory must not be blank.');
    }

    final report = _validate(skill);
    final output = jsonEncode(report.toJson());
    if (!report.valid) {
      throw MambaException(output, exitCode: 2);
    }
    return output;
  }
}
