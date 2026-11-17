import 'dart:io' show stdout;

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../../components/installation_approval.dart';
import '../conversion/conversion_evidence.dart' show ConversionIdentity;
import '../mcp/mcp_conversion_account.dart';
import '../mcp/mcp_conversion_lineage.dart';
import '../mcp/mcp_envelope.dart';
import '../mcp/mcp_native.dart';
import '../mcp/mcp_native_editor.dart';
import '../mcp/mcp_ownership_ledger.dart';
import '../mcp/mcp_redaction.dart';
import '../mcp/mcp_types.dart';
import 'lifecycle_state_service.dart';
import 'mcp_validation_service.dart';

/// One named MCP registration conversion request. Selection is by name plus
/// an explicit source harness and scope; occurrences and paths are never
/// selectors. The target harness is explicit and the target scope defaults to
/// the preserved source scope.
final class McpConversionRequest {
  const McpConversionRequest({
    required this.environment,
    required this.harness,
    required this.scope,
    required this.name,
    required this.targetHarness,
    this.targetScope,
    this.omitFields = const <String>[],
    this.dryRun = false,
    this.apply = false,
    this.yes = false,
    this.interactive = false,
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
  final McpHarness harness;
  final McpScope scope;
  final String name;
  final McpHarness targetHarness;
  final McpScope? targetScope;

  /// Field paths explicitly reviewed as safe to omit. A fresh plan identity
  /// is derived from this set; changing an omission invalidates the plan.
  final List<String> omitFields;

  final bool dryRun;
  final bool apply;
  final bool yes;
  final bool interactive;
  final String? planId;

  final String? cwd;
  final String? projectRoot;
  final String? home;
  final String? claudeConfigDir;
  final String? codexHome;
  final String? piAgentDir;
  final String? stateDir;
}

/// The injectable, scriptable review seam. Production prints the complete
/// redacted plan and asks for confirmation; tests inject a scripted answer.
typedef McpConversionApproval = Future<bool> Function(
  String completePlanPreview,
);

Future<bool> defaultMcpConversionApproval(String completePlanPreview) async {
  stdout.writeln(completePlanPreview);
  return InstallationApprovalComponent(
    label: 'Approve this reviewed MCP conversion plan? (Ctrl+C to cancel)',
  ).render();
}

const Set<String> _claudeHttpTypes = <String>{'http', 'streamable-http', 'ws'};
const Set<String> _codexHttpTypes = <String>{'http', 'streamable-http'};
const Set<String> _piHttpTypes = <String>{'http', 'streamable-http'};

final class _Prepared {
  const _Prepared(
    this.request,
    this.source,
    this.target,
    this.scope,
    this.transport,
    this.proposed,
    this.fields,
    this.credentialRefusals,
    this.diagnostics,
    this.planId,
    this.lineage,
    this.planEnvelope,
    this.sourceText,
  );

  final McpConversionRequest request;
  final McpRegistrationIdentity source;
  final McpRegistrationIdentity target;
  final McpScope scope;
  final McpTransport transport;
  final Map<String, Object?> proposed;
  final List<Map<String, Object?>> fields;
  final List<Map<String, Object?>> credentialRefusals;
  final List<McpConversionDiagnostic> diagnostics;
  final String planId;
  final McpConversionLineageRecord lineage;
  final McpEnvelope planEnvelope;
  final String sourceText;
}

/// Reviewed MCP conversion across all six ordered directions (stories
/// 26-32, 44). Transport and scope are preserved; unrepresentable fields are
/// refused by default; credential material is never copied; the source entry
/// stays managed and byte-for-byte unchanged. Every write is an entry-only
/// patch after a fresh reviewed plan identity and shared per-harness Zema
/// validation. Nothing here launches, connects to, or authenticates a server.
interface class McpConversionService {
  McpConversionService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    McpValidationService? validation,
    McpConversionApproval? approve,
  }) : fs = fileSystem,
       validation = validation ?? McpValidationService(fileSystem: fileSystem),
       approve = approve ?? defaultMcpConversionApproval;

