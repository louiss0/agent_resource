import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'src/mcp/mcp_envelope.dart';
import 'src/mcp/mcp_types.dart';
import 'src/services/mcp_mutation_service.dart';

/// All typed inputs shared by the four MCP lifecycle commands. A fresh bundle
/// is created per command so every declaration handle is registered once.
final class McpMutationInputs {
  final _name = StringOption.required(
    'name',
    regex: RegExp(r'.+'),
    description: 'The MCP server name to select.',
  );
  final _harness = ChoiceOption.required(
    'harness',
    choices: McpHarness.values,
    description: 'The explicit harness that owns the registration.',
  );
  final _scope = ChoiceOption.required(
    'scope',
    choices: McpScope.values,
    description: 'The explicit native scope of the registration.',
  );
  final _command = StringOption(
    'command',
    regex: RegExp(r'.+'),
    description: 'The stdio executable (exactly one of --command/--url).',
  );
  final _args = RepeatableStringOption(
    'args',
    description: 'A stdio argument; repeat for each argument.',
  );
  final _env = RepeatableStringOption(
    'env',
    description: 'A stdio env KEY=reference (VAR-in-braces or !command).',
  );
  final _url = StringOption(
    'url',
    regex: RegExp(r'.+'),
    description: 'The HTTP endpoint (exactly one of --command/--url).',
  );
  final _header = RepeatableStringOption(
    'header',
    description: 'An HTTP header KEY=reference (VAR-in-braces or !command).',
  );
  final _type = StringOption(
    'type',
    regex: RegExp(r'^[a-z][a-z0-9-]*$'),
    description:
        'The native transport type (stdio, http, streamable-http, ws).',
  );
  final _format = ChoiceOption.withDefault(
    'format',
    choices: McpOutputFormat.values,
    defaultValue: McpOutputFormat.text,
  );
  final _cwd = FolderPathOption('cwd');
  final _projectRoot = FolderPathOption('project-root');
  final _home = FolderPathOption('home');
  final _claudeConfigDir = FolderPathOption('claude-config-dir');
  final _codexHome = FolderPathOption('codex-home');
  final _piAgentDir = FolderPathOption('pi-agent-dir');
  final _stateDir = FolderPathOption('state-dir');
  final _planId = StringOption(
    'plan-id',
    regex: RegExp(r'.+'),
    description: 'A reviewed plan identity from --dry-run.',
  );
  final _dryRun = BooleanFlag(
    'dry-run',
    description: 'Preview the complete reviewed plan without writing.',
  );
  final _yes = BooleanFlag(
    'yes',
    description: 'Unattended apply (requires --ack-mcp-risk).',
  );
  final _interactive = BooleanFlag(
    'interactive',
    description: 'Force interactive review and approval.',
  );
  final _ackMcpRisk = BooleanFlag(
    'ack-mcp-risk',
    description: 'Acknowledge the risk of registering an executable/endpoint.',
  );
  final _allowDrift = BooleanFlag(
    'allow-drift',
    description: 'Allow a reviewed resolution of externally drifted state.',
  );

  List<Option<Object?>> get _options => <Option<Object?>>[
    _name,
    _harness,
    _scope,
    _command,
    _args,
    _env,
    _url,
    _header,
    _type,
    _format,
    _cwd,
    _projectRoot,
    _home,
    _claudeConfigDir,
    _codexHome,
    _piAgentDir,
    _stateDir,
    _planId,
  ];

  List<Flag<Object?>> get _flags => <Flag<Object?>>[
    _dryRun,
    _yes,
    _interactive,
    _ackMcpRisk,
    _allowDrift,
  ];
}

/// Shared argv marshalling for one reviewed MCP lifecycle mutation. Selection
/// is by --name plus explicit --harness and --scope; occurrences and paths are
/// never selectors (path options only resolve the bounded native location).
abstract class McpMutationCommand extends Command {
  McpMutationCommand(
    this._service,
    this._operation,
    McpMutationInputs inputs,
    String longDescription,
  ) : _inputs = inputs,
      super(
        options: inputs._options,
        flags: inputs._flags,
        longDescription: longDescription,
      );

