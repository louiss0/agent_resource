import 'dart:convert';

import 'package:mamba/mamba.dart';

import 'src/agent_inspection.dart';

/// The output format selected by `--format`.
enum OutputFormat { text, json }

/// The inspection/validation operation shared by the `agent` commands.
typedef AgentInspectionOperation = AgentInspectionReport Function(
  AgentInspectionInput input, {
  required AgentOperation operation,
});

/// The `agent` command group owning the native-agent inspection and
/// validation children.
final class AgentCommand extends GroupCommand {
  AgentCommand({AgentInspectionOperation operation = inspectNativeAgent})
    : super([AgentInspectCommand(operation), AgentValidateCommand(operation)]);

  @override
  String get name => 'agent';

  @override
  String get shortDescription =>
      'Inspect and validate native agent definitions.';
}

final class AgentInspectCommand(final AgentInspectionOperation _operation)
    extends Command {
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
    return switch (valueOf(_format)) {
      OutputFormat.json => jsonEncode(report.envelope(operation)),
      OutputFormat.text => report.renderText(operation),
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