  final fslib.FileSystem fs;
  final McpValidationService validation;
  final McpConversionApproval approve;

  static const McpNativeResolver _resolver = McpNativeResolver();

  /// Read-only reviewed plan. Throws a value-free refusal diagnostic when a
  /// field cannot be represented and no explicit omission was reviewed.
  McpEnvelope plan(McpConversionRequest request) =>
      _prepare(request).planEnvelope;

  /// Dry-run returns the plan. Apply requires a reviewed plan identity in
  /// unattended mode, or an interactive review followed by a fresh plan.
  Future<McpEnvelope> execute(McpConversionRequest request) async {
    final first = _prepare(request);
    if (request.dryRun || !request.apply) return first.planEnvelope;

    if (request.planId != null && request.planId != first.planId) {
      throw MambaException(
        'Stale or mismatched --plan-id: the source entry, shared file, target '
        'or decisions changed since the plan was reviewed. Nothing was '
        'written.',
        exitCode: 4,
      );
    }

    final interactive = !request.yes || request.interactive;
    if (interactive) {
      if (!await approve(first.planEnvelope.renderText())) {
        throw MambaException(
          'Operation cancelled; everything is unchanged.',
          exitCode: 7,
        );
      }
      // Re-derive the plan after review. A source or shared-file change during
      // the review produces a fresh, different identity and is refused.
      final fresh = _prepare(request);
      if (fresh.planId != first.planId) {
        throw MambaException(
          'The native source or shared file changed after review; re-review '
          'the plan. Nothing was written.',
          exitCode: 4,
        );
      }
      return _apply(fresh);
    }

    if (request.planId == null) {
      throw MambaException(
        'Unattended conversion requires a reviewed --plan-id from '
        '--dry-run; no file was written.',
        exitCode: 4,
      );
    }
    return _apply(first);
  }

  LifecycleContext _context(McpConversionRequest request) =>
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

