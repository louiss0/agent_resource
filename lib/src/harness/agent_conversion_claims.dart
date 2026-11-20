import 'agent_harness_spec.dart';
import 'harness_id.dart';
import 'hub_claim_types.dart';

/// The closed categories of canonical Agent claims.
enum AgentClaimKind {
  identity,
  instructions,
  model,
  effort,
  permission,
  toolSurface,
  mainAgent,
  reference,
  unknown,
}

/// Where one canonical claim came from. It never carries a native value.
final class AgentClaimProvenance extends HubClaimProvenance<HarnessId> {
  const AgentClaimProvenance({
    required super.sourceHarness,
    required super.sourceProfile,
    required this.sourceForm,
    required super.sourcePath,
  });

  final String sourceForm;

  @override
  String get sourceHarnessWire => sourceHarness.wireName;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'sourceHarness': sourceHarnessWire,
    'sourceProfile': sourceProfile,
    'sourceForm': sourceForm,
    'sourcePath': sourcePath,
  };
}

/// One canonical claim plus the provenance of its native declaration.
final class AgentCanonicalClaim
    extends HubClaim<AgentClaimKind, AgentClaimProvenance> {
  const AgentCanonicalClaim({
    required super.canonicalPath,
    required super.sourcePath,
    required super.kind,
    required super.value,
    required super.provenance,
    super.detail,
  });

  Map<String, Object?> toJson() => toJsonBase();
}

/// The hub representation of one native Agent definition.
final class AgentCanonicalClaims
    extends HubClaims<HarnessId, AgentCanonicalClaim> {
  const AgentCanonicalClaims({
    required super.sourceHarness,
    required this.sourceForm,
    required super.sourceProfile,
    required super.claims,
    required super.nativeFields,
    required this.instructions,
  });

  final String sourceForm;
  final String? instructions;

  @override
  String get sourceHarnessWire => sourceHarness.wireName;

  /// A value-free account suitable for binding a reviewed plan identity.
  Map<String, Object?> toJson() => <String, Object?>{
    'sourceHarness': sourceHarnessWire,
    'sourceProfile': sourceProfile,
    'sourceForm': sourceForm,
    'claims': <Object?>[for (final claim in claims) claim.toJsonBase()],
  };
}

/// One bounded import of a native Agent into canonical claims.
final class AgentImportRequest {
  const AgentImportRequest({
    required this.fields,
    required this.sourceForm,
    required this.sourceProfile,
    this.instructions,
  });

  final Map<String, Object?> fields;
  final String sourceForm;
  final String sourceProfile;
  final String? instructions;
}

/// One bounded export of canonical claims into one target native profile.
final class AgentExportRequest {
  const AgentExportRequest({
    required this.canonical,
    required this.definition,
    required this.decisions,
    required this.sourceProfile,
  });

  final AgentCanonicalClaims canonical;
  final Map<String, Object?> definition;
  final Set<String> decisions;
  final String sourceProfile;
}

/// The complete per-field account of one export spoke.
final class AgentExportResult {
  const AgentExportResult({
    required this.fields,
    required this.diagnostics,
    required this.targetProfile,
  });

  final List<Map<String, Object?>> fields;
  final List<Map<String, Object?>> diagnostics;
  final String targetProfile;
}

const _handledPaths = <String>{
  'name',
  'description',
  'developer_instructions',
  'instructions',
};

/// Imports native fields through the source harness's own contract. No target
/// harness is known at this spoke.
AgentCanonicalClaims agentImportNative(
  AgentHarnessSpec source,
  AgentImportRequest request,
) {
  final provenance = AgentClaimProvenance(
    sourceHarness: source.harness,
    sourceProfile: request.sourceProfile,
    sourceForm: request.sourceForm,
    sourcePath: '',
  );
  final claims = <AgentCanonicalClaim>[];
  for (final key in _sorted(request.fields.keys)) {
    final value = request.fields[key];
    final canonicalPath = switch (key) {
      'effort' || 'model_reasoning_effort' || 'thinking' => 'effort',
      'mcp_servers' => 'mcpServers',
      _ => key,
    };
    final kind = switch (key) {
      'name' || 'description' => AgentClaimKind.identity,
      'developer_instructions' => AgentClaimKind.instructions,
      'model' => AgentClaimKind.model,
      'effort' ||
      'model_reasoning_effort' ||
      'thinking' => AgentClaimKind.effort,
      'tools' => AgentClaimKind.toolSurface,
      'disallowedTools' ||
      'permissionMode' ||
      'allowedTools' => AgentClaimKind.permission,
      'mainAgent' => AgentClaimKind.mainAgent,
      'skills' ||
      'mcpServers' ||
      'mcp_servers' ||
      'hooks' => AgentClaimKind.reference,
      _ => AgentClaimKind.unknown,
    };
    claims.add(
      AgentCanonicalClaim(
        canonicalPath: canonicalPath,
        sourcePath: key,
        kind: kind,
        value: value,
        provenance: AgentClaimProvenance(
          sourceHarness: provenance.sourceHarness,
          sourceProfile: provenance.sourceProfile,
          sourceForm: provenance.sourceForm,
          sourcePath: key,
        ),
        detail: kind == AgentClaimKind.toolSurface
            ? value is List
                  ? 'sequence'
                  : 'scalar'
            : null,
      ),
    );
  }
  return AgentCanonicalClaims(
    sourceHarness: source.harness,
    sourceProfile: request.sourceProfile,
    sourceForm: request.sourceForm,
    claims: List<AgentCanonicalClaim>.unmodifiable(claims),
    nativeFields: Map<String, Object?>.unmodifiable(request.fields),
    instructions: request.instructions,
  );
}

