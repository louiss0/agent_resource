import 'dart:convert';

import 'package:zema/zema.dart';

import '../validation/validation_diagnostics.dart';
import 'mcp_types.dart';

/// The only claim a completed MCP validation report may make.
const String mcpValidationClaim =
    'static schema/reference correctness only; not runtime-verified';

/// Pinned documentation baselines for the closed native field matrices.
const String mcpClaudeBaseline = 'claude-code-mcp/2026-11-16';
const String mcpCodexBaseline = 'codex-mcp/2026-07-17';
const String mcpPiBaseline =
    'pi-native-mcp/5a2febe5d7638ab05540b44a60518b41201be170';
const String mcpParentConfigurationBaseline =
    'agent-parent-configuration/2026-10-23';

/// Stable diagnostic codes and their fixed, value-free message templates.
typedef McpValidationCodeDefinition = ({String category, String message});

const Map<String, McpValidationCodeDefinition> mcpValidationCodeTable =
    <String, McpValidationCodeDefinition>{
      'MCP_TRANSPORT_MISSING': (
        category: 'specification',
        message: 'Exactly one of the command and url fields is required.',
      ),
      'MCP_TRANSPORT_CONFLICT': (
        category: 'specification',
        message: 'The command and url fields are mutually exclusive.',
      ),
      'MCP_TRANSPORT_REFINEMENT': (
        category: 'specification',
        message: 'The transport fields are inconsistent.',
      ),
      'MCP_TYPE_REQUIRED': (
        category: 'specification',
        message: 'Field type is required for this HTTP registration.',
      ),
      'MCP_TYPE_UNSUPPORTED': (
        category: 'specification',
        message: 'Field type declares an unsupported transport value.',
      ),
      'MCP_TYPE_TRANSPORT_MISMATCH': (
        category: 'specification',
        message: 'Field type does not agree with the selected transport.',
      ),
      'MCP_FIELD_TRANSPORT_INAPPLICABLE': (
        category: 'specification',
        message: 'Field {field} is not applicable to the selected transport.',
      ),
      'MCP_PI_PROJECT_AUTH_FORBIDDEN': (
        category: 'security',
        message: 'Field auth is prohibited in the Pi project scope.',
      ),
      'UNKNOWN_FIELD': (
        category: 'product',
        message: 'Field {field} is not recognized by this profile.',
      ),
      'FIELD_TYPE': (
        category: 'specification',
        message: 'Field {field} has the wrong scalar type.',
      ),
      'FIELD_SHAPE': (
        category: 'specification',
        message: 'Field {field} has an invalid documented shape.',
      ),
      'FIELD_VALUE': (
        category: 'specification',
        message: 'Field {field} has an unsupported documented value.',
      ),
    };

/// One stable, value-free validation finding.
final class McpValidationDiagnostic {
  const McpValidationDiagnostic({required this.code, required this.field});

  final String code;
  final String field;

  String get escapedField => ValidationDiagnostics.escape(field);

  String get category => mcpValidationCodeTable[code]?.category ?? 'product';

  String get severity => 'error';

  String get message {
    final template =
        mcpValidationCodeTable[code]?.message ??
        'Field {field} has an invalid documented shape.';
    return template.replaceAll('{field}', escapedField);
  }

  String render() => ValidationDiagnostics.format(escapedField, code, message);

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'category': category,
    'severity': severity,
    'field': escapedField,
    'message': message,
  };
}

/// A completed, static, per-harness validation result.
final class McpValidationReport {
  McpValidationReport({
    required this.profile,
    required Map<String, Object?> baseline,
    required List<McpValidationDiagnostic> diagnostics,
    this.claim = mcpValidationClaim,
  }) : baseline = Map<String, Object?>.unmodifiable(baseline),
       diagnostics = _sortedDiagnostics(diagnostics);

  final String profile;
  final Map<String, Object?> baseline;
  final List<McpValidationDiagnostic> diagnostics;
  final String claim;

