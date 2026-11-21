import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../mcp/mcp_conversion_account.dart';
import '../mcp/mcp_native_location.dart';
import '../mcp/mcp_redaction.dart';
import '../mcp/mcp_types.dart';
import '../mcp/mcp_validation_contract.dart';
import 'harness_facet.dart';
import 'hub_claim_types.dart';

/// The root vocabulary a composed MCP facet needs to resolve native files.
abstract interface class McpHarnessRoots {
  String get projectRoot;
  p.Context get path;
  String requireHome();
  String claudeConfigRoot();
  String codexRoot();
  String piAgentRoot();
  String geminiConfigRoot();
}

/// The MCP capability declared and implemented by one harness descriptor.
///
/// Resolution, validation, and the two conversion spokes live here so adding
/// a harness does not add pairwise branches to the domain services.
abstract interface class McpHarnessSpec implements HarnessFacetSpec {
  McpHarness get mcpHarness;
  Set<McpScope> get supportedScopes;
  Set<McpScope> get inspectOnlyScopes;
  String? get inspectOnlyDiagnostic;
  List<String> get projectSegments;
  McpNativeFormat get nativeFormat;
  McpNativeSection get nativeSection;
  McpValidationContract get validation;
  String get conversionProfile;
  Set<String> get runtimeControlFields;
  String? get toolProfile;
  Set<String> get stdioTransportKeys;
  Set<String> get httpTransportKeys;
  String get httpEndpointKey;
  String get headerKey;

  List<McpNativeLocation> locations(McpHarnessRoots roots);

  McpNativeLocation projectLocation(p.Context path, String root);

  String sectionKey(McpNativeSection section);

  McpCanonicalRegistration importNative(McpImportRequest request);

  McpExportResult exportCanonical(McpExportRequest request);
}

/// Declarative transport recognition shared by inspection and conversion.
extension McpHarnessSpecTransport on McpHarnessSpec {
  /// The declared transport requires exactly one native transport key. Type
  /// inference is deliberately not part of this declaration.
  McpTransport? declaredTransport(Map<String, Object?> fields) {
    final stdio = stdioTransportKeys.where(fields.containsKey).length;
    final http = httpTransportKeys.where(fields.containsKey).length;
    if (stdio + http != 1) return null;
    return stdio == 1 ? McpTransport.stdio : McpTransport.http;
  }

  /// Inspection may additionally infer a transport from a declared type; it
  /// never treats a conflicting or missing native declaration as definitive.
  McpTransport? transportOf(Map<String, Object?> fields) {
    final declared = declaredTransport(fields);
    if (declared != null) return declared;
    final type = fields['type'];
    if (type is String) {
      if (validation.httpTypes.contains(type)) return McpTransport.http;
      if (validation.stdioTypes.contains(type)) return McpTransport.stdio;
    }
    return null;
  }
}

/// One bounded request to import a named native registration into canonical
/// MCP claims and its source provenance.
final class McpImportRequest {
  const McpImportRequest({
    required this.fields,
    required this.scope,
    required this.transport,
    required this.omitFields,
  });

  final Map<String, Object?> fields;
  final McpScope scope;
  final McpTransport transport;
  final Set<String> omitFields;
}

/// One bounded request to export canonical claims into one target native
/// entry and its reviewed field account.
final class McpExportRequest {
  const McpExportRequest({required this.canonical, required this.omitFields});

  final McpCanonicalRegistration canonical;
  final Set<String> omitFields;
}

/// The closed categories of canonical MCP claims.
enum McpCanonicalClaimKind {
  command,
  endpoint,
  type,
  arguments,
  referenceMap,
  cwd,
  tools,
  runtimeControl,
  credential,
  unknown,
}

/// Where one canonical claim came from. It never carries a native value.
final class McpClaimProvenance extends HubClaimProvenance<McpHarness> {
  const McpClaimProvenance({
    required super.sourceHarness,
    required this.sourceScope,
    required super.sourceProfile,
    required super.sourcePath,
  });

  final McpScope sourceScope;

  @override
  String get sourceHarnessWire => sourceHarness.wireName;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'sourceHarness': sourceHarnessWire,
    'sourceScope': sourceScope.wireName,
    'sourceProfile': sourceProfile,
    'sourcePath': sourcePath,
  };
}

/// One canonical claim plus its source provenance. [canonicalPath] is the
/// hub vocabulary; [sourcePath] stays the native field path.
final class McpCanonicalClaim
    extends HubClaim<McpCanonicalClaimKind, McpClaimProvenance> {
  const McpCanonicalClaim({
    required super.canonicalPath,
    required super.sourcePath,
    required super.kind,
    required super.value,
    required super.provenance,
    super.detail,
  });

  Map<String, Object?> toJson() => toJsonBase();
}

