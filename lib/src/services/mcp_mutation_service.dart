import 'dart:convert';
import 'dart:io' show stdout;

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../../components/installation_approval.dart';
import '../harness/harness_catalog.dart';
import '../mcp/mcp_envelope.dart';
import '../mcp/mcp_native.dart';
import '../mcp/mcp_native_editor.dart';
import '../mcp/mcp_ownership_ledger.dart';
import '../mcp/mcp_redaction.dart';
import '../mcp/mcp_types.dart';
import 'lifecycle_state_service.dart';
import 'mcp_validation_service.dart';

/// The reviewed MCP lifecycle mutations.
enum McpMutationOperation {
  register('register'),
  replace('replace'),
  adopt('adopt'),
  unregister('unregister');

  const McpMutationOperation(this.wireName);
  final String wireName;
}

/// A request to select one named MCP registration and mutate it. Selection is
/// by name plus explicit harness and scope; occurrences and paths are never
/// selectors - the path overrides only resolve the bounded native location.
final class McpMutationRequest {
  McpMutationRequest({
    required this.operation,
    required this.environment,
    required this.harness,
    required this.scope,
    required this.name,
    this.command,
    this.args = const <String>[],
    this.envValues = const <String>[],
    this.url,
    this.headerValues = const <String>[],
    this.type,
    this.dryRun = false,
    this.yes = false,
    this.interactive = false,
    this.planId,
    this.ackMcpRisk = false,
    this.allowDrift = false,
    this.cwd,
    this.projectRoot,
    this.home,
    this.claudeConfigDir,
    this.codexHome,
    this.piAgentDir,
    this.geminiDir,
    this.stateDir,
    LifecycleRootOverrides? roots,
  }) : roots =
           roots ??
           LifecycleRootOverrides(
             cwd: cwd,
             projectRoot: projectRoot,
             home: home,
             claudeConfigDir: claudeConfigDir,
             codexHome: codexHome,
             piAgentDir: piAgentDir,
             geminiDir: geminiDir,
             stateDir: stateDir,
           );

  final McpMutationOperation operation;
  final Map<String, String> environment;
  final McpHarness harness;
  final McpScope scope;
  final String name;

  final String? command;
  final List<String> args;
  final List<String> envValues;
  final String? url;
  final List<String> headerValues;
  final String? type;

  final bool dryRun;
  final bool yes;
  final bool interactive;
  final String? planId;
  final bool ackMcpRisk;
  final bool allowDrift;

  final String? cwd;
  final String? projectRoot;
  final String? home;
  final String? claudeConfigDir;
  final String? codexHome;
  final String? piAgentDir;
  final String? geminiDir;
  final String? stateDir;

  /// The same overrides as one value for services that thread them onward.
  final LifecycleRootOverrides roots;
}

/// The injectable, scriptable review seam. It receives the complete, redacted
/// plan preview and returns explicit approval. Production prompts the terminal;
/// tests inject a scripted function. A decline (false) cancels with no writes.
typedef McpPlanApproval = Future<bool> Function(String completePlanPreview);

/// Production review: disclose the complete redacted plan, then require a
/// confirmation. When no terminal is attached approval is false (cancelled).
Future<bool> defaultMcpPlanApproval(String completePlanPreview) async {
  stdout.writeln(completePlanPreview);
  return InstallationApprovalComponent(
    label: 'Approve this reviewed MCP mutation plan? (Ctrl+C to cancel)',
  ).render();
}

/// Read-only snapshot of the current shared-file state, used for both planning
/// and the post-review re-verification.
final class _Snapshot {
  const _Snapshot(
    this.context,
    this.location,
    this.sourceText,
    this.currentFields,
    this.records,
    this.createsFile,
  );

  final LifecycleContext context;
  final McpNativeLocation location;
  final String sourceText;
  final Map<String, Object?>? currentFields;
  final Map<String, McpRegistrationRecord> records;
  final bool createsFile;
}

/// Everything derived from one snapshot: eligibility, the proposed entry,
/// the reviewed plan identity, the redacted plan envelope and the mutation.
final class _Prepared {
  const _Prepared(
    this.snapshot,
    this.identity,
    this.record,
    this.proposedFields,
    this.currentDigest,
    this.planId,
    this.planEnvelope,
    this.drift,
    this.transport,
    this.entryMutation,
    this.nativeWritten,
  );

  final _Snapshot snapshot;
  final McpRegistrationIdentity identity;
  final McpRegistrationRecord? record;
  final Map<String, Object?>? proposedFields;
  final String? currentDigest;
  final String planId;
  final McpEnvelope planEnvelope;
  final bool drift;
  final String transport;
  final McpEntryMutation? entryMutation;
  final bool nativeWritten;
}