  bool get valid => diagnostics.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'valid': valid,
    'profile': profile,
    'baseline': baseline,
    'claim': claim,
    'diagnostics': <Object?>[
      for (final diagnostic in diagnostics) diagnostic.toJson(),
    ],
  };

  String renderText() {
    final buffer = StringBuffer()
      ..writeln('valid: $valid')
      ..writeln('profile: $profile')
      ..writeln('claim: $claim')
      ..writeln('baseline: ${jsonEncode(baseline)}')
      ..writeln('diagnostics:');
    if (diagnostics.isEmpty) {
      buffer.writeln('[]');
    } else {
      for (final diagnostic in diagnostics) {
        buffer.writeln(diagnostic.render());
      }
    }
    return buffer.toString();
  }
}

/// One strict Zema contract and its pinned documentation baseline.
final class McpValidationContract {
  McpValidationContract({
    required this.profile,
    required this.sources,
    required this.commonFields,
    required this.stdioFields,
    required this.httpFields,
    required this.stdioTypes,
    required this.httpTypes,
    required this.requiresHttpType,
    required this.schema,
  });

  final String profile;
  final Set<String> sources;
  final Set<String> commonFields;
  final Set<String> stdioFields;
  final Set<String> httpFields;
  final Set<String> stdioTypes;
  final Set<String> httpTypes;
  final bool requiresHttpType;
  final ZemaSchema<dynamic, Map<String, dynamic>> schema;

  Map<String, Object?> get baseline => <String, Object?>{
    'sources': _sorted(sources),
    'httpTypeRequired': requiresHttpType,
    'recognizedFields': <String, Object?>{
      'common': _sorted(commonFields),
      'stdio': _sorted(stdioFields),
      'http': _sorted(httpFields),
    },
    'supportedTypes': <String, Object?>{
      'stdio': _sorted(stdioTypes),
      'http': _sorted(httpTypes),
    },
  };
}

/// The shared, inert schema evaluator. [McpValidationService] owns the public
/// application seam; pack admission and conversion should call that service.
final class const McpValidation() {
  McpValidationReport validate({
    required McpHarness harness,
    required Map<String, Object?> fields,
    McpScope? scope,
  }) {
    final contract = _contracts[harness]!;
    final selection = _selectTransport(fields, contract);
    final diagnostics = <McpValidationDiagnostic>[
      ..._semanticDiagnostics(
        contract: contract,
        fields: fields,
        selection: selection,
      ),
      ..._shapeDiagnostics(contract.schema.safeParse(fields), selection),
    ];
    return McpValidationReport(
      profile: contract.profile,
      baseline: contract.baseline,
      diagnostics: diagnostics,
    );
  }
}

const Set<String> _claudeCommonFields = <String>{'type'};
const Set<String> _claudeStdioFields = <String>{'command', 'args', 'env'};
const Set<String> _claudeHttpFields = <String>{
  'url',
  'headers',
  'headersHelper',
  'oauth',
};
const Set<String> _claudeStdioTypes = <String>{'stdio'};
const Set<String> _claudeHttpTypes = <String>{'http', 'streamable-http', 'ws'};

const Set<String> _codexCommonFields = <String>{
  'type',
  'enabled',
  'required',
  'startup_readiness',
  'startup_timeout_sec',
  'startup_timeout_ms',
  'tool_timeout_sec',
  'enabled_tools',
  'disabled_tools',
  'default_tools_approval_mode',
  'tools',
  'mcp_oauth_credentials_store',
};
const Set<String> _codexStdioFields = <String>{
  'command',
  'args',
  'cwd',
  'env',
  'env_vars',
};
const Set<String> _codexHttpFields = <String>{
  'url',
  'auth',
  'bearer_token_env_var',
  'http_headers',
  'env_http_headers',
  'http_headers_helper',
  'environment_id',
  'oauth',
  'oauth_resource',
  'scopes',
};
const Set<String> _codexStdioTypes = <String>{'stdio'};
const Set<String> _codexHttpTypes = <String>{'http', 'streamable-http'};

const Set<String> _piCommonFields = <String>{
  'type',
  'enabled',
  'timeout',
  'description',
  'exposure',
  'toolExposure',
};
const Set<String> _piStdioFields = <String>{'command', 'args', 'env', 'cwd'};
const Set<String> _piHttpFields = <String>{'url', 'headers', 'oauth', 'auth'};
const Set<String> _piStdioTypes = <String>{'stdio'};
const Set<String> _piHttpTypes = <String>{'http', 'streamable-http'};

