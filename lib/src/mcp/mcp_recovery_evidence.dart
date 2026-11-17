import 'dart:convert';

import 'package:mamba/mamba.dart';

import '../services/parent_config_service.dart' show parseStrictJsonObject;
import 'mcp_native.dart' show mcpCanonicalDigest;
import 'mcp_redaction.dart';
import 'mcp_types.dart';

/// Versioned, integrity-checked evidence for one reviewed MCP mutation.
///
/// Evidence lives only under the Agent Resource state root. It retains the
/// unredacted value of ONE selected entry so a reviewed recovery can restore
/// that entry without ever rewriting a whole shared native file. The digest,
/// retention marker and restricted-access marker make substitution or casual
/// disclosure detectable; reports use [redactedJson] instead.
const int mcpRecoveryEvidenceSchemaVersion = 1;
const String mcpBackupDirectoryName = 'mcp-backups';
const String mcpTransactionDirectoryName = 'mcp-transactions';
const String mcpEvidenceRetention = 'retained-until-reviewed-cleanup';
const String mcpEvidenceAccess = 'restricted-agent-resource-state';

final RegExp mcpBackupIdPattern = RegExp(r'^mbk_[a-f0-9]{32}$');
final RegExp mcpTransactionIdPattern = RegExp(r'^mtx_[a-f0-9]{32}$');

/// The recorded phase of one interrupted MCP mutation.
enum McpRecoveryPhase {
  prepared('prepared'),
  published('published'),
  committed('committed'),
  failedRestored('failedRestored'),
  recoveryRequired('recoveryRequired');

  const McpRecoveryPhase(this.wireName);
  final String wireName;

  String toJson() => wireName;

  static McpRecoveryPhase fromWire(String value) => values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw FormatException('Unknown MCP recovery phase.'),
  );
}

/// The reviewed decision available for one recorded phase.
enum McpRecoveryAction {
  rollback('rollback'),
  complete('complete');

  const McpRecoveryAction(this.wireName);
  final String wireName;

  String toJson() => wireName;

  static McpRecoveryAction fromWire(String value) => values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw FormatException('Unknown MCP recovery action.'),
  );
}

void _requireExactKeys(Map<String, Object?> json, Set<String> keys) {
  final actual = json.keys.toSet();
  if (actual.length != keys.length || !actual.containsAll(keys)) {
    throw const FormatException('Invalid MCP recovery evidence keys.');
  }
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid MCP recovery evidence $key.');
  }
  return value;
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('Invalid MCP recovery evidence $key.');
  }
  return value;
}

Map<String, Object?> _fields(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) {
    throw FormatException('Invalid MCP recovery evidence $key.');
  }
  return Map<String, Object?>.from(value);
}

Map<String, Object?>? _optionalFields(Map<String, Object?> json, String key) {
  if (json[key] == null) return null;
  return _fields(json, key);
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('Invalid MCP recovery evidence $key.');
  }
  return value;
}

Map<String, Object?> _decode(String text) {
  try {
    return parseStrictJsonObject(text);
  } on MambaException {
    throw const FormatException('MCP recovery evidence is not a JSON object.');
  }
}

/// Protected prior state of exactly one selected MCP server entry.
final class McpBackupEvidence {
  McpBackupEvidence({
    required this.backupId,
    required this.operation,
    required this.identity,
    required this.sourceFingerprint,
    required this.fields,
    required this.planId,
    required this.transactionId,
    this.absent = false,
  }) : digest = _entryDigest(fields);

  static const Set<String> _keys = <String>{
    'schemaVersion',
    'artifactDigest',
    'backupId',
    'operation',
    'identity',
    'sourceFingerprint',
    'entryDigest',
    'fields',
    'absent',
    'planId',
    'transactionId',
    'retention',
    'access',
  };

  final String backupId;
  final String operation;
  final McpRegistrationIdentity identity;

  /// Fingerprint of the WHOLE current native file, never its contents.
  final String sourceFingerprint;

  /// Unredacted prior value of the one selected entry. This field is never
  /// included in a success report; only [redactedJson] is disclosed.
  final Map<String, Object?> fields;
  final bool absent;
  final String planId;
  final String transactionId;
  final String digest;
  final String retention = mcpEvidenceRetention;
  final String access = mcpEvidenceAccess;

  static String _entryDigest(Map<String, Object?> fields) =>
      mcpCanonicalDigest(fields);

  Map<String, Object?> _payload() => <String, Object?>{
    'schemaVersion': mcpRecoveryEvidenceSchemaVersion,
    'backupId': backupId,
    'operation': operation,
    'identity': identity.toJson(),
    'sourceFingerprint': sourceFingerprint,
    'entryDigest': digest,
    'fields': fields,
    'absent': absent,
    'planId': planId,
    'transactionId': transactionId,
    'retention': retention,
    'access': access,
  };

  String get artifactDigest => mcpCanonicalDigest(_payload());

  Map<String, Object?> toJson() => <String, Object?>{
    ..._payload(),
    'artifactDigest': artifactDigest,
  };