/// Exports canonical claims through the target harness's own field matrix.
/// No source-harness pair is known at this spoke.
AgentExportResult agentExportCanonical(
  AgentHarnessSpec target,
  AgentExportRequest request,
) {
  final canonical = request.canonical;
  final definition = request.definition;
  final decisions = request.decisions;
  final profile = target.authoringProfile;
  final matrix = target.nativeAgentFields(profile);
  final effortKey = target.effortKey;
  String? targetKeyFor(AgentCanonicalClaim claim) => switch (claim.kind) {
    AgentClaimKind.model => matrix.specFor('model') == null ? null : 'model',
    AgentClaimKind.effort => effortKey,
    AgentClaimKind.toolSurface => 'tools',
    AgentClaimKind.permission =>
      matrix.specFor(claim.sourcePath) == null ? null : claim.sourcePath,
    AgentClaimKind.mainAgent =>
      matrix.specFor('mainAgent') == null ? null : 'mainAgent',
    AgentClaimKind.reference =>
      matrix.specFor(claim.sourcePath) == null ? null : claim.sourcePath,
    AgentClaimKind.unknown =>
      matrix.specFor(claim.sourcePath) == null ? null : claim.sourcePath,
    _ => null,
  };

  final fields = <Map<String, Object?>>[];
  final diagnostics = <Map<String, Object?>>[];
  void add(
    String? sourcePath,
    String? targetPath,
    String outcome,
    String? decision,
  ) => fields.add(<String, Object?>{
    'sourcePath': sourcePath,
    'targetPath': targetPath,
    'sourceProfile': request.sourceProfile,
    'outcome': outcome,
    'decision': decision,
  });

  void unresolved(String? sourcePath, String? targetPath, String? decision) =>
      add(sourcePath, targetPath, 'unresolved', decision);

  void requireDecision(
    String? sourcePath,
    String? targetPath,
    String? decision,
    String code,
    String message,
  ) {
    unresolved(sourcePath, targetPath, decision);
    diagnostics.add(<String, Object?>{
      'code': code,
      'category': 'product',
      'severity': 'error',
      'field': sourcePath,
      'message': message,
    });
  }

  final covered = <String>{};
  for (final claim in canonical.claims) {
    final kind = claim.kind;
    if (kind == AgentClaimKind.identity ||
        kind == AgentClaimKind.instructions) {
      continue;
    }
    if (_handledPaths.contains(claim.canonicalPath)) continue;
    final key = claim.sourcePath;
    final targetKey = targetKeyFor(claim);
    if (kind == AgentClaimKind.effort) covered.add(key);
    if (kind == AgentClaimKind.model) covered.add('model');
    if (kind == AgentClaimKind.toolSurface) covered.add('tools');
    if (kind == AgentClaimKind.permission) covered.add(key);
    if (kind == AgentClaimKind.mainAgent) covered.add(key);
    if (kind == AgentClaimKind.reference) covered.add(key);
    if (kind == AgentClaimKind.unknown) covered.add(key);
    final defined = targetKey == null
        ? false
        : definition.containsKey(targetKey);
    final omit =
        decisions.contains('omit:$key') ||
        (kind == AgentClaimKind.effort && decisions.contains('omit:effort'));
    final inherit = decisions.contains('inherit:$key');
    final mapped =
        decisions.contains('map:$key') ||
        (kind == AgentClaimKind.effort && decisions.contains('map:effort'));

    switch (kind) {
      case AgentClaimKind.model:
        if (targetKey == null) {
          if (omit) {
            add(key, null, 'omitted', 'omit:$key');
          } else if (inherit) {
            add(key, null, 'inherited', 'inherit:$key');
          } else {
            requireDecision(
              key,
              null,
              null,
              'CONVERSION_DECISION_REQUIRED',
              'The target has no native model control; select omit:model '
                  'or inherit:model to approve its loss.',
            );
          }
        } else if (defined) {
          add(key, targetKey, mapped ? 'altered' : 'unresolved', 'map:$key');
        } else if (omit) {
          add(key, null, 'omitted', 'omit:$key');
        } else if (inherit) {
          add(key, null, 'inherited', 'inherit:$key');
        } else {
          unresolved(key, targetKey, null);
        }
      case AgentClaimKind.effort:
        final decisionKey = key == 'effort' ? 'effort' : key;
        if (targetKey == null) {
          if (omit) {
            add(key, null, 'omitted', 'omit:$decisionKey');
          } else {
            unresolved(key, null, null);
          }
        } else if (defined) {
          add(
            key,
            targetKey,
            mapped ? 'altered' : 'unresolved',
            'map:$decisionKey',
          );
        } else if (omit) {
          add(key, null, 'omitted', 'omit:$decisionKey');
        } else {
          unresolved(key, targetKey, null);
        }
      case AgentClaimKind.toolSurface:
        if (defined) {
          add(key, targetKey, mapped ? 'altered' : 'unresolved', 'map:$key');
          if (mapped) {
            requireReviewedToolExposure(
              source: claim.value,
              target: definition[targetKey],
              decisions: decisions,
              requireDecision: requireDecision,
              sourcePath: key,
              targetPath: targetKey,
            );
          }
        } else if (omit) {
          add(key, null, 'omitted', 'omit:$key');
        } else if (inherit) {
          add(key, null, 'inherited', 'inherit:$key');
        } else {
          unresolved(key, targetKey, null);
        }
      case AgentClaimKind.permission:
      case AgentClaimKind.mainAgent:
      case AgentClaimKind.reference:
      case AgentClaimKind.unknown:
        if (targetKey == null) {
          if (omit) {
            add(key, null, 'omitted', 'omit:$key');
          } else {
            add(key, null, 'unrepresentable', null);
          }
        } else if (defined) {
          add(key, targetKey, mapped ? 'altered' : 'unresolved', 'map:$key');
        } else if (omit) {
          add(key, null, 'omitted', 'omit:$key');
        } else {
          add(key, targetKey, 'unrepresentable', null);
        }
      case AgentClaimKind.identity:
      case AgentClaimKind.instructions:
        throw StateError('Unreachable canonical claim kind.');
    }
  }

  final hasEffortClaim = canonical.claims.any(
    (claim) => claim.kind == AgentClaimKind.effort,
  );
  for (final key in _sorted(definition.keys)) {
    if (_handledPaths.contains(key) || covered.contains(key)) continue;
    if (key == 'model' || key == 'tools' || effortKey == key) {
      if (key == effortKey && hasEffortClaim) continue;
      final decision =
          decisions.contains('map:$key') ||
          (key == effortKey && decisions.contains('map:effort'));
      add(
        key == effortKey ? null : key,
        key,
        decision ? 'altered' : 'unresolved',
        'map:$key',
      );
      if (key == 'tools' && decision) {
        requireReviewedToolExposure(
          source: canonical.nativeFields['tools'],
          target: definition[key],
          decisions: decisions,
          requireDecision: requireDecision,
        );
      }
      continue;
    }
    final supported = matrix.specFor(key) != null;
    final decision = decisions.contains('map:$key');
    add(
      supported ? key : null,
      supported ? key : null,
      supported && decision ? 'altered' : 'unresolved',
      'map:$key',
    );
  }

  fields.sort((a, b) {
    final bySource = _compare(a['sourcePath'], b['sourcePath']);
    if (bySource != 0) return bySource;
    final byTarget = _compare(a['targetPath'], b['targetPath']);
    return byTarget;
  });
  diagnostics.sort((a, b) {
    final byCode = (a['code']! as String).compareTo(b['code']! as String);
    return byCode != 0 ? byCode : _compare(a['field'], b['field']);
  });
  return AgentExportResult(
    fields: List<Map<String, Object?>>.unmodifiable(fields),
    diagnostics: List<Map<String, Object?>>.unmodifiable(diagnostics),
    targetProfile: target.profile,
  );
}

