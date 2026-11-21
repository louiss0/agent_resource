import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'src/skill_files.dart';
import 'src/services/guided_authoring_service.dart';
import 'src/services/prompt_read_service.dart';
import 'src/services/prompt_inspection_service.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/skill_installation_service.dart';
import 'src/services/skill_lifecycle_service.dart';
import 'lifecycle.dart';
import 'skill_create_command.dart';
import 'skill_edit_command.dart';
import 'skill_clone_command.dart';
import 'skill_lifecycle_commands.dart';

typedef InspectOperation = String Function(String skill);

/// The `skill` command group and its discovery, inspection, and validation
/// children.
final class SkillCommand extends GroupCommand {
  SkillCommand({
    InspectOperation? inspect,
    PromptReadService? read,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    SkillLifecycleService? lifecycle,
    SkillInstallationService? installation,
    GuidedAuthoringService? guided,
  }) : super(
         _children(
           inspect ?? ((skill) => inspectSkill(skill, fs: fileSystem)),
           read,
           lifecycle,
           installation,
           guided,
           fileSystem,
         ),
       );

  static List<Command> _children(
    InspectOperation inspect,
    PromptReadService? read,
    SkillLifecycleService? lifecycle,
    SkillInstallationService? installation,
    GuidedAuthoringService? guided,
    fslib.FileSystem fileSystem,
  ) {
    final service = lifecycle ?? SkillLifecycleService(fileSystem: fileSystem);
    final reader = read ?? PromptReadService(fileSystem: fileSystem);
    return [
      SkillCreateCommand(
        guided: guided ?? GuidedAuthoringService(fileSystem: fileSystem),
      ),
      SkillEditCommand(
        guided: guided ?? GuidedAuthoringService(fileSystem: fileSystem),
      ),
      SkillCloneCommand(
        guided: guided ?? GuidedAuthoringService(fileSystem: fileSystem),
      ),
      SkillListCommand(service),
      InspectCommand(
        inspect,
        read: reader,
        lifecycle: service,
        fileSystem: fileSystem,
      ),
      ValidateCommand(read: reader, lifecycle: service, fileSystem: fileSystem),
      SkillInstallCommand(
        installation ??
            SkillInstallationService(
              lifecycle: service,
              fileSystem: fileSystem,
            ),
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
          _geminiDir,
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
  static final _geminiDir = FolderPathOption('gemini-dir');
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
        processWorkingDirectory: _lifecycle.state.io.fs.currentDirectory.path,
        environment: Platform.environment,
        scope: valueOf(_scope),
        cwd: valueOf(_cwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        claudeConfigDir: valueOf(_claudeConfigDir),
        codexHome: valueOf(_codexHome),
        geminiDir: valueOf(_geminiDir),
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

const _maxSkillFileBytes = 1048576;

final class InspectCommand extends Command {
  InspectCommand(
    this._inspect, {
    PromptReadService? read,
    SkillLifecycleService? lifecycle,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : _read = read ?? PromptReadService(fileSystem: fileSystem),
       _lifecycle = lifecycle ?? SkillLifecycleService(fileSystem: fileSystem),
       _fileSystem = fileSystem,
       super(
         options: [_inspectSkill, _target],
         flags: [_content],
         longDescription:
             'Inspect SKILL.md native views without instruction content by default. '
             '--content returns the verbatim marker (up to 1,048,576 bytes); '
             'it is not validation and cannot be combined with --target.',
       );

  final InspectOperation _inspect;
  final PromptReadService _read;
  final SkillLifecycleService _lifecycle;
  final fslib.FileSystem _fileSystem;
  static final _inspectSkill = StringOption.required(
    'skill',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
    description: 'Skill directory to inspect.',
  );
  static final _target = ChoiceOption('target', choices: PromptConsumer.values);
  static const _content = BooleanFlag('content');

  @override
  String get name => 'inspect';
  @override
  String get shortDescription => 'Inspect one explicit skill directory.';
  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final skill = valueOf(_inspectSkill);
    if (valueOf(_content)) {
      if (valueOf(_target) != null) {
        throw MambaException(
          '--content cannot be combined with --target.',
          exitCode: 2,
        );
      }
      return _inspect(skill);
    }
    _requireInspectDirectory(
      _fileSystem.path.normalize(_fileSystem.directory(skill).absolute.path),
      _fileSystem,
    );
    final target = valueOf(_target);
    if (target == PromptConsumer.antigravity) {
      return jsonEncode(await _lifecycle.antigravityView(skill));
    }
    final views = await _read.inspect(skill, consumer: target);
    final report = views.toJson();
    if (target != null) {
      report['views'] = [
        if (views.views[target] != null) views.views[target]!.toJson(),
      ];
    }
    return jsonEncode(report);
  }
}

String inspectSkill(
  String skill, {
  fslib.FileSystem fs = const local.LocalFileSystem(),
}) {
  final skillPath = fs.path.normalize(fs.directory(skill).absolute.path);
  _requireInspectDirectory(skillPath, fs);

  final markerPath = fs.path.join(skillPath, 'SKILL.md');
  final markerType = skillEntityType(markerPath, followLinks: false, fs: fs);
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
    fs: fs,
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

void _requireInspectDirectory(String skillPath, fslib.FileSystem fs) {
  final type = skillEntityType(skillPath, followLinks: true, fs: fs);
  if (type == FileSystemEntityType.directory) {
    return;
  }

  if (type == FileSystemEntityType.notFound) {
    throw MambaException('Skill directory does not exist: $skillPath');
  }
  throw MambaException('Skill path is not a directory: $skillPath');
}

final class ValidateCommand extends Command {
  ValidateCommand({
    PromptReadService? read,
    SkillLifecycleService? lifecycle,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : _read = read ?? PromptReadService(fileSystem: fileSystem),
       _lifecycle = lifecycle ?? SkillLifecycleService(fileSystem: fileSystem),
       _fileSystem = fileSystem,
       super(
         options: [_validateSkill, _target],
         longDescription:
             'Validate SKILL.md per native consumer using native Skill or Prompt rules. '
             'Without --target each view is reported separately. '
             'Source-only installation admission is reported separately; '
             'destination and ownership checks still apply. '
             'Invalid or unclassified native views fail with status 2.',
       );
  final PromptReadService _read;
  final SkillLifecycleService _lifecycle;
  final fslib.FileSystem _fileSystem;
  static final _validateSkill = StringOption.required(
    'skill',
    regex: RegExp(r'^\s*\S[\s\S]*$'),
    description: 'Skill directory to validate.',
  );
  static final _target = ChoiceOption('target', choices: PromptConsumer.values);
  @override
  String get name => 'validate';
  @override
  String get shortDescription => 'Validate one skill directory.';
  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final skill = valueOf(_validateSkill);
    _requireInspectDirectory(
      _fileSystem.path.normalize(_fileSystem.directory(skill).absolute.path),
      _fileSystem,
    );
    final target = valueOf(_target);
    if (target == PromptConsumer.antigravity) {
      final report = await _lifecycle.antigravityView(skill);
      report['installationAdmission'] = await _lifecycle.installationAdmission(
        skill,
      );
      final view = (report['views'] as List).single as Map<String, Object?>;
      if (view['valid'] == true) return jsonEncode(report);
      throw MambaException(jsonEncode(report), exitCode: 2);
    }
    final views = await _read.inspect(skill, consumer: target);
    final rendered = <Map<String, Object?>>[];
    final selected = views.views.values.where(
      (view) => target == null || view.consumer == target,
    );
    var failed = selected.isEmpty;
    for (final view in selected) {
      final item = view.toJson();
      switch (view.classification) {
        case PromptClassification.nonPrompt:
        case PromptClassification.prompt:
          if (!view.valid) failed = true;
        case PromptClassification.malformed:
        case PromptClassification.unclassified:
          item['valid'] = false;
          failed = true;
      }
      rendered.add(item);
    }
    final output = jsonEncode({
      ...views.toJson(),
      'views': rendered,
      'installationAdmission': await _lifecycle.installationAdmission(skill),
    });
    if (failed) throw MambaException(output, exitCode: 2);
    return output;
  }
}