  String encode() => jsonEncode(toJson());

  /// Disclosure-safe view: the identity and fingerprints plus a redacted
  /// entry shape. It can never carry a literal credential value.
  Map<String, Object?> redactedJson() => <String, Object?>{
    'backupId': backupId,
    'operation': operation,
    ...identity.toJson(),
    'sourceFingerprint': sourceFingerprint,
    'entryDigest': digest,
    'absent': absent,
    'planId': planId,
    'transactionId': transactionId,
    'retention': retention,
    'access': access,
    'entry': McpRedaction.redactMap(fields),
  };

  static McpBackupEvidence decode(String text) {
    final json = _decode(text);
    _requireExactKeys(json, _keys.union(<String>{'artifactDigest'}));
    if (json['schemaVersion'] != mcpRecoveryEvidenceSchemaVersion) {
      throw const FormatException('Unsupported MCP backup evidence version.');
    }
    final backupId = _string(json, 'backupId');
    final transactionId = _string(json, 'transactionId');
    if (!mcpBackupIdPattern.hasMatch(backupId) ||
        !mcpTransactionIdPattern.hasMatch(transactionId)) {
      throw const FormatException('Invalid MCP backup evidence identity.');
    }
    if (_string(json, 'retention') != mcpEvidenceRetention ||
        _string(json, 'access') != mcpEvidenceAccess) {
      throw const FormatException('MCP backup evidence lacks retention.');
    }
    final fields = _fields(json, 'fields');
    final entryDigest = _string(json, 'entryDigest');
    if (entryDigest != _entryDigest(fields)) {
      throw const FormatException('MCP backup entry digest mismatch.');
    }
    final candidate = McpBackupEvidence(
      backupId: backupId,
      operation: _string(json, 'operation'),
      identity: McpRegistrationIdentity.fromJson(_fields(json, 'identity')),
      sourceFingerprint: _string(json, 'sourceFingerprint'),
      fields: fields,
      planId: _string(json, 'planId'),
      transactionId: transactionId,
      absent: _bool(json, 'absent'),
    );
    if (_string(json, 'artifactDigest') != candidate.artifactDigest) {
      throw const FormatException('MCP backup evidence digest mismatch.');
    }
    return candidate;
  }

  @override
  bool operator ==(Object other) =>
      other is McpBackupEvidence &&
      other.backupId == backupId &&
      other.operation == operation &&
      other.identity == identity &&
      other.sourceFingerprint == sourceFingerprint &&
      mcpCanonicalDigest(other.fields) == digest &&
      other.absent == absent &&
      other.planId == planId &&
      other.transactionId == transactionId;

  @override
  int get hashCode => Object.hash(
    backupId,
    operation,
    identity,
    sourceFingerprint,
    digest,
    absent,
    planId,
    transactionId,
  );
}

/// One reviewed MCP mutation in progress. The phase bounds every decision a
/// later recovery may take; digests bind it to the reviewed file and entry.
final class McpTransactionRecord {
  McpTransactionRecord({
    required this.transactionId,
    required this.backupId,
    required this.operation,
    required this.identity,
    required this.phase,
    required this.planId,
    required this.preSourceFingerprint,
    required this.preBaselineDigest,
    required this.proposedFields,
    this.publishedSourceFingerprint,
    this.publishedBaselineDigest,
  }) : proposedDigest = proposedFields == null
           ? null
           : mcpCanonicalDigest(proposedFields);

  static const Set<String> _keys = <String>{
    'schemaVersion',
    'artifactDigest',
    'transactionId',
    'backupId',
    'operation',
    'identity',
    'phase',
    'planId',
    'preSourceFingerprint',
    'preBaselineDigest',
    'proposedDigest',
    'proposedFields',
    'publishedSourceFingerprint',
    'publishedBaselineDigest',
    'retention',
    'access',
  };

  final String transactionId;
  final String backupId;
  final String operation;
  final McpRegistrationIdentity identity;
  final McpRecoveryPhase phase;
  final String planId;
  final String preSourceFingerprint;
  final String? preBaselineDigest;
  final Map<String, Object?>? proposedFields;
  final String? proposedDigest;
  final String? publishedSourceFingerprint;
  final String? publishedBaselineDigest;
  final String retention = mcpEvidenceRetention;
  final String access = mcpEvidenceAccess;

  /// Actions provable from the recorded phase alone. Current-state guards are
  /// applied separately before either action is allowed to write.
  Set<McpRecoveryAction> get availableActions => switch (phase) {
    McpRecoveryPhase.prepared => <McpRecoveryAction>{
      McpRecoveryAction.rollback,
    },
    McpRecoveryPhase.published => <McpRecoveryAction>{
      McpRecoveryAction.rollback,
      McpRecoveryAction.complete,
    },
    McpRecoveryPhase.recoveryRequired => <McpRecoveryAction>{
      McpRecoveryAction.rollback,
    },
    McpRecoveryPhase.committed => const <McpRecoveryAction>{},
    McpRecoveryPhase.failedRestored => const <McpRecoveryAction>{},
  };

