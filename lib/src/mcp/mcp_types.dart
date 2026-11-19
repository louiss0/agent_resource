import 'dart:convert';

/// The consuming harness whose native configuration declares an MCP server.
enum McpHarness {
  claude('claude'),
  codex('codex'),
  pi('pi'),
  antigravity('antigravity');

  const McpHarness(this.wireName);

  /// Stable wire name used in envelopes and management state.
  final String wireName;

  String toJson() => wireName;

  static McpHarness fromWire(String value) => values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw FormatException('Unknown MCP harness: $value'),
  );
}

/// The native scope a registration belongs to.
enum McpScope {
  project('project'),
  user('user'),
  local('local');

  const McpScope(this.wireName);

  /// Stable wire name used in envelopes and management state.
  final String wireName;

  String toJson() => wireName;

  static McpScope fromWire(String value) => values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw FormatException('Unknown MCP scope: $value'),
  );
}

/// The declared transport of a registration.
enum McpTransport {
  stdio('stdio'),
  http('http');

  const McpTransport(this.wireName);

  /// Stable wire name used in envelopes and management state.
  final String wireName;

  String toJson() => wireName;

  static McpTransport fromWire(String value) => values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw FormatException('Unknown MCP transport: $value'),
  );
}

/// Ownership classification of an observed registration.
enum McpOwnership {
  managed('managed'),
  unmanaged('unmanaged'),
  ownershipUnverified('ownership-unverified');

  const McpOwnership(this.wireName);

  /// Stable wire name used in envelopes and management state.
  final String wireName;

  String toJson() => wireName;

  static McpOwnership fromWire(String value) => values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw FormatException('Unknown MCP ownership: $value'),
  );
}

/// Output rendering for MCP read-only commands.
enum McpOutputFormat {
  text('text'),
  json('json');

  const McpOutputFormat(this.wireName);

  /// Stable wire name used in envelopes and management state.
  final String wireName;

  String toJson() => wireName;

  static McpOutputFormat fromWire(String value) => values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw FormatException('Unknown MCP output format: $value'),
  );
}

/// The four-part identity of one managed MCP server entry (story 45):
/// harness, scope, native configuration location, and server name.
///
/// Ownership follows the entry rather than a file or a raw name. This value
/// type is the stable key shared with later adoption, mutation and conversion
/// waves.
final class McpRegistrationIdentity {
  const McpRegistrationIdentity({
    required this.harness,
    required this.scope,
    required this.location,
    required this.name,
  });

  final McpHarness harness;
  final McpScope scope;

  /// Absolute path of the native configuration file that declares the entry.
  final String location;

  /// The server name.
  final String name;

  /// A deterministic key used to index ownership records.
  String get storageKey =>
      jsonEncode(<String>[harness.wireName, scope.wireName, location, name]);

  Map<String, Object?> toJson() => <String, Object?>{
    'harness': harness.wireName,
    'scope': scope.wireName,
    'location': location,
    'name': name,
  };

  static McpRegistrationIdentity fromJson(Map<String, Object?> json) {
    _requireKeys(json);
    return McpRegistrationIdentity(
      harness: McpHarness.fromWire(_string(json, 'harness')),
      scope: McpScope.fromWire(_string(json, 'scope')),
      location: _string(json, 'location'),
      name: _string(json, 'name'),
    );
  }

  static void _requireKeys(Map<String, Object?> json) {
    for (final key in const <String>['harness', 'scope', 'location', 'name']) {
      if (!json.containsKey(key)) {
        throw const FormatException('Invalid MCP registration identity.');
      }
    }
  }

  static String _string(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Invalid MCP registration identity $key.');
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is McpRegistrationIdentity &&
      other.harness == harness &&
      other.scope == scope &&
      other.location == location &&
      other.name == name;

  @override
  int get hashCode => Object.hash(harness, scope, location, name);

  @override
  String toString() => storageKey;
}
