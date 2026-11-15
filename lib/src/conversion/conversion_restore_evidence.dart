import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The schema version of the inverse restore evidence document.
const int conversionRestoreEvidenceSchemaVersion = 1;

/// The largest inverse restore evidence document that is read or written.
const int maxConversionRestoreEvidenceBytes = 4 * 1024 * 1024;

/// The largest nesting depth of an inverse restore evidence document.
const int maxConversionRestoreEvidenceDepth = 24;

/// The largest number of nodes of an inverse restore evidence document.
const int maxConversionRestoreEvidenceNodes = 20000;

/// The directory that holds the inverse restore evidence of one state root.
const String conversionRestoreDirectoryName = 'conversion-restores';

/// The phase of one inverse restore transaction.
///
/// The inverse restore is a fresh transaction. It is not a rollback of the
/// original conversion and it never reopens the original commit decision.
enum ConversionRestorePhase {
  prepared,
  published,
  committed,
  reconciled,
  completed,
  rolledBack,
  recoveryRequired,
}

/// The durable evidence of one completed-conversion inverse restore.
///
/// The document binds the original conversion, the retained independent source
/// payload, the outgoing target evidence and the ownership observations of the
/// reviewed plan. A corrupt, truncated, substituted or unknown document is
/// never evidence of a free state.
final class ConversionRestoreEvidence {
  const ConversionRestoreEvidence({
    required this.restoreId,
    required this.transactionId,
    required this.phase,
    required this.createdScope,
    required this.sourceLocation,
    required this.targetLocation,
    required this.artifactKind,
    this.subjectKind = 'conversion',
    required this.sourceScope,
    required this.targetScope,
    required this.inPlace,
    required this.payloadPath,
    required this.payloadDigest,
    required this.outgoingDigest,
    required this.observations,
    this.sourceManaged = false,
    this.sourceInstallationId,
    this.targetInstallationId,
    this.sourceRecord,
    this.targetRecord,
    this.retiredSourceRecord,
    this.packKeys = const <String>[],
    this.resourceNames = const <String>[],
    this.packAuthority = const <String, Object?>{},
    this.approvals = const <String, bool>{},
    this.participantMarker = false,
  });

