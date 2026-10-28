import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';
import 'package:toml/toml.dart';

const sourceConfigFileName = 'agent-resources.toml';
const maxSourceConfigBytes = 1024 * 1024;
const maxSourceConfigDepth = 16;
const maxSourceConfigNodes = 100000;
const maxCatalogEntries = 1000;

enum CatalogResourceType { skill, agent }

enum NativeAgentProfile implements MambaEnumValue {
  claude('claude'),
  codex('codex'),
  piCommon('pi-common');

  const NativeAgentProfile(this.wireName);
  final String wireName;

  @override
  String get value => wireName;
}

sealed class CatalogOffering {
  const CatalogOffering({
    required this.id,
    required this.path,
    required this.label,
  });

  final String id;
  final String path;
  final String? label;
}

final class SkillOffering extends CatalogOffering {
  const SkillOffering({
    required super.id,
    required super.path,
    required super.label,
  });
}

final class AgentOffering extends CatalogOffering {
  const AgentOffering({
    required super.id,
    required super.path,
    required super.label,
    required this.profile,
  });

  final NativeAgentProfile profile;
}

/// A validated, immutable view of one resource type in agent-resources.toml.
/// Syntax, root shape and version failures are shared; entry semantics are
/// deliberately isolated to the requested type.
final class ResourceCatalog {
  const ResourceCatalog._({
    required this.schemaVersion,
    required this.configPath,
    required this.configDigest,
    required this.offerings,
  });

  factory ResourceCatalog.load(String path, CatalogResourceType type) {
    final bytes = _readBounded(path);
    final digest = sha256.convert(bytes).toString();
    final String source;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw MambaException(
        '$sourceConfigFileName must be valid UTF-8.',
        exitCode: 1,
      );
    }
    _checkLexicalDepth(source);
    final Map<String, dynamic> document;
    try {
      document = TomlDocument.parse(source).toMap();
    } on TomlParserException catch (error) {
      throw MambaException(
        'Invalid $sourceConfigFileName at ${error.line}:${error.column}: '
        '${error.message}.',
        exitCode: 1,
      );
    } on TomlRedefinitionException catch (error) {
      throw MambaException(
        'Invalid $sourceConfigFileName: duplicate key or table ${error.name}.',
        exitCode: 1,
      );
    } on FormatException catch (error) {
      throw MambaException(
        'Invalid $sourceConfigFileName: ${error.message}.',
        exitCode: 1,
      );
    } on TomlException {
      throw MambaException(
        'Invalid $sourceConfigFileName syntax or value.',
        exitCode: 1,
      );
    }
    _checkDocumentBounds(document);
    _validateRoot(document);
    final offerings = _validateOfferings(document, type);
    return ResourceCatalog._(
      schemaVersion: 1,
      configPath: path,
      configDigest: digest,
      offerings: List<CatalogOffering>.unmodifiable(offerings),
    );
  }

  final int schemaVersion;
  final String configPath;
  final String configDigest;
  final List<CatalogOffering> offerings;
}

List<int> _readBounded(String path) {
  final RandomAccessFile file;
  try {
    file = File(path).openSync();
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not read the required $sourceConfigFileName: ${error.message}',
      exitCode: 3,
    );
  }
  try {
    final bytes = file.readSync(maxSourceConfigBytes + 1);
    if (bytes.length > maxSourceConfigBytes) {
      throw MambaException(
        '$sourceConfigFileName exceeds the 1 MiB source-config budget.',
        exitCode: 3,
      );
    }
    return bytes;
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not read the required $sourceConfigFileName: ${error.message}',
      exitCode: 3,
    );
  } finally {
    file.closeSync();
  }
}

void _checkLexicalDepth(String source) {
  var depth = 0;
  var quote = 0;
  var triple = false;
  var escaped = false;
  var comment = false;
  for (var index = 0; index < source.length; index++) {
    final unit = source.codeUnitAt(index);
    if (comment) {
      if (unit == 0x0A) comment = false;
      continue;
    }
    if (quote != 0) {
      if (triple &&
          index + 2 < source.length &&
          source.codeUnitAt(index + 1) == quote &&
          source.codeUnitAt(index + 2) == quote) {
        quote = 0;
        triple = false;
        index += 2;
        continue;
      }
      if (!triple && unit == quote && !escaped) {
        quote = 0;
        continue;
      }
      if (quote == 0x22 && unit == 0x5C && !escaped) {
        escaped = true;
      } else {
        escaped = false;
      }
      continue;
    }
    if (unit == 0x23) {
      comment = true;
      continue;
    }
    if (unit == 0x22 || unit == 0x27) {
      quote = unit;
      triple =
          index + 2 < source.length &&
          source.codeUnitAt(index + 1) == unit &&
          source.codeUnitAt(index + 2) == unit;
      if (triple) index += 2;
      escaped = false;
      continue;
    }
    if (unit == 0x5B || unit == 0x7B) {
      depth++;
      if (depth > maxSourceConfigDepth) {
        throw MambaException(
          '$sourceConfigFileName exceeds the nesting-depth-16 budget.',
          exitCode: 3,
        );
      }
    } else if (unit == 0x5D || unit == 0x7D) {
      if (depth > 0) depth--;
    }
  }
}

void _checkDocumentBounds(Object? document) {
  var nodes = 0;
  void visit(Object? value, int depth) {
    if (depth > maxSourceConfigDepth) {
      throw MambaException(
        '$sourceConfigFileName exceeds the nesting-depth-16 budget.',
        exitCode: 3,
      );
    }
    nodes++;
    if (nodes > maxSourceConfigNodes) {
      throw MambaException(
        '$sourceConfigFileName exceeds the 100,000-node budget.',
        exitCode: 3,
      );
    }
    if (value is Map) {
      for (final entry in value.entries) {
        visit(entry.key, depth + 1);
        visit(entry.value, depth + 1);
      }
    } else if (value is List) {
      for (final item in value) {
        visit(item, depth + 1);
      }
    }
  }

  visit(document, 0);
}

