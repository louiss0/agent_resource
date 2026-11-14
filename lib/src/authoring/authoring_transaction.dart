import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart';

import '../skill_files.dart';
import 'package_manifest.dart';

/// The schema version of the current authoring transaction document.
///
/// The current document records the content evidence of the retained
/// payload and of the published target, so a recovery can prove the exact
/// bytes it restores and the exact bytes it removes.
const int authoringTransactionSchemaVersion = 2;

/// The schema version of the legacy authoring transaction document.
///
/// A legacy document was written before the publication recorded its
/// content evidence. It carries no integrity proof, so it never becomes
/// trusted: it stays readable, it keeps its metadata and it is never
/// actionable.
const int authoringLegacyTransactionSchemaVersion = 1;

/// The version of the content evidence of one authoring transaction.
const int authoringEvidenceVersion = 1;

/// The directory that holds the authoring transactions of one state root.
const String authoringTransactionDirectoryName = 'authoring-transactions';

/// The directory that holds the retained authoring recovery payloads.
const String authoringRecoveryDirectoryName = 'authoring-recovery';

/// The directory that holds the staged authoring candidates.
const String authoringStagingDirectoryName = 'authoring-staging';

/// The largest authoring transaction document that is read or written.
const int maxAuthoringTransactionBytes = 1024 * 1024;

/// The largest nesting depth of an authoring transaction document.
const int authoringTransactionMaxDepth = 16;

/// The largest number of nodes of an authoring transaction document.
///
/// The document carries three bounded content manifests of at most 256
/// members each. Every member costs a bounded number of nodes, so the
/// budget admits the largest legitimate package and refuses a document that
/// carries more evidence than the authority can prove.
const int authoringTransactionMaxNodes = 8192;

/// The pattern of an authoring transaction identifier.
final RegExp authoringTransactionIdPattern = RegExp(r'^aut_[a-f0-9]{32}$');

/// The pattern of an authoring plan identifier.
///
/// The plan identity names the private payload and staging directories of a
/// transaction. Only a plain plan identifier can name a private directory:
/// a substituted identifier never escapes the private storage.
final RegExp authoringPlanIdPattern = RegExp(r'^authoring-plan-[a-f0-9]{64}$');

/// The pattern of a content digest.
final RegExp _contentDigestPattern = RegExp(r'^[a-f0-9]{64}$');

/// Whether the value is an authoring transaction identifier.
bool isAuthoringTransactionId(String value) =>
    authoringTransactionIdPattern.hasMatch(value);

/// Whether the value is an authoring plan identifier.
///
/// The plan identity names the private payload and staging directories of a
/// transaction. Only a plain plan identifier can name a private directory:
/// a substituted identifier never escapes the private storage.
bool isAuthoringPlanId(String value) => authoringPlanIdPattern.hasMatch(value);

/// A new authoring transaction identifier.
String newAuthoringTransactionId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return 'aut_${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
}

/// The marker file of one published location.
///
/// A package publishes its marker inside the package directory, a regular
/// file publishes itself.
String authoringMarkerPath(fslib.FileSystem fs, String location) {
  if (fs.typeSync(location, followLinks: false) ==
      fslib.FileSystemEntityType.directory) {
    return fs.path.join(location, 'SKILL.md');
  }
  return location;
}

/// Recursively sorts JSON-compatible values so a digest is stable across
/// semantically equivalent map insertion orders.
Object? canonicalAuthoringJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.toList()
      ..sort((left, right) => left.toString().compareTo(right.toString()));
    return <String, Object?>{
      for (final key in keys)
        key.toString(): canonicalAuthoringJson(value[key]),
    };
  }
  if (value is List) {
    return <Object?>[for (final entry in value) canonicalAuthoringJson(entry)];
  }
  return value;
}

