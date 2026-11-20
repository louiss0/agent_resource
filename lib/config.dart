import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/configuration/effective_configuration.dart';
import 'src/pack/pack_configuration.dart' show PackConfigurationScope;
import 'src/services/configuration_workflow_service.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/pack_lifecycle_service.dart';

final class ConfigCommand extends GroupCommand {
  new({
    PackLifecycleService? service,
    ConfigurationWorkflowService? workflow,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    Map<String, String>? environment,
    String? operatingSystem,
  }) : super(
         _children(service, workflow, fileSystem, environment, operatingSystem),
       );

  static List<Command> _children(
    PackLifecycleService? service,
    ConfigurationWorkflowService? workflow,
    fslib.FileSystem fileSystem,
    Map<String, String>? environment,
    String? operatingSystem,
  ) {
    final validateService =
        service ?? PackLifecycleService(fileSystem: fileSystem);
    final workflowService =
        workflow ??
        ConfigurationWorkflowService(
          fileSystem: fileSystem,
          environment: environment,
          operatingSystem: operatingSystem,
        );
    return [
      ConfigValidateCommand(validateService, fileSystem: fileSystem),
      ConfigEffectiveCommand(workflowService),
      ConfigPreferCommand(workflowService),
    ];
  }

  @override
  String get name => 'config';

  @override
  String get shortDescription =>
      'Inspect effective configuration and manage preferences.';
}

final class ConfigValidateCommand extends Command {
  ConfigValidateCommand(
    this._service, {
    this._fileSystem = const local.LocalFileSystem(),
  }) : super(
         options: [_scope, _cwd, _projectRoot, _home, _config, _format],
         flags: const [_resolve],
       );

  final PackLifecycleService _service;
  final fslib.FileSystem _fileSystem;

  static final _scope = ChoiceOption(
    'scope',
    choices: const [LifecycleScope.project, LifecycleScope.user],
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _config = FilePathOption('config');
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static const _resolve = BooleanFlag('resolve');

  @override
  String get name => 'validate';

  @override
  String get shortDescription =>
      'Validate configuration offline, or explicitly resolve sources.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final result = await _service.execute(
      PackLifecycleRequest(
        operation: PackOperation.configValidate,
        resourceType: PackResourceType.skill,
        processWorkingDirectory: _fileSystem.currentDirectory.path,
        environment: Map<String, String>.unmodifiable(Platform.environment),
        scope: valueOf(_scope),
        cwd: valueOf(_cwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        configPath: valueOf(_config),
        resolve: valueOf(_resolve),
      ),
    );
    return switch (format) {
      LifecycleOutputFormat.json => jsonEncode(result.envelope()),
      LifecycleOutputFormat.text => result.renderText(),
    };
  }
}

final class _ConfigWorkflowOptions {
  static final effectiveScope = ChoiceOption.withDefault(
    'scope',
    choices: PackConfigurationScope.values,
    defaultValue: PackConfigurationScope.project,
    description: 'Configuration scope whose effective settings are resolved.',
  );
  static final requiredScope = ChoiceOption.required(
    'scope',
    choices: PackConfigurationScope.values,
    description: 'User or project configuration that will own the preference.',
  );
  static final cwd = FolderPathOption('cwd');
  static final projectRoot = FolderPathOption('project-root');
  static final home = FolderPathOption('home');
  static final userConfig = FilePathOption(
    'user-config',
    suffixes: const ['.toml'],
    description: 'Explicit user configuration path.',
  );
  static final projectConfig = FilePathOption(
    'project-config',
    suffixes: const ['.toml'],
    description: 'Explicit project configuration path.',
  );
  static final config = FilePathOption(
    'config',
    suffixes: const ['.toml'],
    description: 'Explicit path for the selected configuration scope.',
  );
  static final format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
    description: 'Success output format.',
  );
  static final set = RepeatableStringOption.required(
    'set',
    regex: RegExp(r'^\s*[A-Za-z][A-Za-z0-9_.-]*\s*=\s*\S[\s\S]*$'),
    description:
        'Eligible preference assignment, such as '
        'cli.install.targets=claude,codex.',
  );
  static final target = RepeatableStringOption(
    'target',
    regex: RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$'),
    description: 'Explicit installation target override.',
  );
  static final method = StringOption(
    'method',
    regex: RegExp(r'^(canonical|copy|source-link)$'),
    description: 'Explicit Skill installation method override.',
  );
  static final snapshotDays = IntOption(
    'snapshot-days',
    range: (min: 1, max: 36500),
    description: 'Explicit snapshot retention override.',
  );
  static const apply = BooleanFlag(
    'apply',
    description:
        'Write the reviewed eligible preferences to the selected '
        'configuration. Without this flag the command only previews.',
  );
}