final ZemaSchema<dynamic, Map<String, dynamic>> _claudeSchema = _schemaFor(
  commonFields: _claudeCommonFields,
  stdioFields: _claudeStdioFields,
  httpFields: _claudeHttpFields,
  stdioTypes: _claudeStdioTypes,
  httpTypes: _claudeHttpTypes,
);
final ZemaSchema<dynamic, Map<String, dynamic>> _codexSchema = _schemaFor(
  commonFields: _codexCommonFields,
  stdioFields: _codexStdioFields,
  httpFields: _codexHttpFields,
  stdioTypes: _codexStdioTypes,
  httpTypes: _codexHttpTypes,
);
final ZemaSchema<dynamic, Map<String, dynamic>> _piSchema = _schemaFor(
  commonFields: _piCommonFields,
  stdioFields: _piStdioFields,
  httpFields: _piHttpFields,
  stdioTypes: _piStdioTypes,
  httpTypes: _piHttpTypes,
);

final Map<McpHarness, McpValidationContract> _contracts =
    <McpHarness, McpValidationContract>{
      McpHarness.claude: McpValidationContract(
        profile: 'mcp-claude-native-static-v1',
        sources: <String>{mcpClaudeBaseline, mcpParentConfigurationBaseline},
        commonFields: _claudeCommonFields,
        stdioFields: _claudeStdioFields,
        httpFields: _claudeHttpFields,
        stdioTypes: _claudeStdioTypes,
        httpTypes: _claudeHttpTypes,
        requiresHttpType: true,
        schema: _claudeSchema,
      ),
      McpHarness.codex: McpValidationContract(
        profile: 'mcp-codex-native-static-v1',
        sources: <String>{mcpCodexBaseline, mcpParentConfigurationBaseline},
        commonFields: _codexCommonFields,
        stdioFields: _codexStdioFields,
        httpFields: _codexHttpFields,
        stdioTypes: _codexStdioTypes,
        httpTypes: _codexHttpTypes,
        requiresHttpType: false,
        schema: _codexSchema,
      ),
      McpHarness.pi: McpValidationContract(
        profile: 'mcp-pi-native-static-v1',
        sources: <String>{mcpPiBaseline, mcpParentConfigurationBaseline},
        commonFields: _piCommonFields,
        stdioFields: _piStdioFields,
        httpFields: _piHttpFields,
        stdioTypes: _piStdioTypes,
        httpTypes: _piHttpTypes,
        requiresHttpType: false,
        schema: _piSchema,
      ),
    };

/// Builds one strict union per harness. `z.discriminatedUnion` is unavailable
/// in Zema 0.6.0, so two strict objects with literal type sets are combined
/// with a product-level transport refinement.
ZemaSchema<dynamic, Map<String, dynamic>> _schemaFor({
  required Set<String> commonFields,
  required Set<String> stdioFields,
  required Set<String> httpFields,
  required Set<String> stdioTypes,
  required Set<String> httpTypes,
}) {
  final stdio = z
      .object(
        _shapeFor(
          commonFields: commonFields,
          transportFields: stdioFields,
          typeValues: stdioTypes,
        ),
      )
      .makeStrict();
  final http = z
      .object(
        _shapeFor(
          commonFields: commonFields,
          transportFields: httpFields,
          typeValues: httpTypes,
        ),
      )
      .makeStrict();
  return z
      .union<Map<String, dynamic>>(<ZemaSchema<dynamic, Map<String, dynamic>>>[
        stdio,
        http,
      ])
      .refine(
        (map) {
          final Object? command = map['command'];
          final Object? url = map['url'];
          return (command != null) != (url != null);
        },
        code: 'MCP_TRANSPORT_REFINEMENT',
        message: 'The transport fields are inconsistent.',
      );
}

Map<String, ZemaSchema<dynamic, dynamic>> _shapeFor({
  required Set<String> commonFields,
  required Set<String> transportFields,
  required Set<String> typeValues,
}) {
  final shape = <String, ZemaSchema<dynamic, dynamic>>{};
  if (commonFields.contains('type')) {
    shape['type'] = _literalTypes(typeValues);
  }
  final fields = <String>{
    ...commonFields.where((field) => field != 'type'),
    ...transportFields,
  };
  for (final field in _sorted(fields)) {
    shape[field] = field == 'command' || field == 'url'
        ? z.string().min(1)
        : z.string().min(1).optional();
  }
  return shape;
}