int _compare(Object? left, Object? right) =>
    (left as String? ?? '').compareTo(right as String? ?? '');

List<String> _sorted(Iterable<String> values) =>
    List<String>.unmodifiable(values.toList()..sort());

Set<String> _toolNames(Object? value) {
  final names = <String>[];
  if (value is List) {
    names.addAll(value.whereType<String>());
  } else if (value is String) {
    names.addAll(value.split(','));
  }
  return names
      .map((entry) => entry.trim().toLowerCase())
      .where((entry) => entry.isNotEmpty)
      .toSet();
}

bool _broadensTools(Object? source, Object? target) {
  final sourceNames = _toolNames(source);
  final targetNames = _toolNames(target);
  return sourceNames.isNotEmpty &&
      targetNames.difference(sourceNames).isNotEmpty;
}

/// The one tool-exposure guard shared by both import and export spokes.
typedef ToolDecisionRequester = void Function(
  String? sourcePath,
  String? targetPath,
  String? decision,
  String code,
  String message,
);

void requireReviewedToolExposure({
  required Object? source,
  required Object? target,
  required Set<String> decisions,
  required ToolDecisionRequester requireDecision,
  String sourcePath = 'tools',
  String? targetPath = 'tools',
}) {
  if (decisions.contains('widen:tools') || !_broadensTools(source, target)) {
    return;
  }
  requireDecision(
    sourcePath,
    targetPath,
    'widen:tools',
    'CONVERSION_TOOL_EXPOSURE',
    'The proposed tool list exposes tools absent from the source; an '
        'explicit widen:tools decision is required.',
  );
}