/// Reviewed MCP lifecycle mutations (stories 12-23, 44).
///
/// Every mutation is interactive by default with a complete redacted review
/// plan and explicit approval. Unattended runs require complete explicit
/// inputs plus a dedicated MCP-risk acknowledgment. Credentials may only be
/// introduced as references; existing literals are retained and never shown.
/// Native files are edited entry-by-entry (source-range patching), and the
/// Wave A ownership ledger baseline is kept in sync.
interface class McpMutationService {
  McpMutationService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    McpValidationService? validation,
    McpPlanApproval? approve,
  }) : fs = fileSystem,
       validation = validation ?? McpValidationService(fileSystem: fileSystem),
       approve = approve ?? defaultMcpPlanApproval;

  final fslib.FileSystem fs;
  final McpValidationService validation;
  final McpPlanApproval approve;

  static const McpNativeResolver _resolver = McpNativeResolver();

  Future<McpEnvelope> execute(McpMutationRequest request) async {
    _checkWritable(request);
    final first = _prepare(_snapshot(request), request);

    // Dry-run plans only: disclose the plan identity and drift, write nothing,
    // require no approval or risk acknowledgment.
    if (request.dryRun) return first.planEnvelope;

    // An externally changed/deleted managed entry requires explicit reviewed
    // drift resolution: --allow-drift and a reviewed --plan-id from a plan that
    // itself included the drift decision.
    if (first.drift && !request.allowDrift) {
      throw MambaException(
        'The managed registration drifted externally. Resolution requires a '
        'reviewed --allow-drift --plan-id; no file was written.',
        exitCode: 4,
      );
    }
    if (first.drift && request.planId == null) {
      throw MambaException(
        'Drift resolution requires a reviewed --plan-id from '
        '--dry-run --allow-drift; no file was written.',
        exitCode: 4,
      );
    }

    // Any supplied reviewed plan identity must still match CURRENT shared-file
    // bytes + context + proposal + decisions (story 21). An unrelated edit to
    // the shared file changes the identity and is refused.
    if (request.planId != null && request.planId != first.planId) {
      throw MambaException(
        'Stale or mismatched --plan-id: the shared file, baseline, or proposal '
        'changed since the plan was reviewed. Re-review the plan; no file was '
        'written.',
        exitCode: 4,
      );
    }

    final interactive = !request.yes || request.interactive;
    if (interactive) {
      final approved = await approve(first.planEnvelope.renderText());
      if (!approved) {
        throw MambaException(
          'Operation cancelled; everything is unchanged.',
          exitCode: 7,
        );
      }
      // Re-read and refuse if the source or managed baseline changed between
      // review and publication (stories 12, 15, 20).
      final second = _prepare(_snapshot(request), request);
      if (second.planId != first.planId) {
        throw MambaException(
          'The native source or managed baseline changed after review; '
          're-review the plan. Nothing was written.',
          exitCode: 4,
        );
      }
    } else {
      if (!request.ackMcpRisk) {
        throw MambaException(
          'Unattended MCP mutations require the dedicated --ack-mcp-risk flag, '
          'so automation cannot silently consent to running an executable.',
          exitCode: 2,
        );
      }
      _requireCompleteInputs(request);
    }

    return _apply(first, request);
  }

  void _checkWritable(McpMutationRequest request) {
    if (!McpNativeResolver.supports(request.harness, request.scope)) {
      throw MambaException(
        'The ${request.harness.wireName} harness has no '
        '${request.scope.wireName} MCP scope.',
        exitCode: 2,
      );
    }
    final spec = HarnessCatalog.instance.mcpSpec(request.harness);
    if (spec.inspectOnlyScopes.contains(request.scope)) {
      throw MambaException(
        spec.inspectOnlyDiagnostic ?? 'The selected MCP scope is inspect-only.',
        exitCode: 2,
      );
    }
  }

  _Snapshot _snapshot(McpMutationRequest request) {
    final context = McpNativeResolver.resolveLifecycleContext(
      fs,
      environment: request.environment,
      cwd: request.roots.cwd,
      projectRoot: request.roots.projectRoot,
      home: request.roots.home,
      claudeConfigDir: request.roots.claudeConfigDir,
      codexHome: request.roots.codexHome,
      piAgentDir: request.roots.piAgentDir,
      geminiDir: request.roots.geminiDir,
      stateDir: request.roots.stateDir,
    );
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
    final sourceText = readMcpNativeText(fs, location.path) ?? '';
    final currentFields = McpNativeReader(fs).read(location)[request.name];
    final ledger = McpOwnershipLedger(
      fs: fs,
      stateRoot: context.stateRoot(LifecycleScope.user),
    );
    return _Snapshot(
      context,
      location,
      sourceText,
      currentFields,
      ledger.read(),
      sourceText.isEmpty,
    );
  }

  _Prepared _prepare(_Snapshot snapshot, McpMutationRequest request) {
    final identity = McpRegistrationIdentity(
      harness: request.harness,
      scope: request.scope,
      location: snapshot.location.path,
      name: request.name,
    );
    final record = snapshot.records[identity.storageKey];
    final current = snapshot.currentFields;
    final currentDigest = current == null ? null : mcpCanonicalDigest(current);

    Map<String, Object?>? proposed;
    var drift = false;
    McpEntryMutation? entryMutation;
    var nativeWritten = false;

    switch (request.operation) {
      case McpMutationOperation.register:
        if (current != null) {
          throw MambaException(
            'An MCP registration named ${request.name} already exists; use '
            'replace instead of register.',
            exitCode: 2,
          );
        }
        if (record != null) {
          throw MambaException(
            'An ownership record already exists for ${request.name} (a '
            'deleted managed entry). Resolve it through unregister before '
            'registering again.',
            exitCode: 4,
          );
        }
        proposed = _buildRegisterFields(request);
        entryMutation = McpInsertEntry(proposed);
        nativeWritten = true;
      case McpMutationOperation.replace:
        if (current == null) {
          throw MambaException(
            'There is no native MCP registration named ${request.name} to '
            'replace.',
            exitCode: 2,
          );
        }
        if (record == null) {
          throw MambaException(
            'The MCP registration ${request.name} is not managed; adopt it '
            'before replacing it.',
            exitCode: 2,
          );
        }
        drift = record.baselineDigest != currentDigest;
        proposed = _buildReplaceFields(request, current);
        entryMutation = McpPatchEntry(current, proposed);
        nativeWritten = true;
      case McpMutationOperation.unregister:
        if (record == null) {
          throw MambaException(
            'The MCP registration ${request.name} is not managed; only a '
            'managed registration can be unregistered.',
            exitCode: 2,
          );
        }
        drift = current == null || record.baselineDigest != currentDigest;
        if (current != null) {
          entryMutation = const McpRemoveEntry();
          nativeWritten = true;
        }
      case McpMutationOperation.adopt:
        if (current == null) {
          throw MambaException(
            'There is no native MCP registration named ${request.name} to '
            'adopt.',
            exitCode: 2,
          );
        }
        if (record != null) {
          throw MambaException(
            'The MCP registration ${request.name} is already managed.',
            exitCode: 2,
          );
        }
    }

    // Validate the resulting entry through the same shared per-harness Zema
    // contract before any write (story 44). A failure writes nothing.
    if (proposed != null) {
      final report = validation.validate(
        harness: request.harness,
        fields: proposed,
        scope: request.scope,
      );
      if (!report.valid) {
        throw MambaException(
          'MCP registration failed static validation; nothing was written.\n'
          '${report.renderText()}',
          exitCode: 2,
        );
      }
    }

    // Reviewed plan identity binds the CURRENT whole shared-file bytes,
    // context, proposed entry and decisions; ANY shared-file edit invalidates
    // it (story 21).
    final sourceDigest = sha256
        .convert(utf8.encode(snapshot.sourceText))
        .toString();
    final planId = mcpCanonicalDigest(<String, Object?>{
      'operation': request.operation.wireName,
      'harness': request.harness.wireName,
      'scope': request.scope.wireName,
      'location': snapshot.location.path,
      'name': request.name,
      'sourceDigest': sourceDigest,
      'baselineDigest': record?.baselineDigest,
      'createsFile': snapshot.createsFile,
      'proposed': proposed,
      'decisions': <String, Object?>{'allowDrift': request.allowDrift},
    });

    final transport = _transport(proposed ?? current, request.harness);
    final planEnvelope = _planEnvelope(
      request,
      snapshot,
      identity,
      record,
      proposed,
      planId,
      transport,
      drift,
    );
    return _Prepared(
      snapshot,
      identity,
      record,
      proposed,
      currentDigest,
      planId,
      planEnvelope,
      drift,
      transport,
      entryMutation,
      nativeWritten,
    );
  }

  Map<String, Object?> _buildRegisterFields(McpMutationRequest request) {
    final command = request.command;
    final url = request.url;
    if ((command == null) == (url == null)) {
      throw MambaException(
        'Registering an MCP server requires exactly one transport: --command '
        '(stdio) or --url (http). Incomplete explicit inputs are refused.',
        exitCode: 2,
      );
    }
    final spec = HarnessCatalog.instance.mcpSpec(request.harness);
    final fields = <String, Object?>{};
    if (command != null) {
      fields['command'] = command;
      if (request.args.isNotEmpty) fields['args'] = request.args;
      final env = _parseReferences(request.envValues, 'env');
      if (env.isNotEmpty) fields['env'] = env;
      if (request.type != null) fields['type'] = request.type;
    } else {
      fields[spec.httpEndpointKey] = url;
      final headers = _parseReferences(request.headerValues, 'header');
      if (headers.isNotEmpty) {
        fields[spec.headerKey] = headers;
      }
      if (request.type != null) {
        fields['type'] = request.type;
      } else if (spec.validation.requiresHttpType) {
        fields['type'] = 'http';
      }
    }
    return fields;
  }

  Map<String, Object?> _buildReplaceFields(
    McpMutationRequest request,
    Map<String, Object?> current,
  ) {
    final spec = HarnessCatalog.instance.mcpSpec(request.harness);
    final fields = Map<String, Object?>.from(current);
    if (request.command != null) fields['command'] = request.command;
    if (request.url != null) {
      for (final key in spec.httpTransportKeys) {
        fields.remove(key);
      }
      fields[spec.httpEndpointKey] = request.url;
    }
    if (request.args.isNotEmpty) fields['args'] = request.args;
    if (request.type != null) fields['type'] = request.type;
    if (request.envValues.isNotEmpty) {
      final merged = <String, Object?>{};
      final existing = fields['env'];
      if (existing is Map) merged.addAll(Map<String, Object?>.from(existing));
      merged.addAll(_parseReferences(request.envValues, 'env'));
      fields['env'] = merged;
    }
    if (request.headerValues.isNotEmpty) {
      final key = spec.headerKey;
      final merged = <String, Object?>{};
      final existing = fields[key];
      if (existing is Map) merged.addAll(Map<String, Object?>.from(existing));
      merged.addAll(_parseReferences(request.headerValues, 'header'));
      fields[key] = merged;
    }
    return fields;
  }

  /// Newly supplied credential values must be environment-variable or command
  /// references; a literal secret is refused (story 17).
  Map<String, Object?> _parseReferences(List<String> tokens, String flag) {
    final result = <String, Object?>{};
    for (final token in tokens) {
      final equals = token.indexOf('=');
      if (equals <= 0) {
        throw MambaException('--$flag values must use KEY=VALUE.', exitCode: 2);
      }
      final key = token.substring(0, equals);
      final value = token.substring(equals + 1);
      if (!McpRedaction.isReference(value)) {
        throw MambaException(
          '--$flag values must be environment-variable or command references '
          '(for example VAR-in-braces or a leading !command). Literal '
          'credential values are refused (story 17).',
          exitCode: 2,
        );
      }
      result[key] = value;
    }
    return result;
  }

  void _requireCompleteInputs(McpMutationRequest request) {
    if (request.operation == McpMutationOperation.replace &&
        request.command == null &&
        request.url == null &&
        request.args.isEmpty &&
        request.envValues.isEmpty &&
        request.headerValues.isEmpty &&
        request.type == null) {
      throw MambaException(
        'Unattended replace requires at least one explicit field to change.',
        exitCode: 2,
      );
    }
  }

  String _transport(Map<String, Object?>? fields, McpHarness harness) {
    if (fields == null) return 'unknown';
    return HarnessCatalog.instance
            .mcpSpec(harness)
            .transportOf(fields)
            ?.wireName ??
        'unknown';
  }

  McpEnvelope _planEnvelope(
    McpMutationRequest request,
    _Snapshot snapshot,
    McpRegistrationIdentity identity,
    McpRegistrationRecord? record,
    Map<String, Object?>? proposed,
    String planId,
    String transport,
    bool drift,
  ) => McpEnvelope(
    command: 'mcp.${request.operation.wireName}.plan',
    outcome: 'planned',
    data: <String, Object?>{
      'planId': planId,
      'operation': request.operation.wireName,
      'harness': request.harness.wireName,
      'scope': request.scope.wireName,
      'location': snapshot.location.path,
      'name': request.name,
      'transport': transport,
      'writes': false,
      'nativeWritten': false,
      'reviewRequired': true,
      'createsFile': snapshot.createsFile,
      'drift': drift,
      'managed': record != null,
      'ackMcpRisk': request.ackMcpRisk,
      'allowDrift': request.allowDrift,
      // Complete redacted disclosure: the execution/connection surface,
      // helpers, credential references, consequential settings and the
      // proposed native shape. Literal sensitive values are redacted centrally.
      'disclosure':
          'harness, scope, server name, transport, executable or sanitized '
          'endpoint, helpers, credential references and consequential '
          'settings; literal sensitive values are redacted',
      'proposedEntry': proposed,
      'observedEntry': snapshot.currentFields,
      'credentialPolicy':
          'new/copied values are references only; existing literals are '
          'retained and never displayed',
      'claims': 'static configuration review only; no server is launched',
    },
    diagnostics: const <Map<String, Object?>>[
      <String, Object?>{
        'code': 'MCP_STATIC_REVIEW_ONLY',
        'severity': 'info',
        'message':
            'The plan discloses configuration only. No server is launched, '
            'connected to, or authenticated, and no runtime acceptance is '
            'claimed.',
      },
    ],
  );

  McpEnvelope _successEnvelope(_Prepared prepared, McpMutationRequest request) {
    final outcome = switch (request.operation) {
      McpMutationOperation.register => 'registered',
      McpMutationOperation.replace => 'replaced',
      McpMutationOperation.adopt => 'adopted',
      McpMutationOperation.unregister => 'unregistered',
    };
    return McpEnvelope(
      command: 'mcp.${request.operation.wireName}',
      outcome: outcome,
      data: <String, Object?>{
        'planId': prepared.planId,
        'operation': request.operation.wireName,
        'harness': request.harness.wireName,
        'scope': request.scope.wireName,
        'location': prepared.snapshot.location.path,
        'name': request.name,
        'transport': prepared.transport,
        'writes': true,
        'nativeWritten': prepared.nativeWritten,
        'createsFile': prepared.snapshot.createsFile,
        'driftResolved': prepared.drift,
        'validated': prepared.proposedFields != null,
        'proposedEntry': prepared.proposedFields,
        'ownership': switch (request.operation) {
          McpMutationOperation.unregister => 'removed',
          McpMutationOperation.adopt => 'adopted',
          _ => 'recorded',
        },
      },
      diagnostics: const <Map<String, Object?>>[
        <String, Object?>{
          'code': 'MCP_STATIC_MUTATION_ONLY',
          'severity': 'info',
          'message':
              'Only the selected native entry and Agent Resource ownership '
              'state were changed; no server was launched or connected to.',
        },
      ],
    );
  }

  McpEnvelope _apply(_Prepared prepared, McpMutationRequest request) {
    final snapshot = prepared.snapshot;
    final location = snapshot.location;
    final ledger = McpOwnershipLedger(
      fs: fs,
      stateRoot: snapshot.context.stateRoot(LifecycleScope.user),
    );

    // Final guard: refuse publication if the shared source or the managed
    // baseline changed since the reviewed snapshot (stories 12, 15, 20).
    final nowText = readMcpNativeText(fs, location.path) ?? '';
    if (nowText != snapshot.sourceText) {
      throw MambaException(
        'The native source changed before publication; re-review the plan. '
        'Nothing was written.',
        exitCode: 4,
      );
    }
    final nowRecords = ledger.read();
    final nowRecord = nowRecords[prepared.identity.storageKey];
    if (nowRecord?.baselineDigest != prepared.record?.baselineDigest) {
      throw MambaException(
        'The managed baseline changed before publication; re-review the plan. '
        'Nothing was written.',
        exitCode: 4,
      );
    }

    if (prepared.entryMutation != null && prepared.nativeWritten) {
      final newText = const McpNativeEditor().apply(
        format: location.format,
        name: request.name,
        text: snapshot.sourceText,
        mutation: prepared.entryMutation!,
      );
      final file = fs.file(location.path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(newText);
    }

    switch (request.operation) {
      case McpMutationOperation.register:
      case McpMutationOperation.replace:
        ledger.upsert(
          McpRegistrationRecord(
            identity: prepared.identity,
            baselineDigest: mcpCanonicalDigest(prepared.proposedFields),
          ),
        );
      case McpMutationOperation.adopt:
        ledger.upsert(
          McpRegistrationRecord(
            identity: prepared.identity,
            baselineDigest: prepared.currentDigest!,
          ),
        );
      case McpMutationOperation.unregister:
        _removeRecord(ledger, prepared.identity.storageKey);
    }

    return _successEnvelope(prepared, request);
  }

  void _removeRecord(McpOwnershipLedger ledger, String key) {
    final records = ledger.read()..remove(key);
    final keys = records.keys.toList()..sort();
    final document = <String, Object?>{
      'schemaVersion': mcpRegistrationLedgerSchemaVersion,
      'records': <Object?>[for (final key in keys) records[key]!.toJson()],
    };
    final file = fs.file(ledger.path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(document));
  }
}