  Map<String, Object?> _payload() => <String, Object?>{
    'schemaVersion': mcpRecoveryEvidenceSchemaVersion,
    'transactionId': transactionId,
    'backupId': backupId,
    'operation': operation,
    'identity': identity.toJson(),
    'phase': phase.toJson(),
    'planId': planId,
    'preSourceFingerprint': preSourceFingerprint,
    'preBaselineDigest': preBaselineDigest,
    'proposedDigest': proposedDigest,
    'proposedFields': proposedFields,
    'publishedSourceFingerprint': publishedSourceFingerprint,
    'publishedBaselineDigest': publishedBaselineDigest,
    'retention': retention,
    'access': access,
  };

  String get artifactDigest => mcpCanonicalDigest(_payload());

  Map<String, Object?> toJson() => <String, Object?>{
    ..._payload(),
    'artifactDigest': artifactDigest,
  };

  String encode() => jsonEncode(toJson());

  McpTransactionRecord withPhase(
    McpRecoveryPhase next, {
    String? publishedSourceFingerprint,
    String? publishedBaselineDigest,
  }) => McpTransactionRecord(
    transactionId: transactionId,
    backupId: backupId,
    operation: operation,
    identity: identity,
    phase: next,
    planId: planId,
    preSourceFingerprint: preSourceFingerprint,
    preBaselineDigest: preBaselineDigest,
    proposedFields: proposedFields,
    publishedSourceFingerprint:
        publishedSourceFingerprint ?? this.publishedSourceFingerprint,
    publishedBaselineDigest:
        publishedBaselineDigest ?? this.publishedBaselineDigest,
  );

  Map<String, Object?> redactedJson() => <String, Object?>{
    'transactionId': transactionId,
    'backupId': backupId,
    'operation': operation,
    ...identity.toJson(),
    'phase': phase.toJson(),
    'planId': planId,
    'preSourceFingerprint': preSourceFingerprint,
    'proposedDigest': proposedDigest,
    'publishedSourceFingerprint': publishedSourceFingerprint,
    'availableActions': <String>[
      for (final action in availableActions) action.toJson(),
    ]..sort(),
    'retention': retention,
    'access': access,
  };

  static McpTransactionRecord decode(String text) {
    final json = _decode(text);
    _requireExactKeys(json, _keys.union(<String>{'artifactDigest'}));
    if (json['schemaVersion'] != mcpRecoveryEvidenceSchemaVersion) {
      throw const FormatException('Unsupported MCP transaction version.');
    }
    final transactionId = _string(json, 'transactionId');
    final backupId = _string(json, 'backupId');
    if (!mcpTransactionIdPattern.hasMatch(transactionId) ||
        !mcpBackupIdPattern.hasMatch(backupId)) {
      throw const FormatException('Invalid MCP transaction identity.');
    }
    if (_string(json, 'retention') != mcpEvidenceRetention ||
        _string(json, 'access') != mcpEvidenceAccess) {
      throw const FormatException('MCP transaction lacks retention.');
    }
    final proposedFields = _optionalFields(json, 'proposedFields');
    final proposedDigest = _optionalString(json, 'proposedDigest');
    if (proposedDigest !=
        (proposedFields == null ? null : mcpCanonicalDigest(proposedFields))) {
      throw const FormatException('MCP transaction entry digest mismatch.');
    }
    final candidate = McpTransactionRecord(
      transactionId: transactionId,
      backupId: backupId,
      operation: _string(json, 'operation'),
      identity: McpRegistrationIdentity.fromJson(_fields(json, 'identity')),
      phase: McpRecoveryPhase.fromWire(_string(json, 'phase')),
      planId: _string(json, 'planId'),
      preSourceFingerprint: _string(json, 'preSourceFingerprint'),
      preBaselineDigest: _optionalString(json, 'preBaselineDigest'),
      proposedFields: proposedFields,
      publishedSourceFingerprint: _optionalString(
        json,
        'publishedSourceFingerprint',
      ),
      publishedBaselineDigest: _optionalString(json, 'publishedBaselineDigest'),
    );
    if (_string(json, 'artifactDigest') != candidate.artifactDigest) {
      throw const FormatException('MCP transaction digest mismatch.');
    }
    return candidate;
  }

  @override
  bool operator ==(Object other) =>
      other is McpTransactionRecord &&
      other.transactionId == transactionId &&
      other.backupId == backupId &&
      other.operation == operation &&
      other.identity == identity &&
      other.phase == phase &&
      other.planId == planId &&
      other.preSourceFingerprint == preSourceFingerprint &&
      other.preBaselineDigest == preBaselineDigest &&
      other.proposedDigest == proposedDigest &&
      other.publishedSourceFingerprint == publishedSourceFingerprint &&
      other.publishedBaselineDigest == publishedBaselineDigest;

  @override
  int get hashCode => Object.hash(
    transactionId,
    backupId,
    operation,
    identity,
    phase,
    planId,
    preSourceFingerprint,
    preBaselineDigest,
    proposedDigest,
    publishedSourceFingerprint,
    publishedBaselineDigest,
  );
}
