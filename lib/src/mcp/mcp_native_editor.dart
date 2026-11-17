import 'dart:convert';

import 'package:mamba/mamba.dart';

import 'mcp_native.dart' show McpNativeFormat;

/// An entry-level mutation applied to a shared native MCP configuration file.
///
/// The editor patches source ranges inside the selected named entry only; every
/// unrelated key, field, comment, newline style and byte is left untouched. A
/// whole document is never regenerated over a shared file.
sealed class McpEntryMutation {
  const McpEntryMutation();
}

/// Insert a brand-new named entry (register).
final class McpInsertEntry extends McpEntryMutation {
  const McpInsertEntry(this.fields);
  final Map<String, Object?> fields;
}

/// Patch an existing named entry field by field (replace). Fields that are
/// unchanged between [current] and [proposed] - including existing literal
/// credentials and their inline comments - are preserved byte-for-byte.
final class McpPatchEntry extends McpEntryMutation {
  const McpPatchEntry(this.current, this.proposed);
  final Map<String, Object?> current;
  final Map<String, Object?> proposed;
}

/// Remove the named entry (unregister).
final class McpRemoveEntry extends McpEntryMutation {
  const McpRemoveEntry();
}

/// Applies entry-only mutations to strict-JSON and TOML native sources.
///
/// JSON editing uses a bounded, duplicate-key-aware, range-recording parser
/// (comments / JSONC are not valid strict JSON and are refused). TOML editing
/// patches `[mcp_servers.<name>]` table ranges and preserves comments and
/// newline style; ambiguous shapes (multiline strings, arrays of tables) are
/// refused rather than reformatted.
final class McpNativeEditor {
  const McpNativeEditor();

  /// [text] is the whole current source; an empty string represents a missing
  /// file. Throws [MambaException] (operational status 1) on malformed or
  /// ambiguous content.
  String apply({
    required McpNativeFormat format,
    required String name,
    required String text,
    required McpEntryMutation mutation,
  }) => switch (format) {
    McpNativeFormat.json => _JsonEntryEditor(text).apply(name, mutation),
    McpNativeFormat.toml => _TomlEntryEditor(text).apply(name, mutation),
  };
}

MambaException _invalid(String detail) => MambaException(
  'MCP native file cannot be edited entry-only: $detail',
  exitCode: 1,
);

bool _same(Object? a, Object? b) =>
    jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));

Object? _canonical(Object? value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    return <String, Object?>{
      for (final e in entries) e.key.toString(): _canonical(e.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _canonical(item)];
  }
  return value;
}

// ---------------------------------------------------------------------------
// Range-recording strict JSON parser and editor
// ---------------------------------------------------------------------------

final class _JsonNode {
  _JsonNode(this.start, this.end, this.value, this.members, this.multiline);
  final int start;
  final int end;
  final Object? value;
  final Map<String, _JsonMember> members;
  final bool multiline;
}

final class _JsonMember {
  _JsonMember(this.keyStart, this.value, this.memberStart);
  final int keyStart;
  final _JsonNode value;
  final int memberStart;
}

final class _JsonParser {
  _JsonParser(this.source);
  final String source;
  var index = 0;
  var nodes = 0;

  _JsonNode node(int depth) {
    if (depth > 64) {
      throw const FormatException('JSON depth exceeds 64.');
    }
    if (++nodes > 100000) {
      throw const FormatException('JSON node budget exhausted.');
    }
    space();
    if (index >= source.length) {
      throw const FormatException('Unexpected JSON end.');
    }
    final char = source.codeUnitAt(index);
    if (char == 0x7B) {
      return object(depth);
    }
    if (char == 0x5B) {
      return array(depth);
    }
    final start = index;
    final value = scalar();
    return _JsonNode(start, index, value, const <String, _JsonMember>{}, false);
  }

