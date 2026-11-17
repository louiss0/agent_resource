import 'dart:convert';
import 'dart:io' show FileSystemEntityType;

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../mcp/mcp_envelope.dart';
import '../mcp/mcp_native.dart';
import '../mcp/mcp_native_editor.dart';
import '../mcp/mcp_ownership_ledger.dart';
import '../mcp/mcp_recovery_evidence.dart';
import '../mcp/mcp_types.dart';
import 'lifecycle_state_service.dart';
import 'mcp_mutation_service.dart';
import 'mcp_validation_service.dart';

/// Narrow filesystem seam for recovery evidence. Mirrors `LifecycleIO`: every
/// operation calls [before] first so deterministic fault-injection tests can
/// interrupt a recorded phase without touching a native file directly.
class McpRecoveryIO {
  const McpRecoveryIO({this.fs = const local.LocalFileSystem()});

  final fslib.FileSystem fs;

  void before(String operation, String path) {}

  String? read(String path) {
    before('read', path);
    return readMcpNativeText(fs, path);
  }

  void write(String path, String text) {
    before('write', path);
    fs.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text, flush: true);
  }

  void delete(String path) {
    if (fs.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    before('delete', path);
    fs.file(path).deleteSync();
  }

  List<String> list(String path) {
    before('list', path);
    final directory = fs.directory(path);
    if (!directory.existsSync()) return <String>[];
    return <String>[
      for (final entity in directory.listSync(followLinks: false))
        if (entity is fslib.File) entity.path,
    ]..sort();
  }
}

/// One reviewed backup/recovery invocation. Selection remains name plus
/// explicit harness and scope; identifiers select retained evidence, never a
/// native occurrence or path.
final class McpRecoveryRequest {
  const McpRecoveryRequest({
    required this.environment,
    this.harness,
    this.scope,
    this.name,
    this.backupId,
    this.transactionId,
    this.action,
    this.dryRun = false,
    this.yes = false,
    this.interactive = false,
    this.ackMcpRisk = false,
    this.planId,
    this.cwd,
    this.projectRoot,
    this.home,
    this.claudeConfigDir,
    this.codexHome,
    this.piAgentDir,
    this.stateDir,
  });

  final Map<String, String> environment;
  final McpHarness? harness;
  final McpScope? scope;
  final String? name;
  final String? backupId;
  final String? transactionId;
  final McpRecoveryAction? action;
  final bool dryRun;
  final bool yes;
  final bool interactive;
  final bool ackMcpRisk;
  final String? planId;
  final String? cwd;
  final String? projectRoot;
  final String? home;
  final String? claudeConfigDir;
  final String? codexHome;
  final String? piAgentDir;
  final String? stateDir;
}

/// The current, bounded view of one native file and its management record.
final class _Observation {
  const _Observation(
    this.context,
    this.location,
    this.sourceText,
    this.sourceFingerprint,
    this.currentFields,
    this.records,
    this.record,
  );

  final LifecycleContext context;
  final McpNativeLocation location;
  final String sourceText;
  final String sourceFingerprint;
  final Map<String, Object?>? currentFields;
  final Map<String, McpRegistrationRecord> records;
  final McpRegistrationRecord? record;

  String get stateRoot => context.stateRoot(LifecycleScope.user);
}

