/// Central, value-free redaction for MCP reports (stories 4, 42, 43).
///
/// Literal credential values under credential-bearing keys are never
/// disclosed. Environment/command references and sanitized endpoints are.
/// Redaction is idempotent and applied centrally by [McpEnvelope] and by the
/// selected-entry abstraction, so no caller can accidentally print a secret.
final class McpRedaction {
  const McpRedaction._();

  static const String redactionPlaceholder = '<redacted>';

  /// Normalized keys whose values are literal credential material. A map or
  /// list under such a key is redacted wholesale; every nested scalar becomes
  /// the placeholder unless it is a reference.
  static const Set<String> _sensitiveKeys = <String>{
    'env',
    'headers',
    'httpheaders',
    'envhttpheaders',
    'oauth',
    'auth',
    'token',
    'bearer',
    'bearertoken',
    'clientsecret',
    'clientid',
    'clientkey',
    'password',
    'secret',
    'apikey',
    'authorization',
    'credential',
    'credentials',
    'accesstoken',
    'refreshtoken',
    'privatekey',
  };

  /// Normalized endpoint keys: endpoints are disclosed only in sanitized
  /// form (scheme, host, optional port and path), never with credentials,
  /// userinfo, query strings or fragments.
  static const Set<String> _endpointKeys = <String>{
    'url',
    'endpoint',
    'serverurl',
    'baseurl',
    'uri',
    'authservermetadataurl',
    'callbackurl',
    'oauthresource',
  };

  static final RegExp _notAlphaNumeric = RegExp(r'[^a-z0-9]');
  static final RegExp _wholeReference = RegExp(r'^\$\{[^}]+\}$');
  static final RegExp _commandReference = RegExp(r'^!.*$');

  static String _normalize(String key) =>
      key.toLowerCase().replaceAll(_notAlphaNumeric, '');

  static bool _isSensitive(String key) =>
      _sensitiveKeys.contains(_normalize(key));

  static bool _isEndpoint(String key) =>
      _endpointKeys.contains(_normalize(key));

  /// A reference names a variable or command rather than a literal secret.
  /// Only whole-value `${VAR}`, `${VAR:-default}` and `!command` substitutions
  /// are treated as references so a literal that merely resembles a name is
  /// never disclosed by mistake.
  static bool isReference(String value) {
    final trimmed = value.trim();
    return _wholeReference.hasMatch(trimmed) ||
        _commandReference.hasMatch(trimmed);
  }

  /// Redact an entire credential-bearing subtree.
  static Object? redactDeep(Object? value) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): redactDeep(entry.value),
      };
    }
    if (value is List) {
      return <Object?>[for (final item in value) redactDeep(item)];
    }
    if (value is String && isReference(value)) return value;
    return redactionPlaceholder;
  }

  /// Redact an arbitrary report value. Maps are walked key-by-key so nested
  /// credential fields are caught even inside `mcpServers.<name>` objects.
  static Object? redact(
    Object? value, {
    String? key,
    bool sensitiveContext = false,
  }) {
    final sensitive = sensitiveContext || (key != null && _isSensitive(key));
    final endpoint = key != null && _isEndpoint(key);
    if (value is Map) {
      if (sensitive) return redactDeep(value);
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): redact(entry.value, key: entry.key.toString()),
      };
    }
    if (value is List) {
      if (sensitive) return redactDeep(value);
      return <Object?>[for (final item in value) redact(item)];
    }
    if (sensitive) {
      return value is String && isReference(value)
          ? value
          : redactionPlaceholder;
    }
    if (endpoint && value is String) return sanitizeEndpoint(value);
    return value;
  }

  static Map<String, Object?> redactMap(Map<String, Object?> data) =>
      redact(data) as Map<String, Object?>;

  /// Keep scheme, host, optional port and path; drop userinfo, query and
  /// fragment so embedded credentials or tokens are never disclosed.
  static String sanitizeEndpoint(Object? value) {
    if (value is! String) return redactionPlaceholder;
    if (isReference(value)) return value;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return redactionPlaceholder;
    }
    final buffer = StringBuffer()
      ..write(uri.scheme)
      ..write('://')
      ..write(uri.host);
    if (uri.hasPort) buffer.write(':${uri.port}');
    final path = uri.path;
    if (path.isNotEmpty && path != '/') buffer.write(path);
    return buffer.toString();
  }
}
