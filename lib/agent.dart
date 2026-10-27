import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'src/agent_inspection.dart';
import 'src/agent_inventory.dart';
import 'src/services/agent_lifecycle_service.dart';
import 'src/services/agent_graph_service.dart';
import 'lifecycle.dart';
import 'agent_config_commands.dart';
import 'agent_create_command.dart';
import 'agent_compose.dart';
import 'agent_clone.dart';
import 'agent_edit.dart';
import 'agent_convert.dart';
import 'src/services/parent_config_service.dart';

/// The output format selected by `--format`.
enum OutputFormat { text, json }

/// The inspection/validation operation shared by the `agent` commands.
typedef AgentInspectionOperation = AgentInspectionReport Function(
  AgentInspectionInput input, {
  required AgentOperation operation,
});

/// The inventory operation shared by the `agent list` command.
typedef AgentInventoryOperation = FutureOr<AgentInventoryReport> Function(
  AgentInventoryInput input,
);

/// The `agent` command group owning the native-agent inspection and
/// validation children.
final class AgentCommand extends GroupCommand {
  AgentCommand({
    AgentInspectionOperation operation = inspectNativeAgent,
    AgentInventoryOperation inventory = listNativeAgents,
    AgentLifecycleService? lifecycle,
    AgentGraphService? graph,
  }) : super(_children(operation, inventory, lifecycle, graph));

  static List<Command> _children(
    AgentInspectionOperation operation,
    AgentInventoryOperation inventory,
    AgentLifecycleService? lifecycle,
    AgentGraphService? graph,
  ) {
    final service = lifecycle ?? AgentLifecycleService();
    return [
      AgentListCommand(inventory, service),
      AgentConfigCommand(ParentConfigService()),
      AgentCreateCommand(),
      AgentComposeCommand(),
      AgentCloneCommand(),
      AgentEditCommand(),
      AgentConvertCommand(),
      AgentInspectCommand(operation, graph: graph),
      AgentValidateCommand(operation),
      LifecycleActionCommand.agentInstall(service),
      LifecycleActionCommand.agentAdopt(service),
      LifecycleActionCommand.agentReplace(service),
      LifecycleActionCommand.agentRemove(service),
      LifecycleBackupCommand.agent(service),
      LifecycleActionCommand.agentRecover(service),
    ];
  }

  @override
  String get name => 'agent';

  @override
  String get shortDescription =>
      'Discover, inspect, and validate native agent definitions.';
}

final class AgentInspectCommand(
  final AgentInspectionOperation _operation, {
  AgentGraphService? graph,
}) extends Command {
  final AgentGraphService _graphService = graph ?? AgentGraphService();

  this
    : super(
        discretionaryPositionals: [_nativeFile],
        options: [_request, _harness, _format, _cwd],
        flags: [_showInstructions],
        longDescription:
            'Read-only inspection of one native agent definition or one '
            'Codex config-bound role selected by a version-1 request '
            'envelope. Supply either a native file positional or --request, '
            'never both. A native file requires an explicit --harness '
            '(claude, codex, or pi); Markdown is never auto-detected '
            'between Claude and Pi. A request selects a Codex config-bound '
            'role and cannot be combined with --harness. Relative native and '
            'request paths resolve against --cwd when supplied. No harness, '
            'provider, account, model registry, MCP server, hook, '
            'extension, or credential helper is executed or probed. '
            'Inspection is a complete analysis and may succeed with '
            'validation.status failed and ready false; that does not mean '
            'the candidate passed. Reports omit whole Markdown bodies and '
            'developer_instructions, and never dump inline MCP/hook '
            'configurations or sensitive values; --show-instructions adds '
            'the exact instruction text only here on inspect.',
      );

  static final _nativeFile = FilePathPositional.optional(
    'native-file',
    suffixes: const ['.md', '.toml'],
    description: 'Native agent definition file to inspect.',
  );

  static final _request = FilePathOption(
    'request',
    suffixes: const ['.json'],
    description:
        'Version-1 JSON request envelope selecting a Codex config-bound role.',
  );

  static final _harness = ChoiceOption(
    'harness',
    choices: AgentHarness.values,
    description: 'Native harness contract for a native file (never inferred).',
  );

  static final _format = ChoiceOption.withDefault(
    'format',
    choices: OutputFormat.values,
    defaultValue: OutputFormat.text,
    description: 'Report format.',
  );

  static final _cwd = FolderPathOption(
    'cwd',
    description:
        'Working directory that relative native and request paths '
        'resolve against.',
  );

  static const _showInstructions = BooleanFlag(
    'show-instructions',
    description:
        'Include the exact instruction text in the report; instructions '
        'may be private.',
  );

  @override
  String get name => 'inspect';

  @override
  String get shortDescription =>
      'Inspect a native agent definition or bound role.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final input = _inspectionInput(
      nativeFile: valueOf(_nativeFile),
      requestFile: valueOf(_request),
      harness: valueOf(_harness),
      cwd: valueOf(_cwd),
      showInstructions: valueOf(_showInstructions),
    );

    const operation = AgentOperation.inspect;
    final report = _operation(input, operation: operation);
    final graph = _graphService.analyzeInspection(report);
    return switch (valueOf(_format)) {
      OutputFormat.json => jsonEncode(<String, Object?>{
        ...report.envelope(operation),
        'data': <String, Object?>{
          ...report.envelope(operation)['data']! as Map<String, Object?>,
          'graph': graph.toJson(),
        },
      }),
      OutputFormat.text =>
        '${report.renderText(operation)}${graph.renderText()}',
    };
  }
}

