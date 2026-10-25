import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The profile implemented by [validateSkill].
const skillValidationProfile = 'agentskills-core-ascii-v1';

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
ValidationReport validateSkill(String skill) {
  if (skill.trim().isEmpty) {
    throw MambaException('The --skill directory must not be blank.');
  }

  final selectedPath = p.normalize(Directory(skill).absolute.path);
  _requireRootDirectory(selectedPath);

  final diagnostics = <ValidationDiagnostic>[];
  final markerPath = p.join(selectedPath, 'SKILL.md');
  final markerType = _entityType(markerPath, followLinks: false);

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

  final markerBytes = _readMarker(markerPath);
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

  _validateName(frontmatterMap, selectedPath, diagnostics);
  _validateDescription(frontmatterMap, diagnostics);
  _validateLicense(frontmatterMap, diagnostics);
  _validateCompatibility(frontmatterMap, diagnostics);
  _validateMetadata(frontmatterMap, diagnostics);
  _validateAllowedTools(frontmatterMap, diagnostics);
  _warnUnknownFields(frontmatterMap, diagnostics);

  return _report(selectedPath, diagnostics);
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
  final type = _entityType(path, followLinks: true);
  if (type == FileSystemEntityType.directory) {
    return;
  }

  if (type == FileSystemEntityType.notFound) {
    throw MambaException('Skill directory does not exist: $path');
  }
  throw MambaException('Skill path is not a directory: $path');
}

FileSystemEntityType _entityType(String path, {required bool followLinks}) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: followLinks);
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not inspect filesystem path $path: ${error.message}',
    );
  }
}

