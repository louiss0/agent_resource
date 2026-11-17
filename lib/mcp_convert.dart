import 'dart:convert';
import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'src/mcp/mcp_types.dart';
import 'src/services/mcp_conversion_service.dart';

/// Typed inputs for `mcp convert`. A fresh bundle is created per command so
/// every declaration handle is registered exactly once.
final class McpConvertInputs {
  final name = StringOption.required(
    'name',
    regex: RegExp(r'.+'),
    description: 'The MCP server name to select.',
  );
  final harness = ChoiceOption.required(
    'harness',
    choices: McpHarness.values,
    description: 'The explicit harness that owns the source registration.',
  );
  final scope = ChoiceOption.required(
    'scope',
    choices: McpScope.values,
    description: 'The explicit native scope of the source registration.',
  );
  final targetHarness = ChoiceOption.required(
    'target-harness',
    choices: McpHarness.values,
    description: 'The harness to convert the registration to.',
  );
  final targetScope = ChoiceOption(
    'target-scope',
    choices: McpScope.values,
    description:
        'A reviewed scope change; omitted means the source scope is preserved.',
  );
  final omitField = RepeatableStringOption(
    'omit-field',
    regex: RegExp(r'.+'),
    description:
        'A reviewed field path to omit; repeat for each explicitly omitted '
        'field. Changing this decision yields a fresh plan identity.',
  );
  final planId = StringOption(
    'plan-id',
    regex: RegExp(r'.+'),
    description: 'A reviewed plan identity from --dry-run.',
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

  final apply = BooleanFlag(
    'apply',
    description: 'Apply the reviewed conversion plan.',
  );
  final dryRun = BooleanFlag(
    'dry-run',
    description: 'Preview the complete reviewed plan without writing.',
  );
  final yes = BooleanFlag(
    'yes',
    description: 'Unattended apply (requires a reviewed --plan-id).',
  );
  final interactive = BooleanFlag(
    'interactive',
    description: 'Force interactive review and approval.',
  );

  List<Option<Object?>> get options => <Option<Object?>>[
    name,
    harness,
    scope,
    targetHarness,
    targetScope,
    omitField,
    planId,
    format,
    cwd,
    projectRoot,
    home,
    claudeConfigDir,
    codexHome,
    piAgentDir,
    stateDir,
  ];

  List<Flag<Object?>> get flags => <Flag<Object?>>[
    apply,
    dryRun,
    yes,
    interactive,
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
        options: _inputs.options,
        flags: _inputs.flags,
        conflicts: const <String, List<String>>{
          'apply': ['dry-run'],
        },
        longDescription:
            'Convert one managed MCP server registration across Claude Code, '
            'Codex and native Pi. Transport and scope are preserved; changing '
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
    final i = _inputs;
    final envelope = await _service.execute(
      McpConversionRequest(
        environment: Map<String, String>.unmodifiable(Platform.environment),
        harness: valueOf(i.harness),
        scope: valueOf(i.scope),
        name: valueOf(i.name),
        targetHarness: valueOf(i.targetHarness),
        targetScope: valueOf(i.targetScope),
        omitFields: valueOf(i.omitField) ?? const <String>[],
        planId: valueOf(i.planId),
        apply: valueOf(i.apply),
        dryRun: valueOf(i.dryRun),
        yes: valueOf(i.yes),
        interactive: valueOf(i.interactive),
        cwd: valueOf(i.cwd),
        projectRoot: valueOf(i.projectRoot),
        home: valueOf(i.home),
        claudeConfigDir: valueOf(i.claudeConfigDir),
        codexHome: valueOf(i.codexHome),
        piAgentDir: valueOf(i.piAgentDir),
        stateDir: valueOf(i.stateDir),
      ),
    );
    return switch (valueOf(i.format)) {
      McpOutputFormat.json => _encode(envelope.envelope()),
      McpOutputFormat.text => envelope.renderText(),
    };
  }
}

String _encode(Map<String, Object?> envelope) => jsonEncode(envelope);
