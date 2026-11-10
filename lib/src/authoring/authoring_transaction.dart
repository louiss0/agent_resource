import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;

/// The schema version of the authoring transaction document.
const int authoringTransactionSchemaVersion = 1;

/// The largest authoring transaction document that is read or written.
const int maxAuthoringTransactionBytes = 1024 * 1024;

/// The largest nesting depth of an authoring transaction document.
const int authoringTransactionMaxDepth = 16;

/// The largest number of nodes of an authoring transaction document.
const int authoringTransactionMaxNodes = 2000;

/// The pattern of an authoring transaction identifier.
final RegExp authoringTransactionIdPattern = RegExp(r'^aut_[a-f0-9]{32}$');

/// Whether the value is an authoring transaction identifier.
bool isAuthoringTransactionId(String value) =>
    authoringTransactionIdPattern.hasMatch(value);

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
    this.source,
    this.sourceSha256,
    this.sourceInstallationId,
    this.root,
    this.form,
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
      'recoveryPath',
      'receiptId',
      'candidateSha256',
      'observations',
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
    final transaction = AuthoringTransaction(
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

  /// A copy of the transaction with the selected changes.
  AuthoringTransaction copyWith({
    AuthoringTransactionPhase? phase,
    String? receiptId,
    Map<String, Object?>? observations,
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
    recoveryPath: recoveryPath,
    receiptId: receiptId ?? this.receiptId,
    candidateSha256: candidateSha256,
    observations: observations ?? this.observations,
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
    'recoveryPath': recoveryPath,
    'receiptId': receiptId,
    'candidateSha256': candidateSha256,
    'observations': observations,
  };

  /// The serialized document.
  Map<String, Object?> toJson() => <String, Object?>{
    ..._body(),
    'digest': digest,
  };

  /// The encoded document.
  String encode() => jsonEncode(toJson());

  /// Reads a transaction document from its encoded form.
  ///
  /// The document is bounded before it is parsed. An unknown key, an unknown
  /// schema version, a corrupt digest and an inconsistent document fail
  /// closed: they are never evidence of a free state.
  static AuthoringTransaction decode(String encoded) {
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
    return AuthoringTransaction.fromJson(decoded);
  }
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
