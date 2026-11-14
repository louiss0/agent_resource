import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../services/lifecycle_state_service.dart' show LifecycleScope;
import 'authoring_inputs.dart';
import 'authoring_transaction.dart' show canonicalAuthoringJson;
import 'instruction_draft.dart';

/// The schema version of the instruction draft document.
const int instructionDraftSchemaVersion = 1;

/// The largest instruction draft document that is read or written.
const int maxInstructionDraftDocumentBytes = 256 * 1024;

/// The name of the prepared instruction snapshot inside a draft directory.
const String instructionDraftBodyFileName = 'body';

/// The name of the editable working copy inside a draft directory.
const String instructionDraftWorkingFileName = 'working.txt';

/// The name of the metadata document inside a draft directory.
const String instructionDraftMetadataFileName = 'draft.json';

/// The durable metadata of one retained instruction draft.
///
/// The document binds the draft identity, the reconstructible intent and the
/// digest of the prepared instruction snapshot. It never carries the
/// instruction body, a plan identity, an approval or any other consent, and
/// it rejects unknown fields so a consent cannot be smuggled into it.
final class InstructionDraftDocument {
  const InstructionDraftDocument({
    required this.draftId,
    required this.createdAt,
    required this.intent,
    required this.bodyOrigin,
    required this.bodySha256,
    required this.bodyByteLength,
    this.bodySourcePath,
  });

  /// Reads a validated draft document.
  factory InstructionDraftDocument.fromJson(Object? value) {
    final map = _object(value, 'instruction draft');
    _knownKeys(map, const {
      'schemaVersion',
      'draftId',
      'createdAt',
      'intent',
      'body',
      'digest',
    }, 'instruction draft');
    if (_integer(map, 'schemaVersion') != instructionDraftSchemaVersion) {
      throw const FormatException(
        'Unsupported instruction draft schema version.',
      );
    }
    final draftId = _string(map, 'draftId');
    if (!isInstructionDraftId(draftId)) {
      throw const FormatException('Invalid instruction draft identifier.');
    }
    final body = _object(map['body'], 'instruction draft body');
    _knownKeys(body, const {
      'origin',
      'sourcePath',
      'file',
      'sha256',
      'byteLength',
    }, 'instruction draft body');
    final file = _string(body, 'file');
    if (file != instructionDraftBodyFileName) {
      throw const FormatException(
        'The instruction draft does not bind the prepared snapshot.',
      );
    }
    final document = InstructionDraftDocument(
      draftId: draftId,
      createdAt: _string(map, 'createdAt'),
      intent: _intent(map['intent']),
      bodyOrigin: _enum(
        InstructionDraftBodyOrigin.values,
        _string(body, 'origin'),
        'instruction draft body origin',
      ),
      bodySha256: _string(body, 'sha256'),
      bodyByteLength: _integer(body, 'byteLength'),
      bodySourcePath: _nullableString(body, 'sourcePath'),
    );
    if (_string(map, 'digest') != document.digest) {
      throw const FormatException(
        'The instruction draft digest does not bind.',
      );
    }
    return document;
  }

  /// The identity of the draft.
  final String draftId;

  /// The creation time of the draft.
  final String createdAt;

  /// The reconstructible intent of the draft.
  final InstructionDraftIntent intent;

  /// The origin of the drafted instructions.
  final InstructionDraftBodyOrigin bodyOrigin;

  /// The digest of the prepared instruction snapshot.
  final String bodySha256;

  /// The byte length of the prepared instruction snapshot.
  final int bodyByteLength;

  /// The original input the instructions came from, when they came from a
  /// file.
  final String? bodySourcePath;

  /// The digest that binds the document.
  String get digest => sha256
      .convert(utf8.encode(jsonEncode(canonicalAuthoringJson(_body()))))
      .toString();

  /// The bound body of the document.
  Map<String, Object?> _body() => <String, Object?>{
    'schemaVersion': instructionDraftSchemaVersion,
    'draftId': draftId,
    'createdAt': createdAt,
    'intent': _intentJson(intent),
    'body': <String, Object?>{
      'origin': bodyOrigin.name,
      'sourcePath': bodySourcePath,
      'file': instructionDraftBodyFileName,
      'sha256': bodySha256,
      'byteLength': bodyByteLength,
    },
  };

  /// The serialized document.
  Map<String, Object?> toJson() => <String, Object?>{
    ..._body(),
    'digest': digest,
  };

  /// The encoded document.
  String encode() => jsonEncode(toJson());

  /// Reads a draft document from its encoded form.
  ///
  /// The document is bounded before it is parsed. An unknown key, an unknown
  /// schema version, a corrupt digest and an inconsistent document fail
  /// closed: a substituted document is never evidence of an owned draft.
  static InstructionDraftDocument decode(String encoded) {
    final bytes = utf8.encode(encoded);
    if (bytes.length > maxInstructionDraftDocumentBytes) {
      throw const FormatException(
        'The instruction draft document exceeds its byte limit.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException(
        'The instruction draft document is not valid JSON.',
      );
    }
    return InstructionDraftDocument.fromJson(decoded);
  }
}