  final McpMutationService _service;
  final McpMutationOperation _operation;
  final McpMutationInputs _inputs;

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final inputs = _inputs;
    final serverName = valueOf(inputs._name);
    final harness = valueOf(inputs._harness);
    final scope = valueOf(inputs._scope);
    final executable = valueOf(inputs._command);
    final arguments = valueOf(inputs._args) ?? const <String>[];
    final environmentValues = valueOf(inputs._env) ?? const <String>[];
    final endpoint = valueOf(inputs._url);
    final headerValues = valueOf(inputs._header) ?? const <String>[];
    final transportType = valueOf(inputs._type);
    final outputFormat = valueOf(inputs._format);
    final workingDirectory = valueOf(inputs._cwd);
    final projectRoot = valueOf(inputs._projectRoot);
    final home = valueOf(inputs._home);
    final claudeConfigDir = valueOf(inputs._claudeConfigDir);
    final codexHome = valueOf(inputs._codexHome);
    final piAgentDir = valueOf(inputs._piAgentDir);
    final stateDir = valueOf(inputs._stateDir);
    final reviewedPlanId = valueOf(inputs._planId);

    final request = McpMutationRequest(
      operation: _operation,
      environment: Map<String, String>.unmodifiable(Platform.environment),
      harness: harness,
      scope: scope,
      name: serverName,
      command: executable,
      args: arguments,
      envValues: environmentValues,
      url: endpoint,
      headerValues: headerValues,
      type: transportType,
      dryRun: valueOf(inputs._dryRun),
      yes: valueOf(inputs._yes),
      interactive: valueOf(inputs._interactive),
      planId: reviewedPlanId,
      ackMcpRisk: valueOf(inputs._ackMcpRisk),
      allowDrift: valueOf(inputs._allowDrift),
      cwd: workingDirectory,
      projectRoot: projectRoot,
      home: home,
      claudeConfigDir: claudeConfigDir,
      codexHome: codexHome,
      piAgentDir: piAgentDir,
      stateDir: stateDir,
    );
    final envelope = await _service.execute(request);
    return renderMcpEnvelope(envelope, outputFormat);
  }
}

final class McpRegisterCommand extends McpMutationCommand {
  McpRegisterCommand(McpMutationService service)
    : super(
        service,
        McpMutationOperation.register,
        McpMutationInputs(),
        'Register one new MCP server registration interactively by default: '
        'preview a complete redacted plan, require explicit approval, then '
        'edit only the selected named entry in the shared native file. Stdio '
        'uses --command/--args/--env; HTTP uses --url/--header. Newly supplied '
        'credential values must be environment-variable or command references. '
        'The resulting entry is validated statically before any write. '
        'Unattended runs require complete explicit inputs, --ack-mcp-risk, '
        'and a reviewed --plan-id.',
      );

  @override
  String get name => 'register';

  @override
  String get shortDescription =>
      'Register a new MCP server with a reviewed plan.';
}

final class McpReplaceCommand extends McpMutationCommand {
  McpReplaceCommand(McpMutationService service)
    : super(
        service,
        McpMutationOperation.replace,
        McpMutationInputs(),
        'Edit one managed MCP registration with the same interactive review '
        'and approval. The selected named entry is patched field by field; '
        'existing literal credentials are retained in place and never '
        'displayed or copied. Externally changed state requires reviewed '
        '--allow-drift resolution with a --plan-id. The resulting entry is '
        'validated statically before any write.',
      );

  @override
  String get name => 'replace';

  @override
  String get shortDescription =>
      'Edit a managed MCP server with a reviewed plan.';
}

final class McpAdoptCommand extends McpMutationCommand {
  McpAdoptCommand(McpMutationService service)
    : super(
        service,
        McpMutationOperation.adopt,
        McpMutationInputs(),
        'Adopt one existing untracked MCP registration after a reviewed plan '
        'and approval. Records the ownership baseline in the Management '
        'ledger WITHOUT rewriting the native entry.',
      );

  @override
  String get name => 'adopt';

  @override
  String get shortDescription =>
      'Adopt an existing registration without rewriting it.';
}

final class McpUnregisterCommand extends McpMutationCommand {
  McpUnregisterCommand(McpMutationService service)
    : super(
        service,
        McpMutationOperation.unregister,
        McpMutationInputs(),
        'Unregister one managed MCP server after a reviewed plan, approval, '
        'and a drift check. Removes only the selected named entry from the '
        'shared native file and drops its ownership record.',
      );

  @override
  String get name => 'unregister';

  @override
  String get shortDescription =>
      'Unregister a managed MCP server with a drift check.';
}