/// The recursive content evidence of one location.
///
/// The evidence binds every reviewed member of a location by relative path,
/// type, length and content digest. A directory is read through the bounded
/// package manifest, so a link, an unsupported entry or an oversized member
/// refuses the evidence instead of producing an unreviewed record. A single
/// file is bound by its own name, length and digest.
List<Map<String, Object?>> authoringContentEvidence(
  fslib.FileSystem fs,
  String location,
) {
  final type = skillEntityType(location, followLinks: false, fs: fs);
  if (type == fslib.FileSystemEntityType.directory) {
    return readPackageManifest(fs, location).entries;
  }
  if (type != fslib.FileSystemEntityType.file) {
    throw MambaException(
      'The content evidence location is not a readable entry: $location',
      exitCode: 6,
    );
  }
  final bytes = readBoundedSkillMarker(
    location,
    maxBytes: maxPackageManifestFileBytes,
    fs: fs,
  );
  if (bytes.length > maxPackageManifestFileBytes) {
    throw MambaException(
      'The content evidence member exceeds its byte limit: $location',
      exitCode: 3,
    );
  }
  return <Map<String, Object?>>[
    <String, Object?>{
      'path': fs.path.basename(location),
      'type': 'file',
      'length': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    },
  ];
}

/// Whether two content evidence records bind the same reviewed content.
///
/// The comparison is exact: a missing member, an extra member, a changed
/// type, a changed length or a changed digest is a difference.
bool authoringContentEvidenceMatches(
  List<Map<String, Object?>> expected,
  List<Map<String, Object?>> actual,
) {
  final left = _sortedEvidence(expected);
  final right = _sortedEvidence(actual);
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    for (final key in const <String>['path', 'type', 'length', 'sha256']) {
      if (left[index][key] != right[index][key]) return false;
    }
  }
  return true;
}

/// The content evidence records ordered by their relative path.
List<Map<String, Object?>> _sortedEvidence(List<Map<String, Object?>> entries) {
  final sorted = <Map<String, Object?>>[
    for (final entry in entries)
      <String, Object?>{
        'path': entry['path'],
        'type': entry['type'],
        'length': entry['length'],
        'sha256': entry['sha256'],
      },
  ];
  sorted.sort((left, right) => '${left['path']}'.compareTo('${right['path']}'));
  return sorted;
}

/// The phase of one authoring transaction.
///
/// The phase is the evidence of how far the publication reached. A
/// transaction before the commit decision may be rolled back; a transaction
/// after it may only be completed.
enum AuthoringTransactionPhase {
  prepared,
  published,
  committed,
  completed,
  rolledBack,
}

/// A decoded authoring transaction document.
///
/// The current document carries the content evidence of its publication. A
/// legacy document carries no evidence: it stays readable, it keeps its
/// metadata and it is never actionable.
sealed class AuthoringTransactionDocument {
  const AuthoringTransactionDocument();

  /// The identifier of the recorded transaction.
  String get transactionId;

  /// The digest that binds the recorded document.
  String get digest;

  /// Whether the recorded transaction reached its terminal phase.
  bool get terminal;

  /// The locations that the recorded transaction reserves.
  List<String> get reservedLocations;

  /// Whether the recorded document is a legacy document.
  bool get legacyReadOnly => false;
}

/// The current authoring transaction document.
final class CurrentAuthoringTransactionDocument
    extends AuthoringTransactionDocument {
  const CurrentAuthoringTransactionDocument(this.transaction);

  /// The recorded transaction.
  final AuthoringTransaction transaction;

  @override
  String get transactionId => transaction.transactionId;

  @override
  String get digest => transaction.digest;

  @override
  bool get terminal => transaction.terminal;

  @override
  List<String> get reservedLocations => <String>[
    transaction.target,
    if (transaction.source != null) transaction.source!,
  ];
}

/// The legacy authoring transaction document.
///
/// A legacy document is kept readable and never actionable. It records no
/// content evidence, so it cannot prove a retained payload or a published
/// target, and a recovery or a cleanup of it is refused.
final class LegacyAuthoringTransactionDocument
    extends AuthoringTransactionDocument {
  const LegacyAuthoringTransactionDocument(this.transaction);

  /// The recorded legacy transaction.
  final AuthoringLegacyTransaction transaction;

  @override
  String get transactionId => transaction.transactionId;

  @override
  String get digest => transaction.digest;

  @override
  bool get terminal => transaction.terminal;

  @override
  bool get legacyReadOnly => true;

  @override
  List<String> get reservedLocations => <String>[
    transaction.target,
    if (transaction.source != null) transaction.source!,
  ];
}