ZemaSchema<dynamic, dynamic> _literalTypes(Set<String> values) =>
    z.union<String>(<ZemaSchema<dynamic, String>>[
      for (final value in _sorted(values)) z.literal(value),
    ]).optional();

List<String> _sorted(Set<String> values) =>
    List<String>.unmodifiable(values.toList()..sort());

final class _TransportSelection {
  const _TransportSelection({
    required this.transport,
    required this.conflict,
    required this.missing,
  });

  final McpTransport? transport;
  final bool conflict;
  final bool missing;
}

_TransportSelection _selectTransport(
  Map<String, Object?> fields,
  McpValidationContract contract,
) {
  final commandKey = fields.containsKey('command');
  final urlKey = fields.containsKey('url');
  final Object? rawType = fields['type'];
  final String? type = rawType is String ? rawType : null;
  McpTransport? typeTransport;
  if (type != null) {
    if (contract.stdioTypes.contains(type)) {
      typeTransport = McpTransport.stdio;
    } else if (contract.httpTypes.contains(type)) {
      typeTransport = McpTransport.http;
    }
  }
  final conflict = commandKey && urlKey;
  final missing = !commandKey && !urlKey;
  McpTransport? transport;
  if (conflict) {
    transport =
        typeTransport ?? (commandKey ? McpTransport.stdio : McpTransport.http);
  } else if (commandKey) {
    transport = McpTransport.stdio;
  } else if (urlKey) {
    transport = McpTransport.http;
  } else {
    transport = typeTransport;
  }
  return _TransportSelection(
    transport: transport,
    conflict: conflict,
    missing: missing,
  );
}

List<McpValidationDiagnostic> _semanticDiagnostics({
  required McpValidationContract contract,
  required Map<String, Object?> fields,
  required _TransportSelection selection,
}) {
  final diagnostics = <McpValidationDiagnostic>[];
  void add(String code, String field) =>
      diagnostics.add(McpValidationDiagnostic(code: code, field: field));

  if (selection.missing) {
    add(
      'MCP_TRANSPORT_MISSING',
      ValidationDiagnostics.path(<Object?>['transport']),
    );
  }
  if (selection.conflict) {
    add(
      'MCP_TRANSPORT_CONFLICT',
      ValidationDiagnostics.path(<Object?>['transport']),
    );
  }

  final typeField = ValidationDiagnostics.key('type');
  final Object? rawType = fields['type'];
  if (fields.containsKey('type') && rawType is! String) {
    add('FIELD_TYPE', typeField);
  } else if (rawType is String) {
    final supported = <String>{...contract.stdioTypes, ...contract.httpTypes};
    if (!supported.contains(rawType)) {
      add('MCP_TYPE_UNSUPPORTED', typeField);
    } else if (selection.transport == McpTransport.stdio &&
        !contract.stdioTypes.contains(rawType)) {
      add('MCP_TYPE_TRANSPORT_MISMATCH', typeField);
    } else if (selection.transport == McpTransport.http &&
        !contract.httpTypes.contains(rawType)) {
      add('MCP_TYPE_TRANSPORT_MISMATCH', typeField);
    }
  } else if (selection.transport == McpTransport.http &&
      contract.requiresHttpType) {
    add('MCP_TYPE_REQUIRED', typeField);
  }

  final current = <String>{...contract.commonFields};
  final Set<String> other;
  if (selection.transport == McpTransport.stdio) {
    current.addAll(contract.stdioFields);
    other = contract.httpFields;
  } else if (selection.transport == McpTransport.http) {
    current.addAll(contract.httpFields);
    other = contract.stdioFields;
  } else {
    other = const <String>{};
  }
  final all = <String>{
    ...contract.commonFields,
    ...contract.stdioFields,
    ...contract.httpFields,
  };
  for (final key in _sorted(Set<String>.from(fields.keys))) {
    if (current.contains(key)) continue;
    final field = ValidationDiagnostics.key(key);
    if (other.contains(key)) {
      add('MCP_FIELD_TRANSPORT_INAPPLICABLE', field);
    } else if (!all.contains(key)) {
      add('UNKNOWN_FIELD', field);
    }
  }
  return diagnostics;
}

