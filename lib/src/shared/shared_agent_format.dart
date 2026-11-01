import 'package:zema/zema.dart';

import '../validation/validation_diagnostics.dart';

/// The shared, harness-neutral Agent frontmatter contract.
///
/// This library does not implement or relax any native harness schema.
final class const SharedAgentFormat() {
  static final _schema = z.object({
    'name': z.string(),
    'description': z.string(),
    'model': z.string().optional(),
    'tools': z.array(z.string()).min(1).optional(),
    'skills': z.array(z.string()).min(1).optional(),
  });

  /// Validates a decoded frontmatter mapping and returns an immutable value.
  /// Unknown string-keyed fields are retained rather than interpreted.
  static SharedAgentValidationResult validate(Map<Object?, Object?> input) {
    final issues = <SharedAgentValidationIssue>[];
    final fields = <String, Object?>{};
    for (final entry in input.entries) {
      final key = entry.key;
      if (key is! String) {
        issues.add(
          const SharedAgentValidationIssue(
            'frontmatter',
            'invalid_key',
            'Top-level field names must be strings.',
          ),
        );
      } else {
        fields[key] = entry.value;
      }
    }

    final nullFields = <String>{};
    for (final field in _knownFields) {
      if (fields.containsKey(field) && fields[field] == null) {
        nullFields.add(field);
        issues.add(
          SharedAgentValidationIssue(
            field,
            'invalid_type',
            '$field must not be null when present.',
          ),
        );
      }
    }
    final parsed = _schema.safeParse(fields);
    if (!parsed.isSuccess) {
      for (final issue in parsed.errors) {
        if (issue.path.length == 1 && nullFields.contains(issue.path.single)) {
          continue;
        }
        issues.add(
          SharedAgentValidationIssue(
            issue.path.isEmpty
                ? 'frontmatter'
                : ValidationDiagnostics.path(issue.path),
            issue.code,
            issue.code == 'too_small' &&
                    _valueAtPath(fields, issue.path) is List
                ? 'Must contain at least one item when present.'
                : issue.message,
          ),
        );
      }
    }
    if (issues.isNotEmpty) {
      return SharedAgentValidationResult.invalid(issues);
    }

    final snapshot = _freezeMap(fields);
    return SharedAgentValidationResult.valid(
      SharedAgentDefinition._(
        name: fields['name']! as String,
        description: fields['description']! as String,
        model: fields['model'] as String?,
        tools: _strings(fields['tools']),
        skills: _strings(fields['skills']),
        fields: snapshot,
        extensions: Map<String, Object?>.unmodifiable({
          for (final entry in snapshot.entries)
            if (!_knownFields.contains(entry.key)) entry.key: entry.value,
        }),
      ),
    );
  }

  static List<String> _strings(Object? value) => value == null
      ? const <String>[]
      : List<String>.unmodifiable(value as List<Object?>);
}

const _knownFields = <String>{
  'name',
  'description',
  'model',
  'tools',
  'skills',
};

final class SharedAgentDefinition._({
  required final String name,
  required final String description,
  required final String? model,
  required final List<String> tools,
  required final List<String> skills,

  /// Deeply immutable snapshot of all original string-keyed input fields.
  required final Map<String, Object?> fields,

  /// Deeply immutable unknown top-level fields from [fields].
  required final Map<String, Object?> extensions,
});

final class const SharedAgentValidationResult._(
  final SharedAgentDefinition? agent,
  final List<SharedAgentValidationIssue> issues,
) {
  factory SharedAgentValidationResult.valid(SharedAgentDefinition agent) =>
      SharedAgentValidationResult._(agent, const []);

  factory SharedAgentValidationResult.invalid(
    List<SharedAgentValidationIssue> issues,
  ) => SharedAgentValidationResult._(null, List.unmodifiable(issues));

  bool get valid => agent != null;

  List<String> get flatIssues => ValidationDiagnostics.flatten(
    issues.map(
      (issue) => (path: issue.path, code: issue.code, message: issue.message),
    ),
  );

  String get formattedIssues => flatIssues.join('\n');
}

final class const SharedAgentValidationIssue(
  final String path,
  final String code,
  final String message,
) {
  @override
  String toString() => ValidationDiagnostics.format(path, code, message);
}

Object? _valueAtPath(Object? input, Iterable<Object?> path) {
  var current = input;
  for (final segment in path) {
    if (segment is String && current is Map) {
      current = current[segment];
    } else if (segment is int && current is List && segment < current.length) {
      current = current[segment];
    } else {
      return null;
    }
  }
  return current;
}

Map<String, Object?> _freezeMap(Map<String, Object?> input) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in input.entries) entry.key: _freeze(entry.value),
    });

Object? _freeze(Object? value) => switch (value) {
  Map<Object?, Object?> _ => Map<Object?, Object?>.unmodifiable(
    <Object?, Object?>{
      for (final entry in value.entries) entry.key: _freeze(entry.value),
    },
  ),
  List<Object?> _ => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};