/// The evidence of one authoring transaction.
///
/// The document binds the reviewed plan, the published target, the recovery
/// payload of the previous bytes and the phase of the publication. It is the
/// authority of an interrupted ordinary publication: it never adopts a
/// source and it never records an installation.
final class AuthoringTransaction {
  const AuthoringTransaction({
    required this.transactionId,
    required this.planId,
    required this.operation,
    required this.kind,
    required this.profile,
    required this.ownership,
    required this.phase,
    required this.target,
    required this.candidateSha256,
    required this.observations,
    required this.evidence,
    required this.authority,
    this.source,
    this.sourceSha256,
    this.sourceInstallationId,
    this.root,
    this.form,
    this.nativeName,
    this.recoveryPath,
    this.receiptId,
  });

  /// Reads a validated transaction document.
  factory AuthoringTransaction.fromJson(Object? value) {
    final map = _object(value, 'authoring transaction');
    _knownKeys(map, const {
      'schemaVersion',
      'transactionId',
      'planId',
      'operation',
      'kind',
      'profile',
      'ownership',
      'phase',
      'target',
      'source',
      'sourceSha256',
      'sourceInstallationId',
      'root',
      'form',
      'nativeName',
      'recoveryPath',
      'receiptId',
      'candidateSha256',
      'observations',
      'evidence',
      'authority',
      'digest',
    }, 'authoring transaction');
    if (_integer(map, 'schemaVersion') != authoringTransactionSchemaVersion) {
      throw const FormatException(
        'Unsupported authoring transaction schema version.',
      );
    }
    final transactionId = _string(map, 'transactionId');
    if (!isAuthoringTransactionId(transactionId)) {
      throw const FormatException('Invalid authoring transaction identifier.');
    }
    final planId = _string(map, 'planId');
    if (!isAuthoringPlanId(planId)) {
      throw const FormatException('Invalid authoring plan identifier.');
    }
    final transaction = AuthoringTransaction(
      transactionId: transactionId,
      planId: planId,
      operation: _string(map, 'operation'),
      kind: _string(map, 'kind'),
      profile: _string(map, 'profile'),
      ownership: _string(map, 'ownership'),
      phase: AuthoringTransactionPhase.values.firstWhere(
        (value) => value.name == _string(map, 'phase'),
        orElse: () =>
            throw const FormatException('Unknown authoring transaction phase.'),
      ),
      target: _absolutePath(_string(map, 'target')),
      source: map['source'] == null
          ? null
          : _absolutePath(_string(map, 'source')),
      sourceSha256: _nullableString(map, 'sourceSha256'),
      sourceInstallationId: _nullableString(map, 'sourceInstallationId'),
      root: _nullableString(map, 'root'),
      form: _nullableString(map, 'form'),
      nativeName: _nullableString(map, 'nativeName'),
      recoveryPath: map['recoveryPath'] == null
          ? null
          : _absolutePath(_string(map, 'recoveryPath')),
      receiptId: _nullableString(map, 'receiptId'),
      candidateSha256: _string(map, 'candidateSha256'),
      observations: _object(map['observations'], 'observations'),
      evidence: _evidence(map['evidence']),
      authority: _authority(map['authority']),
    );
    if (_string(map, 'digest') != transaction.digest) {
      throw const FormatException(
        'The authoring transaction digest does not bind.',
      );
    }
    return transaction;
  }

  /// The identifier of the transaction.
  final String transactionId;

  /// The identity of the reviewed plan that authorized the publication.
  final String planId;

  /// The published operation.
  final String operation;

  /// The published resource kind.
  final String kind;

  /// The published native profile.
  final String profile;

  /// The ownership the publication established.
  final String ownership;

  /// The phase of the publication.
  final AuthoringTransactionPhase phase;

  /// The published native location.
  final String target;

  /// The reviewed source of the publication.
  final String? source;

  /// The digest of the reviewed source marker before the publication.
  final String? sourceSha256;

  /// The managed installation of a tracked source.
  final String? sourceInstallationId;

  /// The native root of the published placement.
  final String? root;