  _JsonNode object(int depth) {
    final start = index++;
    final members = <String, _JsonMember>{};
    space();
    if (take(0x7D)) {
      return _JsonNode(start, index, const <String, Object?>{}, members, false);
    }
    var memberStart = index;
    while (true) {
      space();
      final keyStart = index;
      final key = string();
      if (members.containsKey(key)) {
        throw FormatException('Duplicate JSON key: $key.');
      }
      space();
      if (!take(0x3A)) {
        throw const FormatException('Expected colon.');
      }
      final valueNode = node(depth + 1);
      members[key] = _JsonMember(keyStart, valueNode, memberStart);
      space();
      if (take(0x7D)) {
        return _JsonNode(
          start,
          index,
          <String, Object?>{
            for (final e in members.entries) e.key: e.value.value.value,
          },
          members,
          source.substring(start, index).contains('\n'),
        );
      }
      if (!take(0x2C)) {
        throw const FormatException('Expected object comma.');
      }
      memberStart = index;
    }
  }

  _JsonNode array(int depth) {
    final start = index++;
    final items = <Object?>[];
    space();
    if (take(0x5D)) {
      return _JsonNode(
        start,
        index,
        <Object?>[],
        const <String, _JsonMember>{},
        false,
      );
    }
    while (true) {
      items.add(node(depth + 1).value);
      space();
      if (take(0x5D)) {
        return _JsonNode(
          start,
          index,
          items,
          const <String, _JsonMember>{},
          false,
        );
      }
      if (!take(0x2C)) {
        throw const FormatException('Expected array comma.');
      }
    }
  }

  Object? scalar() {
    if (index >= source.length) {
      throw const FormatException('Unexpected JSON end.');
    }
    final char = source.codeUnitAt(index);
    if (char == 0x22) {
      return string();
    }
    if (source.startsWith('true', index)) {
      index += 4;
      return true;
    }
    if (source.startsWith('false', index)) {
      index += 5;
      return false;
    }
    if (source.startsWith('null', index)) {
      index += 4;
      return null;
    }
    final match = RegExp(
      r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
    ).matchAsPrefix(source, index);
    if (match == null) {
      throw const FormatException('Invalid JSON value.');
    }
    index = match.end;
    return num.parse(match.group(0)!);
  }

  String string() {
    final start = index++;
    while (index < source.length) {
      final char = source.codeUnitAt(index++);
      if (char == 0x22) {
        return jsonDecode(source.substring(start, index)) as String;
      }
      if (char == 0x5C) {
        if (index >= source.length) {
          break;
        }
        index++;
      } else if (char < 0x20) {
        throw const FormatException('Control character in JSON string.');
      }
    }
    throw const FormatException('Unterminated JSON string.');
  }

  void space() {
    while (index < source.length &&
        const [0x20, 0x09, 0x0A, 0x0D].contains(source.codeUnitAt(index))) {
      index++;
    }
  }

  bool take(int char) {
    if (index < source.length && source.codeUnitAt(index) == char) {
      index++;
      return true;
    }
    return false;
  }
}

final class _JsonDoc {
  _JsonDoc(this.text, this.root);
  final String text;
  final _JsonNode root;

  factory _JsonDoc.parse(String text) {
    final parser = _JsonParser(text);
    final node = parser.node(0);
    parser.space();
    if (parser.index != text.length) {
      throw const FormatException('Trailing JSON content.');
    }
    if (node.value is! Map) {
      throw const FormatException('Expected a JSON object.');
    }
    return _JsonDoc(text, node);
  }

  Object? valueAt(List<String> path) {
    Object? current = root.value;
    for (final part in path) {
      if (current is! Map || !current.containsKey(part)) {
        return null;
      }
      current = current[part];
    }
    return current;
  }

  _JsonNode? objectAt(List<String> path) {
    var node = root;
    for (final part in path) {
      if (node.value is! Map) {
        return null;
      }
      final member = node.members[part];
      if (member == null) {
        return null;
      }
      node = member.value;
    }
    return node.value is Map ? node : null;
  }

  _JsonDoc setField(List<String> path, Object? value, {required bool remove}) {
    if (remove && valueAt(path) == null) {
      return this;
    }
    final parent = objectAt(path.sublist(0, path.length - 1));
    if (parent == null) {
      if (remove) {
        return this;
      }
      final insertion = path.first;
      final existing = valueAt([insertion]);
      final subtree = existing is Map
          ? Map<String, Object?>.from(existing)
          : <String, Object?>{};
      var cursor = subtree;
      for (final part in path.skip(1).take(path.length - 2)) {
        final next = <String, Object?>{};
        cursor[part] = next;
        cursor = next;
      }
      cursor[path.last] = value;
      return setField([insertion], subtree, remove: false);
    }
    final member = parent.members[path.last];
    if (member == null) {
      if (remove) {
        return this;
      }
      return _insert(path, parent, value);
    }
    if (remove) {
      return _remove(parent, member);
    }
    final target = member.value;
    final updated =
        '${text.substring(0, target.start)}'
        '${jsonEncode(value)}${text.substring(target.end)}';
    return _reparse(updated);
  }

