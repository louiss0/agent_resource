import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:zema/zema.dart';

import 'skill_files.dart';
import 'validation/validation_diagnostics.dart';

/// The profile implemented by [validateSkill].
const skillValidationProfile = 'agentskills-core-strict-ascii-v1';

/// The upstream Agent Skills snapshot used by [skillValidationProfile].
const skillValidationBaseline = '69ef37e9424c0a7ea9dd2293b559e43ec8176379';

const _maxMarkerBytes = 1048576;
const _maxFrontmatterBytes = 65536;

/// Distinguishes an upstream format rule from a product restriction or advice.
enum DiagnosticCategory { specification, product, advisory }

/// The only severities emitted by the validation profile.
enum DiagnosticSeverity { error, warning }

/// One stable, machine-readable validation finding.
final class ValidationDiagnostic {
  new({
    required this.code,
    required this.category,
    required this.severity,
    required this.field,
    required this.message,
  });

  final String code;
  final DiagnosticCategory category;
  final DiagnosticSeverity severity;
  final String? field;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'category': _categoryName(category),
    'severity': _severityName(severity),
    'field': field,
    'message': message,
  };
}

/// A completed validation result.
///
/// Operational failures are thrown as [MambaException] and therefore do not
/// produce a partial report. A report is invalid exactly when it contains an
/// error diagnostic; advisory warnings do not make it invalid.
final class ValidationReport {
  new({
    required this.path,
    required this.profile,
    required this.baseline,
    required List<ValidationDiagnostic> diagnostics,
  }) : diagnostics = List<ValidationDiagnostic>.unmodifiable(diagnostics);

  final String path;
  final String profile;
  final String baseline;
  final List<ValidationDiagnostic> diagnostics;

  bool get valid => diagnostics.every(
    (diagnostic) => diagnostic.severity != DiagnosticSeverity.error,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'profile': profile,
    'baseline': baseline,
    'valid': valid,
    'diagnostics': [for (final diagnostic in diagnostics) diagnostic.toJson()],
  };
}