List<McpValidationDiagnostic> _shapeDiagnostics(
  ZemaResult<Map<String, dynamic>> result,
  _TransportSelection selection,
) {
  if (result.isSuccess) return const <McpValidationDiagnostic>[];
  final diagnostics = <McpValidationDiagnostic>[];
  for (final issue in _selectedIssues(result.errors, selection.transport)) {
    if (_skipShapeIssue(issue, selection)) continue;
    diagnostics.add(_diagnosticForIssue(issue));
  }
  return diagnostics;
}

List<ZemaIssue> _selectedIssues(
  Iterable<ZemaIssue> errors,
  McpTransport? transport,
) {
  if (transport == null) return const <ZemaIssue>[];
  for (final error in errors) {
    final Object? unionErrors = error.meta?['unionErrors'];
    if (error.code == 'invalid_union' &&
        unionErrors is List<Object?> &&
        unionErrors.length >= 2) {
      final Object? branch =
          unionErrors[transport == McpTransport.stdio ? 0 : 1];
      if (branch is List<Object?>) {
        final branchIssues = <ZemaIssue>[];
        for (final Object? item in branch) {
          if (item is ZemaIssue) branchIssues.add(item);
        }
        return _flattenIssues(branchIssues);
      }
    }
  }
  return _flattenIssues(errors);
}

bool _skipShapeIssue(ZemaIssue issue, _TransportSelection selection) {
  if (issue.path.isEmpty) return true;
  final Object first = issue.path.first;
  if (first is String && first == 'type') return true;
  if (issue.code == 'unknown_key' && issue.path.length == 1) return true;
  if (issue.code == 'invalid_union' ||
      issue.code == 'MCP_TRANSPORT_REFINEMENT') {
    return true;
  }
  if (selection.missing &&
      issue.code == 'invalid_type' &&
      (first == 'command' || first == 'url')) {
    return true;
  }
  return false;
}

List<McpValidationDiagnostic> _sortedDiagnostics(
  Iterable<McpValidationDiagnostic> diagnostics,
) {
  final seen = <String>{};
  final result = <McpValidationDiagnostic>[];
  for (final diagnostic in diagnostics) {
    if (seen.add('${diagnostic.code}|${diagnostic.field}')) {
      result.add(diagnostic);
    }
  }
  result.sort((a, b) {
    final field = a.field.compareTo(b.field);
    if (field != 0) return field;
    final code = a.code.compareTo(b.code);
    if (code != 0) return code;
    return a.message.compareTo(b.message);
  });
  return List<McpValidationDiagnostic>.unmodifiable(result);
}

List<ZemaIssue> _flattenIssues(Iterable<ZemaIssue> issues) {
  final result = <ZemaIssue>[];
  void visit(ZemaIssue issue) {
    final Object? unionErrors = issue.meta?['unionErrors'];
    if (issue.code == 'invalid_union' && unionErrors is List<Object?>) {
      for (final Object? branch in unionErrors) {
        if (branch is List<Object?>) {
          for (final Object? nested in branch) {
            if (nested is ZemaIssue) {
              visit(nested.prependPath(issue.path));
            }
          }
        }
      }
      return;
    }
    result.add(issue);
  }

  for (final issue in issues) {
    visit(issue);
  }
  return result;
}

McpValidationDiagnostic _diagnosticForIssue(ZemaIssue issue) =>
    McpValidationDiagnostic(
      code: _codeForIssue(issue),
      field: _fieldForIssue(issue),
    );

String _codeForIssue(ZemaIssue issue) => switch (issue.code) {
  'unknown_key' => 'UNKNOWN_FIELD',
  'invalid_type' => 'FIELD_TYPE',
  'too_short' ||
  'too_long' ||
  'invalid_literal' ||
  'invalid_enum' ||
  'too_small' ||
  'too_big' => 'FIELD_VALUE',
  'MCP_TRANSPORT_REFINEMENT' => 'MCP_TRANSPORT_REFINEMENT',
  'invalid_union' => 'MCP_TRANSPORT_REFINEMENT',
  _ => 'FIELD_SHAPE',
};

String _fieldForIssue(ZemaIssue issue) {
  final path = issue.path;
  if (path.isEmpty) return 'registration';
  if (path.length == 1) {
    final Object first = path.first;
    if (first is String) {
      return issue.code == 'unknown_key'
          ? ValidationDiagnostics.key(first)
          : ValidationDiagnostics.path(<Object?>[first]);
    }
  }
  return ValidationDiagnostics.path(path);
}