  /// The native form of the published placement.
  final String? form;

  /// The visible native name of the published placement.
  final String? nativeName;

  /// The retained recovery payload of the previous bytes.
  final String? recoveryPath;

  /// The authoring receipt of the publication.
  final String? receiptId;

  /// The digest of the published native content.
  final String candidateSha256;

  /// The transaction observations.
  final Map<String, Object?> observations;

  /// The content evidence of the retained payload and of the published
  /// target.
  final Map<String, Object?> evidence;

  /// The authority context that authorized the publication.
  ///
  /// The context binds the transaction to the scope, the state root and the
  /// project that recorded it. Copied evidence never authorizes a recovery
  /// in another scope or another project.
  final Map<String, Object?> authority;

  /// The locations that the transaction reserves.
  List<String> get reservedLocations => <String>[target, ?source];

  /// Whether the transaction reached its terminal phase.
  bool get terminal =>
      phase == AuthoringTransactionPhase.completed ||
      phase == AuthoringTransactionPhase.rolledBack;

  /// The recorded content evidence of the retained payload.
  List<Map<String, Object?>>? get payloadManifest {
    final recorded = evidence['payloadManifest'];
    if (recorded is! List<Object?>) return null;
    return <Map<String, Object?>>[
      for (final entry in recorded)
        if (entry is Map<String, Object?>) entry,
    ];
  }

  /// The reviewed content evidence that the published target must carry.
  ///
  /// The planned manifest is the expectation of the publication. It is
  /// recorded before the live change, so a recovery knows which members the
  /// publication was allowed to write and which members it must never
  /// remove.
  List<Map<String, Object?>>? get plannedManifest {
    final recorded = evidence['plannedManifest'];
    if (recorded is! List<Object?>) return null;
    return <Map<String, Object?>>[
      for (final entry in recorded)
        if (entry is Map<String, Object?>) entry,
    ];
  }

  /// The published location that the authoring receipt records.
  ///
  /// The receipt binds the native marker output of the publication, not the
  /// package directory that carries it. The recovery derives the receipt
  /// identity from it and compares the receipt document field by field.
  String? get receiptTarget {
    final recorded = evidence['receiptTarget'];
    return recorded is String ? recorded : null;
  }

  /// The recorded content evidence of the published target.
  List<Map<String, Object?>>? get publishedManifest {
    final recorded = evidence['publishedManifest'];
    if (recorded is! List<Object?>) return null;
    return <Map<String, Object?>>[
      for (final entry in recorded)
        if (entry is Map<String, Object?>) entry,
    ];
  }

  /// A copy of the transaction with the selected changes.
  AuthoringTransaction copyWith({
    AuthoringTransactionPhase? phase,
    String? receiptId,
    Map<String, Object?>? observations,
    Map<String, Object?>? evidence,
  }) => AuthoringTransaction(
    transactionId: transactionId,
    planId: planId,
    operation: operation,
    kind: kind,
    profile: profile,
    ownership: ownership,
    phase: phase ?? this.phase,
    target: target,
    source: source,
    sourceSha256: sourceSha256,
    sourceInstallationId: sourceInstallationId,
    root: root,
    form: form,
    nativeName: nativeName,
    recoveryPath: recoveryPath,
    receiptId: receiptId ?? this.receiptId,
    candidateSha256: candidateSha256,
    observations: observations ?? this.observations,
    evidence: evidence ?? this.evidence,
    authority: authority,
  );

  /// The digest that binds the document.
  String get digest => sha256
      .convert(utf8.encode(jsonEncode(canonicalAuthoringJson(_body()))))
      .toString();

  /// The bound body of the document.
  Map<String, Object?> _body() => <String, Object?>{
    'schemaVersion': authoringTransactionSchemaVersion,
    'transactionId': transactionId,
    'planId': planId,
    'operation': operation,
    'kind': kind,
    'profile': profile,
    'ownership': ownership,
    'phase': phase.name,
    'target': target,
    'source': source,
    'sourceSha256': sourceSha256,
    'sourceInstallationId': sourceInstallationId,
    'root': root,
    'form': form,
    'nativeName': nativeName,
    'recoveryPath': recoveryPath,
    'receiptId': receiptId,
    'candidateSha256': candidateSha256,
    'observations': observations,
    'evidence': evidence,
    'authority': authority,
  };