  _Prepared _prepare(McpConversionRequest request) {
    final context = _context(request);

    if (request.harness == request.targetHarness) {
      throw MambaException(
        'Conversion requires different source and target harnesses; use '
        'mcp replace to edit a registration in place.',
        exitCode: 2,
      );
    }
    if (!McpNativeResolver.supports(request.harness, request.scope)) {
      throw MambaException(
        'The ${request.harness.wireName} harness has no '
        '${request.scope.wireName} MCP scope.',
        exitCode: 2,
      );
    }
    final scope = request.targetScope ?? request.scope;
    if (!McpNativeResolver.supports(request.targetHarness, scope)) {
      throw MambaException(
        'The ${request.targetHarness.wireName} harness has no '
        '${scope.wireName} MCP scope; changing scope is a separate reviewed '
        '--target-scope decision.',
        exitCode: 2,
      );
    }
    if (request.targetHarness == McpHarness.claude &&
        (scope == McpScope.user || scope == McpScope.local)) {
      throw MambaException(
        'Claude user/local registrations live in the shared ~/.claude.json '
        'home file, whose third-party edit protocol is not documented. That '
        'write surface is inspect-only.',
        exitCode: 2,
      );
    }

    final sourceLocation = _oneLocation(
      context,
      request.harness,
      request.scope,
    );
    final targetLocation = _oneLocation(context, request.targetHarness, scope);
    final sourceText = readMcpNativeText(fs, sourceLocation.path) ?? '';
    final targetText = readMcpNativeText(fs, targetLocation.path) ?? '';
    final sourceEntry = McpNativeReader(fs).read(sourceLocation)[request.name];
    if (sourceEntry == null) {
      throw MambaException(
        'No MCP registration was found for the selected harness, scope, '
        'and name.',
        exitCode: 2,
      );
    }
    if (McpNativeReader(fs).read(targetLocation).containsKey(request.name)) {
      throw MambaException(
        'An MCP registration named ${request.name} already exists at the '
        'target harness and scope. Reviewed replacement is required; nothing '
        'was written.',
        exitCode: 4,
      );
    }

    final source = McpRegistrationIdentity(
      harness: request.harness,
      scope: request.scope,
      location: sourceLocation.path,
      name: request.name,
    );
    final target = McpRegistrationIdentity(
      harness: request.targetHarness,
      scope: scope,
      location: targetLocation.path,
      name: request.name,
    );
    final ledger = McpOwnershipLedger(
      fs: fs,
      stateRoot: context.stateRoot(LifecycleScope.user),
    );
    final records = ledger.read();
    final sourceRecord = records[source.storageKey];
    if (sourceRecord == null) {
      throw MambaException(
        'The source MCP registration is not managed; adopt it before '
        'converting so lineage remains attached to an owned entry.',
        exitCode: 2,
      );
    }
    if (sourceRecord.baselineDigest != mcpCanonicalDigest(sourceEntry)) {
      throw MambaException(
        'The managed MCP source drifted externally; re-review the baseline '
        'before conversion.',
        exitCode: 4,
      );
    }

    final transport = _transport(sourceEntry);
    final mapped = _mapEntry(request, sourceEntry, transport);
    final proposed = mapped.proposed;
    final fields = mapped.fields;
    final credentialRefusals = mapped.credentialRefusals;
    final diagnostics = <McpConversionDiagnostic>[
      ...mapped.diagnostics,
      const McpConversionDiagnostic(
        code: 'MCP_CONVERSION_CREDENTIAL_POLICY',
        field: 'credential-policy',
      ),
      const McpConversionDiagnostic(
        code: 'MCP_CONVERSION_STATIC_REVIEW_ONLY',
        field: 'registration',
      ),
      if (scope != request.scope)
        const McpConversionDiagnostic(
          code: 'MCP_CONVERSION_SCOPE_CHANGE',
          field: 'scope',
        ),
    ];
    diagnostics.sort((a, b) {
      final code = a.code.compareTo(b.code);
      return code != 0 ? code : a.field.compareTo(b.field);
    });

    final refusals = fields.where(
      (field) => field['outcome'] == McpFieldOutcome.refused.toJson(),
    );
    final planId =
        'mcp-convert-${mcpCanonicalDigest(<String, Object?>{'source': source.storageKey, 'sourceBytes': _digest(sourceText), 'sourceEntry': mcpCanonicalDigest(sourceEntry), 'sourceBaseline': sourceRecord.baselineDigest, 'target': target.storageKey, 'targetBytes': _digest(targetText), 'transport': transport.wireName, 'scopeChanged': scope != request.scope, 'proposed': proposed, 'fields': fields, 'credentialRefusals': credentialRefusals, 'omitFields': _sorted(request.omitFields)})}';

    final lineage = McpConversionLineageRecord(
      identity: ConversionIdentity(
        lineageId: mcpConversionLineageId(
          source: source,
          target: target,
          planId: planId,
        ),
        convertedFromId: source.storageKey,
      ),
      sourceIdentity: source,
      targetIdentity: target,
      planId: planId,
    );

    final data = <String, Object?>{
      'planId': planId,
      'name': request.name,
      'sourceHarness': request.harness.wireName,
      'sourceScope': request.scope.wireName,
      'sourceLocation': source.location,
      'targetHarness': request.targetHarness.wireName,
      'targetScope': scope.wireName,
      'targetLocation': target.location,
      'transport': transport.wireName,
      'sourcePreserved': true,
      'sourceManaged': true,
      'writes': false,
      'nativeWritten': false,
      'reviewRequired': true,
      'scopeChanged': scope != request.scope,
      'createsFile': targetText.isEmpty,
      'proposedEntry': proposed,
      'fields': fields,
      'credentialRefusals': credentialRefusals,
      'lineage': lineage.toJson(),
      'validation': <String, Object?>{'valid': true},
      'claim': 'static configuration review only; no server is launched',
    };

    if (refusals.isNotEmpty) {
      throw MambaException(
        McpEnvelope(
          command: 'mcp.convert.plan',
          outcome: 'refused',
          data: data,
          diagnostics: <Map<String, Object?>>[
            for (final diagnostic in diagnostics) diagnostic.toJson(),
          ],
        ).renderText(),
        exitCode: 2,
      );
    }

    final report = validation.validate(
      harness: request.targetHarness,
      fields: proposed,
      scope: scope,
    );
    if (!report.valid) {
      throw MambaException(
        'MCP conversion target failed static validation; nothing was '
        'written.\n${report.renderText()}',
        exitCode: 2,
      );
    }
    data['validation'] = <String, Object?>{
      'valid': true,
      'profile': report.profile,
    };

    return _Prepared(
      request,
      source,
      target,
      scope,
      transport,
      proposed,
      fields,
      credentialRefusals,
      diagnostics,
      planId,
      lineage,
      McpEnvelope(
        command: 'mcp.convert.plan',
        outcome: 'planned',
        data: data,
        diagnostics: <Map<String, Object?>>[
          for (final diagnostic in diagnostics) diagnostic.toJson(),
        ],
      ),
      sourceText,
    );
  }