/// The hub representation of one named MCP registration.
final class McpCanonicalRegistration
    extends HubClaims<McpHarness, McpCanonicalClaim> {
  const McpCanonicalRegistration({
    required super.sourceHarness,
    required this.sourceScope,
    required super.sourceProfile,
    required this.transport,
    required super.claims,
    required super.nativeFields,
  });

  final McpScope sourceScope;
  final McpTransport transport;

  @override
  String get sourceHarnessWire => sourceHarness.wireName;

  /// A value-free account suitable for binding a reviewed plan identity.
  Map<String, Object?> toJson() => <String, Object?>{
    'sourceHarness': sourceHarnessWire,
    'sourceScope': sourceScope.wireName,
    'sourceProfile': sourceProfile,
    'transport': transport.wireName,
    'claims': <Object?>[for (final claim in claims) claim.toJsonBase()],
  };
}

/// The complete target-native export and its reviewed loss diagnostics.
final class McpExportResult {
  const McpExportResult({
    required this.proposed,
    required this.fields,
    required this.credentialRefusals,
    required this.diagnostics,
  });

  final Map<String, Object?> proposed;
  final List<Map<String, Object?>> fields;
  final List<Map<String, Object?>> credentialRefusals;
  final List<McpConversionDiagnostic> diagnostics;
}

/// Imports one native entry into canonical claims using the source harness's
/// own field matrix. No target harness is known at this spoke.
McpCanonicalRegistration mcpImportNative(
  McpHarnessSpec source,
  McpImportRequest request,
) {
  final fields = request.fields;
  final omitted = request.omitFields;
  for (final key in <String>{
    ...source.stdioTransportKeys,
    ...source.httpTransportKeys,
  }) {
    if (omitted.contains(key)) {
      throw MambaException(
        'The transport field $key cannot be omitted; transport must be '
        'preserved.',
        exitCode: 2,
      );
    }
  }

  final claims = <McpCanonicalClaim>[];
  for (final key in _sorted(fields.keys)) {
    final value = fields[key];
    final provenance = McpClaimProvenance(
      sourceHarness: source.mcpHarness,
      sourceScope: request.scope,
      sourceProfile: source.conversionProfile,
      sourcePath: key,
    );
    var canonicalPath = key;
    var kind = McpCanonicalClaimKind.unknown;
    String? detail;
    if (mcpCredentialPolicyFields.contains(key)) {
      kind = McpCanonicalClaimKind.credential;
    } else if (source.stdioTransportKeys.contains(key)) {
      kind = McpCanonicalClaimKind.command;
    } else if (source.httpTransportKeys.contains(key)) {
      canonicalPath = 'url';
      kind = McpCanonicalClaimKind.endpoint;
    } else if (key == 'type' &&
        source.validation.commonFields.contains('type')) {
      kind = McpCanonicalClaimKind.type;
    } else if (key == 'args') {
      kind = McpCanonicalClaimKind.arguments;
    } else if (source.mcpHarness == McpHarness.codex &&
        (key == 'env_vars' || key == 'env_http_headers')) {
      canonicalPath = key == 'env_vars' ? 'env' : 'headers';
      kind = McpCanonicalClaimKind.referenceMap;
      detail = key;
    } else if (key == 'env' || key == 'headers' || key == 'http_headers') {
      canonicalPath = key == 'env' ? 'env' : 'headers';
      kind = McpCanonicalClaimKind.referenceMap;
      detail = key;
    } else if (key == 'cwd') {
      kind = McpCanonicalClaimKind.cwd;
    } else if (key == 'tools') {
      kind = McpCanonicalClaimKind.tools;
      detail = source.toolProfile;
    } else if (source.runtimeControlFields.contains(key)) {
      kind = McpCanonicalClaimKind.runtimeControl;
    }
    claims.add(
      McpCanonicalClaim(
        canonicalPath: canonicalPath,
        sourcePath: key,
        kind: kind,
        value: value,
        provenance: provenance,
        detail: detail,
      ),
    );
  }
  return McpCanonicalRegistration(
    sourceHarness: source.mcpHarness,
    sourceScope: request.scope,
    sourceProfile: source.conversionProfile,
    transport: request.transport,
    claims: List<McpCanonicalClaim>.unmodifiable(claims),
    nativeFields: Map<String, Object?>.unmodifiable(fields),
  );
}