/// Validates one explicitly selected skill directory without executing or
/// inspecting anything outside its immediate SKILL.md marker.
ValidationReport validateSkill(String skill, {String? expectedDirectoryName}) {
  if (skill.trim().isEmpty) {
    throw MambaException('The --skill directory must not be blank.');
  }

  final selectedPath = p.normalize(Directory(skill).absolute.path);
  _requireRootDirectory(selectedPath);

  final diagnostics = <ValidationDiagnostic>[];
  final markerPath = p.join(selectedPath, 'SKILL.md');
  final markerType = skillEntityType(markerPath, followLinks: false);

  if (markerType == FileSystemEntityType.notFound) {
    diagnostics.add(
      _diagnostic(
        code: 'SKILL_FILE_MISSING',
        category: DiagnosticCategory.specification,
        field: null,
        message: 'The skill directory does not contain SKILL.md.',
      ),
    );
    return _report(selectedPath, diagnostics);
  }

  if (markerType == FileSystemEntityType.link) {
    diagnostics.add(
      _diagnostic(
        code: 'SKILL_FILE_LINK',
        category: DiagnosticCategory.product,
        field: null,
        message: 'SKILL.md is a link and was not read.',
      ),
    );
    return _report(selectedPath, diagnostics);
  }

  if (markerType != FileSystemEntityType.file) {
    diagnostics.add(
      _diagnostic(
        code: 'SKILL_FILE_TYPE',
        category: DiagnosticCategory.specification,
        field: null,
        message: 'SKILL.md must be a regular file.',
      ),
    );
    return _report(selectedPath, diagnostics);
  }

  final markerBytes = readBoundedSkillMarker(
    markerPath,
    maxBytes: _maxMarkerBytes,
  );
  if (markerBytes.length > _maxMarkerBytes) {
    diagnostics.add(
      _diagnostic(
        code: 'FILE_SIZE_LIMIT',
        category: DiagnosticCategory.product,
        field: null,
        message: 'SKILL.md exceeds $_maxMarkerBytes bytes.',
      ),
    );
    return _report(selectedPath, diagnostics);
  }

  final String content;
  try {
    content = _decodeUtf8(markerBytes);
  } on _InvalidUtf8 {
    diagnostics.add(
      _diagnostic(
        code: 'UTF8_INVALID',
        category: DiagnosticCategory.product,
        field: null,
        message: 'SKILL.md is not valid UTF-8.',
      ),
    );
    return _report(selectedPath, diagnostics);
  }
  final frontmatter = _extractFrontmatter(content);
  switch (frontmatter.status) {
    case _FrontmatterStatus.missing:
      diagnostics.add(
        _diagnostic(
          code: 'FRONTMATTER_MISSING',
          category: DiagnosticCategory.specification,
          field: null,
          message: 'SKILL.md must start with a standalone --- line.',
        ),
      );
      return _report(selectedPath, diagnostics);
    case _FrontmatterStatus.unterminated:
      diagnostics.add(
        _diagnostic(
          code: 'FRONTMATTER_UNTERMINATED',
          category: DiagnosticCategory.specification,
          field: null,
          message: 'Frontmatter has no standalone closing --- line.',
        ),
      );
      return _report(selectedPath, diagnostics);
    case _FrontmatterStatus.complete:
      break;
  }

  final yamlText = frontmatter.yamlText!;
  if (utf8.encode(yamlText).length > _maxFrontmatterBytes) {
    diagnostics.add(
      _diagnostic(
        code: 'FRONTMATTER_SIZE_LIMIT',
        category: DiagnosticCategory.product,
        field: null,
        message: 'Frontmatter exceeds $_maxFrontmatterBytes UTF-8 bytes.',
      ),
    );
    return _report(selectedPath, diagnostics);
  }

  Object? parsed;
  try {
    // package:yaml builds data, rather than evaluating tags or executing
    // values. We only inspect the immediate mapping and its declared fields.
    parsed = loadYaml(yamlText);
  } on Exception {
    diagnostics.add(
      _diagnostic(
        code: 'YAML_INVALID',
        category: DiagnosticCategory.specification,
        field: null,
        message: 'Frontmatter is not valid YAML.',
      ),
    );
    return _report(selectedPath, diagnostics);
  }

  if (parsed is! Map) {
    diagnostics.add(
      _diagnostic(
        code: 'FRONTMATTER_MAPPING',
        category: DiagnosticCategory.specification,
        field: null,
        message: 'Frontmatter must be a YAML mapping.',
      ),
    );
    return _report(selectedPath, diagnostics);
  }

  final frontmatterMap = Map<Object?, Object?>.from(parsed);
  for (final entry in frontmatterMap.entries) {
    if (entry.key is! String) {
      diagnostics.add(
        _diagnostic(
          code: 'FRONTMATTER_KEYS',
          category: DiagnosticCategory.product,
          field: null,
          message: 'Top-level YAML mapping keys must be strings.',
        ),
      );
    }
  }

  _validateFrontmatter(
    frontmatterMap,
    selectedPath,
    diagnostics,
    expectedDirectoryName: expectedDirectoryName,
  );

  return _report(selectedPath, diagnostics);
}