List<int> _readMarker(String path) {
  RandomAccessFile? file;
  List<int>? bytes;
  try {
    file = File(path).openSync();
    bytes = file.readSync(_maxMarkerBytes + 1);
  } on FileSystemException catch (error) {
    throw MambaException('Could not read skill marker $path: ${error.message}');
  } finally {
    if (file != null) {
      try {
        file.closeSync();
      } on FileSystemException catch (error) {
        throw MambaException(
          'Could not close skill marker $path: ${error.message}',
        );
      }
    }
  }
  return bytes;
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

void _validateName(
  Map<Object?, Object?> map,
  String selectedPath,
  List<ValidationDiagnostic> diagnostics,
) {
  if (!map.containsKey('name')) {
    diagnostics.add(
      _diagnostic(
        code: 'NAME_REQUIRED',
        category: DiagnosticCategory.specification,
        field: 'name',
        message: 'Frontmatter requires a name string.',
      ),
    );
    return;
  }

  final value = map['name'];
  if (value is! String) {
    diagnostics.add(
      _diagnostic(
        code: 'NAME_TYPE',
        category: DiagnosticCategory.specification,
        field: 'name',
        message: 'name must be a string.',
      ),
    );
    return;
  }

  final length = value.runes.length;
  final empty = value.isEmpty || value.trim().isEmpty;
  if (empty) {
    diagnostics.add(
      _diagnostic(
        code: 'NAME_EMPTY',
        category: DiagnosticCategory.specification,
        field: 'name',
        message: 'name must not be empty or whitespace-only.',
      ),
    );
  } else if (length > 64) {
    diagnostics.add(
      _diagnostic(
        code: 'NAME_LENGTH',
        category: DiagnosticCategory.specification,
        field: 'name',
        message: 'name must contain 1–64 Unicode scalar values.',
      ),
    );
  }

  if (p.basename(selectedPath) != value) {
    diagnostics.add(
      _diagnostic(
        code: 'NAME_DIRECTORY',
        category: DiagnosticCategory.specification,
        field: 'name',
        message: 'name must exactly match the skill directory basename.',
      ),
    );
  }

  if (empty) {
    return;
  }
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

void _validateDescription(
  Map<Object?, Object?> map,
  List<ValidationDiagnostic> diagnostics,
) {
  if (!map.containsKey('description')) {
    diagnostics.add(
      _diagnostic(
        code: 'DESCRIPTION_REQUIRED',
        category: DiagnosticCategory.specification,
        field: 'description',
        message: 'Frontmatter requires a description string.',
      ),
    );
    return;
  }

  final value = map['description'];
  if (value is! String) {
    diagnostics.add(
      _diagnostic(
        code: 'DESCRIPTION_TYPE',
        category: DiagnosticCategory.specification,
        field: 'description',
        message: 'description must be a string.',
      ),
    );
    return;
  }

  final empty = value.isEmpty || value.trim().isEmpty;
  if (empty) {
    diagnostics.add(
      _diagnostic(
        code: 'DESCRIPTION_EMPTY',
        category: DiagnosticCategory.specification,
        field: 'description',
        message: 'description must not be empty or whitespace-only.',
      ),
    );
  }
  if (value.runes.length > 1024) {
    diagnostics.add(
      _diagnostic(
        code: 'DESCRIPTION_LENGTH',
        category: DiagnosticCategory.specification,
        field: 'description',
        message: 'description must contain 1–1024 Unicode scalar values.',
      ),
    );
  }
}

void _validateLicense(
  Map<Object?, Object?> map,
  List<ValidationDiagnostic> diagnostics,
) {
  if (map.containsKey('license') && map['license'] is! String) {
    diagnostics.add(
      _diagnostic(
        code: 'LICENSE_TYPE',
        category: DiagnosticCategory.specification,
        field: 'license',
        message: 'license must be a string when present.',
      ),
    );
  }
}

void _validateCompatibility(
  Map<Object?, Object?> map,
  List<ValidationDiagnostic> diagnostics,
) {
  if (!map.containsKey('compatibility')) {
    return;
  }
  final value = map['compatibility'];
  if (value is! String) {
    diagnostics.add(
      _diagnostic(
        code: 'COMPATIBILITY_TYPE',
        category: DiagnosticCategory.specification,
        field: 'compatibility',
        message: 'compatibility must be a string when present.',
      ),
    );
    return;
  }
  final length = value.runes.length;
  if (length < 1 || length > 500) {
    diagnostics.add(
      _diagnostic(
        code: 'COMPATIBILITY_LENGTH',
        category: DiagnosticCategory.specification,
        field: 'compatibility',
        message: 'compatibility must contain 1–500 Unicode scalar values.',
      ),
    );
  }
}

void _validateMetadata(
  Map<Object?, Object?> map,
  List<ValidationDiagnostic> diagnostics,
) {
  if (!map.containsKey('metadata')) {
    return;
  }
  final value = map['metadata'];
  if (value is! Map) {
    diagnostics.add(
      _diagnostic(
        code: 'METADATA_TYPE',
        category: DiagnosticCategory.specification,
        field: 'metadata',
        message: 'metadata must be a map when present.',
      ),
    );
    return;
  }
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) {
      diagnostics.add(
        _diagnostic(
          code: 'METADATA_ENTRY_TYPE',
          category: DiagnosticCategory.specification,
          field: 'metadata',
          message: 'metadata keys and values must be strings.',
        ),
      );
    }
  }
}

void _validateAllowedTools(
  Map<Object?, Object?> map,
  List<ValidationDiagnostic> diagnostics,
) {
  if (map.containsKey('allowed-tools') && map['allowed-tools'] is! String) {
    diagnostics.add(
      _diagnostic(
        code: 'ALLOWED_TOOLS_TYPE',
        category: DiagnosticCategory.specification,
        field: 'allowed-tools',
        message: 'allowed-tools must be a string when present.',
      ),
    );
  }
}

void _warnUnknownFields(
  Map<Object?, Object?> map,
  List<ValidationDiagnostic> diagnostics,
) {
  const known = <String>{
    'name',
    'description',
    'license',
    'compatibility',
    'metadata',
    'allowed-tools',
  };
  final unknown = <String>[
    for (final key in map.keys)
      if (key is String && !known.contains(key)) key,
  ]..sort();

  for (final key in unknown) {
    diagnostics.add(
      _diagnostic(
        code: 'UNKNOWN_FIELD',
        category: DiagnosticCategory.advisory,
        field: key,
        message: 'Unknown top-level field: $key.',
        severity: DiagnosticSeverity.warning,
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
