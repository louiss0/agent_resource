import 'dart:convert';
import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'src/mcp/mcp_envelope.dart';
import 'src/mcp/mcp_types.dart';
import 'src/services/mcp_mutation_service.dart';

/// All typed inputs shared by the four MCP lifecycle commands. A fresh bundle
/// is created per command so every declaration handle is registered once.
final class McpMutationInputs {
  final name = StringOption.required(
    'name',
    regex: RegExp(r'.+'),
    description: 'The MCP server name to select.',
  );
  final harness = ChoiceOption.required(
    'harness',
    choices: McpHarness.values,
    description: 'The explicit harness that owns the registration.',
  );
  final scope = ChoiceOption.required(
    'scope',
    choices: McpScope.values,
    description: 'The explicit native scope of the registration.',
  );
  final command = StringOption(
    'command',
    regex: RegExp(r'.+'),
    description: 'The stdio executable (exactly one of --command/--url).',
  );
  final args = RepeatableStringOption(
    'args',
    description: 'A stdio argument; repeat for each argument.',
  );
  final env = RepeatableStringOption(
    'env',
    description: 'A stdio env KEY=reference (VAR-in-braces or !command).',
  );
  final url = StringOption(
    'url',
    regex: RegExp(r'.+'),
    description: 'The HTTP endpoint (exactly one of --command/--url).',
  );
  final header = RepeatableStringOption(
    'header',
    description: 'An HTTP header KEY=reference (VAR-in-braces or !command).',
  );
  final type = StringOption(
    'type',
    regex: RegExp(r'^[a-z][a-z0-9-]*$'),
    description:
        'The native transport type (stdio, http, streamable-http, ws).',
  );
  final format = ChoiceOption.withDefault(
    'format',
    choices: McpOutputFormat.values,
    defaultValue: McpOutputFormat.text,
  );
  final cwd = FolderPathOption('cwd');
  final projectRoot = FolderPathOption('project-root');
  final home = FolderPathOption('home');
  final claudeConfigDir = FolderPathOption('claude-config-dir');
  final codexHome = FolderPathOption('codex-home');
  final piAgentDir = FolderPathOption('pi-agent-dir');
  final stateDir = FolderPathOption('state-dir');
  final planId = StringOption(
    'plan-id',
    regex: RegExp(r'.+'),
    description: 'A reviewed plan identity from --dry-run.',
  );
  final dryRun = BooleanFlag(
    'dry-run',
    description: 'Preview the complete reviewed plan without writing.',
  );
  final yes = BooleanFlag(
    'yes',
    description: 'Unattended apply (requires --ack-mcp-risk).',
  );
  final interactive = BooleanFlag(
    'interactive',
    description: 'Force interactive review and approval.',
  );
  final ackMcpRisk = BooleanFlag(
    'ack-mcp-risk',
    description: 'Acknowledge the risk of registering an executable/endpoint.',
  );
  final allowDrift = BooleanFlag(
    'allow-drift',
    description: 'Allow a reviewed resolution of externally drifted state.',
  );

  List<Option<Object?>> get options => <Option<Object?>>[
    name,
    harness,
    scope,
    command,
    args,
    env,
    url,
    header,
    type,
    format,
    cwd,
    projectRoot,
    home,
    claudeConfigDir,
    codexHome,
    piAgentDir,
    stateDir,
    planId,
  ];

  List<Flag<Object?>> get flags => <Flag<Object?>>[
    dryRun,
    yes,
    interactive,
    ackMcpRisk,
    allowDrift,
  ];
}

String _render(McpEnvelope envelope, McpOutputFormat format) =>
    switch (format) {
      McpOutputFormat.json => jsonEncode(envelope.envelope()),
      McpOutputFormat.text => envelope.renderText(),
    };

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
        options: inputs.options,
        flags: inputs.flags,
        longDescription: longDescription,
      );

  final McpMutationService _service;
  final McpMutationOperation _operation;
  final McpMutationInputs _inputs;

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final i = _inputs;
    final request = McpMutationRequest(
      operation: _operation,
      environment: Map<String, String>.unmodifiable(Platform.environment),
      harness: valueOf(i.harness),
      scope: valueOf(i.scope),
      name: valueOf(i.name),
      command: valueOf(i.command),
      args: valueOf(i.args) ?? const <String>[],
      envValues: valueOf(i.env) ?? const <String>[],
      url: valueOf(i.url),
      headerValues: valueOf(i.header) ?? const <String>[],
      type: valueOf(i.type),
      dryRun: valueOf(i.dryRun),
      yes: valueOf(i.yes),
      interactive: valueOf(i.interactive),
      planId: valueOf(i.planId),
      ackMcpRisk: valueOf(i.ackMcpRisk),
      allowDrift: valueOf(i.allowDrift),
      cwd: valueOf(i.cwd),
      projectRoot: valueOf(i.projectRoot),
      home: valueOf(i.home),
      claudeConfigDir: valueOf(i.claudeConfigDir),
      codexHome: valueOf(i.codexHome),
      piAgentDir: valueOf(i.piAgentDir),
      stateDir: valueOf(i.stateDir),
    );
    final envelope = await _service.execute(request);
    return _render(envelope, valueOf(i.format));
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
