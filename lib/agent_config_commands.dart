import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/lifecycle_state_service.dart';
import 'src/services/parent_config_service.dart';

LifecycleOptions _options(
  ValueOf valueOf,
  FolderPathOption cwd,
  FolderPathOption projectRoot,
  FolderPathOption home,
  FolderPathOption claude,
  FolderPathOption codex,
  FolderPathOption state,
  LifecycleScope scope, {
  required bool approved,
}) => LifecycleOptions(
  processWorkingDirectory: Directory.current.path,
  environment: Map<String, String>.unmodifiable(Platform.environment),
  scope: scope,
  cwd: valueOf(cwd),
  projectRoot: valueOf(projectRoot),
  home: valueOf(home),
  claudeConfigDir: valueOf(claude),
  codexHome: valueOf(codex),
  stateDir: valueOf(state),
  approved: approved,
);

String _render(ParentResult result, LifecycleOutputFormat format) =>
    switch (format) {
      LifecycleOutputFormat.json => jsonEncode(result.envelope()),
      LifecycleOutputFormat.text => result.renderText(),
    };

abstract base class _ConfigCommand extends Command {
  _ConfigCommand(this._service, this._operation, {bool apply = false})
    : super(
        options: [
          _request,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
          _scope,
        ],
        flags: apply ? const [_yes, _clientsStopped] : const [],
      );

  final ParentConfigService _service;
  final ParentOperation _operation;

  static final _request = FilePathOption.required(
    'request',
    suffixes: const ['.json'],
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _state = FolderPathOption('state-dir');
  static final _scope = ChoiceOption.required(
    'scope',
    choices: const [LifecycleScope.user, LifecycleScope.project],
  );
  static const _yes = BooleanFlag('yes');
  static const _clientsStopped = BooleanFlag('clients-stopped');

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final scope = valueOf(_scope);
    final apply = _operation == ParentOperation.apply;
    final options = _options(
      valueOf,
      _cwd,
      _projectRoot,
      _home,
      _claude,
      _codex,
      _state,
      scope,
      approved: apply && valueOf(_yes),
    );
    final request = parseParentRequest(
      valueOf(_request),
      options.cwd ?? options.processWorkingDirectory,
    );
    if (request.operation != _operation) {
      throw MambaException(
        'The request operation must match the selected command (${_operation.name}).',
        exitCode: 1,
      );
    }
    if (request.scope != scope) {
      throw MambaException(
        'The request scope must match --scope.',
        exitCode: 4,
      );
    }
    if (_operation == ParentOperation.apply) {
      if (!valueOf(_clientsStopped) || !request.clientsStopped) {
        throw MambaException(
          'Parent apply requires the stopped-client acknowledgement.',
          exitCode: 4,
        );
      }
    }
    final result = switch (_operation) {
      ParentOperation.inspect => await _service.inspect(
        request: request,
        options: options,
      ),
      ParentOperation.plan => await _service.plan(
        request: request,
        options: options,
      ),
      ParentOperation.apply => await _service.apply(
        request: request,
        options: options,
      ),
    };
    return _render(result, format);
  }
}

final class AgentConfigInspectCommand extends _ConfigCommand {
  new(ParentConfigService service) : super(service, ParentOperation.inspect);
  @override
  String get name => 'inspect';
  @override
  String get shortDescription => 'Inspect selected native parent units.';
}

final class AgentConfigPlanCommand extends _ConfigCommand {
  new(ParentConfigService service) : super(service, ParentOperation.plan);
  @override
  String get name => 'plan';
  @override
  String get shortDescription => 'Plan a source-preserving parent change.';
}

final class AgentConfigApplyCommand extends _ConfigCommand {
  new(ParentConfigService service)
    : super(service, ParentOperation.apply, apply: true);
  @override
  String get name => 'apply';
  @override
  String get shortDescription => 'Apply an approved parent-unit plan.';
}

final class AgentConfigCommand extends GroupCommand {
  AgentConfigCommand(ParentConfigService service)
    : super([
        AgentConfigInspectCommand(service),
        AgentConfigPlanCommand(service),
        AgentConfigApplyCommand(service),
      ]);

  @override
  String get name => 'config';
  @override
  String get shortDescription => 'Inspect, plan, and apply parent settings.';
}