  factory ConversionRestoreEvidence.fromJson(Object? value) {
    final map = _object(value, 'conversion restore evidence');
    _knownKeys(map, const {
      'schemaVersion',
      'restoreId',
      'transactionId',
      'phase',
      'createdScope',
      'sourceLocation',
      'targetLocation',
      'artifactKind',
      'subjectKind',
      'sourceScope',
      'targetScope',
      'inPlace',
      'payloadPath',
      'payloadDigest',
      'outgoingDigest',
      'observations',
      'sourceManaged',
      'sourceInstallationId',
      'targetInstallationId',
      'sourceRecord',
      'targetRecord',
      'retiredSourceRecord',
      'packKeys',
      'resourceNames',
      'packAuthority',
      'approvals',
      'participantMarker',
      'digest',
    }, 'conversion restore evidence');
    if (_integer(map, 'schemaVersion') !=
        conversionRestoreEvidenceSchemaVersion) {
      throw const FormatException(
        'Unsupported conversion restore evidence schema version.',
      );
    }
    final restoreId = _string(map, 'restoreId');
    if (!RegExp(r'^rsv_[a-f0-9]{32}$').hasMatch(restoreId)) {
      throw const FormatException('Invalid conversion restore identifier.');
    }
    final transactionId = _string(map, 'transactionId');
    if (!RegExp(r'^(cvx|aut)_[a-f0-9]{32}$').hasMatch(transactionId)) {
      throw const FormatException('Invalid conversion transaction identifier.');
    }
    final approvals = <String, bool>{};
    final rawApprovals = _object(map['approvals'], 'approvals');
    for (final entry in rawApprovals.entries) {
      if (entry.value is! bool) {
        throw const FormatException('An approval must be a boolean.');
      }
      approvals[entry.key] = entry.value! as bool;
    }
    final evidence = ConversionRestoreEvidence(
      restoreId: restoreId,
      transactionId: transactionId,
      phase: ConversionRestorePhase.values.firstWhere(
        (value) => value.name == _string(map, 'phase'),
        orElse: () =>
            throw const FormatException('Unknown conversion restore phase.'),
      ),
      createdScope: _enumValue(_string(map, 'createdScope'), const [
        'project',
        'user',
      ]),
      sourceLocation: _absolutePath(_string(map, 'sourceLocation')),
      targetLocation: _absolutePath(_string(map, 'targetLocation')),
      artifactKind: _string(map, 'artifactKind'),
      subjectKind: map.containsKey('subjectKind')
          ? _enumValue(_string(map, 'subjectKind'), const [
              'conversion',
              'authoring',
            ])
          : 'conversion',
      sourceScope: _enumValue(_string(map, 'sourceScope'), const [
        'project',
        'user',
      ]),
      targetScope: _enumValue(_string(map, 'targetScope'), const [
        'project',
        'user',
      ]),
      inPlace: _bool(map, 'inPlace'),
      payloadPath: _absolutePath(_string(map, 'payloadPath')),
      payloadDigest: _string(map, 'payloadDigest'),
      outgoingDigest: _string(map, 'outgoingDigest'),
      observations: _object(map['observations'], 'observations'),
      sourceManaged: _bool(map, 'sourceManaged'),
      sourceInstallationId: _nullableString(map, 'sourceInstallationId'),
      targetInstallationId: _nullableString(map, 'targetInstallationId'),
      sourceRecord: map['sourceRecord'] == null
          ? null
          : _object(map['sourceRecord'], 'source record'),
      targetRecord: map['targetRecord'] == null
          ? null
          : _object(map['targetRecord'], 'target record'),
      retiredSourceRecord: map['retiredSourceRecord'] == null
          ? null
          : _object(map['retiredSourceRecord'], 'retired source record'),
      packKeys: _stringList(map['packKeys']),
      resourceNames: _stringList(map['resourceNames']),
      packAuthority: map['packAuthority'] == null
          ? const <String, Object?>{}
          : _object(map['packAuthority'], 'pack authority'),
      approvals: approvals,
      participantMarker: map.containsKey('participantMarker')
          ? _bool(map, 'participantMarker')
          : false,
    );
    final digest = _string(map, 'digest');
    if (digest != evidence.digest) {
      throw const FormatException(
        'The conversion restore evidence digest does not bind.',
      );
    }
    return evidence;
  }

  /// The identifier of the inverse restore transaction.
  final String restoreId;

  /// The identifier of the original completed conversion.
  final String transactionId;
  final ConversionRestorePhase phase;
  final String createdScope;

  /// The original location of the converted source.
  final String sourceLocation;

  /// The location of the converted target that is retired by the restore.
  final String targetLocation;

  /// The artifact kind of the restored conversion.
  final String artifactKind;

  /// The kind of the restored conversion authority.
  ///
  /// A managed conversion is restored from the conversion evidence of the
  /// coordinator. An ordinary conversion is restored from the authoring
  /// evidence of the ordinary publisher. The two authorities never mix.
  final String subjectKind;
  final String sourceScope;
  final String targetScope;

  /// Whether the conversion replaced the source in place.
  final bool inPlace;

  /// The retained independent payload of the original source.
  final String payloadPath;
  final String payloadDigest;

  /// The digest of the outgoing target that the restore preserves.
  final String outgoingDigest;

  /// The exact current observations of the reviewed plan.
  final Map<String, Object?> observations;

  /// Whether the original source was a managed installation.
  final bool sourceManaged;
  final String? sourceInstallationId;
  final String? targetInstallationId;

  /// The installation record that the restore reinstates.
  final Map<String, Object?>? sourceRecord;

  /// The installation record of the converted target at review time.
  final Map<String, Object?>? targetRecord;

