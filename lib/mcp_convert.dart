import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'src/mcp/mcp_envelope.dart';
import 'src/mcp/mcp_types.dart';
import 'src/services/mcp_conversion_service.dart';

/// Typed inputs for `mcp convert`. A fresh bundle is created per command so
/// every declaration handle is registered exactly once.
final class McpConvertInputs {
  final _name = StringOption.required(
    'name',
    regex: RegExp(r'.+'),
    description: 'The MCP server name to select.',
  );
  final _harness = ChoiceOption.required(
    'harness',
    choices: McpHarness.values,
    description: 'The explicit harness that owns the source registration.',
  );
  final _scope = ChoiceOption.required(
    'scope',
    choices: McpScope.values,
    description: 'The explicit native scope of the source registration.',
  );
  final _targetHarness = ChoiceOption.required(
    'target-harness',
    choices: McpHarness.values,
    description: 'The harness to convert the registration to.',
  );
  final _targetScope = ChoiceOption(
    'target-scope',
    choices: McpScope.values,
    description:
        'A reviewed scope change; omitted means the source scope is preserved.',
  );
  final _omitField = RepeatableStringOption(
    'omit-field',
    regex: RegExp(r'.+'),
    description:
        'A reviewed field path to omit; repeat for each explicitly omitted '
        'field. Changing this decision yields a fresh plan identity.',
  );
  final _planId = StringOption(
    'plan-id',
    regex: RegExp(r'.+'),
    description: 'A reviewed plan identity from --dry-run.',
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
  final _geminiDir = FolderPathOption('gemini-dir');
  final _stateDir = FolderPathOption('state-dir');

  final _apply = BooleanFlag(
    'apply',
    description: 'Apply the reviewed conversion plan.',
  );
  final _dryRun = BooleanFlag(
    'dry-run',
    description: 'Preview the complete reviewed plan without writing.',
  );
  final _yes = BooleanFlag(
    'yes',
    description: 'Unattended apply (requires a reviewed --plan-id).',
  );
  final _interactive = BooleanFlag(
    'interactive',
    description: 'Force interactive review and approval.',
  );

  List<Option<Object?>> get _options => <Option<Object?>>[
    _name,
    _harness,
    _scope,
    _targetHarness,
    _targetScope,
    _omitField,
    _planId,
    _format,
    _cwd,
    _projectRoot,
    _home,
    _claudeConfigDir,
    _codexHome,
    _piAgentDir,
    _geminiDir,
    _stateDir,
  ];

  List<Flag<Object?>> get _flags => <Flag<Object?>>[
    _apply,
    _dryRun,
    _yes,
    _interactive,
  ];
}

/// `mcp convert` (stories 26-32). A named registration is selected by name
/// plus an explicit source harness and scope; paths and occurrences are never
/// selectors. Planning, review, a fresh plan identity and an entry-only apply
/// are owned by the injected [McpConversionService].
final class McpConvertCommand extends Command {
  McpConvertCommand(McpConversionService service)
    : this._(service, McpConvertInputs());

  McpConvertCommand._(this._service, this._inputs)
    : super(
        options: _inputs._options,
        flags: _inputs._flags,
        conflicts: const <String, List<String>>{
          'apply': ['dry-run'],
        },
        longDescription:
            'Convert one managed MCP server registration across Claude Code, '
            'Codex, Pi and Antigravity. Transport and scope are preserved; changing '
            'scope is a separate reviewed --target-scope decision. Fields '
            'with no target-native equivalent refuse the conversion unless '
            'explicitly omitted with --omit-field. OAuth state, provider '
            'credentials and literal secrets are never copied; re-authenticate '
            'at the target. A complete redacted plan must be reviewed before '
            'any entry-only write; --dry-run prints the plan and its fresh '
            'identity without writing. Static only: no server is launched, '
            'connected to or authenticated.',
      );

  final McpConversionService _service;
  final McpConvertInputs _inputs;

  @override
  String get name => 'convert';

  @override
  String get shortDescription =>
      'Convert a managed MCP registration to another harness.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final inputs = _inputs;
    final serverName = valueOf(inputs._name);
    final sourceHarness = valueOf(inputs._harness);
    final sourceScope = valueOf(inputs._scope);
    final targetHarness = valueOf(inputs._targetHarness);
    final reviewedTargetScope = valueOf(inputs._targetScope);
    final omittedFields = valueOf(inputs._omitField) ?? const <String>[];
    final reviewedPlanId = valueOf(inputs._planId);
    final outputFormat = valueOf(inputs._format);
    final workingDirectory = valueOf(inputs._cwd);
    final projectRoot = valueOf(inputs._projectRoot);
    final home = valueOf(inputs._home);
    final claudeConfigDir = valueOf(inputs._claudeConfigDir);
    final codexHome = valueOf(inputs._codexHome);
    final piAgentDir = valueOf(inputs._piAgentDir);
    final geminiDir = valueOf(inputs._geminiDir);
    final stateDir = valueOf(inputs._stateDir);

    final envelope = await _service.execute(
      McpConversionRequest(
        environment: Map<String, String>.unmodifiable(Platform.environment),
        harness: sourceHarness,
        scope: sourceScope,
        name: serverName,
        targetHarness: targetHarness,
        targetScope: reviewedTargetScope,
        omitFields: omittedFields,
        planId: reviewedPlanId,
        apply: valueOf(inputs._apply),
        dryRun: valueOf(inputs._dryRun),
        yes: valueOf(inputs._yes),
        interactive: valueOf(inputs._interactive),
        cwd: workingDirectory,
        projectRoot: projectRoot,
        home: home,
        claudeConfigDir: claudeConfigDir,
        codexHome: codexHome,
        piAgentDir: piAgentDir,
        geminiDir: geminiDir,
        stateDir: stateDir,
      ),
    );
    return renderMcpEnvelope(envelope, outputFormat);
  }
}