/// Reads only the declared name so an arbitrary source folder can be copied
/// to its validated installation name. Full validation remains a separate gate.
String readDeclaredSkillName(String skill) {
  final selectedPath = p.normalize(Directory(skill).absolute.path);
  _requireRootDirectory(selectedPath);
  final markerPath = p.join(selectedPath, 'SKILL.md');
  if (skillEntityType(markerPath, followLinks: false) !=
      FileSystemEntityType.file) {
    throw MambaException(
      'The Skill source must contain a regular SKILL.md.',
      exitCode: 2,
    );
  }
  final bytes = readBoundedSkillMarker(markerPath, maxBytes: _maxMarkerBytes);
  if (bytes.length > _maxMarkerBytes) {
    throw MambaException('SKILL.md exceeds the maximum size.', exitCode: 2);
  }
  final String content;
  try {
    content = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw MambaException('SKILL.md is not valid UTF-8.', exitCode: 2);
  }
  final frontmatter = _extractFrontmatter(content);
  if (frontmatter.status != _FrontmatterStatus.complete) {
    throw MambaException('SKILL.md frontmatter is incomplete.', exitCode: 2);
  }
  final Object? parsed;
  try {
    parsed = loadYaml(frontmatter.yamlText!);
  } on Exception {
    throw MambaException(
      'SKILL.md frontmatter is not valid YAML.',
      exitCode: 2,
    );
  }
  if (parsed is! Map || parsed['name'] is! String) {
    throw MambaException('SKILL.md requires a string name.', exitCode: 2);
  }
  return parsed['name']! as String;
}

ValidationReport _report(
  String selectedPath,
  List<ValidationDiagnostic> diagnostics,
) => ValidationReport(
  path: selectedPath,
  profile: skillValidationProfile,
  baseline: skillValidationBaseline,
  diagnostics: diagnostics,
);

void _requireRootDirectory(String path) {
  final type = skillEntityType(path, followLinks: true);
  if (type == FileSystemEntityType.directory) {
    return;
  }

  if (type == FileSystemEntityType.notFound) {
    throw MambaException('Skill directory does not exist: $path');
  }
  throw MambaException('Skill path is not a directory: $path');
}