  /// The serialized document.
  Map<String, Object?> toJson() => <String, Object?>{
    ..._body(),
    'digest': digest,
  };

  /// The encoded document.
  String encode() => jsonEncode(toJson());
}

/// The read-only view of one legacy authoring transaction document.
///
/// A legacy document was written before the publication recorded its
/// content evidence. It cannot prove a retained payload or a published
/// target, so it never becomes actionable: it stays visible, it keeps its
/// metadata and it is reported as `legacyReadOnly` with the reason it is
/// blocked. It is never migrated, rewritten or deleted automatically.
final class AuthoringLegacyTransaction {
  const AuthoringLegacyTransaction({
    required this.transactionId,
    required this.planId,
    required this.operation,
    required this.kind,
    required this.profile,
    required this.ownership,
    required this.phase,
    required this.target,
    required this.candidateSha256,
    required this.observations,
    this.source,
    this.sourceSha256,
    this.sourceInstallationId,
    this.root,
    this.form,
    this.recoveryPath,
    this.receiptId,
  });

  /// Reads a validated legacy transaction document.
  factory AuthoringLegacyTransaction.fromJson(Object? value) {
    final map = _object(value, 'legacy authoring transaction');
    _knownKeys(map, const {
      'schemaVersion',
      'transactionId',
      'planId',
      'operation',
      'kind',
      'profile',
      'ownership',
      'phase',
      'target',
      'source',
      'sourceSha256',
      'sourceInstallationId',
      'root',
      'form',
      'recoveryPath',
      'receiptId',
      'candidateSha256',
      'observations',
      'digest',
    }, 'legacy authoring transaction');
    if (_integer(map, 'schemaVersion') !=
        authoringLegacyTransactionSchemaVersion) {
      throw const FormatException(
        'Unsupported legacy authoring transaction schema version.',
      );
    }
    final transactionId = _string(map, 'transactionId');
    if (!isAuthoringTransactionId(transactionId)) {
      throw const FormatException('Invalid authoring transaction identifier.');
    }
    final transaction = AuthoringLegacyTransaction(
      transactionId: transactionId,
      planId: _string(map, 'planId'),
      operation: _string(map, 'operation'),
      kind: _string(map, 'kind'),
      profile: _string(map, 'profile'),
      ownership: _string(map, 'ownership'),
      phase: AuthoringTransactionPhase.values.firstWhere(
        (value) => value.name == _string(map, 'phase'),
        orElse: () =>
            throw const FormatException('Unknown authoring transaction phase.'),
      ),
      target: _absolutePath(_string(map, 'target')),
      source: map['source'] == null
          ? null
          : _absolutePath(_string(map, 'source')),
      sourceSha256: _nullableString(map, 'sourceSha256'),
      sourceInstallationId: _nullableString(map, 'sourceInstallationId'),
      root: _nullableString(map, 'root'),
      form: _nullableString(map, 'form'),
      recoveryPath: map['recoveryPath'] == null
          ? null
          : _absolutePath(_string(map, 'recoveryPath')),
      receiptId: _nullableString(map, 'receiptId'),
      candidateSha256: _string(map, 'candidateSha256'),
      observations: _object(map['observations'], 'observations'),
    );
    if (_string(map, 'digest') != transaction.digest) {
      throw const FormatException(
        'The legacy authoring transaction digest does not bind.',
      );
    }
    return transaction;
  }

  /// The identifier of the transaction.
  final String transactionId;

  /// The identity of the reviewed plan that authorized the publication.
  final String planId;

  /// The published operation.
  final String operation;

  /// The published resource kind.
  final String kind;

  /// The published native profile.
  final String profile;

  /// The ownership the publication established.
  final String ownership;

  /// The phase of the publication.
  final AuthoringTransactionPhase phase;

  /// The published native location.
  final String target;

  /// The reviewed source of the publication.
  final String? source;

  /// The digest of the reviewed source marker before the publication.
  final String? sourceSha256;

  /// The managed installation of a tracked source.
  final String? sourceInstallationId;