/// Exports canonical claims into one target-native entry using the target
/// harness's own field matrix. No source-harness pair is known at this spoke.
McpExportResult mcpExportCanonical(
  McpHarnessSpec target,
  McpExportRequest request,
) {
  final canonical = request.canonical;
  final omitted = request.omitFields;
  final proposed = <String, Object?>{};
  final fields = <Map<String, Object?>>[];
  final credentialRefusals = <Map<String, Object?>>[];
  final diagnostics = <McpConversionDiagnostic>[];

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
      'sourceProfile': canonical.sourceProfile,
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

  for (final claim in canonical.claims) {
    final key = claim.sourcePath;
    final value = claim.value;
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
    switch (claim.kind) {
      case McpCanonicalClaimKind.command:
        if (value is String && value.isNotEmpty) {
          proposed['command'] = value;
          add(key, 'command', McpFieldOutcome.represented, 'same-transport');
        } else {
          refuse(key, 'invalid-transport-value');
        }
      case McpCanonicalClaimKind.endpoint:
        if (value is String && value.isNotEmpty) {
          final safe = McpRedaction.sanitizeEndpoint(value);
          if (safe == McpRedaction.redactionPlaceholder) {
            refuse(key, 'endpoint-cannot-be-sanitized');
            break;
          }
          final targetKey = target.httpEndpointKey;
          proposed[targetKey] = safe;
          if (safe != value) {
            add(
              key,
              targetKey,
              McpFieldOutcome.altered,
              'credential-policy',
              decision: 'policy:endpoint-query-removed',
            );
            credentialRefusals.add(<String, Object?>{
              'sourcePath': key,
              'policy': 'endpoint-query-removed',
              'reason': 'not copied; re-authenticate at the target harness',
            });
          } else if (key != targetKey) {
            add(
              key,
              targetKey,
              McpFieldOutcome.altered,
              'native-endpoint-key',
              decision: 'native:endpoint-key',
            );
          } else {
            add(key, targetKey, McpFieldOutcome.represented, 'same-transport');
          }
        } else {
          refuse(key, 'invalid-transport-value');
        }
      case McpCanonicalClaimKind.type:
        _exportType(
          target: target,
          canonical: canonical,
          value: value,
          omitted: omitted,
          proposed: proposed,
          add: add,
          refuse: refuse,
        );
      case McpCanonicalClaimKind.arguments:
        if (value is List) {
          proposed['args'] = value;
          add(key, 'args', McpFieldOutcome.represented, 'same-shape');
        } else {
          refuse(key, 'wrong-shape');
        }
      case McpCanonicalClaimKind.referenceMap:
        _exportReferenceMap(
          target: target,
          claim: claim,
          value: value,
          omitted: omitted,
          proposed: proposed,
          add: add,
          refuse: refuse,
          policyOmit: policyOmit,
        );
      case McpCanonicalClaimKind.cwd:
        if (target.validation.stdioFields.contains('cwd')) {
          proposed['cwd'] = value;
          add(key, 'cwd', McpFieldOutcome.represented, 'same-shape');
        } else {
          refuse(key, 'no-native-equivalent');
        }
      case McpCanonicalClaimKind.tools:
        _exportTools(
          target: target,
          claim: claim,
          value: value,
          omitted: omitted,
          proposed: proposed,
          add: add,
          refuse: refuse,
        );
      case McpCanonicalClaimKind.credential:
        policyOmit(key, 'credentials-not-copied');
      case McpCanonicalClaimKind.runtimeControl:
      case McpCanonicalClaimKind.unknown:
        if (target.runtimeControlFields.contains(key) &&
            _targetSupportsField(target, key)) {
          proposed[key] = value;
          add(key, key, McpFieldOutcome.represented, 'same-shape');
        } else {
          refuse(key, 'no-native-equivalent');
        }
    }
  }

  if (canonical.transport == McpTransport.http &&
      target.validation.requiresHttpType &&
      !canonical.nativeFields.containsKey('type') &&
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
    (a, b) => (a['sourcePath'] as String).compareTo(b['sourcePath'] as String),
  );
  diagnostics.sort((a, b) {
    final byCode = a.code.compareTo(b.code);
    return byCode != 0 ? byCode : a.field.compareTo(b.field);
  });
  return McpExportResult(
    proposed: Map<String, Object?>.unmodifiable(proposed),
    fields: List<Map<String, Object?>>.unmodifiable(fields),
    credentialRefusals: List<Map<String, Object?>>.unmodifiable(
      credentialRefusals,
    ),
    diagnostics: List<McpConversionDiagnostic>.unmodifiable(diagnostics),
  );
}

