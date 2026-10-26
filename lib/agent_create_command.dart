import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/bound_role_service.dart';
import 'src/services/lifecycle_state_service.dart';

final class AgentCreateCommand extends Command {
  new()
    : super(
        options: [
          _request,
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _codex,
          _state,
        ],
        flags: const [_dryRun, _yes, _clientsStopped],
      );

  static final _request = FilePathOption.required(
    'request',
    suffixes: const ['.json'],
  );
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: const [LifecycleScope.project, LifecycleScope.user],
    defaultValue: LifecycleScope.project,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');
  static const _clientsStopped = BooleanFlag('clients-stopped');

  @override
  String get name => 'create';
  @override
  String get shortDescription =>
      'Plan or publish a reviewed Codex bound-role creation.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final cwd = valueOf(_cwd);
    final options = LifecycleOptions(
      processWorkingDirectory: Directory.current.path,
      environment: Map<String, String>.unmodifiable(Platform.environment),
      scope: valueOf(_scope),
      cwd: cwd,
      projectRoot: valueOf(_projectRoot),
      home: valueOf(_home),
      codexHome: valueOf(_codex),
      stateDir: valueOf(_state),
      dryRun: valueOf(_dryRun),
      approved: valueOf(_yes),
    );
    final request = parseBoundRoleRequest(
      valueOf(_request),
      cwd ?? options.processWorkingDirectory,
    );
    if (request.operation != BoundOperation.create) {
      throw MambaException(
        'The agent create request operation must be create.',
      );
    }
    if (valueOf(_clientsStopped) != request.clientsStopped) {
      throw MambaException(
        'The request and command must agree on clientsStopped.',
        exitCode: 4,
      );
    }
    final result = await BoundRoleService().run(request, options);
    return switch (valueOf(_format)) {
      LifecycleOutputFormat.json => jsonEncode(result.envelope()),
      LifecycleOutputFormat.text => result.renderText(),
    };
  }
}
