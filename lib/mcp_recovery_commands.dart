import 'dart:convert';
import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'src/mcp/mcp_envelope.dart';
import 'src/mcp/mcp_recovery_evidence.dart';
import 'src/mcp/mcp_types.dart';
import 'src/services/mcp_recovery_service.dart';

/// The typed inputs shared by the MCP backup and recovery commands. A fresh
/// bundle is created per command so every handle is registered exactly once.
final class McpRecoveryInputs {
  final name = StringOption('name', regex: RegExp(r'.+'));
  final harness = ChoiceOption('harness', choices: McpHarness.values);
  final scope = ChoiceOption('scope', choices: McpScope.values);
  final backupId = StringOption('backup-id', regex: RegExp(r'.+'));
  final transactionId = StringOption('transaction-id', regex: RegExp(r'.+'));
  final action = ChoiceOption('action', choices: McpRecoveryAction.values);
  final planId = StringOption('plan-id', regex: RegExp(r'.+'));
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
  final dryRun = BooleanFlag(
    'dry-run',
    description: 'Preview a fresh reviewed plan without writing.',
  );
  final yes = BooleanFlag('yes', description: 'Unattended reviewed apply.');
  final interactive = BooleanFlag(
    'interactive',
    description: 'Force interactive review and approval.',
  );
  final ackMcpRisk = BooleanFlag(
    'ack-mcp-risk',
    description: 'Acknowledge the risk of restoring an executable or endpoint.',
  );

  List<Option<Object?>> get contextOptions => <Option<Object?>>[
    format,
    cwd,
    projectRoot,
    home,
    claudeConfigDir,
    codexHome,
    piAgentDir,
    stateDir,
  ];

  List<Option<Object?>> get selectionOptions => <Option<Object?>>[
    name,
    harness,
    scope,
  ];

  List<Flag<Object?>> get reviewFlags => <Flag<Object?>>[
    dryRun,
    yes,
    interactive,
  ];
}

String _render(McpEnvelope envelope, McpOutputFormat format) =>
    switch (format) {
      McpOutputFormat.json => jsonEncode(envelope.envelope()),
      McpOutputFormat.text => envelope.renderText(),
    };

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
          ...inputs.contextOptions,
          inputs.harness,
          inputs.scope,
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
    final envelope = await _service.listBackups(
      McpRecoveryRequest(
        environment: Map<String, String>.unmodifiable(Platform.environment),
        harness: valueOf(_inputs.harness),
        scope: valueOf(_inputs.scope),
        cwd: valueOf(_inputs.cwd),
        projectRoot: valueOf(_inputs.projectRoot),
        home: valueOf(_inputs.home),
        claudeConfigDir: valueOf(_inputs.claudeConfigDir),
        codexHome: valueOf(_inputs.codexHome),
        piAgentDir: valueOf(_inputs.piAgentDir),
        stateDir: valueOf(_inputs.stateDir),
      ),
    );
    return _render(envelope, valueOf(_inputs.format));
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
          ...inputs.selectionOptions,
          inputs.backupId,
          inputs.planId,
          ...inputs.contextOptions,
        ],
        flags: <Flag<Object?>>[...inputs.reviewFlags, inputs.ackMcpRisk],
        longDescription: longDescription,
      );

  final McpRecoveryService _service;
  final McpRecoveryInputs _inputs;

  McpRecoveryRequest request(ValueOf valueOf) => McpRecoveryRequest(
    environment: Map<String, String>.unmodifiable(Platform.environment),
    harness: valueOf(_inputs.harness),
    scope: valueOf(_inputs.scope),
    name: valueOf(_inputs.name),
    backupId: valueOf(_inputs.backupId),
    planId: valueOf(_inputs.planId),
    dryRun: valueOf(_inputs.dryRun),
    yes: valueOf(_inputs.yes),
    interactive: valueOf(_inputs.interactive),
    ackMcpRisk: valueOf(_inputs.ackMcpRisk),
    cwd: valueOf(_inputs.cwd),
    projectRoot: valueOf(_inputs.projectRoot),
    home: valueOf(_inputs.home),
    claudeConfigDir: valueOf(_inputs.claudeConfigDir),
    codexHome: valueOf(_inputs.codexHome),
    piAgentDir: valueOf(_inputs.piAgentDir),
    stateDir: valueOf(_inputs.stateDir),
  );

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final envelope = await apply(request(valueOf));
    return _render(envelope, valueOf(_inputs.format));
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
          ...inputs.selectionOptions,
          inputs.transactionId,
          inputs.action,
          inputs.planId,
          ...inputs.contextOptions,
        ],
        flags: <Flag<Object?>>[...inputs.reviewFlags, inputs.ackMcpRisk],
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
    final envelope = await _service.recover(
      McpRecoveryRequest(
        environment: Map<String, String>.unmodifiable(Platform.environment),
        harness: valueOf(_inputs.harness),
        scope: valueOf(_inputs.scope),
        name: valueOf(_inputs.name),
        transactionId: valueOf(_inputs.transactionId),
        action: valueOf(_inputs.action),
        planId: valueOf(_inputs.planId),
        dryRun: valueOf(_inputs.dryRun),
        yes: valueOf(_inputs.yes),
        interactive: valueOf(_inputs.interactive),
        ackMcpRisk: valueOf(_inputs.ackMcpRisk),
        cwd: valueOf(_inputs.cwd),
        projectRoot: valueOf(_inputs.projectRoot),
        home: valueOf(_inputs.home),
        claudeConfigDir: valueOf(_inputs.claudeConfigDir),
        codexHome: valueOf(_inputs.codexHome),
        piAgentDir: valueOf(_inputs.piAgentDir),
        stateDir: valueOf(_inputs.stateDir),
      ),
    );
    return _render(envelope, valueOf(_inputs.format));
  }
}
