import 'dart:convert';

import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart';

import '../conversion/conversion_evidence.dart'
    show ConversionIdentity, conversionEvidenceSchemaVersion;
import '../services/parent_config_service.dart' show parseStrictJsonObject;
import 'mcp_native.dart' show mcpCanonicalDigest, readMcpNativeText;
import 'mcp_types.dart' show McpRegistrationIdentity;

const int mcpConversionLineageSchemaVersion = 1;
const String mcpConversionLineageFileName = 'mcp-conversion-lineage.json';

/// One MCP conversion lineage record. It uses the repository conversion
/// identity vocabulary (`lineageId`, `convertedFromId`) and never carries a
/// credential value. Source and target are four-part registration identities.
final class McpConversionLineageRecord {
  const McpConversionLineageRecord({
    required this.identity,
    required this.sourceIdentity,
    required this.targetIdentity,
    required this.planId,
  });

  final ConversionIdentity identity;
  final McpRegistrationIdentity sourceIdentity;
  final McpRegistrationIdentity targetIdentity;
  final String planId;

  Map<String, Object?> toJson() => <String, Object?>{
    'lineageId': identity.lineageId,
    'convertedFromId': identity.convertedFromId,
    'sourceIdentity': sourceIdentity.toJson(),
    'targetIdentity': targetIdentity.toJson(),
    'planId': planId,
  };

  static McpConversionLineageRecord fromJson(Map<String, Object?> json) {
    final lineageId = json['lineageId'];
    final convertedFromId = json['convertedFromId'];
    final planId = json['planId'];
    final source = json['sourceIdentity'];
    final target = json['targetIdentity'];
    if (lineageId is! String ||
        convertedFromId is! String ||
        planId is! String ||
        source is! Map ||
        target is! Map) {
      throw const FormatException('Invalid MCP conversion lineage record.');
    }
    return McpConversionLineageRecord(
      identity: ConversionIdentity(
        lineageId: lineageId,
        convertedFromId: convertedFromId,
      ),
      sourceIdentity: McpRegistrationIdentity.fromJson(
        Map<String, Object?>.from(source),
      ),
      targetIdentity: McpRegistrationIdentity.fromJson(
        Map<String, Object?>.from(target),
      ),
      planId: planId,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is McpConversionLineageRecord &&
      other.identity.lineageId == identity.lineageId &&
      other.identity.convertedFromId == identity.convertedFromId &&
      other.sourceIdentity == sourceIdentity &&
      other.targetIdentity == targetIdentity &&
      other.planId == planId;

  @override
  int get hashCode =>
      Object.hash(identity.lineageId, sourceIdentity, targetIdentity, planId);
}

/// Deterministic lineage identity for one reviewed MCP conversion. A fresh
/// plan identity yields a fresh lineage; re-applying the same reviewed plan
/// to the same source and target is idempotent.
String mcpConversionLineageId({
  required McpRegistrationIdentity source,
  required McpRegistrationIdentity target,
  required String planId,
}) =>
    'mcp-lineage-${mcpCanonicalDigest(<String, Object?>{'schemaVersion': conversionEvidenceSchemaVersion, 'source': source.storageKey, 'target': target.storageKey, 'planId': planId})}';

/// Local protected state for MCP conversion lineage. Writes are confined to
/// the Agent Resource state root; no native harness file is touched.
final class McpConversionLineageStore {
  const McpConversionLineageStore({required this.fs, required this.stateRoot});

  final fslib.FileSystem fs;
  final String stateRoot;

  String get path => fs.path.join(stateRoot, mcpConversionLineageFileName);

  List<McpConversionLineageRecord> read() {
    final text = readMcpNativeText(fs, path);
    if (text == null) return <McpConversionLineageRecord>[];
    final Map<String, Object?> document;
    try {
      document = parseStrictJsonObject(text);
    } on FormatException {
      throw MambaException(
        'The MCP conversion lineage state is not valid strict JSON.',
        exitCode: 1,
      );
    }
    if (document['schemaVersion'] != mcpConversionLineageSchemaVersion) {
      throw MambaException(
        'Unsupported MCP conversion lineage schema version.',
        exitCode: 1,
      );
    }
    final records = document['records'];
    if (records is! List) {
      throw MambaException(
        'The MCP conversion lineage records must be a list.',
        exitCode: 1,
      );
    }
    final result = <McpConversionLineageRecord>[];
    for (final item in records) {
      if (item is! Map) {
        throw MambaException(
          'Invalid MCP conversion lineage record.',
          exitCode: 1,
        );
      }
      try {
        result.add(
          McpConversionLineageRecord.fromJson(Map<String, Object?>.from(item)),
        );
      } on FormatException {
        throw MambaException(
          'Invalid MCP conversion lineage record.',
          exitCode: 1,
        );
      }
    }
    result.sort(
      (a, b) => a.identity.lineageId!.compareTo(b.identity.lineageId!),
    );
    return List<McpConversionLineageRecord>.unmodifiable(result);
  }

  void upsert(McpConversionLineageRecord record) {
    final records = read()..add(record);
    records.sort(
      (a, b) => a.identity.lineageId!.compareTo(b.identity.lineageId!),
    );
    final seen = <String>{};
    final document = <String, Object?>{
      'schemaVersion': mcpConversionLineageSchemaVersion,
      'records': <Object?>[
        for (final item in records)
          if (seen.add(item.identity.lineageId!)) item.toJson(),
      ],
    };
    fs.directory(stateRoot).createSync(recursive: true);
    fs.file(path).writeAsStringSync(jsonEncode(document));
  }
}