final class AgentValidateCommand(final AgentInspectionOperation _operation)
    extends Command {
  this
    : super(
        discretionaryPositionals: [_nativeFile],
        options: [_request, _harness, _format, _cwd],
        longDescription:
            'Explicit correctness gate for one native agent definition or '
            'one Codex config-bound role selected by a version-1 request '
            'envelope. Supply either a native file positional or --request, '
            'never both. A native file requires an explicit --harness '
            '(claude, codex, or pi); Markdown is never auto-detected '
            'between Claude and Pi. A request selects a Codex config-bound '
            'role and cannot be combined with --harness. Relative native '
            'and request paths resolve against --cwd when supplied. No '
            'harness, provider, account, model registry, MCP server, hook, '
            'extension, or credential helper is executed or probed. '
            'Blocking native or product violations fail with status 2 and '
            'human-readable diagnostics, with no success JSON even when '
            '--format json was requested. Reports omit whole Markdown '
            'bodies and developer_instructions, and never dump inline '
            'MCP/hook configurations or sensitive values. Validation is '
            'read-only and creates no records, caches, backups, logs, or '
            'staging files.',
      );

  static final _nativeFile = FilePathPositional.optional(
    'native-file',
    suffixes: const ['.md', '.toml'],
    description: 'Native agent definition file to validate.',
  );

  static final _request = FilePathOption(
    'request',
    suffixes: const ['.json'],
    description:
        'Version-1 JSON request envelope selecting a Codex config-bound role.',
  );

  static final _harness = ChoiceOption(
    'harness',
    choices: AgentHarness.values,
    description: 'Native harness contract for a native file (never inferred).',
  );

  static final _format = ChoiceOption.withDefault(
    'format',
    choices: OutputFormat.values,
    defaultValue: OutputFormat.text,
    description: 'Report format for a passed validation.',
  );

  static final _cwd = FolderPathOption(
    'cwd',
    description:
        'Working directory that relative native and request paths '
        'resolve against.',
  );

  @override
  String get name => 'validate';

  @override
  String get shortDescription =>
      'Validate a native agent definition or bound role.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final input = _inspectionInput(
      nativeFile: valueOf(_nativeFile),
      requestFile: valueOf(_request),
      harness: valueOf(_harness),
      cwd: valueOf(_cwd),
      showInstructions: false,
    );

    const operation = AgentOperation.validate;
    final report = _operation(input, operation: operation);
    if (report.hasErrors) {
      throw MambaException(report.renderText(operation), exitCode: 2);
    }
    return switch (valueOf(_format)) {
      OutputFormat.json => jsonEncode(report.envelope(operation)),
      OutputFormat.text => report.renderText(operation),
    };
  }
}

/// Resolves the shared source-selection rules for both `agent` children.
///
/// A native positional and `--request` are mutually exclusive, a request
/// rejects `--harness`, a native file requires an explicit harness, and one
/// source must be present. Violations are usage failures with status 1.
AgentInspectionInput _inspectionInput({
  required String? nativeFile,
  required String? requestFile,
  required AgentHarness? harness,
  required String? cwd,
  required bool showInstructions,
}) {
  if (nativeFile != null && nativeFile.trim().isEmpty) {
    throw MambaException('The native file path must not be blank.');
  }
  if (requestFile != null && requestFile.trim().isEmpty) {
    throw MambaException('The --request path must not be blank.');
  }
  if (cwd != null && cwd.trim().isEmpty) {
    throw MambaException('The --cwd directory must not be blank.');
  }
  if (nativeFile != null && requestFile != null) {
    throw MambaException(
      'Provide either a native file or --request, not both.',
    );
  }
  if (requestFile != null && harness != null) {
    throw MambaException(
      'A --request envelope selects a Codex config-bound role and cannot '
      'be combined with --harness.',
    );
  }
  if (nativeFile == null && requestFile == null) {
    throw MambaException(
      'Provide a native file or a --request envelope to select a source.',
    );
  }
  if (nativeFile != null && harness == null) {
    throw MambaException(
      'A native file requires an explicit --harness (claude, codex, or pi); '
      'Markdown is never auto-detected.',
    );
  }

  return AgentInspectionInput(
    nativeFile: nativeFile,
    requestFile: requestFile,
    cwd: cwd,
    harness: harness,
    showInstructions: showInstructions,
  );
}