  /// The retired record of the original source at review time.
  ///
  /// The record is the exact state that the inverse restore replaces. It
  /// lets a resumed inverse restore accept its own already applied state and
  /// refuse every other occupant.
  final Map<String, Object?>? retiredSourceRecord;

  /// The upstream pack keys that the restore reserves.
  ///
  /// A pending inverse restore reserves its pack keys, so an old pack
  /// mutation cannot change the membership that the restore observes.
  final List<String> packKeys;

  /// The native resource names of the observed pack membership.
  final List<String> resourceNames;

  /// The observed pack authority of the restored participants.
  ///
  /// The authority is the current content of the pack groups of the shared
  /// state document: the packs, the snapshots, the approvals, the selections
  /// and the operations that mention the restored participants. The restore
  /// binds the exact observation and refuses a changed authority.
  final Map<String, Object?> packAuthority;
  final Map<String, bool> approvals;

  /// Whether this document is the participant marker of another scope.
  ///
  /// The marker reserves the inverse restore in the scope that does not
  /// coordinate it, so an old mutator of that scope cannot change the
  /// source, the target or the identities of the pending inverse restore.
  final bool participantMarker;

  /// Whether the restore already retired the converted target.
  bool get completed =>
      phase == ConversionRestorePhase.completed ||
      phase == ConversionRestorePhase.rolledBack;

  /// The digest that binds the evidence document.
  String get digest {
    final body = <String, Object?>{
      'schemaVersion': conversionRestoreEvidenceSchemaVersion,
      'restoreId': restoreId,
      'transactionId': transactionId,
      'phase': phase.name,
      'createdScope': createdScope,
      'sourceLocation': sourceLocation,
      'targetLocation': targetLocation,
      'artifactKind': artifactKind,
      'subjectKind': subjectKind,
      'sourceScope': sourceScope,
      'targetScope': targetScope,
      'inPlace': inPlace,
      'payloadPath': payloadPath,
      'payloadDigest': payloadDigest,
      'outgoingDigest': outgoingDigest,
      'observations': observations,
      'sourceManaged': sourceManaged,
      'sourceInstallationId': sourceInstallationId,
      'targetInstallationId': targetInstallationId,
      'sourceRecord': sourceRecord,
      'targetRecord': targetRecord,
      'retiredSourceRecord': retiredSourceRecord,
      'packKeys': packKeys,
      'resourceNames': resourceNames,
      'packAuthority': packAuthority,
      'approvals': approvals,
    };
    return sha256
        .convert(utf8.encode(jsonEncode(_canonicalJson(body))))
        .toString();
  }

  /// A copy of the evidence with the selected observations replaced.
  ConversionRestoreEvidence copyWith({
    ConversionRestorePhase? phase,
    Map<String, Object?>? observations,
    bool? participantMarker,
  }) => ConversionRestoreEvidence(
    restoreId: restoreId,
    transactionId: transactionId,
    phase: phase ?? this.phase,
    createdScope: createdScope,
    sourceLocation: sourceLocation,
    targetLocation: targetLocation,
    artifactKind: artifactKind,
    subjectKind: subjectKind,
    sourceScope: sourceScope,
    targetScope: targetScope,
    inPlace: inPlace,
    payloadPath: payloadPath,
    payloadDigest: payloadDigest,
    outgoingDigest: outgoingDigest,
    observations: observations ?? this.observations,
    sourceManaged: sourceManaged,
    sourceInstallationId: sourceInstallationId,
    targetInstallationId: targetInstallationId,
    sourceRecord: sourceRecord,
    targetRecord: targetRecord,
    retiredSourceRecord: retiredSourceRecord,
    packKeys: packKeys,
    resourceNames: resourceNames,
    packAuthority: packAuthority,
    approvals: approvals,
    participantMarker: participantMarker ?? this.participantMarker,
  );

