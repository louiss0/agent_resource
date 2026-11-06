import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/lifecycle_state_service.dart';
import 'src/services/pack_lifecycle_service.dart';

final class ConfigCommand extends GroupCommand {
  new({
    PackLifecycleService? service,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : super([
         ConfigValidateCommand(
           service ?? PackLifecycleService(fileSystem: fileSystem),
           fileSystem: fileSystem,
         ),
       ]);

  @override
  String get name => 'config';

  @override
  String get shortDescription => 'Validate Agent Resource configuration.';
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