final class AgentListCommand(
  final AgentInventoryOperation _inventory,
  final AgentLifecycleService _lifecycle,
) extends Command {
  this
    : super(
        options: [
          _scope,
          _listHarness,
          _listFormat,
          _listCwd,
          _projectRoot,
          _home,
          _claudeConfigDir,
          _codexHome,
          _piAgentDir,
          _readRoots,
          _stateDir,
        ],
        flags: [_verify],
        longDescription:
            'Read-only bounded inventory of native Agent occurrences. Scope '
            'defaults to project; user and all require an explicit or captured '
            'home context. Optional harness filters presentation. Claude and '
            'Codex project inventories use the bounded cwd-to-project-root '
            'ancestor chain; Pi uses the selected project boundary. Codex '
            'config-declared roles retain binding provenance. Pi immediate '
            'files are distinguished from deeper provider-specific candidates. '
            'Additional read roots contribute only Claude project trees. '
            'Traversal is limited to 64 ancestors, depth 16, 20,000 entries, '
            '2,000 directories, and 64 MiB of metadata. Linked candidates are '
            'reported without target reads; linked roots are refused. '
            'Occurrence IDs are inventory identities, not managed installation '
            'IDs or mutation selectors. Managed occurrences expose verified '
            'installation IDs; unmanaged, tracked-missing, and '
            'ownership-unverified states remain distinct. Without --verify, '
            'modification is notVerified; verification never invents a missing '
            'baseline comparison. Inventory makes no native '
            'activation, runtime precedence, ownership, or uniqueness-winner '
            'claim. Malformed candidates remain visible; incomplete required '
            'coverage fails without partial JSON. No harness, agent, hook, MCP '
            'server, extension, registry, account, or network probe is run, and '
            'no files or management records are created.',
      );

  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: AgentScope.values,
    defaultValue: AgentScope.project,
    description: 'Installation scopes to inventory.',
  );

  static final _listHarness = ChoiceOption(
    'harness',
    choices: AgentHarness.values,
    description: 'Optional native harness presentation filter.',
  );

  static final _listFormat = ChoiceOption.withDefault(
    'format',
    choices: OutputFormat.values,
    defaultValue: OutputFormat.text,
    description: 'Inventory format.',
  );

  static final _listCwd = FolderPathOption(
    'cwd',
    description: 'Working directory for project and relative-path context.',
  );

  static final _projectRoot = FolderPathOption(
    'project-root',
    description: 'Explicit project boundary containing cwd.',
  );

  static final _home = FolderPathOption(
    'home',
    description: 'Home directory for user-scope context.',
  );

  static final _claudeConfigDir = FolderPathOption(
    'claude-config-dir',
    description: 'Claude personal configuration directory.',
  );

  static final _codexHome = FolderPathOption(
    'codex-home',
    description: 'Codex home directory.',
  );

  static final _piAgentDir = FolderPathOption(
    'pi-agent-dir',
    description: 'Pi user Agent directory.',
  );

  static final _readRoots = RepeatableFolderPathOption(
    'read-root',
    description: 'Additional read-only Claude project root.',
  );

  static final _stateDir = FolderPathOption(
    'state-dir',
    description: 'User lifecycle state directory.',
  );

  static const _verify = BooleanFlag(
    'verify',
    description: 'Request managed baseline comparison when available.',
  );

  @override
  String get name => 'list';

  @override
  String get shortDescription => 'Inventory native Agent occurrences.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final report = await _inventory(
      AgentInventoryInput(
        processWorkingDirectory: Directory.current.path,
        environment: Platform.environment,
        scope: valueOf(_scope),
        harness: valueOf(_listHarness),
        verify: valueOf(_verify),
        cwd: valueOf(_listCwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        claudeConfigDir: valueOf(_claudeConfigDir),
        codexHome: valueOf(_codexHome),
        piAgentDir: valueOf(_piAgentDir),
        readRoots: valueOf(_readRoots) ?? const <String>[],
        stateDir: valueOf(_stateDir),
      ),
    );
    final managed = _lifecycle.managementAware(
      report,
      AgentInventoryInput(
        processWorkingDirectory: Directory.current.path,
        environment: Platform.environment,
        scope: valueOf(_scope),
        harness: valueOf(_listHarness),
        verify: valueOf(_verify),
        cwd: valueOf(_listCwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        claudeConfigDir: valueOf(_claudeConfigDir),
        codexHome: valueOf(_codexHome),
        piAgentDir: valueOf(_piAgentDir),
        readRoots: valueOf(_readRoots) ?? const <String>[],
        stateDir: valueOf(_stateDir),
      ),
    );
    return switch (valueOf(_listFormat)) {
      OutputFormat.json => jsonEncode(managed.envelope()),
      OutputFormat.text => managed.renderText(),
    };
  }
}