/// The JSON body of one authoring intent.
Map<String, Object?> _intentJson(InstructionDraftIntent intent) =>
    <String, Object?>{
      'operation': intent.operation.name,
      'kind': intent.kind.name,
      'profile': intent.profile.name,
      'scope': intent.scope.name,
      'source': <String, Object?>{
        'path': intent.sourcePath,
        'installationId': intent.installationId,
        'profile': intent.sourceProfile?.name,
      },
      'fields': <String, Object?>{
        for (final entry in intent.fields.entries)
          entry.key: _fieldJson(entry.value),
      },
      'manage': intent.manage,
      'composition': intent.composition?.name,
      'conversion': intent.conversion?.name,
      'output': intent.output,
      'decisions': intent.decisions.toList()..sort(),
      'references': intent.references,
    };

/// Reads one authoring intent.
InstructionDraftIntent _intent(Object? value) {
  final map = _object(value, 'instruction draft intent');
  _knownKeys(map, const {
    'operation',
    'kind',
    'profile',
    'scope',
    'source',
    'fields',
    'manage',
    'composition',
    'conversion',
    'output',
    'decisions',
    'references',
  }, 'instruction draft intent');
  final source = _object(map['source'], 'instruction draft source');
  _knownKeys(source, const {
    'path',
    'installationId',
    'profile',
  }, 'instruction draft source');
  final fields = _object(map['fields'], 'instruction draft fields');
  return InstructionDraftIntent(
    operation: _enum(
      AuthoringOperation.values,
      _string(map, 'operation'),
      'authoring operation',
    ),
    kind: _enum(AuthoringKind.values, _string(map, 'kind'), 'authoring kind'),
    profile: _enum(
      AuthoringProfile.values,
      _string(map, 'profile'),
      'authoring profile',
    ),
    scope: _enum(
      LifecycleScope.values,
      _string(map, 'scope'),
      'lifecycle scope',
    ),
    sourcePath: _nullableString(source, 'path'),
    installationId: _nullableString(source, 'installationId'),
    sourceProfile: source['profile'] == null
        ? null
        : _enum(
            AuthoringProfile.values,
            _string(source, 'profile'),
            'authoring profile',
          ),
    fields: Map<String, AuthoringFieldValue>.unmodifiable(
      <String, AuthoringFieldValue>{
        for (final entry in fields.entries)
          entry.key: _fieldValue(entry.key, entry.value),
      },
    ),
    manage: _boolean(map, 'manage'),
    composition: map['composition'] == null
        ? null
        : _enum(
            CompositionMode.values,
            _string(map, 'composition'),
            'composition mode',
          ),
    conversion: map['conversion'] == null
        ? null
        : _enum(
            ConversionDirection.values,
            _string(map, 'conversion'),
            'conversion direction',
          ),
    output: _nullableString(map, 'output'),
    decisions: Set<String>.unmodifiable(_strings(map, 'decisions')),
    references: Map<String, String>.unmodifiable(<String, String>{
      for (final entry in _object(
        map['references'],
        'instruction draft references',
      ).entries)
        entry.key: '${entry.value}',
    }),
  );
}

/// The JSON body of one native field value.
Map<String, Object?> _fieldJson(AuthoringFieldValue value) => switch (value) {
  TextFieldValue(:final text) => <String, Object?>{
    'type': 'text',
    'value': text,
  },
  ListFieldValue(:final values) => <String, Object?>{
    'type': 'list',
    'value': values,
  },
  MapFieldValue(:final entries) => <String, Object?>{
    'type': 'map',
    'value': entries,
  },
  ClearedFieldValue() => const <String, Object?>{'type': 'cleared'},
  InheritedFieldValue() => const <String, Object?>{'type': 'inherited'},
};

/// Reads one native field value.
AuthoringFieldValue _fieldValue(String name, Object? value) {
  final map = _object(value, 'instruction draft field');
  final type = _string(map, 'type');
  switch (type) {
    case 'text':
      _knownKeys(map, const {'type', 'value'}, 'instruction draft field');
      return TextFieldValue(_string(map, 'value'));
    case 'list':
      _knownKeys(map, const {'type', 'value'}, 'instruction draft field');
      return ListFieldValue(_strings(map, 'value'));
    case 'map':
      _knownKeys(map, const {'type', 'value'}, 'instruction draft field');
      final entries = _object(map['value'], 'instruction draft field');
      return MapFieldValue(
        Map<String, Object?>.unmodifiable(<String, Object?>{
          for (final entry in entries.entries) entry.key: entry.value,
        }),
      );
    case 'cleared':
      _knownKeys(map, const {'type'}, 'instruction draft field');
      return const ClearedFieldValue();
    case 'inherited':
      _knownKeys(map, const {'type'}, 'instruction draft field');
      return const InheritedFieldValue();
    default:
      throw FormatException('Unsupported instruction draft field type: $type');
  }
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

bool _boolean(Map<String, Object?> map, String key) {
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

List<String> _strings(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! List<Object?>) {
    throw FormatException('The $key must be an array.');
  }
  final items = <String>[];
  for (final item in value) {
    if (item is! String) {
      throw FormatException('The $key must contain only text values.');
    }
    items.add(item);
  }
  return items;
}

T _enum<T extends Enum>(List<T> values, String name, String label) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unknown $label: $name');
}