  _JsonDoc _insert(List<String> path, _JsonNode parent, Object? value) {
    final member = '${jsonEncode(path.last)}: ${jsonEncode(value)}';
    final newline = text.contains('\r\n') ? '\r\n' : '\n';
    final close = parent.end - 1;
    final String insertion;
    if (parent.members.isEmpty) {
      insertion = parent.multiline ? '$newline  $member$newline' : member;
    } else {
      final first = parent.members.values.first;
      final prefix = text.substring(parent.start + 1, first.keyStart);
      final newlineIndex = prefix.lastIndexOf('\n');
      if (newlineIndex >= 0) {
        final indent = prefix.substring(newlineIndex + 1);
        insertion = ',$newline$indent$member';
      } else {
        insertion = ', $member';
      }
    }
    return _reparse(
      '${text.substring(0, close)}$insertion${text.substring(close)}',
    );
  }

  _JsonDoc _remove(_JsonNode parent, _JsonMember member) {
    final members = parent.members.values.toList();
    final index = members.indexOf(member);
    final int start;
    final int end;
    if (index < members.length - 1) {
      start = member.memberStart;
      end = members[index + 1].memberStart;
    } else if (index > 0) {
      start = members[index - 1].value.end;
      end = member.value.end;
    } else {
      start = member.memberStart;
      end = member.value.end;
    }
    return _reparse('${text.substring(0, start)}${text.substring(end)}');
  }

  _JsonDoc _reparse(String updated) {
    try {
      return _JsonDoc.parse(updated);
    } on FormatException catch (error) {
      throw _invalid(error.message);
    }
  }
}

final class _JsonEntryEditor {
  _JsonEntryEditor(String text) : _text = text.trim().isEmpty ? '{}\n' : text;

  final String _text;
  static const String _section = 'mcpServers';

  String apply(String name, McpEntryMutation mutation) {
    try {
      return _apply(name, mutation);
    } on FormatException catch (error) {
      throw _invalid(error.message);
    }
  }

  String _apply(String name, McpEntryMutation mutation) {
    switch (mutation) {
      case McpInsertEntry():
        return _doc()
            .setField([_section, name], mutation.fields, remove: false)
            .text;
      case McpRemoveEntry():
        return _doc().setField([_section, name], null, remove: true).text;
      case McpPatchEntry():
        var doc = _doc();
        final current = mutation.current;
        final proposed = mutation.proposed;
        for (final key in current.keys.toList()) {
          if (!proposed.containsKey(key)) {
            doc = doc.setField([_section, name, key], null, remove: true);
          }
        }
        for (final entry in proposed.entries) {
          if (current.containsKey(entry.key) &&
              _same(current[entry.key], entry.value)) {
            continue;
          }
          doc = doc.setField(
            [_section, name, entry.key],
            entry.value,
            remove: false,
          );
        }
        return doc.text;
    }
  }

  _JsonDoc _doc() {
    try {
      return _JsonDoc.parse(_text);
    } on FormatException catch (error) {
      throw _invalid(error.message);
    }
  }
}

// ---------------------------------------------------------------------------
// Range-preserving TOML editor
// ---------------------------------------------------------------------------

final class _TomlLine {
  _TomlLine(
    this.start,
    this.end,
    this.raw,
    this.isHeader,
    this.key,
    this.equalsIndex,
  );

  /// Byte (UTF-16 code-unit) offsets into the source; [end] includes the
  /// trailing newline when present.
  final int start;
  final int end;
  final String raw;
  final bool isHeader;
  final String? key;
  final int equalsIndex;
}

