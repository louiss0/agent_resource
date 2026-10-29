import 'agent_inspection.dart';

/// Applies explicit source-name → target-name mappings to a disclosed native
/// association field. Returns field-specific errors instead of guessing a
/// cross-harness association or silently leaving the request inert.
List<String> applyNativeReferenceMappings(
  Map<String, Object?> fields,
  Map<String, String> mappings,
  AgentHarness harness,
) {
  final errors = <String>[];
  for (final entry in mappings.entries) {
    final separator = entry.key.indexOf(':');
    if (separator <= 0 || separator == entry.key.length - 1) {
      errors.add('${entry.key}: reference keys use <kind>:<source-name>.');
      continue;
    }
    final kind = entry.key.substring(0, separator);
    final sourceName = entry.key.substring(separator + 1);
    final field = switch ((kind, harness)) {
      ('skill', AgentHarness.claude || AgentHarness.codex) => 'skills',
      ('mcp-server', AgentHarness.claude) => 'mcpServers',
      ('mcp-server', AgentHarness.codex) => 'mcp_servers',
      ('hook', AgentHarness.claude) => 'hooks',
      _ => null,
    };
    if (field == null) {
      errors.add(
        '${entry.key}: ${harness.name} has no supported native association for $kind.',
      );
      continue;
    }
    final value = fields[field];
    if (value == null) {
      errors.add(
        '${entry.key}: define the target $field association explicitly.',
      );
      continue;
    }
    if (!containsNativeReference(value, sourceName) &&
        !containsNativeReference(value, entry.value)) {
      errors.add(
        '${entry.key}: target $field contains neither the source nor mapped name.',
      );
      continue;
    }
    fields[field] = _replaceReference(value, sourceName, entry.value);
  }
  return errors;
}

/// Whether a decoded native association value names [name] at any depth.
bool containsNativeReference(Object? value, String name) {
  if (value is String) return value == name;
  if (value is List<Object?>) {
    return value.any((entry) => containsNativeReference(entry, name));
  }
  if (value is Map<String, Object?>) {
    return value.entries.any(
      (entry) =>
          entry.key == name || containsNativeReference(entry.value, name),
    );
  }
  return false;
}

Object? _replaceReference(Object? value, String source, String target) {
  if (value is String) return value == source ? target : value;
  if (value is List<Object?>) {
    return <Object?>[
      for (final entry in value) _replaceReference(entry, source, target),
    ];
  }
  if (value is Map<String, Object?>) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key == source ? target : entry.key: _replaceReference(
          entry.value,
          source,
          target,
        ),
    };
  }
  return value;
}
