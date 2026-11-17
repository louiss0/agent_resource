import 'dart:convert';

import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart';

import '../services/parent_config_service.dart';
import 'mcp_native.dart' show readMcpNativeText;
import 'mcp_types.dart';

const int mcpRegistrationLedgerSchemaVersion = 1;
const String mcpRegistrationLedgerFileName = 'mcp-registrations.json';

/// One ownership record: the four-part identity plus a baseline digest.
final class McpRegistrationRecord {
  const McpRegistrationRecord({
    required this.identity,
    required this.baselineDigest,
  });

  final McpRegistrationIdentity identity;
  final String baselineDigest;

  Map<String, Object?> toJson() => <String, Object?>{
    ...identity.toJson(),
    'baselineDigest': baselineDigest,
  };

  static McpRegistrationRecord fromJson(Map<String, Object?> json) {
    final digest = json['baselineDigest'];
    if (digest is! String) {
      throw const FormatException('Invalid MCP registration record digest.');
    }
    return McpRegistrationRecord(
      identity: McpRegistrationIdentity.fromJson(json),
      baselineDigest: digest,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is McpRegistrationRecord &&
      other.identity == identity &&
      other.baselineDigest == baselineDigest;

  @override
  int get hashCode => Object.hash(identity, baselineDigest);
}

/// The MCP ownership ledger at `<stateRoot>/mcp-registrations.json`
/// (schemaVersion 1).
///
/// Read-only discovery uses [read]; later mutation waves use [upsert] for
/// adoption, drift, backups and transactions. No marker is ever written into
/// a native harness file: writes are confined to the Agent Resource state
/// root.
final class McpOwnershipLedger {
  McpOwnershipLedger({required this.fs, required this.stateRoot});

  final fslib.FileSystem fs;
  final String stateRoot;

  String get path => fs.path.join(stateRoot, mcpRegistrationLedgerFileName);

  /// Reads records keyed by [McpRegistrationIdentity.storageKey]. A missing
  /// ledger yields an empty map. Malformed state is an operational failure.
  Map<String, McpRegistrationRecord> read() {
    final text = readMcpNativeText(fs, path);
    if (text == null) return <String, McpRegistrationRecord>{};
    final Map<String, Object?> document;
    try {
      document = parseStrictJsonObject(text);
    } on FormatException {
      throw MambaException(
        'The MCP registration ledger is not valid strict JSON.',
        exitCode: 1,
      );
    }
    if (document['schemaVersion'] != mcpRegistrationLedgerSchemaVersion) {
      throw MambaException(
        'Unsupported MCP registration ledger schema version.',
        exitCode: 1,
      );
    }
    final records = document['records'];
    if (records is! List) {
      throw MambaException(
        'The MCP registration ledger records must be a list.',
        exitCode: 1,
      );
    }
    final result = <String, McpRegistrationRecord>{};
    for (final item in records) {
      if (item is! Map) {
        throw MambaException(
          'Invalid MCP registration ledger record.',
          exitCode: 1,
        );
      }
      final McpRegistrationRecord record;
      try {
        record = McpRegistrationRecord.fromJson(
          Map<String, Object?>.from(item),
        );
      } on FormatException {
        throw MambaException(
          'Invalid MCP registration ledger record.',
          exitCode: 1,
        );
      }
      final key = record.identity.storageKey;
      if (result.containsKey(key)) {
        throw MambaException(
          'Duplicate MCP registration ledger identity.',
          exitCode: 1,
        );
      }
      result[key] = record;
    }
    return result;
  }

  /// Inserts or replaces one record, keyed by its four-part identity. Writes
  /// only under [stateRoot], never into a native harness file.
  void upsert(McpRegistrationRecord record) {
    final records = read();
    records[record.identity.storageKey] = record;
    final keys = records.keys.toList()..sort();
    final document = <String, Object?>{
      'schemaVersion': mcpRegistrationLedgerSchemaVersion,
      'records': <Object?>[for (final key in keys) records[key]!.toJson()],
    };
    fs.directory(stateRoot).createSync(recursive: true);
    fs.file(path).writeAsStringSync(jsonEncode(document));
  }
}