  McpEnvelope _apply(_Prepared prepared) {
    // Final guard: any shared-file or managed-state change after review
    // invalidates the plan before the single entry-only write.
    final again = _prepare(prepared.request);
    if (again.planId != prepared.planId) {
      throw MambaException(
        'The native source or target changed before publication; re-review '
        'the plan. Nothing was written.',
        exitCode: 4,
      );
    }
    final context = _context(prepared.request);
    final stateRoot = context.stateRoot(LifecycleScope.user);
    final location = _oneLocation(
      context,
      prepared.request.targetHarness,
      prepared.scope,
    );
    final newText = const McpNativeEditor().apply(
      format: location.format,
      name: prepared.request.name,
      text: readMcpNativeText(fs, location.path) ?? '',
      mutation: McpInsertEntry(prepared.proposed),
    );
    final targetFile = fs.file(location.path);
    targetFile.parent.createSync(recursive: true);
    targetFile.writeAsStringSync(newText);

    McpOwnershipLedger(fs: fs, stateRoot: stateRoot).upsert(
      McpRegistrationRecord(
        identity: prepared.target,
        baselineDigest: mcpCanonicalDigest(prepared.proposed),
      ),
    );
    McpConversionLineageStore(
      fs: fs,
      stateRoot: stateRoot,
    ).upsert(prepared.lineage);

    final data = Map<String, Object?>.from(prepared.planEnvelope.data)
      ..['writes'] = true
      ..['nativeWritten'] = true
      ..['sourceBytesUnchanged'] =
          readMcpNativeText(fs, prepared.source.location) ==
          prepared.sourceText;
    return McpEnvelope(
      command: 'mcp.convert',
      outcome: 'converted',
      data: data,
      diagnostics: <Map<String, Object?>>[
        for (final diagnostic in prepared.diagnostics) diagnostic.toJson(),
      ],
    );
  }

  McpNativeLocation _oneLocation(
    LifecycleContext context,
    McpHarness harness,
    McpScope scope,
  ) {
    final locations = _resolver.resolve(
      context,
      harness: harness,
      scope: scope,
    );
    if (locations.length != 1) {
      throw MambaException(
        'Could not resolve exactly one native MCP location for the selection.',
        exitCode: 2,
      );
    }
    return locations.single;
  }

  McpTransport _transport(Map<String, Object?> fields) {
    final command = fields.containsKey('command');
    final url = fields.containsKey('url');
    if (command == url) {
      throw MambaException(
        'An MCP registration must declare exactly one transport: command '
        '(stdio) or url (http).',
        exitCode: 2,
      );
    }
    return command ? McpTransport.stdio : McpTransport.http;
  }