  /// The serialized evidence document.
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': conversionRestoreEvidenceSchemaVersion,
    'restoreId': restoreId,
    'transactionId': transactionId,
    'phase': phase.name,
    'createdScope': createdScope,
    'sourceLocation': sourceLocation,
    'targetLocation': targetLocation,
    'artifactKind': artifactKind,
    'sourceScope': sourceScope,
    'targetScope': targetScope,
    'inPlace': inPlace,
    'payloadPath': payloadPath,
    'payloadDigest': payloadDigest,
    'outgoingDigest': outgoingDigest,
    'observations': observations,
    'sourceManaged': sourceManaged,
    'sourceInstallationId': sourceInstallationId,
    'targetInstallationId': targetInstallationId,
    'sourceRecord': sourceRecord,
    'targetRecord': targetRecord,
    'retiredSourceRecord': retiredSourceRecord,
    'packKeys': packKeys,
    'resourceNames': resourceNames,
    'packAuthority': packAuthority,
    'approvals': approvals,
    'participantMarker': participantMarker,
    'digest': digest,
  };

  /// The encoded evidence document.
  String encode() => jsonEncode(toJson());

  /// Reads an evidence document from its encoded form.
  ///
  /// The document is bounded before it is parsed. Unknown keys, an unknown
  /// schema version and a corrupt digest fail closed.
  static ConversionRestoreEvidence decode(String encoded) {
    final bytes = utf8.encode(encoded);
    if (bytes.length > maxConversionRestoreEvidenceBytes) {
      throw const FormatException(
        'The conversion restore evidence exceeds its byte limit.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException(
        'The conversion restore evidence is not valid JSON.',
      );
    }
    _checkBudget(decoded, 0);
    return ConversionRestoreEvidence.fromJson(decoded);
  }
}

/// Recursively sorts JSON-compatible values so the digest of an evidence
/// document is stable across semantically equivalent map insertion orders.
Object? _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.toList()
      ..sort((left, right) => left.toString().compareTo(right.toString()));
    return <String, Object?>{
      for (final key in keys) key.toString(): _canonicalJson(value[key]),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _canonicalJson(item)];
  }
  return value;
}

void _checkBudget(Object? value, int depth) {
  if (depth > maxConversionRestoreEvidenceDepth) {
    throw const FormatException(
      'The conversion restore evidence exceeds its depth limit.',
    );
  }
  var nodes = 0;
  void walk(Object? node, int depth) {
    if (++nodes > maxConversionRestoreEvidenceNodes) {
      throw const FormatException(
        'The conversion restore evidence exceeds its node limit.',
      );
    }
    if (node is Map) {
      for (final entry in node.entries) {
        walk(entry.key, depth + 1);
        walk(entry.value, depth + 1);
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item, depth + 1);
      }
    }
  }

  walk(value, 0);
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw FormatException('The $label must be an object.');
  }
  return value;
}

void _knownKeys(Map<String, Object?> map, Set<String> allowed, String label) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('Unknown $label field: $key');
    }
  }
}

String _string(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('The $key must be a nonblank string.');
  }
  return value;
}

String? _nullableString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw FormatException('The $key must be a nonblank string.');
  }
  return value;
}

bool _bool(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) {
    throw FormatException('The $key must be a boolean.');
  }
  return value;
}

int _integer(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) {
    throw FormatException('The $key must be an integer.');
  }
  return value;
}

List<String> _stringList(Object? value) {
  if (value == null) return const <String>[];
  if (value is! List) {
    throw const FormatException('The value must be a list.');
  }
  final result = <String>[];
  for (final item in value) {
    if (item is! String || item.isEmpty) {
      throw const FormatException('A list member must be a nonblank string.');
    }
    result.add(item);
  }
  return result;
}

String _enumValue(String value, List<String> allowed) {
  if (!allowed.contains(value)) {
    throw FormatException('Unsupported value: $value');
  }
  return value;
}

String _absolutePath(String value) {
  if (!value.startsWith('/') && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
    throw const FormatException('A recorded path must be absolute.');
  }
  return value;
}