  /// The native root of the published placement.
  final String? root;

  /// The native form of the published placement.
  final String? form;

  /// The retained recovery payload of the previous bytes.
  final String? recoveryPath;

  /// The authoring receipt of the publication.
  final String? receiptId;

  /// The digest of the published native content.
  final String candidateSha256;

  /// The transaction observations.
  final Map<String, Object?> observations;

  /// Whether the transaction reached its terminal phase.
  bool get terminal =>
      phase == AuthoringTransactionPhase.completed ||
      phase == AuthoringTransactionPhase.rolledBack;

  /// The reason a legacy transaction is blocked.
  ///
  /// A legacy document records no content evidence, so a recovery cannot
  /// prove the retained payload or the published target it would change.
  String get blockedReason =>
      'The legacy authoring transaction records no content evidence; a '
      'recovery or a cleanup of it is refused and its bytes are retained.';

  /// The digest that binds the document.
  String get digest => sha256
      .convert(utf8.encode(jsonEncode(canonicalAuthoringJson(_body()))))
      .toString();

  /// The bound body of the document.
  Map<String, Object?> _body() => <String, Object?>{
    'schemaVersion': authoringLegacyTransactionSchemaVersion,
    'transactionId': transactionId,
    'planId': planId,
    'operation': operation,
    'kind': kind,
    'profile': profile,
    'ownership': ownership,
    'phase': phase.name,
    'target': target,
    'source': source,
    'sourceSha256': sourceSha256,
    'sourceInstallationId': sourceInstallationId,
    'root': root,
    'form': form,
    'recoveryPath': recoveryPath,
    'receiptId': receiptId,
    'candidateSha256': candidateSha256,
    'observations': observations,
  };
}