List<_TomlLine> _tomlLines(String source) {
  final segments = source.split('\n');
  final lines = <_TomlLine>[];
  var offset = 0;
  for (var i = 0; i < segments.length; i++) {
    final seg = segments[i];
    final hasNewline = i < segments.length - 1;
    final end = offset + seg.length + (hasNewline ? 1 : 0);
    final raw = seg.endsWith('\r') ? seg.substring(0, seg.length - 1) : seg;
    final trimmed = raw.trim();
    final bool isHeader = trimmed.startsWith('[');
    final int equals = trimmed.startsWith('#') ? -1 : raw.indexOf('=');
    String? key;
    if (!isHeader && equals > 0) {
      final rawKey = raw.substring(0, equals).trim();
      if (!rawKey.contains('.') &&
          !rawKey.startsWith('"') &&
          !rawKey.startsWith("'")) {
        key = rawKey;
      } else if (rawKey.startsWith('"') &&
          rawKey.endsWith('"') &&
          rawKey.length > 1) {
        key = rawKey.substring(1, rawKey.length - 1);
      }
    }
    lines.add(_TomlLine(offset, end, raw, isHeader, key, equals));
    offset = end;
  }
  return lines;
}

final class _TomlHeader {
  const _TomlHeader(this.segments, this.canonicalKey, this.hasQuotedSegment);

  /// Decoded dotted-key segments, e.g. `['mcp_servers', 'foo.bar']`.
  final List<String> segments;

  /// Canonical key text; quoted segments are re-encoded with the same encoder
  /// used to generate managed table headers.
  final String canonicalKey;
  final bool hasQuotedSegment;
}

final RegExp _bareTomlKey = RegExp(r'^[A-Za-z0-9_-]+$');

/// TOML basic-string encoding of one key segment (escapes `"` and `\`).
String _tomlQuoteKey(String value) => jsonEncode(value);

bool _isBareTomlKey(String value) => _bareTomlKey.hasMatch(value);

String _tomlServerHeader(String name) =>
    '[mcp_servers.${_isBareTomlKey(name) ? name : _tomlQuoteKey(name)}]';

bool _tomlSpace(int char) => char == 0x20 || char == 0x09;

({String value, int end})? _tomlQuotedSegment(String text, int start) {
  final quote = text[start];
  var escaped = false;
  for (var i = start + 1; i < text.length; i++) {
    final char = text[i];
    if (char == '\n' || char == '\r') return null;
    if (quote == r"'") {
      if (char == quote) {
        return (value: text.substring(start + 1, i), end: i + 1);
      }
      continue;
    }
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (char == quote) {
      try {
        final value = jsonDecode(text.substring(start, i + 1));
        return (value: value as String, end: i + 1);
      } catch (_) {
        return null;
      }
    }
  }
  return null;
}

/// Parses a bracketed table header independently of any trailing comment.
///
/// Returns `null` for arrays of tables and for syntax this bounded editor does
/// not understand; those shapes are refused before any write.
_TomlHeader? _tomlHeader(String raw) {
  final text = raw.trimLeft();
  if (!text.startsWith('[') || text.startsWith('[[')) return null;
  var index = 1;
  final segments = <String>[];
  final quoted = <bool>[];
  while (true) {
    while (index < text.length && _tomlSpace(text.codeUnitAt(index))) {
      index++;
    }
    if (index >= text.length) return null;
    final char = text[index];
    final String segment;
    final bool isQuoted;
    if (char == '"' || char == r"'") {
      final parsed = _tomlQuotedSegment(text, index);
      if (parsed == null) return null;
      segment = parsed.value;
      index = parsed.end;
      isQuoted = true;
    } else {
      final start = index;
      while (index < text.length && _isBareTomlKey(text[index])) {
        index++;
      }
      if (start == index) return null;
      segment = text.substring(start, index);
      isQuoted = false;
    }
    segments.add(segment);
    quoted.add(isQuoted);
    while (index < text.length && _tomlSpace(text.codeUnitAt(index))) {
      index++;
    }
    if (index >= text.length) return null;
    if (text[index] == ']') {
      index++;
      break;
    }
    if (text[index] != '.') return null;
    index++;
  }
  while (index < text.length && _tomlSpace(text.codeUnitAt(index))) {
    index++;
  }
  if (index < text.length && text[index] != '#') return null;
  return _TomlHeader(
    List<String>.unmodifiable(segments),
    <String>[
      for (var i = 0; i < segments.length; i++)
        quoted[i] ? _tomlQuoteKey(segments[i]) : segments[i],
    ].join('.'),
    quoted.contains(true),
  );
}