String _decodeUtf8(List<int> bytes) {
  try {
    // Dart's strict UTF-8 decoder accepts and removes one standard leading
    // BOM. Do not trim a second U+FEFF from the decoded content.
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException catch (error) {
    // This is a completed product diagnostic, not an operational read error.
    // The caller needs a report, so use an internal marker exception here.
    throw _InvalidUtf8(error.message.toString());
  }
}

_Frontmatter _extractFrontmatter(String content) {
  final firstNewline = content.indexOf('\n');
  final firstLineEnd = firstNewline < 0 ? content.length : firstNewline;
  if (_lineText(content, 0, firstLineEnd) != '---') {
    return const _Frontmatter(_FrontmatterStatus.missing);
  }
  if (firstNewline < 0) {
    return const _Frontmatter(_FrontmatterStatus.unterminated);
  }

  var lineStart = firstNewline + 1;
  while (lineStart <= content.length) {
    final newline = content.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? content.length : newline;
    if (_lineText(content, lineStart, lineEnd) == '---') {
      return _Frontmatter(
        _FrontmatterStatus.complete,
        content.substring(firstNewline + 1, lineStart),
      );
    }
    if (newline < 0) {
      break;
    }
    lineStart = newline + 1;
  }

  return const _Frontmatter(_FrontmatterStatus.unterminated);
}

String _lineText(String content, int start, int end) {
  final hasCarriageReturn = end > start && content.codeUnitAt(end - 1) == 0x0D;
  return content.substring(start, hasCarriageReturn ? end - 1 : end);
}

final _skillFrontmatterSchema = z.object({
  'name': z
      .string()
      .min(1)
      .refine(
        (value) => value.runes.length <= 64,
        code: 'too_big',
        message: 'name must contain at most 64 Unicode scalar values.',
      ),
  'description': z
      .string()
      .min(1)
      .refine(
        (value) => value.runes.length <= 1024,
        code: 'too_big',
        message: 'description must contain at most 1024 Unicode scalar values.',
      ),
  'license': z.string().optional(),
  'compatibility': z
      .string()
      .min(1)
      .refine(
        (value) => value.runes.length <= 500,
        code: 'too_big',
        message:
            'compatibility must contain at most 500 Unicode scalar values.',
      )
      .optional(),
  'metadata': z.map(z.string(), z.string()).optional(),
  'allowed-tools': z.string().optional(),
  'disable-model-invocation': z.boolean().optional(),
}).makeStrict();

const _skillFields = <String>[
  'name',
  'description',
  'license',
  'compatibility',
  'metadata',
  'allowed-tools',
  'disable-model-invocation',
];

void _validateFrontmatter(
  Map<Object?, Object?> map,
  String selectedPath,
  List<ValidationDiagnostic> diagnostics, {
  String? expectedDirectoryName,
}) {
  final result = _skillFrontmatterSchema.safeParse(map);
  final issues = result.isSuccess ? const <ZemaIssue>[] : result.errors;
  for (final field in _skillFields) {
    final fieldIssues = issues.where(
      (issue) => issue.path.isNotEmpty && issue.path.first == field,
    );
    if (map.containsKey(field) && map[field] == null && fieldIssues.isEmpty) {
      final code = switch (field) {
        'license' => 'LICENSE_TYPE',
        'compatibility' => 'COMPATIBILITY_TYPE',
        'metadata' => 'METADATA_TYPE',
        'allowed-tools' => 'ALLOWED_TOOLS_TYPE',
        'disable-model-invocation' => 'DISABLE_MODEL_INVOCATION_TYPE',
        _ => 'FIELD_TYPE',
      };
      diagnostics.add(
        _diagnostic(
          code: code,
          category: field == 'disable-model-invocation'
              ? DiagnosticCategory.product
              : DiagnosticCategory.specification,
          field: field,
          message: _skillFieldMessage(field, code),
        ),
      );
    }
    for (final issue in fieldIssues) {
      final code = switch ((field, issue.code)) {
        ('name', 'invalid_type') =>
          map.containsKey(field) ? 'NAME_TYPE' : 'NAME_REQUIRED',
        ('name', 'too_small') => 'NAME_EMPTY',
        ('name', 'too_big') => 'NAME_LENGTH',
        ('description', 'invalid_type') =>
          map.containsKey(field) ? 'DESCRIPTION_TYPE' : 'DESCRIPTION_REQUIRED',
        ('description', 'too_small') => 'DESCRIPTION_EMPTY',
        ('description', 'too_big') => 'DESCRIPTION_LENGTH',
        ('license', _) => 'LICENSE_TYPE',
        ('compatibility', 'invalid_type') => 'COMPATIBILITY_TYPE',
        ('compatibility', _) => 'COMPATIBILITY_LENGTH',
        ('metadata', 'invalid_type') when issue.path.length == 1 =>
          'METADATA_TYPE',
        ('metadata', _) => 'METADATA_ENTRY_TYPE',
        ('allowed-tools', _) => 'ALLOWED_TOOLS_TYPE',
        ('disable-model-invocation', _) => 'DISABLE_MODEL_INVOCATION_TYPE',
        _ => 'FIELD_TYPE',
      };
      diagnostics.add(
        _diagnostic(
          code: code,
          category: field == 'disable-model-invocation'
              ? DiagnosticCategory.product
              : DiagnosticCategory.specification,
          field: field,
          message: _skillFieldMessage(field, code),
        ),
      );
    }
    if (field == 'name') {
      _validateNameSemantics(
        map,
        selectedPath,
        diagnostics,
        expectedDirectoryName: expectedDirectoryName,
      );
    } else if (field == 'description') {
      final value = map[field];
      if (value is String && value.isNotEmpty && value.trim().isEmpty) {
        diagnostics.add(
          _diagnostic(
            code: 'DESCRIPTION_EMPTY',
            category: DiagnosticCategory.specification,
            field: field,
            message: _skillFieldMessage(field, 'DESCRIPTION_EMPTY'),
          ),
        );
      }
    }
  }

  final unknown = <String>[
    for (final key in map.keys)
      if (key is String && !_skillFields.contains(key)) key,
  ]..sort();
  for (final key in unknown) {
    diagnostics.add(
      _diagnostic(
        code: 'UNKNOWN_FIELD',
        category: DiagnosticCategory.product,
        field: ValidationDiagnostics.escape(key),
        message: 'Unknown top-level fields are forbidden by this profile.',
      ),
    );
  }
}

String _skillFieldMessage(String field, String code) => switch (code) {
  'NAME_REQUIRED' ||
  'DESCRIPTION_REQUIRED' => 'Frontmatter requires a $field string.',
  'NAME_TYPE' || 'DESCRIPTION_TYPE' => '$field must be a string.',
  'NAME_EMPTY' ||
  'DESCRIPTION_EMPTY' => '$field must not be empty or whitespace-only.',
  'NAME_LENGTH' => 'name must contain 1–64 Unicode scalar values.',
  'DESCRIPTION_LENGTH' =>
    'description must contain 1–1024 Unicode scalar values.',
  'LICENSE_TYPE' => 'license must be a string when present.',
  'COMPATIBILITY_TYPE' => 'compatibility must be a string when present.',
  'COMPATIBILITY_LENGTH' =>
    'compatibility must contain 1–500 Unicode scalar values.',
  'METADATA_TYPE' => 'metadata must be a map when present.',
  'METADATA_ENTRY_TYPE' => 'metadata keys and values must be strings.',
  'ALLOWED_TOOLS_TYPE' => 'allowed-tools must be a string when present.',
  'DISABLE_MODEL_INVOCATION_TYPE' =>
    'disable-model-invocation must be a boolean when present.',
  _ => '$field has an invalid value.',
};

void _validateNameSemantics(
  Map<Object?, Object?> map,
  String selectedPath,
  List<ValidationDiagnostic> diagnostics, {
  String? expectedDirectoryName,
}) {
  final value = map['name'];
  if (value is! String) return;
  final empty = value.isEmpty || value.trim().isEmpty;
  if (value.isNotEmpty && value.trim().isEmpty) {
    diagnostics.add(
      _diagnostic(
        code: 'NAME_EMPTY',
        category: DiagnosticCategory.specification,
        field: 'name',
        message: _skillFieldMessage('name', 'NAME_EMPTY'),
      ),
    );
  }
  if ((expectedDirectoryName ?? p.basename(selectedPath)) != value) {
    diagnostics.add(
      _diagnostic(
        code: 'NAME_DIRECTORY',
        category: DiagnosticCategory.specification,
        field: 'name',
        message: 'name must exactly match the skill directory basename.',
      ),
    );
  }
  if (empty) return;
  if (value.runes.any((rune) => rune > 0x7F)) {
    diagnostics.add(
      _diagnostic(
        code: 'NAME_ASCII_POLICY',
        category: DiagnosticCategory.product,
        field: 'name',
        message: 'This profile restricts names to ASCII characters.',
      ),
    );
    return;
  }
  if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value)) {
    diagnostics.add(
      _diagnostic(
        code: 'NAME_FORMAT',
        category: DiagnosticCategory.specification,
        field: 'name',
        message: 'name must use lowercase ASCII letters, digits, and single hyphens.',
      ),
    );
  }
}

ValidationDiagnostic _diagnostic({
  required String code,
  required DiagnosticCategory category,
  required String? field,
  required String message,
  DiagnosticSeverity severity = DiagnosticSeverity.error,
}) => ValidationDiagnostic(
  code: code,
  category: category,
  severity: severity,
  field: field,
  message: message,
);

String _categoryName(DiagnosticCategory category) => category.name;

String _severityName(DiagnosticSeverity severity) => severity.name;

enum _FrontmatterStatus { missing, unterminated, complete }

final class _Frontmatter {
  const new(this.status, [this.yamlText]);

  final _FrontmatterStatus status;
  final String? yamlText;
}

final class _InvalidUtf8 implements Exception {
  const new(this.message);

  final String message;
}
