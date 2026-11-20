import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'src/mcp/mcp_envelope.dart';
import 'src/mcp/mcp_recovery_evidence.dart';
import 'src/mcp/mcp_types.dart';
import 'src/services/mcp_recovery_service.dart';

/// The typed inputs shared by the MCP backup and recovery commands. A fresh
/// bundle is created per command so every handle is registered exactly once.
final class McpRecoveryInputs {
  final _name = StringOption('name', regex: RegExp(r'.+'));
  final _harness = ChoiceOption('harness', choices: McpHarness.values);
  final _scope = ChoiceOption('scope', choices: McpScope.values);
  final _backupId = StringOption('backup-id', regex: RegExp(r'.+'));
  final _transactionId = StringOption('transaction-id', regex: RegExp(r'.+'));
  final _action = ChoiceOption('action', choices: McpRecoveryAction.values);
  final _planId = StringOption('plan-id', regex: RegExp(r'.+'));
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
  final _dryRun = BooleanFlag(
    'dry-run',
    description: 'Preview a fresh reviewed plan without writing.',
  );
  final _yes = BooleanFlag('yes', description: 'Unattended reviewed apply.');
  final _interactive = BooleanFlag(
    'interactive',
    description: 'Force interactive review and approval.',
  );
  final _ackMcpRisk = BooleanFlag(
    'ack-mcp-risk',
    description: 'Acknowledge the risk of restoring an executable or endpoint.',
  );

  List<Option<Object?>> get _contextOptions => <Option<Object?>>[
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

  List<Option<Object?>> get _selectionOptions => <Option<Object?>>[
    _name,
    _harness,
    _scope,
  ];

  List<Flag<Object?>> get _reviewFlags => <Flag<Object?>>[
    _dryRun,
    _yes,
    _interactive,
  ];
}

/// Appended to `McpCommand._children`: the `backup` group and `recover` leaf.
List<Command> mcpRecoveryCommands(McpRecoveryService service) => <Command>[
  McpBackupCommand(service),
  McpRecoverCommand(service),
];

/// `mcp backup` owns only protected entry evidence; it never lists or handles
/// whole native configuration files.
final class McpBackupCommand extends GroupCommand {
  McpBackupCommand(McpRecoveryService service)
    : super(<Command>[
        McpBackupListCommand(service),
        McpBackupRestoreCommand(service),
        McpBackupCleanupCommand(service),
      ]);

  @override
  String get name => 'backup';

  @override
  String get shortDescription =>
      'List, restore, and clean up protected MCP entry evidence.';
}

final class McpBackupListCommand extends Command {
  McpBackupListCommand(McpRecoveryService service)
    : this._(service, McpRecoveryInputs());

  McpBackupListCommand._(this._service, McpRecoveryInputs inputs)
    : _inputs = inputs,
      super(
        options: <Option<Object?>>[
          ...inputs._contextOptions,
          inputs._harness,
          inputs._scope,
        ],
        longDescription:
            'Lists protected MCP entry backups under the Agent Resource state '
            'root. Each backup retains only one selected native entry and a '
            'whole-file fingerprint, never a whole shared configuration file. '
            'Credential-bearing values are redacted in every output.',
      );

  final McpRecoveryService _service;
  final McpRecoveryInputs _inputs;

  @override
  String get name => 'list';

  @override
  String get shortDescription =>
      'List protected MCP entry backups with redaction.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final inputs = _inputs;
    final outputFormat = valueOf(inputs._format);
    final envelope = await _service.listBackups(
      McpRecoveryRequest(
        environment: Map<String, String>.unmodifiable(Platform.environment),
        harness: valueOf(inputs._harness),
        scope: valueOf(inputs._scope),
        cwd: valueOf(inputs._cwd),
        projectRoot: valueOf(inputs._projectRoot),
        home: valueOf(inputs._home),
        claudeConfigDir: valueOf(inputs._claudeConfigDir),
        codexHome: valueOf(inputs._codexHome),
        piAgentDir: valueOf(inputs._piAgentDir),
        geminiDir: valueOf(inputs._geminiDir),
        stateDir: valueOf(inputs._stateDir),
      ),
    );
    return renderMcpEnvelope(envelope, outputFormat);
  }
}

/// Shared argv marshalling for reviewed, entry-only evidence actions.
abstract class McpEvidenceCommand extends Command {
  McpEvidenceCommand(
    this._service,
    McpRecoveryInputs inputs,
    String longDescription,
  ) : _inputs = inputs,
      super(
        options: <Option<Object?>>[
          ...inputs._selectionOptions,
          inputs._backupId,
          inputs._planId,
          ...inputs._contextOptions,
        ],
        flags: <Flag<Object?>>[...inputs._reviewFlags, inputs._ackMcpRisk],
        longDescription: longDescription,
      );

  final McpRecoveryService _service;
  final McpRecoveryInputs _inputs;