bool _isMcpServerEntry(_TomlHeader header, String name) {
  if (header.segments.length != 2 || header.segments.first != 'mcp_servers') {
    return false;
  }
  final wanted = 'mcp_servers.$name';
  final wantedQuoted = 'mcp_servers.${_tomlQuoteKey(name)}';
  return header.canonicalKey == wanted || header.canonicalKey == wantedQuoted;
}

bool _isMcpServerDescendant(_TomlHeader header, String name) =>
    header.segments.length > 2 &&
    header.segments.first == 'mcp_servers' &&
    header.segments[1] == name;

/// (regionStart, regionEnd, headerEnd, hasTable).
({int start, int end, int headerEnd, bool found}) _tomlTable(
  String source,
  String name,
) {
  final lines = _tomlLines(source);
  var headerIndex = -1;
  for (var i = 0; i < lines.length; i++) {
    final header = _tomlHeader(lines[i].raw);
    if (header == null || !_isMcpServerEntry(header, name)) continue;
    if (headerIndex >= 0) {
      throw _invalid('duplicate [mcp_servers.$name] table.');
    }
    headerIndex = i;
  }
  if (headerIndex < 0) {
    return (
      start: source.length,
      end: source.length,
      headerEnd: source.length,
      found: false,
    );
  }
  var regionEnd = source.length;
  for (var i = headerIndex + 1; i < lines.length; i++) {
    if (!lines[i].isHeader) continue;
    final header = _tomlHeader(lines[i].raw);
    if (header != null && _isMcpServerDescendant(header, name)) continue;
    regionEnd = lines[i].start;
    break;
  }
  return (
    start: lines[headerIndex].start,
    end: regionEnd,
    headerEnd: lines[headerIndex].end,
    found: true,
  );
}

/// (valueStart, valueEnd, lineStart, lineEnd) of a key inside the table.
({int valueStart, int valueEnd, int lineStart, int lineEnd})? _tomlKeyRange(
  String source,
  String name,
  String key,
) {
  final table = _tomlTable(source, name);
  if (!table.found) {
    return null;
  }
  ({int valueStart, int valueEnd, int lineStart, int lineEnd})? result;
  var pastDescendantHeader = false;
  for (final line in _tomlLines(source)) {
    if (line.start < table.headerEnd || line.start >= table.end) {
      continue;
    }
    if (line.isHeader) {
      // The removal region includes descendant tables; their keys belong to
      // the descendant, not to the selected server entry.
      pastDescendantHeader = true;
      continue;
    }
    if (pastDescendantHeader) continue;
    if (line.key == null || line.key != key || line.equalsIndex <= 0) {
      continue;
    }
    var valueStart = line.start + line.equalsIndex + 1;
    while (valueStart < line.start + line.raw.length &&
        (line.raw[valueStart - line.start] == ' ' ||
            line.raw[valueStart - line.start] == '\t')) {
      valueStart++;
    }
    final comment = _tomlCommentStart(line.raw, line.equalsIndex + 1);
    var valueEnd = line.start + (comment < 0 ? line.raw.length : comment);
    while (valueEnd > valueStart &&
        (line.raw[valueEnd - line.start - 1] == ' ' ||
            line.raw[valueEnd - line.start - 1] == '\t')) {
      valueEnd--;
    }
    if (result != null) {
      throw _invalid('ambiguous [mcp_servers.$name].$key key.');
    }
    result = (
      valueStart: valueStart,
      valueEnd: valueEnd,
      lineStart: line.start,
      lineEnd: line.end,
    );
  }
  return result;
}

int _tomlCommentStart(String line, int from) {
  var quoted = false;
  var escaped = false;
  for (var i = from; i < line.length; i++) {
    final char = line[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
    } else if (char == '"') {
      quoted = true;
    } else if (char == '#') {
      return i;
    }
  }
  return -1;
}

String _tomlEncode(Object? value) {
  if (value is String) {
    return jsonEncode(value);
  }
  if (value is num || value is bool) {
    return '$value';
  }
  if (value is List) {
    return '[${value.map(_tomlEncode).join(', ')}]';
  }
  if (value is Map) {
    return '{ ${value.entries.map((e) => '${jsonEncode(e.key.toString())} = ${_tomlEncode(e.value)}').join(', ')} }';
  }
  throw _invalid('unsupported TOML value type.');
}

