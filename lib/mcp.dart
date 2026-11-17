import 'dart:convert';
import 'dart:io' show Platform;

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'mcp_lifecycle_commands.dart';
import 'src/mcp/mcp_envelope.dart';
import 'src/mcp/mcp_types.dart';
import 'src/mcp/mcp_validation.dart';
import 'src/services/mcp_inspection_service.dart';
import 'src/services/mcp_mutation_service.dart';
import 'src/services/mcp_validation_service.dart';

/// The singular `mcp` command group and its read-only discovery and
/// validation children. Mirrors the singular `skill` group: services default
/// to the same injected [fslib.FileSystem] used by the rest of the application.
final class McpCommand extends GroupCommand {
  McpCommand({
    McpInspectionService? inspection,
    McpValidationService? validation,
    McpMutationService? mutation,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : super(_children(inspection, validation, mutation, fileSystem));

  static List<Command> _children(
    McpInspectionService? inspection,
    McpValidationService? validation,
    McpMutationService? mutation,
    fslib.FileSystem fileSystem,
  ) {
    final service = inspection ?? McpInspectionService(fileSystem: fileSystem);
    final validationService =
        validation ?? McpValidationService(fileSystem: fileSystem);
    final mutationService =
        mutation ?? McpMutationService(fileSystem: fileSystem);
    return <Command>[
      McpListCommand(service),
      McpInspectCommand(service),
      McpValidateCommand(validationService),
      McpRegisterCommand(mutationService),
      McpReplaceCommand(mutationService),
      McpAdoptCommand(mutationService),
      McpUnregisterCommand(mutationService),
    ];
  }

  @override
  String get name => 'mcp';

  @override
  String get shortDescription =>
      'Discover, validate, and manage MCP server registrations.';
}

final class McpListCommand extends Command {
  McpListCommand(this._service)
    : super(
        options: [
          _harness,
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claudeConfigDir,
          _codexHome,
          _piAgentDir,
          _stateDir,
        ],
        flags: [_verify],
        longDescription:
            'Read-only, management-aware MCP registration inventory across '
            'Claude Code, Codex, and native Pi. Discovers native configuration '
            'for the selected harnesses and scopes and classifies each entry '
            'as managed, unmanaged, or ownership-unverified. This is passive '
            'static discovery: it never launches, connects to, or '
            'authenticates against a server and never claims runtime '
            'activation. --verify discloses fresh baseline digests.',
      );

  static final _harness = ChoiceOption(
    'harness',
    choices: McpHarness.values,
    description: 'Limit discovery to one harness.',
  );
  static final _scope = ChoiceOption(
    'scope',
    choices: McpScope.values,
    description: 'Limit discovery to one native scope.',
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: McpOutputFormat.values,
    defaultValue: McpOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claudeConfigDir = FolderPathOption('claude-config-dir');
  static final _codexHome = FolderPathOption('codex-home');
  static final _piAgentDir = FolderPathOption('pi-agent-dir');
  static final _stateDir = FolderPathOption('state-dir');
  static const _verify = BooleanFlag('verify');

  final McpInspectionService _service;

  @override
  String get name => 'list';

  @override
  String get shortDescription =>
      'List observed MCP registrations across harnesses and scopes.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final envelope = await _service.list(
      McpInspectionRequest(
        environment: Map<String, String>.unmodifiable(Platform.environment),
        harness: valueOf(_harness),
        scope: valueOf(_scope),
        verify: valueOf(_verify),
        cwd: valueOf(_cwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        claudeConfigDir: valueOf(_claudeConfigDir),
        codexHome: valueOf(_codexHome),
        piAgentDir: valueOf(_piAgentDir),
        stateDir: valueOf(_stateDir),
      ),
    );
    return _render(envelope, valueOf(_format));
  }
}

final class McpInspectCommand extends Command {
  McpInspectCommand(this._service)
    : super(
        options: [
          _name,
          _harness,
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claudeConfigDir,
          _codexHome,
          _piAgentDir,
          _stateDir,
        ],
        longDescription:
            'Read-only inspection of one MCP registration selected by name '
            'plus explicit harness and scope. Renders the native shape with '
            'literal credential values redacted, disclosing references and '
            'sanitized endpoints only. Never writes to the native file and '
            'never launches, connects to, or authenticates against a server.',
      );

  static final _name = StringOption(
    'name',
    description: 'The MCP server name to inspect.',
  );
  static final _harness = ChoiceOption(
    'harness',
    choices: McpHarness.values,
    description: 'The explicit harness that owns the registration.',
  );
  static final _scope = ChoiceOption(
    'scope',
    choices: McpScope.values,
    description: 'The explicit native scope of the registration.',
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: McpOutputFormat.values,
    defaultValue: McpOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claudeConfigDir = FolderPathOption('claude-config-dir');
  static final _codexHome = FolderPathOption('codex-home');
  static final _piAgentDir = FolderPathOption('pi-agent-dir');
  static final _stateDir = FolderPathOption('state-dir');

  final McpInspectionService _service;

  @override
  String get name => 'inspect';

  @override
  String get shortDescription =>
      'Inspect one MCP registration with credential redaction.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final envelope = await _service.inspect(
      McpInspectionRequest(
        environment: Map<String, String>.unmodifiable(Platform.environment),
        name: valueOf(_name),
        harness: valueOf(_harness),
        scope: valueOf(_scope),
        cwd: valueOf(_cwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        claudeConfigDir: valueOf(_claudeConfigDir),
        codexHome: valueOf(_codexHome),
        piAgentDir: valueOf(_piAgentDir),
        stateDir: valueOf(_stateDir),
      ),
    );
    return _render(envelope, valueOf(_format));
  }
}

String _render(McpEnvelope envelope, McpOutputFormat format) =>
    switch (format) {
      McpOutputFormat.json => jsonEncode(envelope.envelope()),
      McpOutputFormat.text => envelope.renderText(),
    };

final class McpValidateCommand extends Command {
  McpValidateCommand(this._service)
    : super(
        options: [
          _name,
          _harness,
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claudeConfigDir,
          _codexHome,
          _piAgentDir,
          _stateDir,
        ],
        longDescription:
            'Statically validates one MCP registration selected by --name '
            'plus explicit --harness and --scope. Occurrences and paths are '
            'not selectors: path options only resolve the bounded native '
            'location. Uses one shared per-harness Zema contract with '
            'value-free diagnostics and a static schema/reference '
            'correctness claim. Native configuration is read only; no '
            'server is launched, connected to, or authenticated.',
      );

  static final _name = StringOption.required(
    'name',
    regex: RegExp(r'.+'),
    description: 'The MCP server name to validate.',
  );
  static final _harness = ChoiceOption.required(
    'harness',
    choices: McpHarness.values,
    description: 'The explicit harness that owns the registration.',
  );
  static final _scope = ChoiceOption.required(
    'scope',
    choices: McpScope.values,
    description: 'The explicit native scope of the registration.',
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: McpOutputFormat.values,
    defaultValue: McpOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claudeConfigDir = FolderPathOption('claude-config-dir');
  static final _codexHome = FolderPathOption('codex-home');
  static final _piAgentDir = FolderPathOption('pi-agent-dir');
  static final _stateDir = FolderPathOption('state-dir');

  final McpValidationService _service;

  @override
  String get name => 'validate';

  @override
  String get shortDescription =>
      'Validate one MCP registration against its static native contract.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final harness = valueOf(_harness);
    final scope = valueOf(_scope);
    final name = valueOf(_name);
    final format = valueOf(_format);
    final McpValidationReport report = _service.validateSelection(
      McpValidationSelectionRequest(
        environment: Map<String, String>.unmodifiable(Platform.environment),
        harness: harness,
        scope: scope,
        name: name,
        cwd: valueOf(_cwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        claudeConfigDir: valueOf(_claudeConfigDir),
        codexHome: valueOf(_codexHome),
        piAgentDir: valueOf(_piAgentDir),
        stateDir: valueOf(_stateDir),
      ),
    );
    if (!report.valid) {
      final output = switch (format) {
        McpOutputFormat.json => jsonEncode(report.toJson()),
        McpOutputFormat.text => report.renderText(),
      };
      throw MambaException(output, exitCode: 2);
    }
    final envelope = McpEnvelope(
      command: 'mcp.validate',
      outcome: 'validated',
      data: <String, Object?>{
        'harness': harness.wireName,
        'scope': scope.wireName,
        'name': name,
        'valid': report.valid,
        'report': report.toJson(),
      },
      diagnostics: const <Map<String, Object?>>[],
    );
    return _render(envelope, format);
  }
}