/// Reads a transaction document of any supported schema version.
///
/// The document is bounded before it is parsed. A current document is
/// returned as the actionable transaction, a legacy document is returned as
/// a read-only view and an unknown schema version or a corrupt document
/// fails closed: it is never evidence of a free state.
AuthoringTransactionDocument decodeAuthoringTransactionDocument(
  String encoded,
) {
  final bytes = utf8.encode(encoded);
  if (bytes.length > maxAuthoringTransactionBytes) {
    throw const FormatException(
      'The authoring transaction document exceeds its byte limit.',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(encoded);
  } on FormatException {
    rethrow;
  } on Object {
    throw const FormatException(
      'The authoring transaction document is not valid JSON.',
    );
  }
  _checkBudget(decoded);
  final map = _object(decoded, 'authoring transaction');
  final version = map['schemaVersion'];
  if (version is! int) {
    throw const FormatException(
      'The authoring transaction document has no schema version.',
    );
  }
  if (version == authoringTransactionSchemaVersion) {
    return CurrentAuthoringTransactionDocument(
      AuthoringTransaction.fromJson(map),
    );
  }
  if (version == authoringLegacyTransactionSchemaVersion) {
    return LegacyAuthoringTransactionDocument(
      AuthoringLegacyTransaction.fromJson(map),
    );
  }
  throw const FormatException(
    'Unsupported authoring transaction schema version.',
  );
}

/// Checks the node budget of a parsed document.
void _checkBudget(Object? value) {
  var nodes = 0;
  void walk(Object? node, int depth) {
    if (++nodes > authoringTransactionMaxNodes) {
      throw const FormatException(
        'The authoring transaction exceeds its node limit.',
      );
    }
    if (depth > authoringTransactionMaxDepth) {
      throw const FormatException(
        'The authoring transaction exceeds its depth limit.',
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

/// The validated content evidence of one transaction.
Map<String, Object?> _evidence(Object? value) {
  final map = _object(value, 'authoring transaction evidence');
  _knownKeys(map, const {
    'version',
    'payloadPath',
    'payloadManifest',
    'plannedManifest',
    'publishedManifest',
    'receiptTarget',
  }, 'authoring transaction evidence');
  if (_integer(map, 'version') != authoringEvidenceVersion) {
    throw const FormatException(
      'Unsupported authoring transaction evidence version.',
    );
  }
  final payloadPath = map['payloadPath'] == null
      ? null
      : _absolutePath(_string(map, 'payloadPath'));
  final payloadManifest = _manifest(map['payloadManifest'], 'payloadManifest');
  final plannedManifest = _manifest(map['plannedManifest'], 'plannedManifest');
  final publishedManifest = _manifest(
    map['publishedManifest'],
    'publishedManifest',
  );
  if (payloadManifest != null && payloadPath == null) {
    throw const FormatException(
      'The authoring transaction evidence has no payload path.',
    );
  }
  return <String, Object?>{
    'version': authoringEvidenceVersion,
    'payloadPath': payloadPath,
    'payloadManifest': payloadManifest,
    'plannedManifest': plannedManifest,
    'publishedManifest': publishedManifest,
    'receiptTarget': _absolutePath(_string(map, 'receiptTarget')),
  };
}

/// The validated content evidence records of one transaction.
List<Map<String, Object?>>? _manifest(Object? value, String label) {
  if (value == null) return null;
  if (value is! List<Object?>) {
    throw FormatException('The $label must be a list.');
  }
  final entries = <Map<String, Object?>>[];
  var previous = '';
  for (final item in value) {
    final entry = _object(item, label);
    _knownKeys(entry, const {'path', 'type', 'length', 'sha256'}, label);
    final path = _string(entry, 'path');
    if (path.startsWith('/') ||
        path.contains('\\') ||
        path.split('/').contains('..')) {
      throw FormatException('The $label holds an unsafe relative path.');
    }
    final type = _string(entry, 'type');
    if (type != 'file' && type != 'directory') {
      throw FormatException('The $label holds an unsupported member type.');
    }
    final length = _integer(entry, 'length');
    if (length < 0) {
      throw FormatException('The $label holds a negative member length.');
    }
    final digest = entry['sha256'];
    if (type == 'directory') {
      if (digest != null) {
        throw FormatException('The $label holds a digested directory.');
      }
    } else {
      if (digest is! String || !_contentDigestPattern.hasMatch(digest)) {
        throw FormatException('The $label holds an invalid content digest.');
      }
    }
    if (previous.isNotEmpty && path.compareTo(previous) <= 0) {
      throw FormatException(
        'The $label must be ordered by path and free of duplicates.',
      );
    }
    previous = path;
    entries.add(<String, Object?>{
      'path': path,
      'type': type,
      'length': length,
      'sha256': digest,
    });
  }
  return entries;
}

/// The validated authority context of one transaction.
Map<String, Object?> _authority(Object? value) {
  final map = _object(value, 'authoring transaction authority');
  _knownKeys(map, const {
    'scope',
    'stateRoot',
    'projectRoot',
    'home',
    'userStateRoot',
  }, 'authoring transaction authority');
  final scope = _string(map, 'scope');
  if (scope != 'project' && scope != 'user') {
    throw const FormatException('Unknown authoring transaction scope.');
  }
  return <String, Object?>{
    'scope': scope,
    'stateRoot': _absolutePath(_string(map, 'stateRoot')),
    'projectRoot': _absolutePath(_string(map, 'projectRoot')),
    'home': map['home'] == null ? null : _absolutePath(_string(map, 'home')),
    'userStateRoot': map['userStateRoot'] == null
        ? null
        : _absolutePath(_string(map, 'userStateRoot')),
  };
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

int _integer(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) {
    throw FormatException('The $key must be an integer.');
  }
  return value;
}

String _absolutePath(String value) {
  if (!value.startsWith('/') && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
    throw const FormatException('A recorded path must be absolute.');
  }
  return value;
}

/// One pending ordinary authoring transaction.
///
/// A pending transaction reserves its published location and its reviewed
/// source until it reaches a terminal phase. It also reserves its visible
/// native name inside its native root, so a name conflict with a pending
/// publication is detected before the live change.
final class PendingAuthoringTransaction {
  const PendingAuthoringTransaction({
    required this.transactionId,
    required this.documentPath,
    required this.target,
    required this.source,
    required this.nativeName,
    required this.root,
    required this.kind,
    required this.profile,
  });

  /// The identity of the pending transaction.
  final String transactionId;

  /// The exact evidence document that records the pending transaction.
  ///
  /// The path is the authority of the transaction: an exclusion that names
  /// one document never exempts another scope that happens to carry the
  /// same identity.
  final String documentPath;

  /// The published location that the transaction reserves.
  final String target;

  /// The reviewed source that the transaction reserves.
  final String? source;

  /// The visible native name that the transaction reserves.
  final String? nativeName;

  /// The native root of the reserved name.
  final String? root;

  /// The published resource kind.
  final String kind;

  /// The published native profile.
  final String profile;

  /// The locations that the transaction reserves.
  List<String> get reservedLocations => <String>[target, ?source];

  /// Whether the transaction reserves one of the locations.
  bool reserves(fslib.FileSystem fs, Iterable<String> locations) {
    final reserved = reservedLocations
        .map((location) => fs.path.normalize(fs.path.absolute(location)))
        .toList();
    return locations.any((location) {
      final candidate = fs.path.normalize(fs.path.absolute(location));
      return reserved.any(
        (path) =>
            fs.path.equals(path, candidate) ||
            fs.path.isWithin(path, candidate) ||
            fs.path.isWithin(candidate, path),
      );
    });
  }
}

/// The pending ordinary authoring transactions of one authority directory.
///
/// The scan is fail closed: a corrupt or an unknown document refuses the
/// mutation instead of implying a free state. A terminal transaction
/// reserves nothing. A legacy transaction reserves its recorded target and
/// its recorded source until it is resolved by hand, because it records no
/// content evidence and it is never interpreted as a free state.
List<PendingAuthoringTransaction> pendingAuthoringTransactions(
  fslib.FileSystem fs,
  String transactionDirectory,
) {
  final pending = <PendingAuthoringTransaction>[];
  final type = fs.typeSync(transactionDirectory, followLinks: false);
  if (type == fslib.FileSystemEntityType.notFound) return pending;
  if (type != fslib.FileSystemEntityType.directory) {
    throw MambaException(
      'The authoring transaction authority is not a directory: '
      '$transactionDirectory',
      exitCode: 6,
    );
  }

  for (final entry
      in fs.directory(transactionDirectory).listSync(followLinks: false)) {
    final name = fs.path.basename(entry.path);
    if (!name.endsWith('.json')) continue;
    final transactionId = name.substring(0, name.length - '.json'.length);
    if (!isAuthoringTransactionId(transactionId)) continue;
    final bytes = readBoundedSkillMarker(
      entry.path,
      maxBytes: maxAuthoringTransactionBytes,
      fs: fs,
    );
    if (bytes.length > maxAuthoringTransactionBytes) {
      throw MambaException(
        'The authoring transaction document exceeds its byte limit: $name',
        exitCode: 6,
      );
    }
    final String encoded;
    try {
      encoded = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw MambaException(
        'The authoring transaction document is not valid UTF-8: $name',
        exitCode: 6,
      );
    }
    final AuthoringTransactionDocument document;
    try {
      document = decodeAuthoringTransactionDocument(encoded);
    } on FormatException catch (error) {
      throw MambaException(
        'The authoring transaction evidence is unusable: ${error.message}',
        exitCode: 6,
      );
    }
    if (document.transactionId != transactionId) {
      throw MambaException(
        'The authoring transaction document does not carry its own identity: '
        '$name',
        exitCode: 6,
      );
    }
    if (document.terminal) continue;
    switch (document) {
      case CurrentAuthoringTransactionDocument(:final transaction):
        pending.add(
          PendingAuthoringTransaction(
            transactionId: transaction.transactionId,
            documentPath: entry.path,
            target: transaction.target,
            source: transaction.source,
            nativeName: transaction.nativeName,
            root: transaction.root,
            kind: transaction.kind,
            profile: transaction.profile,
          ),
        );
      case LegacyAuthoringTransactionDocument(:final transaction):
        pending.add(
          PendingAuthoringTransaction(
            transactionId: transaction.transactionId,
            documentPath: entry.path,
            target: transaction.target,
            source: transaction.source,
            nativeName: null,
            root: transaction.root,
            kind: transaction.kind,
            profile: transaction.profile,
          ),
        );
    }
  }
  return pending;
}