final class ConfigEffectiveCommand extends Command {
  ConfigEffectiveCommand(this._service)
    : super(
        options: [
          _ConfigWorkflowOptions.effectiveScope,
          _ConfigWorkflowOptions.cwd,
          _ConfigWorkflowOptions.projectRoot,
          _ConfigWorkflowOptions.home,
          _ConfigWorkflowOptions.userConfig,
          _ConfigWorkflowOptions.projectConfig,
          _ConfigWorkflowOptions.config,
          _ConfigWorkflowOptions.target,
          _ConfigWorkflowOptions.method,
          _ConfigWorkflowOptions.snapshotDays,
          _ConfigWorkflowOptions.format,
        ],
        conflicts: const {
          'config': ['user-config', 'project-config'],
        },
        longDescription:
            'Shows the effective safe preferences, the user and project '
            'configuration paths, and the origin of every resolved value. '
            'Missing configuration files fall back to built-in defaults. '
            'The command is read-only and never writes configuration or '
            'management state.',
      );

  final ConfigurationWorkflowService _service;

  @override
  String get name => 'effective';

  @override
  String get shortDescription =>
      'Show effective settings, paths, and value origins.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final result = _service.execute(
      ConfigurationWorkflowRequest(
        operation: ConfigurationWorkflowOperation.effective,
        scope: valueOf(_ConfigWorkflowOptions.effectiveScope),
        cwd: valueOf(_ConfigWorkflowOptions.cwd),
        projectRoot: valueOf(_ConfigWorkflowOptions.projectRoot),
        home: valueOf(_ConfigWorkflowOptions.home),
        userConfigPath: valueOf(_ConfigWorkflowOptions.userConfig),
        projectConfigPath: valueOf(_ConfigWorkflowOptions.projectConfig),
        configPath: valueOf(_ConfigWorkflowOptions.config),
        explicitTargets:
            valueOf(_ConfigWorkflowOptions.target) ?? const <String>[],
        explicitMethod: valueOf(_ConfigWorkflowOptions.method),
        explicitSnapshotDays: valueOf(_ConfigWorkflowOptions.snapshotDays),
      ),
    );
    return renderConfigurationWorkflowResult(
      result,
      valueOf(_ConfigWorkflowOptions.format),
    );
  }
}

final class ConfigPreferCommand extends Command {
  ConfigPreferCommand(this._service)
    : super(
        options: [
          _ConfigWorkflowOptions.requiredScope,
          _ConfigWorkflowOptions.cwd,
          _ConfigWorkflowOptions.projectRoot,
          _ConfigWorkflowOptions.home,
          _ConfigWorkflowOptions.userConfig,
          _ConfigWorkflowOptions.projectConfig,
          _ConfigWorkflowOptions.config,
          _ConfigWorkflowOptions.set,
          _ConfigWorkflowOptions.format,
        ],
        flags: const [_ConfigWorkflowOptions.apply],
        conflicts: const {
          'config': ['user-config', 'project-config'],
        },
        longDescription:
            'Previews eligible user- or project-level preference changes by '
            'default. --apply writes only the reviewed safe preferences to '
            'the selected configuration with focused, comment-preserving '
            'table edits; ambiguous inline or dotted layouts are refused. '
            'Publication is staged through a temporary file and rename, so '
            'a failed write leaves the original configuration unchanged. '
            'Approvals, adoption authority, destructive consent, risk '
            'acknowledgements, and credentials are refused and never '
            'remembered.',
      );

  final ConfigurationWorkflowService _service;

  @override
  String get name => 'prefer';

  @override
  String get shortDescription =>
      'Preview or apply eligible user or project preferences.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final result = _service.execute(
      ConfigurationWorkflowRequest(
        operation: ConfigurationWorkflowOperation.prefer,
        scope: valueOf(_ConfigWorkflowOptions.requiredScope),
        apply: valueOf(_ConfigWorkflowOptions.apply),
        cwd: valueOf(_ConfigWorkflowOptions.cwd),
        projectRoot: valueOf(_ConfigWorkflowOptions.projectRoot),
        home: valueOf(_ConfigWorkflowOptions.home),
        userConfigPath: valueOf(_ConfigWorkflowOptions.userConfig),
        projectConfigPath: valueOf(_ConfigWorkflowOptions.projectConfig),
        configPath: valueOf(_ConfigWorkflowOptions.config),
        preferences: valueOf(_ConfigWorkflowOptions.set),
      ),
    );
    return renderConfigurationWorkflowResult(
      result,
      valueOf(_ConfigWorkflowOptions.format),
    );
  }
}

String renderConfigurationWorkflowResult(
  ConfigurationWorkflowResult result,
  LifecycleOutputFormat format,
) => switch (format) {
  LifecycleOutputFormat.json => jsonEncode(result.envelope()),
  LifecycleOutputFormat.text => result.renderText(),
};