typedef _AddAccount = void Function(
  String?,
  String?,
  McpFieldOutcome,
  String, {
  String? decision,
});

void _exportType({
  required McpHarnessSpec target,
  required McpCanonicalRegistration canonical,
  required Object? value,
  required Set<String> omitted,
  required Map<String, Object?> proposed,
  required _AddAccount add,
  required void Function(String, String) refuse,
}) {
  if (value is! String) {
    refuse('type', 'wrong-shape');
    return;
  }
  final allowed = !target.validation.commonFields.contains('type')
      ? const <String>{}
      : canonical.transport == McpTransport.stdio
      ? target.validation.stdioTypes
      : target.validation.httpTypes;
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

void _exportReferenceMap({
  required McpHarnessSpec target,
  required McpCanonicalClaim claim,
  required Object? value,
  required Set<String> omitted,
  required Map<String, Object?> proposed,
  required _AddAccount add,
  required void Function(String, String) refuse,
  required void Function(String, String) policyOmit,
}) {
  final key = claim.sourcePath;
  if (claim.detail == 'env_vars' && value is List) {
    final identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    if (value.any((name) => name is! String || !identifier.hasMatch(name))) {
      refuse(key, 'unsupported-native-reference');
      return;
    }
    value = <String, String>{
      for (final name in value.cast<String>())
        name:
            r'$'
            '{$name}',
    };
  }
  if (value is! Map) {
    refuse(key, 'wrong-shape');
    return;
  }
  if (claim.detail == 'env_http_headers') {
    final identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    if (value.values.any(
      (name) => name is! String || !identifier.hasMatch(name),
    )) {
      refuse(key, 'unsupported-native-reference');
      return;
    }
    value = <Object?, String>{
      for (final entry in value.entries)
        entry.key:
            r'$'
            '{${entry.value}}',
    };
  }
  final isEnv = claim.canonicalPath == 'env';
  final codex = target.mcpHarness == McpHarness.codex;
  final targetKey = codex
      ? (isEnv ? 'env_vars' : 'env_http_headers')
      : (isEnv ? 'env' : target.headerKey);
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
      final native = McpRedaction.nativeReference(target.mcpHarness, scalar);
      if (native == null || (codex && isEnv && native != entry.key)) {
        refuse(path, 'unsupported-native-reference');
        narrowed = true;
        continue;
      }
      copied[entry.key.toString()] = native;
      add(
        path,
        '$targetKey.${entry.key}',
        codex ? McpFieldOutcome.altered : McpFieldOutcome.represented,
        'reference-only',
        decision: codex ? 'native:reference' : null,
      );
    } else {
      policyOmit(path, 'literal-value-not-copied');
      narrowed = true;
    }
  }
  if (copied.isNotEmpty) {
    proposed[targetKey] = codex && isEnv ? copied.keys.toList() : copied;
  }
  add(
    key,
    copied.isEmpty ? null : targetKey,
    narrowed ? McpFieldOutcome.altered : McpFieldOutcome.represented,
    'reference-only',
    decision: narrowed ? 'policy:references-only' : null,
  );
}

void _exportTools({
  required McpHarnessSpec target,
  required McpCanonicalClaim claim,
  required Object? value,
  required Set<String> omitted,
  required Map<String, Object?> proposed,
  required _AddAccount add,
  required void Function(String, String) refuse,
}) {
  final key = claim.sourcePath;
  if (value is! Map) {
    refuse(key, 'wrong-shape');
    return;
  }
  final compatible =
      target.toolProfile != null && target.toolProfile == claim.detail;
  if (compatible) {
    final copied = <String, Object?>{};
    var narrowed = false;
    for (final tool in value.entries) {
      final toolPath = '$key.${tool.key}';
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
    if (copied.isNotEmpty) proposed['tools'] = copied;
    add(
      key,
      copied.isEmpty ? null : 'tools',
      narrowed ? McpFieldOutcome.altered : McpFieldOutcome.represented,
      'runtime-control',
      decision: narrowed ? 'policy:reviewed-omission' : null,
    );
    return;
  }

  final paths = <String>[];
  for (final tool in value.entries) {
    final toolPath = '$key.${tool.key}';
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
}

bool _targetSupportsField(McpHarnessSpec target, String key) =>
    target.validation.commonFields.contains(key) ||
    target.validation.stdioFields.contains(key) ||
    target.validation.httpFields.contains(key);

List<String> _sorted(Iterable<String> values) =>
    List<String>.unmodifiable(values.toList()..sort());