  McpRecoveryRequest request(ValueOf valueOf) {
    final inputs = _inputs;
    final serverName = valueOf(inputs._name);
    final harness = valueOf(inputs._harness);
    final scope = valueOf(inputs._scope);
    final reviewedBackupId = valueOf(inputs._backupId);
    final reviewedPlanId = valueOf(inputs._planId);
    return McpRecoveryRequest(
      environment: Map<String, String>.unmodifiable(Platform.environment),
      harness: harness,
      scope: scope,
      name: serverName,
      backupId: reviewedBackupId,
      planId: reviewedPlanId,
      dryRun: valueOf(inputs._dryRun),
      yes: valueOf(inputs._yes),
      interactive: valueOf(inputs._interactive),
      ackMcpRisk: valueOf(inputs._ackMcpRisk),
      cwd: valueOf(inputs._cwd),
      projectRoot: valueOf(inputs._projectRoot),
      home: valueOf(inputs._home),
      claudeConfigDir: valueOf(inputs._claudeConfigDir),
      codexHome: valueOf(inputs._codexHome),
      piAgentDir: valueOf(inputs._piAgentDir),
      geminiDir: valueOf(inputs._geminiDir),
      stateDir: valueOf(inputs._stateDir),
    );
  }

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final outputFormat = valueOf(_inputs._format);
    final envelope = await apply(request(valueOf));
    return renderMcpEnvelope(envelope, outputFormat);
  }

  Future<McpEnvelope> apply(McpRecoveryRequest request);

  @override
  String get shortDescription => (longDescription ?? '').split('.').first;
}

final class McpBackupRestoreCommand extends McpEvidenceCommand {
  McpBackupRestoreCommand(McpRecoveryService service)
    : super(
        service,
        McpRecoveryInputs(),
        'Restores only the selected MCP entry from one retained backup after a '
        'fresh reviewed plan built from current native bytes and the current '
        'management baseline. A stale plan or a changed shared file is refused. '
        'Unrelated keys, comments and bytes survive; no whole file is replaced.',
      );

  @override
  String get name => 'restore';

  @override
  Future<McpEnvelope> apply(McpRecoveryRequest request) =>
      _service.restoreBackup(request);
}

final class McpBackupCleanupCommand extends McpEvidenceCommand {
  McpBackupCleanupCommand(McpRecoveryService service)
    : super(
        service,
        McpRecoveryInputs(),
        'Removes only the explicitly selected, eligible backup evidence after '
        'review. Evidence still referenced by a recoverable transaction is '
        'never erased. No native configuration file is touched.',
      );

  @override
  String get name => 'cleanup';

  @override
  Future<McpEnvelope> apply(McpRecoveryRequest request) =>
      _service.cleanupBackup(request);
}

final class McpRecoverCommand extends Command {
  McpRecoverCommand(McpRecoveryService service)
    : this._(service, McpRecoveryInputs());

  McpRecoverCommand._(this._service, McpRecoveryInputs inputs)
    : _inputs = inputs,
      super(
        options: <Option<Object?>>[
          ...inputs._selectionOptions,
          inputs._transactionId,
          inputs._action,
          inputs._planId,
          ...inputs._contextOptions,
        ],
        flags: <Flag<Object?>>[...inputs._reviewFlags, inputs._ackMcpRisk],
        longDescription:
            'Completes or rolls back an interrupted MCP mutation using a '
            'reviewed action that must be provable from the recorded phase. '
            'Only the affected native entry is written; unrelated content is '
            'preserved. Inconsistent or substituted evidence and an '
            'unprovable decision are refused. Without --transaction-id the '
            'pending transactions are inspected read-only.',
      );

  final McpRecoveryService _service;
  final McpRecoveryInputs _inputs;

  @override
  String get name => 'recover';

  @override
  String get shortDescription =>
      'Recover an interrupted MCP mutation with a reviewed action.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final inputs = _inputs;
    final outputFormat = valueOf(inputs._format);
    final serverName = valueOf(inputs._name);
    final harness = valueOf(inputs._harness);
    final scope = valueOf(inputs._scope);
    final transactionId = valueOf(inputs._transactionId);
    final reviewedAction = valueOf(inputs._action);
    final reviewedPlanId = valueOf(inputs._planId);
    final envelope = await _service.recover(
      McpRecoveryRequest(
        environment: Map<String, String>.unmodifiable(Platform.environment),
        harness: harness,
        scope: scope,
        name: serverName,
        transactionId: transactionId,
        action: reviewedAction,
        planId: reviewedPlanId,
        dryRun: valueOf(inputs._dryRun),
        yes: valueOf(inputs._yes),
        interactive: valueOf(inputs._interactive),
        ackMcpRisk: valueOf(inputs._ackMcpRisk),
        cwd: valueOf(inputs._cwd),
        projectRoot: valueOf(inputs._projectRoot),
        home: valueOf(inputs._home),
        claudeConfigDir: valueOf(inputs._claudeConfigDir),
        codexHome: valueOf(inputs._codexHome),
        piAgentDir: valueOf(inputs._piAgentDir),
        geminiDir: valueOf(inputs._geminiDir),
        stateDir: valueOf(inputs._stateDir),
      ),
    );
    return renderMcpEnvelope(envelope, outputFormat);
  }
}
