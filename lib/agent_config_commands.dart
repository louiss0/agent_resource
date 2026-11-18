import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/lifecycle_state_service.dart';
import 'src/services/mcp_parent_retirement_service.dart';
import 'src/services/parent_config_service.dart';

LifecycleOptions _options(
  String processWorkingDirectory,
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
  processWorkingDirectory: processWorkingDirectory,
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

final class AgentConfigInspectCommand extends Command {
  AgentConfigInspectCommand(this._service)
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
      );

  final ParentConfigService _service;

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

  @override
  String get name => 'inspect';

  @override
  String get shortDescription => 'Inspect selected native parent units.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final scope = valueOf(_scope);
    final options = _options(
      _service.fs.currentDirectory.path,
      valueOf,
      _cwd,
      _projectRoot,
      _home,
      _claude,
      _codex,
      _state,
      scope,
      approved: false,
    );
    final request = parseParentRequest(
      valueOf(_request),
      options.cwd ?? options.processWorkingDirectory,
      fs: _service.fs,
    );
    if (request.operation != ParentOperation.inspect) {
      throw MambaException(
        'The request operation must match the selected command (inspect).',
        exitCode: 1,
      );
    }
    if (request.scope != scope) {
      throw MambaException(
        'The request scope must match --scope.',
        exitCode: 4,
      );
    }
    final result = await _service.inspect(request: request, options: options);
    return _render(result, format);
  }
}

final class AgentConfigPlanCommand extends Command {
  AgentConfigPlanCommand(this._service)
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
      );

  final ParentConfigService _service;

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

  @override
  String get name => 'plan';

  @override
  String get shortDescription => 'Plan a source-preserving parent change.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final scope = valueOf(_scope);
    final options = _options(
      _service.fs.currentDirectory.path,
      valueOf,
      _cwd,
      _projectRoot,
      _home,
      _claude,
      _codex,
      _state,
      scope,
      approved: false,
    );
    final request = parseParentRequest(
      valueOf(_request),
      options.cwd ?? options.processWorkingDirectory,
      fs: _service.fs,
    );
    if (request.operation != ParentOperation.plan) {
      throw MambaException(
        'The request operation must match the selected command (plan).',
        exitCode: 1,
      );
    }
    if (request.scope != scope) {
      throw MambaException(
        'The request scope must match --scope.',
        exitCode: 4,
      );
    }
    final result = await _service.plan(request: request, options: options);
    return _render(result, format);
  }
}

final class AgentConfigApplyCommand extends Command {
  AgentConfigApplyCommand(this._service)
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
        flags: const [_yes, _ackClientsStopped, _clientsStopped],
      );

  final ParentConfigService _service;

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
  static const _ackClientsStopped = BooleanFlag(
    'ack-clients-stopped',
    description: 'Acknowledge that native clients were stopped before apply.',
  );
  static const _clientsStopped = BooleanFlag(
    'clients-stopped',
    description: 'Compatibility alias for --ack-clients-stopped.',
  );

  @override
  String get name => 'apply';

  @override
  String get shortDescription => 'Apply an approved parent-unit plan.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final scope = valueOf(_scope);
    final options = _options(
      _service.fs.currentDirectory.path,
      valueOf,
      _cwd,
      _projectRoot,
      _home,
      _claude,
      _codex,
      _state,
      scope,
      approved: valueOf(_yes),
    );
    final request = parseParentRequest(
      valueOf(_request),
      options.cwd ?? options.processWorkingDirectory,
      fs: _service.fs,
    );
    if (request.operation != ParentOperation.apply) {
      throw MambaException(
        'The request operation must match the selected command (apply).',
        exitCode: 1,
      );
    }
    if (request.scope != scope) {
      throw MambaException(
        'The request scope must match --scope.',
        exitCode: 4,
      );
    }
    if ((!valueOf(_ackClientsStopped) && !valueOf(_clientsStopped)) ||
        !request.clientsStopped) {
      throw MambaException(
        'Parent apply requires the stopped-client acknowledgement.',
        exitCode: 4,
      );
    }
    final result = await _service.apply(request: request, options: options);
    return _render(result, format);
  }
}

final class AgentConfigCommand extends GroupCommand {
  AgentConfigCommand(ParentConfigService service)
    : super([
        AgentConfigInspectCommand(service),
        AgentConfigPlanCommand(service),
        AgentConfigApplyCommand(service),
        AgentConfigDrainMcpCommand(
          McpParentRetirementService(fileSystem: service.fs),
        ),
      ]);

  @override
  String get name => 'config';

  @override
  String get shortDescription => 'Inspect, plan, and apply parent settings.';
}

final class AgentConfigDrainMcpCommand extends Command {
  AgentConfigDrainMcpCommand(this._service)
    : super(
        options: [
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _state,
          _scope,
        ],
        flags: const [_yes],
        longDescription:
            'Reviewed retirement of in-flight MCP parent-unit plans and '
            'evidence. With no flags this only inventories the legacy '
            'MCP-owned records, backups, and transactions and reports a '
            'redacted account (no writes). Add --yes to apply the reviewed '
            'drain. The drain refuses while any MCP parent transaction is '
            'in a non-terminal/recoverable phase, naming the pending IDs '
            'and pointing to the parent-config recovery/restore/cleanup '
            'path. It never deletes unrelated parent evidence, never '
            'rewrites a native harness file, and never prints credential '
            'values. MCP operations now live under the singular `mcp` '
            'command group (for example: mcp list, mcp register, mcp replace).',
      );

  final McpParentRetirementService _service;

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
  static const _yes = BooleanFlag(
    'yes',
    description:
        'Apply the reviewed drain; otherwise report the inventory only.',
  );

  @override
  String get name => 'drain-mcp';

  @override
  String get shortDescription =>
      'Drain retired MCP parent-unit plans and evidence.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final bool apply = valueOf(_yes);
    final format = valueOf(_format);
    final scope = valueOf(_scope);
    final options = _options(
      _service.fs.currentDirectory.path,
      valueOf,
      _cwd,
      _projectRoot,
      _home,
      _claude,
      _codex,
      _state,
      scope,
      approved: apply,
    );
    final result = await _service.drain(options: options, apply: apply);
    return _render(result, format);
  }
}
