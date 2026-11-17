import '../validation/validation_diagnostics.dart';

/// Stable, value-free diagnostic codes for pack MCP admission
/// (stories 34-38). Messages are drawn from fixed tables and never echo a
/// received field value or credential.
const String mcpPackNameInvalid = 'MCP_NAME_INVALID';
const String mcpPackUnknownField = 'MCP_UNKNOWN_FIELD';
const String mcpPackProviderAuthForbidden = 'MCP_PROVIDER_AUTH_FORBIDDEN';
const String mcpPackLiteralSecret = 'MCP_LITERAL_SECRET_REFUSED';
const String mcpPackTargetUnsupported = 'MCP_TARGET_UNSUPPORTED';
const String mcpPackCollisionReviewRequired = 'MCP_COLLISION_REVIEW_REQUIRED';

/// One inline MCP server declaration carried by a pack catalog.
///
/// [name] is the native server name and [fields] are the raw native
/// registration fields (validated per requested target harness). The fields
/// may carry credential *references* but never literal secrets; they must
/// never be printed verbatim.
final class PackMcpDeclaration {
  PackMcpDeclaration({required this.name, required Map<String, Object?> fields})
    : fields = Map<String, Object?>.unmodifiable(fields);

  final String name;
  final Map<String, Object?> fields;
}

/// The pinned, closed set of native MCP field names a pack declaration may
/// carry. This mirrors the union of the Claude, Codex and Pi static field
/// matrices in `lib/src/mcp/mcp_validation.dart`; unknown fields are errors.
final class PackMcpFields {
  const PackMcpFields._();

  static const Set<String> recognized = <String>{
    // Common.
    'type',
    'enabled',
    'required',
    'description',
    // stdio.
    'command',
    'args',
    'cwd',
    'env',
    'env_vars',
    // http.
    'url',
    'headers',
    'headersHelper',
    'http_headers',
    'env_http_headers',
    'http_headers_helper',
    'bearer_token_env_var',
    'environment_id',
    'auth',
    'oauth',
    'oauth_resource',
    'scopes',
    // Codex runtime controls.
    'startup_readiness',
    'startup_timeout_sec',
    'startup_timeout_ms',
    'tool_timeout_sec',
    'enabled_tools',
    'disabled_tools',
    'default_tools_approval_mode',
    'tools',
    'mcp_oauth_credentials_store',
    // Pi runtime controls.
    'timeout',
    'exposure',
    'toolExposure',
  };

  /// Fields that are references by construction: they name a variable or a
  /// header-to-variable mapping rather than carrying a credential value.
  /// Their values are never treated as literal secrets.
  static const Set<String> referenceOnlyFields = <String>{
    'bearer_token_env_var',
    'env_vars',
    'env_http_headers',
  };

  /// Fields whose values occupy credential-bearing positions: every literal
  /// inside one is credential material whatever its nested key is called.
  static const Set<String> sensitiveContainers = <String>{
    'env',
    'headers',
    'http_headers',
    'oauth',
    'auth',
  };

  /// Nested keys that carry credential material even outside a sensitive
  /// container. A public identifier such as an OAuth `clientId` is not one.
  static const Set<String> _sensitiveWords = <String>{
    'token',
    'secret',
    'password',
    'apikey',
    'authorization',
    'credential',
    'bearer',
    'privatekey',
  };

  static final RegExp _embeddedReference = RegExp(r'\$\{[^}]+\}');
  static final RegExp _notAlphaNumeric = RegExp(r'[^a-z0-9]');
  static final RegExp _validName = RegExp(r'^[A-Za-z0-9_-]+$');

  /// A value names a variable or command rather than a literal secret. Whole
  /// and embedded `${VAR}` / `${VAR:-default}` expansions and `!command`
  /// substitutions are references; a plain literal is not.
  static bool isReference(String value) =>
      _embeddedReference.hasMatch(value) || value.trimLeft().startsWith('!');

  static bool isSensitiveKey(String key) {
    final normalized = key.toLowerCase().replaceAll(_notAlphaNumeric, '');
    return _sensitiveWords.any(
      (word) => normalized.contains(word.replaceAll('_', '')),
    );
  }

  static bool validName(String name) => _validName.hasMatch(name);

  /// Provider-credential selection: Pi `auth = { provider = "..." }`.
  static bool isProviderAuth(Object? value) =>
      value is Map && value.containsKey('provider');
}

/// One value-free admission finding: the offending native field and a stable
/// code. No received value is ever carried.
final class PackMcpFinding {
  const PackMcpFinding(this.field, this.code);

  final String field;
  final String code;
}

/// The shared, inert admission rule for an inline pack MCP declaration.
///
/// It permits credential references and refuses literal secrets,
/// provider-credential selection and unknown fields. Per-harness shape and
/// transport correctness is a separate check through McpValidationService.
final class PackMcpAdmission {
  const PackMcpAdmission._();

  /// Aggregated, value-free admission findings for one declaration's native
  /// fields (the catalog `name` key is not a native field).
  static List<PackMcpFinding> findings(Map<String, Object?> fields) {
    final result = <PackMcpFinding>[];
    for (final entry in fields.entries) {
      final key = entry.key;
      final value = entry.value;
      if (!PackMcpFields.recognized.contains(key)) {
        result.add(PackMcpFinding(key, mcpPackUnknownField));
        continue;
      }
      if (PackMcpFields.referenceOnlyFields.contains(key)) continue;
      if (key == 'auth' && PackMcpFields.isProviderAuth(value)) {
        result.add(PackMcpFinding(key, mcpPackProviderAuthForbidden));
        continue;
      }
      // Values in a credential-bearing container are sensitive by position,
      // regardless of the nested key. Elsewhere only explicitly sensitive
      // nested keys (token, secret, authorization, ...) are inspected.
      final sensitive = PackMcpFields.sensitiveContainers.contains(key);
      if (sensitive || value is Map) {
        if (_hasLiteral(value, sensitive)) {
          result.add(PackMcpFinding(key, mcpPackLiteralSecret));
        }
      }
    }
    return List<PackMcpFinding>.unmodifiable(result);
  }

  /// Whether [value] carries a literal string in a credential position.
  /// References (`${VAR}` and `!command`) are never literal secrets; their
  /// received text is never retained in a finding or a diagnostic.
  static bool _hasLiteral(Object? value, bool sensitive) {
    if (value is String) {
      return sensitive && !PackMcpFields.isReference(value);
    }
    if (value is Map) {
      return value.entries.any(
        (entry) => _hasLiteral(
          entry.value,
          sensitive || PackMcpFields.isSensitiveKey(entry.key.toString()),
        ),
      );
    }
    if (value is List) {
      return value.any((item) => _hasLiteral(item, sensitive));
    }
    return false;
  }

  /// A fixed, value-free message for one admission code. Only the escaped
  /// field name is echoed; no received value is included.
  static String message(String code, String field) {
    final escaped = ValidationDiagnostics.escape(field);
    return switch (code) {
      mcpPackNameInvalid => 'must be a non-empty server name',
      mcpPackUnknownField =>
        'field $escaped is not a recognized MCP native field',
      mcpPackProviderAuthForbidden =>
        'provider-credential selection in $escaped is refused',
      mcpPackLiteralSecret =>
        'credential values in $escaped must be environment-variable or '
            'command references; literal secrets are refused',
      _ => 'field $escaped is not admitted',
    };
  }
}