  ({
    Map<String, Object?> proposed,
    List<Map<String, Object?>> fields,
    List<Map<String, Object?>> credentialRefusals,
    List<McpConversionDiagnostic> diagnostics,
  })
  _mapEntry(
    McpConversionRequest request,
    Map<String, Object?> source,
    McpTransport transport,
  ) {
    final proposed = <String, Object?>{};
    final fields = <Map<String, Object?>>[];
    final credentialRefusals = <Map<String, Object?>>[];
    final diagnostics = <McpConversionDiagnostic>[];
    final omitted = request.omitFields.toSet();
    final profile = 'mcp-${request.harness.wireName}-native-v1';
    final target = request.targetHarness;

    void add(
      String? sourcePath,
      String? targetPath,
      McpFieldOutcome outcome,
      String reason, {
      String? decision,
    }) {
      fields.add(<String, Object?>{
        'sourcePath': sourcePath,
        'targetPath': targetPath,
        'sourceProfile': profile,
        'outcome': outcome.toJson(),
        'decision': decision,
        'reason': reason,
      });
    }

    void refuse(String path, String reason) {
      add(path, null, McpFieldOutcome.refused, reason);
      diagnostics.add(
        McpConversionDiagnostic(
          code: 'MCP_CONVERSION_UNREPRESENTABLE',
          field: path,
        ),
      );
    }

    void policyOmit(String path, String policy) {
      add(
        path,
        null,
        McpFieldOutcome.omittedAfterReview,
        'credential-policy',
        decision: 'policy:$policy',
      );
      credentialRefusals.add(<String, Object?>{
        'sourcePath': path,
        'policy': policy,
        'reason': 'not copied; re-authenticate at the target harness',
      });
    }

    for (final transportKey in const <String>['command', 'url']) {
      if (omitted.contains(transportKey)) {
        throw MambaException(
          'The transport field $transportKey cannot be omitted; transport '
          'must be preserved.',
          exitCode: 2,
        );
      }
    }

    for (final key in _sorted(source.keys)) {
      if (omitted.contains(key)) {
        add(
          key,
          null,
          McpFieldOutcome.omittedAfterReview,
          'reviewed-omission',
          decision: 'omit:$key',
        );
        continue;
      }
      if (mcpCredentialPolicyFields.contains(key)) {
        policyOmit(key, 'credentials-not-copied');
        continue;
      }
      final value = source[key];
      switch (key) {
        case 'command':
          if (value is String && value.isNotEmpty) {
            proposed[key] = value;
            add(key, key, McpFieldOutcome.represented, 'same-transport');
          } else {
            refuse(key, 'invalid-transport-value');
          }
        case 'url':
          if (value is String && value.isNotEmpty) {
            final safe = McpRedaction.sanitizeEndpoint(value);
            if (safe == McpRedaction.redactionPlaceholder) {
              refuse(key, 'endpoint-cannot-be-sanitized');
            } else if (safe != value) {
              proposed[key] = safe;
              add(
                key,
                key,
                McpFieldOutcome.altered,
                'credential-policy',
                decision: 'policy:endpoint-query-removed',
              );
              credentialRefusals.add(<String, Object?>{
                'sourcePath': key,
                'policy': 'endpoint-query-removed',
                'reason': 'not copied; re-authenticate at the target harness',
              });
            } else {
              proposed[key] = value;
              add(key, key, McpFieldOutcome.represented, 'same-transport');
            }
          } else {
            refuse(key, 'invalid-transport-value');
          }
        case 'type':
          _mapType(value, target, transport, omitted, proposed, add, refuse);
        case 'args':
          if (value is List) {
            proposed[key] = value;
            add(key, key, McpFieldOutcome.represented, 'same-shape');
          } else {
            refuse(key, 'wrong-shape');
          }
        case 'env' || 'headers' || 'http_headers':
          if (value is Map) {
            final targetKey =
                key == 'http_headers' && target != McpHarness.codex
                ? 'headers'
                : key == 'headers' && target == McpHarness.codex
                ? 'http_headers'
                : key;
            final copied = <String, Object?>{};
            var narrowed = false;
            for (final entry in value.entries) {
              final path = '$key.${entry.key}';
              if (omitted.contains(path)) {
                add(
                  path,
                  null,
                  McpFieldOutcome.omittedAfterReview,
                  'reviewed-omission',
                  decision: 'omit:$path',
                );
                narrowed = true;
                continue;
              }
              final scalar = entry.value;
              if (scalar is String && McpRedaction.isReference(scalar)) {
                copied[entry.key.toString()] = scalar;
                add(
                  path,
                  '$targetKey.${entry.key}',
                  McpFieldOutcome.represented,
                  'reference-only',
                );
              } else {
                policyOmit(path, 'literal-value-not-copied');
                narrowed = true;
              }
            }
            if (copied.isNotEmpty) proposed[targetKey] = copied;
            add(
              key,
              copied.isEmpty ? null : targetKey,
              narrowed ? McpFieldOutcome.altered : McpFieldOutcome.represented,
              'reference-only',
              decision: narrowed ? 'policy:references-only' : null,
            );
          } else {
            refuse(key, 'wrong-shape');
          }
        case 'cwd':
          if (target == McpHarness.claude) {
            refuse(key, 'no-native-equivalent');
          } else {
            proposed[key] = value;
            add(key, key, McpFieldOutcome.represented, 'same-shape');
          }
        case 'tools':
          if (target == McpHarness.codex && value is Map) {
            final copied = <String, Object?>{};
            var narrowed = false;
            for (final tool in value.entries) {
              final toolPath = 'tools.${tool.key}';
              if (omitted.contains(toolPath)) {
                add(
                  toolPath,
                  null,
                  McpFieldOutcome.omittedAfterReview,
                  'reviewed-omission',
                  decision: 'omit:$toolPath',
                );
                narrowed = true;
                continue;
              }
              if (tool.value is! Map) {
                refuse(toolPath, 'wrong-shape');
                continue;
              }
              final controls = <String, Object?>{};
              for (final control in (tool.value as Map).entries) {
                final path = '$toolPath.${control.key}';
                if (omitted.contains(path)) {
                  add(
                    path,
                    null,
                    McpFieldOutcome.omittedAfterReview,
                    'reviewed-omission',
                    decision: 'omit:$path',
                  );
                  narrowed = true;
                  continue;
                }
                controls[control.key.toString()] = control.value;
                add(path, path, McpFieldOutcome.represented, 'same-shape');
              }
              if (controls.isNotEmpty) copied[tool.key.toString()] = controls;
            }
            if (copied.isNotEmpty) proposed[key] = copied;
            add(
              key,
              copied.isEmpty ? null : key,
              narrowed ? McpFieldOutcome.altered : McpFieldOutcome.represented,
              'runtime-control',
              decision: narrowed ? 'policy:reviewed-omission' : null,
            );
          } else if (value is Map) {
            final paths = <String>[];
            for (final tool in value.entries) {
              final toolPath = 'tools.${tool.key}';
              if (omitted.contains(toolPath)) {
                add(
                  toolPath,
                  null,
                  McpFieldOutcome.omittedAfterReview,
                  'reviewed-omission',
                  decision: 'omit:$toolPath',
                );
                continue;
              }
              if (tool.value is Map) {
                for (final control in (tool.value as Map).keys) {
                  paths.add('$toolPath.$control');
                }
              } else {
                paths.add(toolPath);
              }
            }
            if (paths.isEmpty) {
              refuse(key, 'harness-specific-runtime-control');
            } else {
              for (final path in paths) {
                if (omitted.contains(path)) {
                  add(
                    path,
                    null,
                    McpFieldOutcome.omittedAfterReview,
                    'reviewed-omission',
                    decision: 'omit:$path',
                  );
                } else {
                  refuse(path, 'harness-specific-runtime-control');
                }
              }
            }
          } else {
            refuse(key, 'wrong-shape');
          }
        case 'enabled':
          if (target == McpHarness.claude) {
            refuse(key, 'no-native-equivalent');
          } else {
            proposed[key] = value;
            add(key, key, McpFieldOutcome.represented, 'same-shape');
          }
        default:
          if (mcpCodexRuntimeControls.contains(key) &&
              target == McpHarness.codex) {
            proposed[key] = value;
            add(key, key, McpFieldOutcome.represented, 'same-shape');
          } else if (mcpPiRuntimeControls.contains(key) &&
              target == McpHarness.pi) {
            proposed[key] = value;
            add(key, key, McpFieldOutcome.represented, 'same-shape');
          } else {
            refuse(key, 'no-native-equivalent');
          }
      }
    }

    if (transport == McpTransport.http &&
        target == McpHarness.claude &&
        !source.containsKey('type') &&
        !omitted.contains('type')) {
      proposed['type'] = 'http';
      add(
        null,
        'type',
        McpFieldOutcome.altered,
        'target-requires-http-type',
        decision: 'derive:http-type',
      );
    }

    final knownPaths = fields
        .map((field) => field['sourcePath'])
        .whereType<String>()
        .toSet();
    for (final path in _sorted(omitted)) {
      if (!knownPaths.contains(path)) {
        throw MambaException(
          'Unknown --omit-field $path: no such source field was observed.',
          exitCode: 2,
        );
      }
    }

    fields.sort((a, b) {
      final left = a['sourcePath'] as String? ?? '';
      final right = b['sourcePath'] as String? ?? '';
      final bySource = left.compareTo(right);
      if (bySource != 0) return bySource;
      final aTarget = a['targetPath'] as String? ?? '';
      final bTarget = b['targetPath'] as String? ?? '';
      final byTarget = aTarget.compareTo(bTarget);
      if (byTarget != 0) return byTarget;
      return (a['outcome'] as String).compareTo(b['outcome'] as String);
    });
    credentialRefusals.sort(
      (a, b) =>
          (a['sourcePath'] as String).compareTo(b['sourcePath'] as String),
    );
    diagnostics.sort((a, b) {
      final byCode = a.code.compareTo(b.code);
      return byCode != 0 ? byCode : a.field.compareTo(b.field);
    });
    return (
      proposed: proposed,
      fields: fields,
      credentialRefusals: credentialRefusals,
      diagnostics: diagnostics,
    );
  }

  void _mapType(
    Object? value,
    McpHarness target,
    McpTransport transport,
    Set<String> omitted,
    Map<String, Object?> proposed,
    void Function(String?, String?, McpFieldOutcome, String, {String? decision})
    add,
    void Function(String, String) refuse,
  ) {
    if (value is! String) {
      refuse('type', 'wrong-shape');
      return;
    }
    final allowed = transport == McpTransport.stdio
        ? const <String>{'stdio'}
        : switch (target) {
            McpHarness.claude => _claudeHttpTypes,
            McpHarness.codex => _codexHttpTypes,
            McpHarness.pi => _piHttpTypes,
          };
    if (allowed.contains(value)) {
      proposed['type'] = value;
      add('type', 'type', McpFieldOutcome.represented, 'supported-type');
    } else if (omitted.contains('type')) {
      add(
        'type',
        null,
        McpFieldOutcome.omittedAfterReview,
        'reviewed-omission',
        decision: 'omit:type',
      );
    } else {
      refuse('type', 'no-native-equivalent');
    }
  }

  static String _digest(String text) => mcpCanonicalDigest(text);

  static List<String> _sorted(Iterable<String> values) =>
      List<String>.unmodifiable(values.toList()..sort());
}