/// Reviewed MCP backup and recovery (stories 24, 25).
///
/// This service wraps the Wave C mutation service so every reviewed mutation
/// first retains ONE selected entry as protected evidence and records a phased
/// transaction. It also serves `mcp backup list/restore/cleanup` and
/// `mcp recover`. Every restored or recovered write is a fresh reviewed,
/// entry-only patch: a whole shared file is never replaced and a stale plan or
/// drifted file is refused.
interface class McpRecoveryService implements McpMutationService {
  McpRecoveryService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    McpMutationService? mutation,
    McpPlanApproval? approve,
    McpRecoveryIO? io,
  }) : fs = fileSystem,
       _delegate =
           mutation ??
           McpMutationService(fileSystem: fileSystem, approve: approve),
       approve = approve ?? defaultMcpPlanApproval,
       io = io ?? McpRecoveryIO(fs: fileSystem);

  @override
  final fslib.FileSystem fs;

  final McpMutationService _delegate;

  @override
  McpValidationService get validation => _delegate.validation;

  @override
  final McpPlanApproval approve;

  final McpRecoveryIO io;

  static const McpNativeResolver _resolver = McpNativeResolver();

  // -------------------------------------------------------------------------
  // Reviewed mutations: retain one prior entry, then record each phase.
  // -------------------------------------------------------------------------

  @override
  Future<McpEnvelope> execute(McpMutationRequest request) async {
    if (request.dryRun) return _delegate.execute(request);

    final recoveryRequest = _recoveryRequest(request);
    final plan = await _delegate.execute(_asDryRun(request));
    final planId = _planId(plan);
    final observation = _observe(recoveryRequest);
    final identity = _selection(recoveryRequest);
    final ids = _ids(planId, identity.storageKey);
    final backup = McpBackupEvidence(
      backupId: ids.$1,
      operation: request.operation.wireName,
      identity: identity,
      sourceFingerprint: observation.sourceFingerprint,
      fields: observation.currentFields ?? const <String, Object?>{},
      absent: observation.currentFields == null,
      planId: planId,
      transactionId: ids.$2,
    );
    var transaction = McpTransactionRecord(
      transactionId: ids.$2,
      backupId: ids.$1,
      operation: request.operation.wireName,
      identity: identity,
      phase: McpRecoveryPhase.prepared,
      planId: planId,
      preSourceFingerprint: observation.sourceFingerprint,
      preBaselineDigest: observation.record?.baselineDigest,
      proposedFields: _proposedFields(plan),
    );

    _writeBackup(observation.stateRoot, backup);
    _writeTransaction(observation.stateRoot, transaction);
    var publicationRecorded = false;
    try {
      final result = await _delegate.execute(request);
      final publishedObservation = _observe(recoveryRequest);
      transaction = transaction.withPhase(
        McpRecoveryPhase.published,
        publishedSourceFingerprint: publishedObservation.sourceFingerprint,
        publishedBaselineDigest:
            publishedObservation.records[identity.storageKey]?.baselineDigest,
      );
      _writeTransaction(publishedObservation.stateRoot, transaction);
      publicationRecorded = true;
      if (!_publicationMatches(transaction, backup, publishedObservation)) {
        transaction = transaction.withPhase(McpRecoveryPhase.recoveryRequired);
        _writeTransaction(publishedObservation.stateRoot, transaction);
        throw MambaException(
          'The MCP mutation completed but its reviewed state could not be '
          'verified. Recovery is required; no success was reported.',
          exitCode: 6,
        );
      }
      transaction = transaction.withPhase(McpRecoveryPhase.committed);
      _writeTransaction(publishedObservation.stateRoot, transaction);
      return result;
    } catch (error) {
      if (error is MambaException && error.exitCode == 6) rethrow;
      if (publicationRecorded) {
        // The published phase is already durable and its guards were checked;
        // a later state-write failure must not downgrade recorded evidence.
        throw MambaException(
          'The MCP mutation was published but not committed. Evidence was '
          'retained and recovery is required; no success was reported.',
          exitCode: 6,
        );
      }
      final current = _observe(recoveryRequest);
      final priorEntryDigest = backup.absent ? null : backup.digest;
      final entryChanged = _digest(current.currentFields) != priorEntryDigest;
      final baselineChanged =
          current.records[identity.storageKey]?.baselineDigest !=
          observation.record?.baselineDigest;
      // An unrelated shared-file edit during review is not a publication. Keep
      // the delegate's stale-plan refusal; only retained publication evidence
      // turns a failure into recovery-required state.
      if (!entryChanged && !baselineChanged) {
        _discard(observation.stateRoot, backup, transaction);
        rethrow;
      }
      transaction = transaction.withPhase(
        McpRecoveryPhase.recoveryRequired,
        publishedSourceFingerprint: current.sourceFingerprint,
        publishedBaselineDigest:
            current.records[identity.storageKey]?.baselineDigest,
      );
      _writeTransaction(current.stateRoot, transaction);
      throw MambaException(
        'The MCP mutation was interrupted after publication. Evidence was '
        'retained and recovery is required; no success was reported.',
        exitCode: 6,
      );
    }
  }

  // -------------------------------------------------------------------------
  // mcp backup list
  // -------------------------------------------------------------------------

  Future<McpEnvelope> listBackups(McpRecoveryRequest request) async {
    final stateRoot = _context(request).stateRoot(LifecycleScope.user);
    final backups = <Map<String, Object?>>[];
    for (final path in io.list(_backupDirectory(stateRoot))) {
      final text = io.read(path);
      if (text == null) continue;
      final evidence = _decodeBackup(text);
      if (request.harness != null &&
          evidence.identity.harness != request.harness) {
        continue;
      }
      if (request.scope != null && evidence.identity.scope != request.scope) {
        continue;
      }
      backups.add(evidence.redactedJson());
    }
    backups.sort(
      (a, b) => (a['backupId'] as String).compareTo(b['backupId'] as String),
    );
    return McpEnvelope(
      command: 'mcp.backup.list',
      outcome: 'listed',
      data: <String, Object?>{
        'count': backups.length,
        'backups': backups,
        'retention': mcpEvidenceRetention,
        'access': mcpEvidenceAccess,
        'claims':
            'protected entry evidence only; no whole native file is retained',
      },
    );
  }

  // -------------------------------------------------------------------------
  // mcp backup restore (story 24)
  // -------------------------------------------------------------------------

  Future<McpEnvelope> restoreBackup(McpRecoveryRequest request) async {
    final backupId = _id(request.backupId, mcpBackupIdPattern, '--backup-id');
    final identity = _selection(request);
    final observation = _observe(request);
    _requireIdentity(observation, identity);
    final evidence = _readBackup(observation.stateRoot, backupId);
    if (evidence.identity != identity) {
      throw MambaException(
        'The backup evidence belongs to a different MCP server entry; '
        'substitution is refused.',
        exitCode: 4,
      );
    }
    final restoreFields = evidence.absent
        ? null
        : Map<String, Object?>.from(evidence.fields);
    if (restoreFields != null) {
      final report = validation.validate(
        harness: identity.harness,
        scope: identity.scope,
        fields: restoreFields,
      );
      if (!report.valid) {
        throw MambaException(
          'The retained entry fails static validation; no file was written.\n'
          '${report.renderText()}',
          exitCode: 2,
        );
      }
    }
    final mutation = _restoreMutation(observation.currentFields, restoreFields);
    final planId = _recoveryPlanId(
      operation: 'backup-restore',
      evidenceDigest: evidence.artifactDigest,
      observation: observation,
      identity: identity,
      proposedDigest: restoreFields == null
          ? null
          : mcpCanonicalDigest(restoreFields),
      action: null,
    );
    final plan = _recoveryPlan(
      command: 'mcp.backup.restore.plan',
      operation: 'backup-restore',
      planId: planId,
      identity: identity,
      observation: observation,
      evidence: evidence.redactedJson(),
      proposedFields: restoreFields,
      availableActions: null,
    );
    if (request.dryRun) return plan;
    await _approveRecovery(request, plan, planId, () {
      final again = _observe(request);
      return _recoveryPlanId(
        operation: 'backup-restore',
        evidenceDigest: evidence.artifactDigest,
        observation: again,
        identity: identity,
        proposedDigest: restoreFields == null
            ? null
            : mcpCanonicalDigest(restoreFields),
        action: null,
      );
    });

    final current = _observe(request);
    if (mutation != null) {
      final nextText = const McpNativeEditor().apply(
        format: current.location.format,
        name: identity.name,
        text: current.sourceText,
        mutation: mutation,
      );
      io.write(current.location.path, nextText);
    }
    _writeBaseline(
      current,
      identity,
      restoreFields == null ? null : mcpCanonicalDigest(restoreFields),
    );
    return McpEnvelope(
      command: 'mcp.backup.restore',
      outcome: 'restored',
      data: <String, Object?>{
        'planId': planId,
        'backupId': backupId,
        ...identity.toJson(),
        'writes': mutation != null,
        'nativeWritten': mutation != null,
        'sourceFingerprintBefore': current.sourceFingerprint,
        'entry': restoreFields,
        'retention': mcpEvidenceRetention,
      },
    );
  }

  // -------------------------------------------------------------------------
  // mcp backup cleanup
  // -------------------------------------------------------------------------

  Future<McpEnvelope> cleanupBackup(McpRecoveryRequest request) async {
    final backupId = _id(request.backupId, mcpBackupIdPattern, '--backup-id');
    final contextStateRoot = _context(request).stateRoot(LifecycleScope.user);
    final evidence = _readBackup(contextStateRoot, backupId);
    for (final path in io.list(_transactionDirectory(contextStateRoot))) {
      final text = io.read(path);
      if (text == null) continue;
      final transaction = _decodeTransaction(text);
      if (transaction.backupId != backupId ||
          transaction.availableActions.isEmpty) {
        continue;
      }
      throw MambaException(
        'Backup $backupId is still referenced by recoverable transaction '
        '${transaction.transactionId}; recovery must be resolved or refused '
        'before cleanup.',
        exitCode: 4,
      );
    }
    final planId = mcpCanonicalDigest(<String, Object?>{
      'operation': 'backup-cleanup',
      'backupId': backupId,
      'evidenceDigest': evidence.artifactDigest,
      'stateRoot': contextStateRoot,
    });
    final plan = McpEnvelope(
      command: 'mcp.backup.cleanup.plan',
      outcome: 'planned',
      data: <String, Object?>{
        ...evidence.redactedJson(),
        'planId': planId,
        'operation': 'backup-cleanup',
        'writes': false,
        'reviewRequired': true,
      },
    );
    if (request.dryRun) return plan;
    await _approveRecovery(request, plan, planId, () {
      final again = _readBackup(contextStateRoot, backupId);
      return mcpCanonicalDigest(<String, Object?>{
        'operation': 'backup-cleanup',
        'backupId': backupId,
        'evidenceDigest': again.artifactDigest,
        'stateRoot': contextStateRoot,
      });
    });
    io.delete(_backupPath(contextStateRoot, backupId));
    return McpEnvelope(
      command: 'mcp.backup.cleanup',
      outcome: 'cleaned',
      data: <String, Object?>{
        'planId': planId,
        'backupId': backupId,
        'deleted': true,
      },
    );
  }

  // -------------------------------------------------------------------------
  // mcp recover (story 25)
  // -------------------------------------------------------------------------

  Future<McpEnvelope> recover(McpRecoveryRequest request) async {
    final stateRoot = _context(request).stateRoot(LifecycleScope.user);
    final transactionId = request.transactionId;
    if (transactionId == null) {
      final pending = <Map<String, Object?>>[];
      for (final path in io.list(_transactionDirectory(stateRoot))) {
        final text = io.read(path);
        if (text == null) continue;
        final transaction = _decodeTransaction(text);
        if (transaction.availableActions.isNotEmpty) {
          pending.add(transaction.redactedJson());
        }
      }
      pending.sort(
        (a, b) => (a['transactionId'] as String).compareTo(
          b['transactionId'] as String,
        ),
      );
      return McpEnvelope(
        command: 'mcp.recover',
        outcome: 'inspected',
        data: <String, Object?>{
          'count': pending.length,
          'transactions': pending,
          'claims':
              'recovery is reviewed and entry-only; no server is contacted',
        },
      );
    }

    final id = _id(transactionId, mcpTransactionIdPattern, '--transaction-id');
    final transaction = _readTransaction(stateRoot, id);
    final evidence = _readBackup(stateRoot, transaction.backupId);
    if (evidence.identity != transaction.identity ||
        evidence.transactionId != transaction.transactionId ||
        transaction.backupId != evidence.backupId) {
      throw MambaException(
        'Recovery evidence is inconsistent or substituted; no action was '
        'taken.',
        exitCode: 4,
      );
    }
    if (request.harness != null &&
        transaction.identity.harness != request.harness) {
      throw MambaException(
        'The transaction belongs to a different MCP harness; refusal is '
        'required.',
        exitCode: 4,
      );
    }
    if (request.scope != null && transaction.identity.scope != request.scope) {
      throw MambaException(
        'The transaction belongs to a different MCP scope; refusal is '
        'required.',
        exitCode: 4,
      );
    }
    if (request.name != null && transaction.identity.name != request.name) {
      throw MambaException(
        'The transaction belongs to a different MCP server name; refusal is '
        'required.',
        exitCode: 4,
      );
    }
    final action = request.action;
    if (action == null) {
      return McpEnvelope(
        command: 'mcp.recover',
        outcome: 'inspected',
        data: <String, Object?>{
          ...transaction.redactedJson(),
          'backup': evidence.redactedJson(),
        },
      );
    }
    if (!transaction.availableActions.contains(action)) {
      throw MambaException(
        'Recovery action ${action.wireName} is not provable from phase '
        '${transaction.phase.wireName}; no file was written.',
        exitCode: 4,
      );
    }

    final identity = transaction.identity;
    final observation = _observe(
      McpRecoveryRequest(
        environment: request.environment,
        harness: identity.harness,
        scope: identity.scope,
        name: identity.name,
        cwd: request.cwd,
        projectRoot: request.projectRoot,
        home: request.home,
        claudeConfigDir: request.claudeConfigDir,
        codexHome: request.codexHome,
        piAgentDir: request.piAgentDir,
        stateDir: request.stateDir,
      ),
    );
    _requireIdentity(observation, identity);
    _requireRecoveryGuards(transaction, evidence, observation, action);

    final planId = _recoveryPlanId(
      operation: 'recover-${action.wireName}',
      evidenceDigest: evidence.artifactDigest,
      observation: observation,
      identity: identity,
      proposedDigest: transaction.proposedDigest,
      action: action,
      transactionDigest: transaction.artifactDigest,
    );
    final plan = _recoveryPlan(
      command: 'mcp.recover.plan',
      operation: 'recover-${action.wireName}',
      planId: planId,
      identity: identity,
      observation: observation,
      evidence: evidence.redactedJson(),
      proposedFields: null,
      availableActions: <String>[action.wireName],
      transaction: transaction.redactedJson(),
    );
    if (request.dryRun) return plan;
    await _approveRecovery(request, plan, planId, () {
      final again = _observe(
        McpRecoveryRequest(
          environment: request.environment,
          harness: identity.harness,
          scope: identity.scope,
          name: identity.name,
          cwd: request.cwd,
          projectRoot: request.projectRoot,
          home: request.home,
          claudeConfigDir: request.claudeConfigDir,
          codexHome: request.codexHome,
          piAgentDir: request.piAgentDir,
          stateDir: request.stateDir,
        ),
      );
      return _recoveryPlanId(
        operation: 'recover-${action.wireName}',
        evidenceDigest: evidence.artifactDigest,
        observation: again,
        identity: identity,
        proposedDigest: transaction.proposedDigest,
        action: action,
        transactionDigest: transaction.artifactDigest,
      );
    });

    final current = _observe(
      McpRecoveryRequest(
        environment: request.environment,
        harness: identity.harness,
        scope: identity.scope,
        name: identity.name,
        cwd: request.cwd,
        projectRoot: request.projectRoot,
        home: request.home,
        claudeConfigDir: request.claudeConfigDir,
        codexHome: request.codexHome,
        piAgentDir: request.piAgentDir,
        stateDir: request.stateDir,
      ),
    );
    if (action == McpRecoveryAction.complete) {
      final updated = transaction.withPhase(McpRecoveryPhase.committed);
      _writeTransaction(stateRoot, updated);
      return _recoverySuccess(
        planId: planId,
        transaction: updated,
        action: action,
        nativeWritten: false,
        sourceFingerprint: current.sourceFingerprint,
      );
    }

    final restoreFields = evidence.absent
        ? null
        : Map<String, Object?>.from(evidence.fields);
    final mutation = _restoreMutation(current.currentFields, restoreFields);
    if (mutation != null) {
      final nextText = const McpNativeEditor().apply(
        format: current.location.format,
        name: identity.name,
        text: current.sourceText,
        mutation: mutation,
      );
      io.write(current.location.path, nextText);
    }
    _writeBaseline(current, identity, transaction.preBaselineDigest);
    final updated = transaction.withPhase(McpRecoveryPhase.failedRestored);
    _writeTransaction(stateRoot, updated);
    return _recoverySuccess(
      planId: planId,
      transaction: updated,
      action: action,
      nativeWritten: mutation != null,
      sourceFingerprint: current.sourceFingerprint,
    );
  }

  // -------------------------------------------------------------------------
  // Review, guards and evidence access
  // -------------------------------------------------------------------------

  LifecycleContext _context(McpRecoveryRequest request) =>
      LifecycleContext.resolve(
        LifecycleOptions(
          processWorkingDirectory: fs.currentDirectory.path,
          environment: request.environment,
          scope: LifecycleScope.user,
          cwd: request.cwd,
          projectRoot: request.projectRoot,
          home: request.home,
          claudeConfigDir: request.claudeConfigDir,
          codexHome: request.codexHome,
          piAgentDir: request.piAgentDir,
          stateDir: request.stateDir,
        ),
        fileSystem: fs,
      );

  _Observation _observe(McpRecoveryRequest request) {
    if (request.name == null ||
        request.harness == null ||
        request.scope == null) {
      throw MambaException(
        'MCP recovery selection requires --name, --harness and --scope.',
        exitCode: 2,
      );
    }
    final context = _context(request);
    final locations = _resolver.resolve(
      context,
      harness: request.harness,
      scope: request.scope,
    );
    if (locations.length != 1) {
      throw MambaException(
        'Could not resolve exactly one native MCP location for the selection.',
        exitCode: 2,
      );
    }
    final location = locations.single;
    final sourceText = io.read(location.path) ?? '';
    final record = McpOwnershipLedger(
      fs: fs,
      stateRoot: context.stateRoot(LifecycleScope.user),
    ).read();
    final identity = McpRegistrationIdentity(
      harness: request.harness!,
      scope: request.scope!,
      location: location.path,
      name: request.name!,
    );
    return _Observation(
      context,
      location,
      sourceText,
      sha256.convert(utf8.encode(sourceText)).toString(),
      McpNativeReader(fs).read(location)[request.name],
      record,
      record[identity.storageKey],
    );
  }

  McpRegistrationIdentity _selection(McpRecoveryRequest request) {
    if (request.name == null ||
        request.harness == null ||
        request.scope == null) {
      throw MambaException(
        'MCP recovery selection requires --name, --harness and --scope.',
        exitCode: 2,
      );
    }
    final context = _context(request);
    final location = _resolver.resolve(
      context,
      harness: request.harness,
      scope: request.scope,
    );
    if (location.length != 1) {
      throw MambaException(
        'Could not resolve exactly one native MCP location for the selection.',
        exitCode: 2,
      );
    }
    return McpRegistrationIdentity(
      harness: request.harness!,
      scope: request.scope!,
      location: location.single.path,
      name: request.name!,
    );
  }

  void _requireIdentity(
    _Observation observation,
    McpRegistrationIdentity identity,
  ) {
    final resolved = McpRegistrationIdentity(
      harness: observation.location.harness,
      scope: observation.location.scope,
      location: observation.location.path,
      name: identity.name,
    );
    if (resolved != identity) {
      throw MambaException(
        'The selected entry does not match the resolved native location; '
        'substituted evidence is refused.',
        exitCode: 4,
      );
    }
  }

  String _recoveryPlanId({
    required String operation,
    required String evidenceDigest,
    required _Observation observation,
    required McpRegistrationIdentity identity,
    required String? proposedDigest,
    required McpRecoveryAction? action,
    String? transactionDigest,
  }) => mcpCanonicalDigest(<String, Object?>{
    'operation': operation,
    'backupDigest': evidenceDigest,
    'transactionDigest': transactionDigest,
    'identity': identity.toJson(),
    'sourceFingerprint': observation.sourceFingerprint,
    'currentEntryDigest': observation.currentFields == null
        ? null
        : mcpCanonicalDigest(observation.currentFields),
    'baselineDigest': observation.record?.baselineDigest,
    'proposedDigest': proposedDigest,
    'action': action?.wireName,
  });

  McpEnvelope _recoveryPlan({
    required String command,
    required String operation,
    required String planId,
    required McpRegistrationIdentity identity,
    required _Observation observation,
    required Map<String, Object?> evidence,
    required Map<String, Object?>? proposedFields,
    required List<String>? availableActions,
    Map<String, Object?>? transaction,
  }) => McpEnvelope(
    command: command,
    outcome: 'planned',
    data: <String, Object?>{
      'planId': planId,
      'operation': operation,
      ...identity.toJson(),
      'sourceFingerprint': observation.sourceFingerprint,
      'currentEntry': observation.currentFields,
      'baselineDigest': observation.record?.baselineDigest,
      'backup': evidence,
      'transaction': ?transaction,
      'availableActions': ?availableActions,
      'proposedEntry': proposedFields,
      'writes': false,
      'reviewRequired': true,
      'credentialPolicy':
          'retained literals stay in protected state and are never displayed',
      'claims': 'static entry review only; no server is launched or contacted',
    },
  );

  /// Reviews a fresh plan; a supplied --plan-id must match it exactly. The
  /// post-approval closure recomputes the same identity after a fresh read of
  /// the shared file, which refuses any drift between review and publication.
  Future<void> _approveRecovery(
    McpRecoveryRequest request,
    McpEnvelope plan,
    String planId,
    String Function() freshPlanId,
  ) async {
    if (request.planId != null && request.planId != planId) {
      throw MambaException(
        'Stale or mismatched --plan-id: the shared file, baseline or evidence '
        'changed since the plan was reviewed. Re-review the plan; no file was '
        'written.',
        exitCode: 4,
      );
    }
    if (!request.yes || request.interactive) {
      final approved = await approve(plan.renderText());
      if (!approved) {
        throw MambaException(
          'Operation cancelled; everything is unchanged.',
          exitCode: 7,
        );
      }
    } else {
      if (!request.ackMcpRisk || request.planId == null) {
        throw MambaException(
          'Unattended MCP recovery requires --yes, a reviewed --plan-id and '
          '--ack-mcp-risk; nothing was written.',
          exitCode: 2,
        );
      }
    }
    if (freshPlanId() != planId) {
      throw MambaException(
        'The native source, managed baseline or evidence changed after '
        'review; re-review the plan. Nothing was written.',
        exitCode: 4,
      );
    }
  }

  void _requireRecoveryGuards(
    McpTransactionRecord transaction,
    McpBackupEvidence evidence,
    _Observation observation,
    McpRecoveryAction action,
  ) {
    final expectedGuard =
        transaction.publishedSourceFingerprint ??
        transaction.preSourceFingerprint;
    if (observation.sourceFingerprint != expectedGuard) {
      throw MambaException(
        'The shared MCP file changed since the reviewed phase; recovery is '
        'refused rather than overwriting unrelated content.',
        exitCode: 4,
      );
    }
    if (action == McpRecoveryAction.complete) {
      if (evidence.absent) {
        if (observation.currentFields != null) {
          throw MambaException(
            'Recovery completion is not provable: the entry should be absent.',
            exitCode: 4,
          );
        }
      } else if (_digest(observation.currentFields) !=
          transaction.proposedDigest) {
        throw MambaException(
          'Recovery completion is not provable: the published entry differs '
          'from the reviewed target.',
          exitCode: 4,
        );
      }
      final baseline = transaction.operation == 'unregister'
          ? null
          : transaction.operation == 'adopt'
          ? evidence.digest
          : transaction.proposedDigest;
      if (observation.record?.baselineDigest != baseline) {
        throw MambaException(
          'Recovery completion is not provable: the management baseline '
          'differs from the reviewed target.',
          exitCode: 4,
        );
      }
    }
  }

  bool _publicationMatches(
    McpTransactionRecord transaction,
    McpBackupEvidence backup,
    _Observation observation,
  ) {
    final expectedBaseline = switch (transaction.operation) {
      'register' || 'replace' => transaction.proposedDigest,
      'adopt' => backup.digest,
      'unregister' => null,
      _ => null,
    };
    if (observation.record?.baselineDigest != expectedBaseline) return false;
    if (transaction.operation == 'unregister') {
      return observation.currentFields == null;
    }
    if (transaction.operation == 'adopt') {
      return _digest(observation.currentFields) == backup.digest;
    }
    return _digest(observation.currentFields) == transaction.proposedDigest;
  }

  McpEntryMutation? _restoreMutation(
    Map<String, Object?>? current,
    Map<String, Object?>? target,
  ) {
    if (current == null && target == null) return null;
    if (current == null) return McpInsertEntry(target!);
    if (target == null) return const McpRemoveEntry();
    return McpPatchEntry(current, target);
  }

  String? _digest(Map<String, Object?>? fields) =>
      fields == null ? null : mcpCanonicalDigest(fields);

  Map<String, Object?>? _proposedFields(McpEnvelope plan) {
    final value = plan.data['proposedEntry'];
    if (value is! Map) return null;
    return Map<String, Object?>.from(value);
  }

  String _planId(McpEnvelope plan) {
    final value = plan.data['planId'];
    if (value is! String) {
      throw MambaException(
        'The reviewed MCP mutation plan has no plan identity.',
        exitCode: 1,
      );
    }
    return value;
  }

  McpRecoveryRequest _recoveryRequest(McpMutationRequest request) =>
      McpRecoveryRequest(
        environment: request.environment,
        harness: request.harness,
        scope: request.scope,
        name: request.name,
        cwd: request.cwd,
        projectRoot: request.projectRoot,
        home: request.home,
        claudeConfigDir: request.claudeConfigDir,
        codexHome: request.codexHome,
        piAgentDir: request.piAgentDir,
        stateDir: request.stateDir,
      );

  McpMutationRequest _asDryRun(McpMutationRequest request) =>
      McpMutationRequest(
        operation: request.operation,
        environment: request.environment,
        harness: request.harness,
        scope: request.scope,
        name: request.name,
        command: request.command,
        args: request.args,
        envValues: request.envValues,
        url: request.url,
        headerValues: request.headerValues,
        type: request.type,
        dryRun: true,
        yes: request.yes,
        interactive: request.interactive,
        planId: request.planId,
        ackMcpRisk: request.ackMcpRisk,
        allowDrift: request.allowDrift,
        cwd: request.cwd,
        projectRoot: request.projectRoot,
        home: request.home,
        claudeConfigDir: request.claudeConfigDir,
        codexHome: request.codexHome,
        piAgentDir: request.piAgentDir,
        stateDir: request.stateDir,
      );

  (String, String) _ids(String planId, String identityKey) {
    final seed = sha256.convert(utf8.encode('$planId|$identityKey')).toString();
    return ('mbk_${seed.substring(0, 32)}', 'mtx_${seed.substring(32, 64)}');
  }

  String _id(String? value, RegExp pattern, String flag) {
    if (value == null || !pattern.hasMatch(value)) {
      throw MambaException(
        '$flag must select one valid evidence identifier.',
        exitCode: 2,
      );
    }
    return value;
  }

  String _backupDirectory(String stateRoot) =>
      fs.path.join(stateRoot, mcpBackupDirectoryName);

  String _transactionDirectory(String stateRoot) =>
      fs.path.join(stateRoot, mcpTransactionDirectoryName);

  String _backupPath(String stateRoot, String id) =>
      fs.path.join(_backupDirectory(stateRoot), '$id.json');

  String _transactionPath(String stateRoot, String id) =>
      fs.path.join(_transactionDirectory(stateRoot), '$id.json');

  McpBackupEvidence _readBackup(String stateRoot, String id) {
    final text = io.read(_backupPath(stateRoot, id));
    if (text == null) {
      throw MambaException(
        'No retained MCP backup evidence exists for $id.',
        exitCode: 4,
      );
    }
    return _decodeBackup(text);
  }

  McpTransactionRecord _readTransaction(String stateRoot, String id) {
    final text = io.read(_transactionPath(stateRoot, id));
    if (text == null) {
      throw MambaException(
        'No MCP transaction record exists for $id.',
        exitCode: 4,
      );
    }
    return _decodeTransaction(text);
  }

  McpBackupEvidence _decodeBackup(String text) {
    try {
      return McpBackupEvidence.decode(text);
    } on FormatException {
      throw MambaException(
        'MCP backup evidence is inconsistent or substituted; refusal is '
        'required.',
        exitCode: 4,
      );
    }
  }

  McpTransactionRecord _decodeTransaction(String text) {
    try {
      return McpTransactionRecord.decode(text);
    } on FormatException {
      throw MambaException(
        'MCP transaction evidence is inconsistent or substituted; refusal is '
        'required.',
        exitCode: 4,
      );
    }
  }

  void _writeBackup(String stateRoot, McpBackupEvidence evidence) =>
      io.write(_backupPath(stateRoot, evidence.backupId), evidence.encode());

  void _writeTransaction(String stateRoot, McpTransactionRecord transaction) =>
      io.write(
        _transactionPath(stateRoot, transaction.transactionId),
        transaction.encode(),
      );

  void _discard(
    String stateRoot,
    McpBackupEvidence backup,
    McpTransactionRecord transaction,
  ) {
    for (final path in <String>[
      _transactionPath(stateRoot, transaction.transactionId),
      _backupPath(stateRoot, backup.backupId),
    ]) {
      try {
        io.delete(path);
      } on Object {
        // Retained evidence is still protected; never mask the original error.
      }
    }
  }

  void _writeBaseline(
    _Observation observation,
    McpRegistrationIdentity identity,
    String? digest,
  ) {
    final ledger = McpOwnershipLedger(fs: fs, stateRoot: observation.stateRoot);
    final records = ledger.read()..remove(identity.storageKey);
    if (digest != null) {
      records[identity.storageKey] = McpRegistrationRecord(
        identity: identity,
        baselineDigest: digest,
      );
    }
    final keys = records.keys.toList()..sort();
    io.write(
      ledger.path,
      jsonEncode(<String, Object?>{
        'schemaVersion': mcpRegistrationLedgerSchemaVersion,
        'records': <Object?>[for (final key in keys) records[key]!.toJson()],
      }),
    );
  }

  McpEnvelope _recoverySuccess({
    required String planId,
    required McpTransactionRecord transaction,
    required McpRecoveryAction action,
    required bool nativeWritten,
    required String sourceFingerprint,
  }) => McpEnvelope(
    command: 'mcp.recover',
    outcome: 'recovered',
    data: <String, Object?>{
      'planId': planId,
      ...transaction.redactedJson(),
      'action': action.wireName,
      'writes': true,
      'nativeWritten': nativeWritten,
      'sourceFingerprint': sourceFingerprint,
    },
  );
}
