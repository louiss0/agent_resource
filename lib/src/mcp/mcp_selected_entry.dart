import 'mcp_redaction.dart';
import 'mcp_types.dart';

/// One observed or selected MCP registration, reusable by later mutation
/// waves (register/adopt/convert).
///
/// [rawFields] preserves the native shape for those waves, while
/// [redactedFields] and [toJson] are always safe to disclose. The identity,
/// digest and ownership status make this the single cohesive seam for
/// building on a discovered entry without a rewrite.
final class McpSelectedEntry {
  const McpSelectedEntry({
    required this.identity,
    required this.rawFields,
    required this.digest,
    required this.ownership,
    this.present = true,
    this.transport,
  });

  final McpRegistrationIdentity identity;

  /// The unredacted native field shape, retained for later mutation waves.
  final Map<String, Object?> rawFields;

  /// Baseline digest of the native entry (deterministic over canonical JSON).
  final String digest;

  final McpOwnership ownership;

  /// False when a ledger record exists but the native entry is missing.
  final bool present;

  final McpTransport? transport;

  McpHarness get harness => identity.harness;
  McpScope get scope => identity.scope;
  String get location => identity.location;
  String get name => identity.name;

  Map<String, Object?> get redactedFields => McpRedaction.redactMap(rawFields);

  /// A redacted, disclosure-safe view. Digests are management-internal
  /// evidence and are surfaced only when [discloseDigest] is requested.
  Map<String, Object?> toJson({bool discloseDigest = false}) =>
      <String, Object?>{
        'harness': harness.wireName,
        'scope': scope.wireName,
        'location': location,
        'name': name,
        'transport': transport?.wireName,
        'ownership': ownership.wireName,
        'present': present,
        if (discloseDigest) 'digest': digest,
        'fields': redactedFields,
      };
}
