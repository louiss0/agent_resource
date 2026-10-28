import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import 'src/skill_files.dart';
import 'src/skill_validation.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/skill_installation_service.dart';
import 'src/services/skill_lifecycle_service.dart';
import 'lifecycle.dart';
import 'skill_lifecycle_commands.dart';

/// The scope reported for a discovered skill occurrence.
enum DiscoveryScope { project, user }

typedef DiscoverOperation = String Function(String root, DiscoveryScope scope);
typedef InspectOperation = String Function(String skill);
typedef ValidateOperation = ValidationReport Function(String skill);

/// The `skill` command group and its discovery, inspection, and validation
/// children.
final class SkillCommand extends GroupCommand {
  SkillCommand({
    InspectOperation inspect = inspectSkill,
    ValidateOperation validate = validateSkill,
    SkillLifecycleService? lifecycle,
    SkillInstallationService? installation,
  }) : super(_children(inspect, validate, lifecycle, installation));

  static List<Command> _children(
    InspectOperation inspect,
    ValidateOperation validate,
    SkillLifecycleService? lifecycle,
    SkillInstallationService? installation,
  ) {
    final service = lifecycle ?? SkillLifecycleService();
    return [
      SkillListCommand(service),
      InspectCommand(inspect),
      ValidateCommand(validate),
      SkillInstallCommand(
        installation ?? SkillInstallationService(lifecycle: service),
      ),
      SkillAdoptCommand(service),
      SkillReplaceCommand(service),
      SkillRemoveCommand(service),
      SkillBackupCommand(service),
      SkillRecoverCommand(service),
    ];
  }

  @override
  String get name => 'skill';

  @override
  String get shortDescription => 'Manage skills.';
}

final class SkillListCommand(final SkillLifecycleService _lifecycle)
    extends Command {
  this
    : super(
        options: [
          _scope,
          _destination,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claudeConfigDir,
          _codexHome,
          _stateDir,
          _readRoots,
        ],
        flags: [_verify],
        longDescription:
            'Read-only management-aware Skill inventory. Scope defaults to '
            'user. Project inventory includes the bounded cwd-to-project-root '
            'ancestor chain. Destination filters presentation only. Managed '
            'occurrences, tracked-missing records, unmanaged candidates, and '
            'ownership-unverified states remain distinct. --verify performs a '
            'fresh complete baseline comparison; without it modification is '
            'notVerified. No management artifacts are created.',
      );

  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.user,
  );
  static final _destination = ChoiceOption(
    'destination',
    choices: SkillDestination.values,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claudeConfigDir = FolderPathOption('claude-config-dir');
  static final _codexHome = FolderPathOption('codex-home');
  static final _stateDir = FolderPathOption('state-dir');
  static final _readRoots = RepeatableFolderPathOption('read-root');
  static const _verify = BooleanFlag('verify');

  @override
  String get name => 'list';

  @override
  String get shortDescription => 'Inventory managed and unmanaged Skills.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final result = await _lifecycle.list(
      LifecycleOptions(
        processWorkingDirectory: Directory.current.path,
        environment: Platform.environment,
        scope: valueOf(_scope),
        cwd: valueOf(_cwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        claudeConfigDir: valueOf(_claudeConfigDir),
        codexHome: valueOf(_codexHome),
        stateDir: valueOf(_stateDir),
        readRoots: valueOf(_readRoots) ?? const <String>[],
      ),
      destination: valueOf(_destination),
      verify: valueOf(_verify),
    );
    return switch (valueOf(_format)) {
      LifecycleOutputFormat.json => jsonEncode(result.envelope()),
      LifecycleOutputFormat.text => result.renderText(),
    };
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
