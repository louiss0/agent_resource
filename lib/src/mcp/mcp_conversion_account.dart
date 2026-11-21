import '../validation/validation_diagnostics.dart';

/// The closed outcome vocabulary of one MCP conversion field account
/// (story 30). Wire names are stable and appear in both text and JSON.
enum McpFieldOutcome {
  represented('represented'),
  altered('altered'),
  omittedAfterReview('omitted-after-review'),
  refused('refused');

  const McpFieldOutcome(this.wireName);

  final String wireName;

  String toJson() => wireName;
}

/// One deterministic field account row, mirroring the agent conversion
/// `_field` shape with an additional value-free reason. No source or target
/// value is ever included in an account row.
final class McpConversionAccount {
  const McpConversionAccount({
    required this.sourcePath,
    required this.targetPath,
    required this.sourceProfile,
    required this.outcome,
    required this.decision,
    required this.reason,
  });

  final String? sourcePath;
  final String? targetPath;
  final String sourceProfile;
  final McpFieldOutcome outcome;
  final String? decision;
  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourcePath': sourcePath,
    'targetPath': targetPath,
    'sourceProfile': sourceProfile,
    'outcome': outcome.toJson(),
    'decision': decision,
    'reason': reason,
  };
}

/// Stable, value-free MCP conversion diagnostic codes.
typedef McpConversionCodeDefinition = ({
  String category,
  String severity,
  String message,
});

const Map<String, McpConversionCodeDefinition>
mcpConversionCodeTable = <String, McpConversionCodeDefinition>{
  'MCP_CONVERSION_UNREPRESENTABLE': (
    category: 'product',
    severity: 'error',
    message: 'Field {field} cannot be represented by the target harness.',
  ),
  'MCP_CONVERSION_DECISION_REQUIRED': (
    category: 'product',
    severity: 'error',
    message: 'Field {field} requires an explicit, reviewed omission decision.',
  ),
  'MCP_CONVERSION_CREDENTIAL_POLICY': (
    category: 'security',
    severity: 'info',
    message:
        'Credential and OAuth state fields are never copied during conversion.',
  ),
  'MCP_CONVERSION_SCOPE_CHANGE': (
    category: 'product',
    severity: 'info',
    message: 'The target scope differs from the preserved source scope.',
  ),
  'MCP_CONVERSION_STATIC_REVIEW_ONLY': (
    category: 'product',
    severity: 'info',
    message:
        'Conversion changes configuration only; no server is launched, '
        'connected to, or authenticated.',
  ),
};

/// One stable, value-free conversion diagnostic. Only escaped field names
/// and fixed message templates are disclosed.
final class McpConversionDiagnostic {
  const McpConversionDiagnostic({required this.code, required this.field});

  final String code;
  final String field;

  String get escapedField => ValidationDiagnostics.escape(field);

  String get category => mcpConversionCodeTable[code]?.category ?? 'product';

  String get severity => mcpConversionCodeTable[code]?.severity ?? 'error';

  String get message {
    final template =
        mcpConversionCodeTable[code]?.message ?? 'Conversion was refused.';
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

/// Source fields that carry OAuth state, provider credential selection or
/// stored credential references. They are never copied to a target harness.
const Set<String> mcpCredentialPolicyFields = <String>{
  'oauth',
  'auth',
  'clientId',
  'clientSecret',
  'client_id',
  'client_secret',
  'callbackUrl',
  'callback_url',
  'mcp_oauth_credentials_store',
  'bearer_token_env_var',
  'oauth_resource',
  'scopes',
  'http_headers_helper',
  'headersHelper',
  'authProviderType',
};

/// Codex runtime controls with no equivalent in Claude or native Pi. The
/// fields are included in a public, value-free refusal account instead of
/// being approximated or silently dropped.
const Set<String> mcpCodexRuntimeControls = <String>{
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
  'environment_id',
};

/// Native Pi runtime controls with no equivalent in Claude or Codex.
const Set<String> mcpPiRuntimeControls = <String>{
  'enabled',
  'timeout',
  'description',
  'exposure',
  'toolExposure',
};

/// Antigravity runtime controls with no equivalent in the other harnesses.
/// A different `tools` shape is still reviewed as a loss, not approximated.
const Set<String> mcpAntigravityRuntimeControls = <String>{
  'disabled',
  'enabledTools',
  'disabledTools',
  'tools',
  'timeoutSeconds',
};
