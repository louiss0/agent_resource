import 'mcp_redaction.dart';

/// A versioned MCP success envelope (stories 42, 43), mirroring
/// `LifecycleResult.envelope()`/`renderText()` with a `schemaVersion: 1`
/// shape of `command`, `outcome`, `data` and `diagnostics`.
///
/// Redaction is central: [data] may carry raw native fields, but both
/// [envelope] and [renderText] disclose only redacted values, so a literal
/// credential value can never be printed through either surface.
final class McpEnvelope {
  const McpEnvelope({
    required this.command,
    required this.outcome,
    required this.data,
    this.diagnostics = const <Map<String, Object?>>[],
  });

  static const int schemaVersion = 1;

  final String command;
  final String outcome;
  final Map<String, Object?> data;
  final List<Map<String, Object?>> diagnostics;

  Map<String, Object?> _redactedData() => McpRedaction.redactMap(data);

  List<Map<String, Object?>> _redactedDiagnostics() => <Map<String, Object?>>[
    for (final diagnostic in diagnostics) McpRedaction.redactMap(diagnostic),
  ];

  Map<String, Object?> envelope() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'command': command,
    'outcome': outcome,
    'data': _redactedData(),
    'diagnostics': _redactedDiagnostics(),
  };

  /// Deterministic, terminal-safe text rendering. Map iteration follows the
  /// deterministic insertion order of the redacted data; lists are sorted by
  /// the service before they reach the envelope.
  String renderText() {
    final redactedData = _redactedData();
    final redactedDiagnostics = _redactedDiagnostics();
    final buffer = StringBuffer()..writeln('$command: $outcome');
    void render(Object? value, String indent) {
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.value is Map || entry.value is List) {
            buffer.writeln('$indent${entry.key}:');
            render(entry.value, '$indent  ');
          } else {
            buffer.writeln(
              '$indent${entry.key}: ${_terminalSafe(entry.value)}',
            );
          }
        }
      } else if (value is List) {
        if (value.isEmpty) {
          buffer.writeln('$indent[]');
        } else {
          for (final item in value) {
            buffer.writeln('$indent-');
            render(item, '$indent  ');
          }
        }
      } else {
        buffer.writeln('$indent${_terminalSafe(value)}');
      }
    }

    render(redactedData, '');
    render(<String, Object?>{'diagnostics': redactedDiagnostics}, '');
    return buffer.toString();
  }
}

Object? _terminalSafe(Object? value) {
  if (value is! String) return value;
  final buffer = StringBuffer();
  for (final unit in value.codeUnits) {
    buffer.writeCharCode(unit < 0x20 || unit == 0x7F ? 0x3F : unit);
  }
  return buffer.toString();
}