void _validateRoot(Map<String, dynamic> document) {
  final unknown = document.keys
      .where(
        (key) => !const {'schema_version', 'skills', 'agents'}.contains(key),
      )
      .toList();
  if (unknown.isNotEmpty) {
    throw MambaException(
      '$sourceConfigFileName has unsupported root field(s): '
      '${unknown.join(', ')}.',
      exitCode: 1,
    );
  }
  if (document['schema_version'] is! int ||
      document['schema_version'] != 1 ||
      document['schema_version'] is bool) {
    throw MambaException(
      '$sourceConfigFileName requires integer schema_version = 1.',
      exitCode: 1,
    );
  }
}

List<CatalogOffering> _validateOfferings(
  Map<String, dynamic> document,
  CatalogResourceType type,
) {
  final section = type == CatalogResourceType.skill ? 'skills' : 'agents';
  final value = document[section];
  if (value == null) return const <CatalogOffering>[];
  if (value is! List) {
    throw MambaException(
      '$sourceConfigFileName $section must be an array of entry tables.',
      exitCode: 1,
    );
  }
  if (value.length > maxCatalogEntries) {
    throw MambaException(
      '$sourceConfigFileName $section exceeds the 1,000-entry catalog budget.',
      exitCode: 3,
    );
  }
  final errors = <String>[];
  final offerings = <CatalogOffering>[];
  final ids = <String>{};
  final paths = <String>{};
  for (var index = 0; index < value.length; index++) {
    final location = '$section[$index]';
    final raw = value[index];
    if (raw is! Map) {
      errors.add('$location must be an entry table.');
      continue;
    }
    final entry = <String, Object?>{
      for (final field in raw.entries)
        if (field.key is String) field.key as String: field.value,
    };
    if (entry.length != raw.length) {
      errors.add('$location has a non-string field name.');
      continue;
    }
    final allowed = type == CatalogResourceType.skill
        ? const {'id', 'path', 'label'}
        : const {'id', 'path', 'profile', 'label'};
    for (final field in entry.keys.where((key) => !allowed.contains(key))) {
      errors.add('$location has unsupported field $field.');
    }
    final id = _stringField(entry, 'id', location, errors, required: true);
    final path = _stringField(entry, 'path', location, errors, required: true);
    final label = _stringField(entry, 'label', location, errors);
    final profile = type == CatalogResourceType.agent
        ? _stringField(entry, 'profile', location, errors, required: true)
        : null;
    if (id != null && !_validId(id)) {
      errors.add(
        '$location id must be 1–64 lowercase ASCII kebab-case characters.',
      );
    }
    if (label != null && !_validLabel(label)) {
      errors.add(
        '$location label must be a nonblank single-line string of at most '
        '256 Unicode scalar values without control characters.',
      );
    }
    if (path != null && !_validPath(path)) {
      errors.add(
        '$location path must be a safe forward-slash source-relative path; '
        'only a root Skill may use ".".',
      );
    }
    if (path != null && utf8.encode(path).length > 4096) {
      errors.add('$location path exceeds the 4,096-UTF-8-byte budget.');
    }
    if (id != null && !ids.add(id)) {
      errors.add('$location duplicates id "$id" in $section.');
    }
    if (path != null && !paths.add(path)) {
      errors.add('$location duplicates path "$path" in $section.');
    }
    NativeAgentProfile? nativeProfile;
    if (profile != null) {
      nativeProfile = NativeAgentProfile.values
          .where((candidate) => candidate.wireName == profile)
          .firstOrNull;
      if (nativeProfile == null) {
        errors.add(
          '$location profile must be exactly claude, codex, or pi-common.',
        );
      }
    }
    if (id == null ||
        path == null ||
        !_validId(id) ||
        !_validPath(path) ||
        (label != null && !_validLabel(label)) ||
        (type == CatalogResourceType.agent && nativeProfile == null)) {
      continue;
    }
    offerings.add(
      type == CatalogResourceType.skill
          ? SkillOffering(id: id, path: path, label: label)
          : AgentOffering(
              id: id,
              path: path,
              label: label,
              profile: nativeProfile!,
            ),
    );
  }
  if (errors.isNotEmpty) {
    throw MambaException(
      'Invalid $sourceConfigFileName $section catalog:\n- ${errors.join('\n- ')}',
      exitCode: 1,
    );
  }
  return offerings;
}

String? _stringField(
  Map<String, Object?> entry,
  String field,
  String location,
  List<String> errors, {
  bool required = false,
}) {
  final value = entry[field];
  if (value == null) {
    if (required || entry.containsKey(field)) {
      errors.add('$location $field must be a string.');
    }
    return null;
  }
  if (value is! String) {
    errors.add('$location $field must be a string.');
    return null;
  }
  return value;
}

bool _validId(String id) =>
    id.length <= 64 && RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(id);

bool _validLabel(String label) =>
    label.trim().isNotEmpty &&
    label.runes.length <= 256 &&
    !label.runes.any((rune) => rune < 0x20 || rune == 0x7F);

bool _validPath(String path) {
  if (path == '.') return true;
  if (path.isEmpty ||
      path.contains(r'\') ||
      path.endsWith('/') ||
      path.runes.any((rune) => rune < 0x20 || rune == 0x7F)) {
    return false;
  }
  if (path.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(path)) {
    return false;
  }
  final segments = path.split('/');
  return segments.every(
    (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
