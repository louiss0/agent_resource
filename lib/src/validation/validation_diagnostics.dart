/// Focused, value-free formatting for schema diagnostics.
final class const ValidationDiagnostics() {
  static String format(String path, String code, String message) =>
      '[${escape(code)}] ${escape(path)}: ${escape(message)}';

  static List<String> flatten(
    Iterable<({String path, String code, String message})> diagnostics,
  ) => List.unmodifiable(
    diagnostics.map(
      (diagnostic) =>
          format(diagnostic.path, diagnostic.code, diagnostic.message),
    ),
  );

  /// Prevents attacker-controlled field names from controlling a terminal.
  static String escape(String value) {
    final output = StringBuffer();
    for (final rune in value.runes) {
      if (rune < 0x20 ||
          (rune >= 0x7f && rune <= 0x9f) ||
          (rune >= 0x202a && rune <= 0x202e) ||
          (rune >= 0x2066 && rune <= 0x2069) ||
          rune == 0x200e ||
          rune == 0x200f) {
        output.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
      } else {
        output.writeCharCode(rune);
      }
    }
    return output.toString();
  }

  /// Formats map keys and array indexes without Zema's ambiguous `.[0]`.
  static String path(Iterable<Object?> segments) {
    final output = StringBuffer();
    for (final segment in segments) {
      if (segment is int) {
        output.write('[$segment]');
      } else {
        if (output.isNotEmpty) output.write('.');
        output.write(escape(segment.toString()));
      }
    }
    return output.toString();
  }

  /// Quotes one map-key path segment without allowing dots to become
  /// ambiguous with path separators.
  static String key(String value) =>
      '"${escape(value).replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