void _rejectAmbiguousToml(String source) {
  if (source.contains("'''") || source.contains('"""')) {
    throw _invalid('multiline TOML strings are not eligible.');
  }
  for (final line in _tomlLines(source)) {
    final trimmed = line.raw.trim();
    if (trimmed.startsWith('[[')) {
      throw _invalid('TOML arrays of tables are not eligible.');
    }
    final header = _tomlHeader(line.raw);
    if (header != null) {
      if (header.hasQuotedSegment && header.segments.first != 'mcp_servers') {
        throw _invalid('quoted TOML section keys are not eligible.');
      }
      continue;
    }
    final equals = line.equalsIndex;
    if (equals <= 0) {
      continue;
    }
    final comment = _tomlCommentStart(line.raw, equals + 1);
    final value = line.raw
        .substring(equals + 1, comment < 0 ? line.raw.length : comment)
        .trim();
    if (value.startsWith('[') && !value.endsWith(']')) {
      throw _invalid('multiline TOML arrays are not eligible.');
    }
  }
}

final class _TomlEntryEditor {
  _TomlEntryEditor(this.text);

  final String text;

  String apply(String name, McpEntryMutation mutation) {
    _rejectAmbiguousToml(text);
    final newline = text.contains('\r\n') ? '\r\n' : '\n';
    switch (mutation) {
      case McpInsertEntry():
        return _insertTable(name, mutation.fields, newline);
      case McpRemoveEntry():
        final table = _tomlTable(text, name);
        if (!table.found) {
          return text;
        }
        return '${text.substring(0, table.start)}${text.substring(table.end)}';
      case McpPatchEntry():
        return _patch(name, mutation.current, mutation.proposed, newline);
    }
  }

  String _insertTable(
    String name,
    Map<String, Object?> fields,
    String newline,
  ) {
    var result = text;
    final buffer = StringBuffer();
    if (result.isNotEmpty && !result.endsWith('\n')) {
      buffer.write(newline);
    }
    buffer.write('${_tomlServerHeader(name)}$newline');
    for (final entry in fields.entries) {
      buffer.write('${entry.key} = ${_tomlEncode(entry.value)}$newline');
    }
    result += buffer.toString();
    return result;
  }

  String _patch(
    String name,
    Map<String, Object?> current,
    Map<String, Object?> proposed,
    String newline,
  ) {
    final table = _tomlTable(text, name);
    if (!table.found) {
      return _insertTable(name, proposed, newline);
    }
    var result = text;
    for (final key in current.keys.toList()) {
      if (proposed.containsKey(key)) {
        continue;
      }
      final range = _tomlKeyRange(result, name, key);
      if (range == null) {
        continue;
      }
      result =
          '${result.substring(0, range.lineStart)}'
          '${result.substring(range.lineEnd)}';
    }
    // New keys are inserted directly after the table header.
    final added = <MapEntry<String, Object?>>[];
    for (final entry in proposed.entries) {
      if (!current.containsKey(entry.key)) {
        added.add(entry);
      }
    }
    if (added.isNotEmpty) {
      final header = _tomlTable(result, name);
      final buffer = StringBuffer();
      for (final entry in added) {
        buffer.write('${entry.key} = ${_tomlEncode(entry.value)}$newline');
      }
      result =
          '${result.substring(0, header.headerEnd)}'
          '${buffer.toString()}${result.substring(header.headerEnd)}';
    }
    for (final entry in proposed.entries) {
      if (current.containsKey(entry.key) &&
          _same(current[entry.key], entry.value)) {
        continue;
      }
      if (!current.containsKey(entry.key)) {
        continue; // already inserted above
      }
      final range = _tomlKeyRange(result, name, entry.key);
      if (range == null) {
        throw _invalid(
          '[mcp_servers.$name].${entry.key} not found for replacement.',
        );
      }
      result =
          '${result.substring(0, range.valueStart)}'
          '${_tomlEncode(entry.value)}${result.substring(range.valueEnd)}';
    }
    return result;
  }
}
