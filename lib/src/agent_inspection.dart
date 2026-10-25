/// Read-only native Agent inspection and validation engine.
///
/// Implements the bounded native contracts from
/// `docs/specs/native-agent-inspection.md` for Claude Markdown definitions,
/// Codex standalone TOML definitions and config-bound roles, and the common
/// Pi Markdown profile. The engine never executes harnesses, hooks, MCP
/// servers, or helpers, never touches the network or a subprocess, and never
/// writes to the filesystem. It reads only explicitly selected files.
///
/// Outcome mapping:
/// - Source-relationship, usage, malformed-request, and missing-selection
///   failures throw [MambaException] with status 1.
/// - Blocking native/product violations are report diagnostics; the command
///   layer turns them into status 2 for validate. The engine never uses 2.
/// - Incomplete read/parse coverage, inaccessible required input, and budget
///   exhaustion throw status 3.
/// - Linked-file and other safety refusals throw status 4.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import 'package:yaml/yaml.dart';

import 'skill_files.dart';

/// The harness whose native contract a definition file follows.
enum AgentHarness { claude, codex, pi }

/// The command operation an inspection serves.
enum AgentOperation { inspect, validate }

/// One explicitly selected inspection or validation request.
final class AgentInspectionInput {
  const new({
    this.nativeFile,
    this.requestFile,
    this.cwd,
    this.harness,
    this.showInstructions = false,
  });

  /// A directly selected native definition file; requires [harness].
  final String? nativeFile;

  /// A bound-role request document; implies the Codex config-bound form.
  final String? requestFile;

  /// Optional working-directory context for resolving relative selections.
  final String? cwd;

  /// The explicit harness for [nativeFile]; never auto-detected.
  final AgentHarness? harness;

  /// Includes exact instruction text in the report; honored on inspect only.
  final bool showInstructions;
}

/// Distinguishes a native contract rule from a product restriction or advice.
enum AgentDiagnosticCategory { specification, product, advisory }

/// The only severities emitted by this engine.
enum AgentDiagnosticSeverity { error, warning }

/// One stable, machine-readable inspection finding.
final class AgentDiagnostic {
  const new({
    required this.code,
    required this.category,
    required this.severity,
    required this.field,
    required this.message,
  });

  final String code;
  final AgentDiagnosticCategory category;
  final AgentDiagnosticSeverity severity;
  final String? field;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'category': category.name,
    'severity': severity.name,
    'field': field,
    'message': message,
  };
}

/// The sealed validation outcome of an inspected candidate.
sealed class AgentValidationStatus {
  const AgentValidationStatus._();

  /// The wire value used in reports.
  String get wireName;
}

/// All required coverage completed without an error diagnostic.
final class AgentValidationPassed extends AgentValidationStatus {
  const AgentValidationPassed() : super._();

  @override
  String get wireName => 'passed';
}

/// Coverage completed with at least one error diagnostic.
final class AgentValidationFailed extends AgentValidationStatus {
  const AgentValidationFailed() : super._();

  @override
  String get wireName => 'failed';
}

/// Required coverage could not complete. Explicit inspection throws instead;
/// inventory may retain an unsupported linked candidate without target reads.
final class AgentValidationIncomplete extends AgentValidationStatus {
  const AgentValidationIncomplete() : super._();

  @override
  String get wireName => 'incomplete';
}

/// A read-only candidate inspection report.
///
/// The report exists even when the candidate failed validation. Operational
/// and incomplete-coverage failures throw, except inventory's explicit opt-in
/// to observing unsupported links without reading their targets. Instruction text is
/// never part of the default output; [AgentInspectionInput.showInstructions]
/// adds it on inspect only.
final class AgentInspectionReport {
  const AgentInspectionReport._({
    required this.form,
    required this.profile,
    required this.evidence,
    required this.definitionFile,
    required this.binding,
    required this.identity,
    required this.coverage,
    required this.diagnostics,
    required this.instructionsPresent,
    required this.instructionsProvenance,
    required this.instructionsRuntimeTrimmed,
    required this.instructionText,
    required this.references,
    required this.capabilities,
    required this.parentRequirements,
    required this.showInstructions,
  });

  /// The native form: `claude-agent-file`, `codex-agent-file`,
  /// `codex-config-bound-role`, or `pi-agent-file`.
  final String form;

  /// The evidence profile identifier.
  final String profile;

  /// Fixed evidence provenance for the profile.
  final Map<String, Object?> evidence;

  /// Normalized absolute lexical path of the definition file, when one was
  /// read. Null for metadata-only bindings and undetermined definitions.
  final String? definitionFile;

  /// Binding provenance for config-bound roles; null otherwise.
  final Map<String, Object?>? binding;

  /// Declared/resolved name and description with fallback provenance.
  final Map<String, Object?> identity;

  /// The coverage steps actually performed.
  final List<String> coverage;

  /// Every diagnostic produced by the inspection.
  final List<AgentDiagnostic> diagnostics;

  final bool instructionsPresent;
  final String instructionsProvenance;
  final bool instructionsRuntimeTrimmed;

  /// The exact instruction string; withheld from default output.
  final String? instructionText;

  final List<Map<String, Object?>> references;
  final List<Map<String, Object?>> capabilities;
  final List<Map<String, Object?>> parentRequirements;

  final bool showInstructions;

  /// Whether any error diagnostic was produced.
  bool get hasErrors => diagnostics.any(
    (diagnostic) => diagnostic.severity == AgentDiagnosticSeverity.error,
  );

  /// The sealed validation status. Only inventory's unsupported-link
  /// observation can return incomplete coverage rather than throw.
  AgentValidationStatus get validationStatus =>
      coverage.contains('link-observation')
      ? const AgentValidationIncomplete()
      : hasErrors
      ? const AgentValidationFailed()
      : const AgentValidationPassed();

  /// Whether required coverage passed; warnings alone do not make it unready.
  bool get ready => validationStatus is AgentValidationPassed;

  /// The exact versioned success envelope for [operation].
  Map<String, Object?> envelope(AgentOperation operation) => <String, Object?>{
    'schemaVersion': 1,
    'command': _commandLabel(operation),
    'outcome': _outcomeLabel(operation),
    'data': _data(operation),
    'diagnostics': [for (final diagnostic in diagnostics) diagnostic.toJson()],
  };

  /// A plain-text presentation of the same facts.
  String renderText(AgentOperation operation) {
    final buffer = StringBuffer()
      ..writeln('${_commandLabel(operation)}: ${_outcomeLabel(operation)}')
      ..writeln('form: $form')
      ..writeln('profile: $profile');
    final definition = definitionFile;
    if (definition != null) {
      buffer.writeln('definition: $definition');
    }
    final bound = binding;
    if (bound != null) {
      buffer
        ..writeln('declaring config: ${bound['configFile']}')
        ..writeln('role key: ${bound['roleKey']}')
        ..writeln('request: ${bound['requestFile']}');
    }
    final name = identity['name']! as Map<String, Object?>;
    final description = identity['description']! as Map<String, Object?>;
    buffer
      ..writeln(
        'name: ${name['resolved'] ?? '(unresolved)'} '
        '(${name['provenance']})',
      )
      ..writeln(
        'description: ${description['resolved'] ?? '(unresolved)'} '
        '(${description['provenance']})',
      )
      ..writeln('validation: ${validationStatus.wireName}')
      ..writeln('ready: $ready')
      ..writeln('coverage: ${coverage.join(', ')}');
    final instructions = _instructionsData(operation);
    if (instructions['present'] == true) {
      buffer.writeln(
        'instructions: ${instructions['byteLength']} bytes, '
        '${instructions['scalarLength']} scalars, '
        'sha256 ${instructions['sha256']}',
      );
      final text = instructions['text'];
      if (text is String) {
        buffer
          ..writeln('instructions text:')
          ..writeln(text);
      }
    } else {
      buffer.writeln('instructions: not present ($instructionsProvenance)');
    }
    buffer.writeln('diagnostics:');
    for (final diagnostic in diagnostics) {
      final field = diagnostic.field;
      buffer.writeln(
        '  [${diagnostic.severity.name}] ${diagnostic.code}'
        '${field == null ? '' : ' ($field)'}: ${diagnostic.message}',
      );
    }
    buffer.writeln('references:');
    for (final reference in references) {
      buffer.writeln(
        '  - ${reference['kind']} ${reference['name']} '
        '(${reference['label']})',
      );
    }
    buffer.writeln('capabilities:');
    for (final capability in capabilities) {
      buffer.writeln(
        '  - ${capability['kind']} ${capability['name']} '
        '(${capability['label']})',
      );
    }
    buffer.writeln('parent requirements:');
    for (final requirement in parentRequirements) {
      buffer.writeln('  - ${requirement['aspect']} (${requirement['label']})');
    }
    return buffer.toString();
  }

  Map<String, Object?> _data(AgentOperation operation) => <String, Object?>{
    'form': form,
    'profile': profile,
    'evidence': evidence,
    'source': <String, Object?>{
      'definitionFile': definitionFile,
      'binding': binding,
    },
    'identity': identity,
    'validation': <String, Object?>{
      'status': validationStatus.wireName,
      'coverage': coverage,
      'diagnostics': [
        for (final diagnostic in diagnostics) diagnostic.toJson(),
      ],
    },
    'instructions': _instructionsData(operation),
    'references': references,
    'capabilities': capabilities,
    'parentRequirements': parentRequirements,
    'ready': ready,
  };

  Map<String, Object?> _instructionsData(AgentOperation operation) {
    final text = instructionText;
    if (!instructionsPresent || text == null) {
      return <String, Object?>{
        'present': false,
        'provenance': instructionsProvenance,
        'byteLength': null,
        'scalarLength': null,
        'sha256': null,
        'runtimeTrimmed': instructionsRuntimeTrimmed,
      };
    }
    final bytes = utf8.encode(text);
    return <String, Object?>{
      'present': true,
      'provenance': instructionsProvenance,
      'byteLength': bytes.length,
      'scalarLength': text.runes.length,
      'sha256': sha256.convert(bytes).toString(),
      'runtimeTrimmed': instructionsRuntimeTrimmed,
      if (showInstructions && operation == AgentOperation.inspect) 'text': text,
    };
  }
}

/// Inspects or validates one explicitly selected native Agent candidate.
///
/// Throws [MambaException] with status 1 (usage/malformed request/missing
/// selection), 3 (incomplete coverage/budgets), or 4 (linked-file refusal).
/// Blocking validation violations are returned in the report instead; the
/// command layer maps [AgentInspectionReport.hasErrors] to status 2 for
/// [AgentOperation.validate].
AgentInspectionReport inspectNativeAgent(
  AgentInspectionInput input, {
  required AgentOperation operation,
}) {
  final nativeFile = _checkedOptional(input.nativeFile, 'native file');
  final requestFile = _checkedOptional(input.requestFile, 'request file');
  final cwd = _checkedOptional(input.cwd, 'working directory');

  if (nativeFile != null && requestFile != null) {
    throw _usage(
      'A native file positional and --request are mutually exclusive.',
    );
  }
  if (nativeFile == null && requestFile == null) {
    throw _usage(
      'Provide a native definition file with --harness, or a bound-role '
      'request with --request.',
    );
  }
  if (requestFile != null && input.harness != null) {
    throw _usage(
      'A bound-role request implies the Codex config-bound form and '
      'conflicts with --harness.',
    );
  }
  if (nativeFile != null && input.harness == null) {
    throw _usage('A native definition file requires an explicit harness.');
  }

  if (requestFile != null) {
    return _inspectBoundRole(
      requestFile,
      cwd,
      input.showInstructions,
      operation,
    );
  }
  return _inspectDirect(
    nativeFile!,
    input.harness!,
    cwd,
    input.showInstructions,
  );
}

// ---------------------------------------------------------------------------
// Bounds and evidence constants
// ---------------------------------------------------------------------------

const _maxDefinitionBytes = 1048576; // 1 MiB
const _maxFrontmatterBytes = 65536; // 64 KiB
const _maxDefinitionDepth = 32;
const _maxDefinitionNodes = 10000;
const _maxConfigBytes = 8388608; // 8 MiB
const _maxConfigDepth = 64;
const _maxConfigNodes = 100000;
const _maxRequestBytes = 8388608; // 8 MiB
const _maxRequestDepth = 32;
const _maxRequestNodes = 100000;

const _claudeProfile = 'claude-agent-native-v1';
const _codexProfile = 'codex-agent-native-v1';
const _piProfile = 'pi-agent-common-v1';
const _codexSourceCommit = '8531184b49bcb160175a84e140b659a83a426df7';

const _claudeEvidence = <String, Object?>{
  'kind': 'official-document-snapshot',
  'documentSha256':
      '84b2646c513754ef5f33c6f5a0d7f59960021a65b5a09c35b9158fa116a73d5a',
};

const _codexEvidence = <String, Object?>{
  'kind': 'official-document-snapshot-and-pinned-source',
  'documentSha256':
      'e7469d41c5a18a4ee66ee40ca4a9a2617a697e42554a0198ac4481e1e597357f',
  'sourceCommit': _codexSourceCommit,
};

const _piEvidence = <String, Object?>{
  'kind': 'pinned-package-sources',
  'packages': <Map<String, Object?>>[
    <String, Object?>{
      'name': 'pi-subagents',
      'version': '0.81.0',
      'commit': '1bc941363cb62fc23c94c5519364b03dc150be3e',
    },
    <String, Object?>{
      'name': '@tintinweb/pi-subagents',
      'version': '0.22.0',
      'commit': '85a704cb8f35c96c0cabfa665b572bab296942e5',
    },
  ],
};

// ---------------------------------------------------------------------------
// Failure helpers
// ---------------------------------------------------------------------------

MambaException _usage(String message) => MambaException(message, exitCode: 1);

MambaException _incomplete(String message) =>
    MambaException(message, exitCode: 3);

MambaException _refusal(String message) => MambaException(message, exitCode: 4);

String? _checkedOptional(String? value, String label) {
  if (value == null) {
    return null;
  }
  if (value.trim().isEmpty) {
    throw _usage('The selected $label must not be blank.');
  }
  return value;
}

String _commandLabel(AgentOperation operation) => switch (operation) {
  AgentOperation.inspect => 'agent inspect',
  AgentOperation.validate => 'agent validate',
};

String _outcomeLabel(AgentOperation operation) => switch (operation) {
  AgentOperation.inspect => 'inspected',
  AgentOperation.validate => 'validated',
};

// ---------------------------------------------------------------------------
// Filesystem, decode, and budget primitives
// ---------------------------------------------------------------------------

String _resolvePath(String base, String path) =>
    p.normalize(p.isAbsolute(path) ? path : p.join(base, path));

String _resolveWorkingDirectory(String? cwd) {
  final raw = cwd ?? Directory.current.path;
  final resolved = p.normalize(
    p.isAbsolute(raw) ? raw : p.join(Directory.current.path, raw),
  );
  final type = _observeType(resolved, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    throw _usage('The working directory does not exist: $resolved');
  }
  if (type != FileSystemEntityType.directory) {
    throw _usage('The working directory is not a directory: $resolved');
  }
  return resolved;
}

/// Link-aware filesystem observation for required inputs. An inaccessible
/// lookup is an incomplete-coverage failure (status 3), never conflated with
/// absence.
FileSystemEntityType _observeType(String path, {required bool followLinks}) {
  try {
    return skillEntityType(path, followLinks: followLinks);
  } on MambaException catch (error) {
    throw _incomplete('Could not observe $path: ${error.message}');
  }
}

/// Reads a required file within [maxBytes]; over-cap reads and inaccessible
/// files are incomplete-coverage failures (status 3).
List<int> _readBounded(String path, int maxBytes, String what) {
  final List<int> bytes;
  try {
    bytes = readBoundedSkillMarker(path, maxBytes: maxBytes);
  } on MambaException catch (error) {
    throw _incomplete('Could not read the $what: ${error.message}');
  }
  if (bytes.length > maxBytes) {
    throw _incomplete('The $what exceeds the $maxBytes-byte budget: $path');
  }
  return bytes;
}

/// Strict UTF-8 decode with no replacement characters; null on failure.
String? _decodeStrictUtf8(List<int> bytes) {
  try {
    // Accepts and removes one standard leading BOM, matching the Skill
    // validator's established behavior.
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    return null;
  }
}

/// Counts parsed nodes and enforces depth and node budgets. Budget
/// exhaustion is incomplete analysis (status 3), never truncated success.
int _measureStructure(
  Object? value,
  int depth,
  int maxDepth,
  int maxNodes,
  int count,
  String what,
) {
  var total = count + 1;
  if (total > maxNodes) {
    throw _incomplete('$what exceeds the $maxNodes parsed-node budget.');
  }
  if (depth > maxDepth) {
    throw _incomplete('$what exceeds the depth-$maxDepth parse budget.');
  }
  if (value is Map) {
    for (final entry in value.entries) {
      total = _measureStructure(
        entry.key,
        depth + 1,
        maxDepth,
        maxNodes,
        total,
        what,
      );
      total = _measureStructure(
        entry.value,
        depth + 1,
        maxDepth,
        maxNodes,
        total,
        what,
      );
    }
  } else if (value is List) {
    for (final item in value) {
      total = _measureStructure(
        item,
        depth + 1,
        maxDepth,
        maxNodes,
        total,
        what,
      );
    }
  }
  return total;
}

String _typeName(Object? value) => switch (value) {
  null => 'null',
  String _ => 'string',
  bool _ => 'boolean',
  int _ => 'integer',
  double _ => 'float',
  List<Object?> _ => 'list',
  Map<Object?, Object?> _ => 'map',
  _ => 'other',
};

// ---------------------------------------------------------------------------
// Report assembly
// ---------------------------------------------------------------------------

final class _ReportBuilder {
  _ReportBuilder({
    required this.form,
    required this.profile,
    required this.evidence,
  });

  final String form;
  final String profile;
  final Map<String, Object?> evidence;
  String? definitionFile;
  Map<String, Object?>? binding;
  final Map<String, Object?> identityName = <String, Object?>{
    'declared': null,
    'resolved': null,
    'provenance': 'unresolved',
  };
  final Map<String, Object?> identityDescription = <String, Object?>{
    'declared': null,
    'resolved': null,
    'provenance': 'unresolved',
  };
  final List<String> coverage = <String>[];
  final List<AgentDiagnostic> diagnostics = <AgentDiagnostic>[];
  bool instructionsPresent = false;
  String instructionsProvenance = 'undetermined';
  bool instructionsRuntimeTrimmed = false;
  String? instructionText;
  final List<Map<String, Object?>> references = <Map<String, Object?>>[];
  final List<Map<String, Object?>> capabilities = <Map<String, Object?>>[];
  final List<Map<String, Object?>> parentRequirements =
      <Map<String, Object?>>[];

  void error(
    String code,
    AgentDiagnosticCategory category,
    String? field,
    String message,
  ) {
    diagnostics.add(
      AgentDiagnostic(
        code: code,
        category: category,
        severity: AgentDiagnosticSeverity.error,
        field: field,
        message: message,
      ),
    );
  }

  void warn(
    String code,
    AgentDiagnosticCategory category,
    String? field,
    String message,
  ) {
    diagnostics.add(
      AgentDiagnostic(
        code: code,
        category: category,
        severity: AgentDiagnosticSeverity.warning,
        field: field,
        message: message,
      ),
    );
  }

  AgentInspectionReport finish({required bool showInstructions}) =>
      AgentInspectionReport._(
        form: form,
        profile: profile,
        evidence: evidence,
        definitionFile: definitionFile,
        binding: binding == null
            ? null
            : Map<String, Object?>.unmodifiable(binding!),
        identity: <String, Object?>{
          'name': Map<String, Object?>.unmodifiable(identityName),
          'description': Map<String, Object?>.unmodifiable(identityDescription),
        },
        coverage: List<String>.unmodifiable(coverage),
        diagnostics: List<AgentDiagnostic>.unmodifiable(diagnostics),
        instructionsPresent: instructionsPresent,
        instructionsProvenance: instructionsProvenance,
        instructionsRuntimeTrimmed: instructionsRuntimeTrimmed,
        instructionText: instructionText,
        references: List<Map<String, Object?>>.unmodifiable(
          references.map(Map<String, Object?>.unmodifiable),
        ),
        capabilities: List<Map<String, Object?>>.unmodifiable(
          capabilities.map(Map<String, Object?>.unmodifiable),
        ),
        parentRequirements: List<Map<String, Object?>>.unmodifiable(
          parentRequirements.map(Map<String, Object?>.unmodifiable),
        ),
        showInstructions: showInstructions,
      );
}

Map<String, Object?> _reference(
  String kind,
  String name,
  String label, [
  String? detail,
]) => <String, Object?>{
  'kind': kind,
  'name': name,
  'label': label,
  'detail': ?detail,
};

Map<String, Object?> _capability(
  String kind,
  String name,
  String label, [
  String? detail,
]) => <String, Object?>{
  'kind': kind,
  'name': name,
  'label': label,
  'detail': ?detail,
};

Map<String, Object?> _parentRequirement(
  String aspect,
  String label,
  String detail,
) => <String, Object?>{'aspect': aspect, 'label': label, 'detail': detail};

// ---------------------------------------------------------------------------
// Direct native-file inspection
// ---------------------------------------------------------------------------

AgentInspectionReport _inspectDirect(
  String nativeFile,
  AgentHarness harness,
  String? cwd,
  bool showInstructions,
) {
  final workingDirectory = _resolveWorkingDirectory(cwd);
  final path = _resolvePath(workingDirectory, nativeFile);
  final builder = switch (harness) {
    AgentHarness.claude => _ReportBuilder(
      form: 'claude-agent-file',
      profile: _claudeProfile,
      evidence: _claudeEvidence,
    ),
    AgentHarness.codex => _ReportBuilder(
      form: 'codex-agent-file',
      profile: _codexProfile,
      evidence: _codexEvidence,
    ),
    AgentHarness.pi => _ReportBuilder(
      form: 'pi-agent-file',
      profile: _piProfile,
      evidence: _piEvidence,
    ),
  };
  builder.coverage.add('source-selection');
  builder.definitionFile = path;

  final type = _observeType(path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw _refusal(
      'Refusing to read the linked file $path; select the definition file '
      'directly.',
    );
  }
  if (type == FileSystemEntityType.notFound) {
    throw _usage('The native definition file does not exist: $path');
  }
  if (type != FileSystemEntityType.file) {
    throw _usage('The native definition path is not a regular file: $path');
  }
  builder.coverage.add('filesystem-observation');

  final bytes = _readBounded(path, _maxDefinitionBytes, 'native definition');
  builder.coverage.add('bounded-read');
  final text = _decodeStrictUtf8(bytes);
  builder.coverage.add('utf8-decode');
  if (text == null) {
    builder.error(
      'UTF8_INVALID',
      AgentDiagnosticCategory.product,
      null,
      'The definition file is not valid UTF-8; its content was not decoded, '
          'rewritten, or displayed.',
    );
    return builder.finish(showInstructions: showInstructions);
  }

  if (harness == AgentHarness.codex) {
    final fields = _parseTomlCandidate(text, builder, 'The definition file');
    if (fields != null) {
      builder.coverage.add('field-validation');
      _validateCodexFields(fields, builder, bound: false);
    }
    return builder.finish(showInstructions: showInstructions);
  }

  final fields = _parseMarkdownCandidate(text, builder, harness);
  if (fields != null) {
    builder.coverage.add('field-validation');
    if (harness == AgentHarness.claude) {
      _validateClaudeFields(fields, builder);
    } else {
      _validatePiFields(fields, builder);
    }
  }
  return builder.finish(showInstructions: showInstructions);
}

// ---------------------------------------------------------------------------
// Markdown frontmatter handling (Claude and Pi)
// ---------------------------------------------------------------------------

enum _FrontmatterStatus { missing, unterminated, complete }

final class _FrontmatterExtraction {
  const _FrontmatterExtraction(this.status, {this.yamlText, this.body});

  final _FrontmatterStatus status;
  final String? yamlText;
  final String? body;
}

/// Parses the Markdown candidate, records the preserved body for hashing and
/// explicit display, and returns the frontmatter map, or null after adding
/// blocking diagnostics.
Map<Object?, Object?>? _parseMarkdownCandidate(
  String text,
  _ReportBuilder builder,
  AgentHarness harness,
) {
  final extraction = _extractFrontmatter(text);
  switch (extraction.status) {
    case _FrontmatterStatus.missing:
      builder.error(
        'FRONTMATTER_MISSING',
        AgentDiagnosticCategory.specification,
        null,
        'The definition must start with a standalone --- line.',
      );
      return null;
    case _FrontmatterStatus.unterminated:
      builder.error(
        'FRONTMATTER_UNTERMINATED',
        AgentDiagnosticCategory.specification,
        null,
        'The frontmatter has no standalone closing --- line.',
      );
      return null;
    case _FrontmatterStatus.complete:
      break;
  }
  builder.coverage.add('frontmatter-extraction');
  builder.instructionsPresent = true;
  builder.instructionsProvenance = 'markdown-body';
  builder.instructionText = extraction.body;
  builder.instructionsRuntimeTrimmed = harness == AgentHarness.pi;

  final yamlText = extraction.yamlText!;
  if (utf8.encode(yamlText).length > _maxFrontmatterBytes) {
    throw _incomplete(
      'The frontmatter exceeds the $_maxFrontmatterBytes-byte budget.',
    );
  }
  builder.coverage.add('frontmatter-size');

  final restrictions = _scanYamlRestrictions(yamlText);
  if (restrictions.isNotEmpty) {
    for (final restriction in restrictions) {
      builder.error(
        restriction.code,
        AgentDiagnosticCategory.product,
        null,
        '${restriction.description} (line ${restriction.line}).',
      );
    }
    return null;
  }
  builder.coverage.add('frontmatter-restrictions');

  final Object? parsed;
  try {
    // package:yaml builds data; it evaluates nothing and executes nothing.
    parsed = loadYaml(yamlText);
  } on YamlException catch (error) {
    final duplicate = error.toString().contains('Duplicate mapping key');
    builder.error(
      duplicate ? 'YAML_DUPLICATE_KEY' : 'YAML_INVALID',
      AgentDiagnosticCategory.specification,
      null,
      duplicate
          ? 'The frontmatter contains a duplicate key; duplicate keys are '
                'blocking.'
          : 'The frontmatter is not valid YAML; parsing is non-repairing.',
    );
    return null;
  }
  builder.coverage.add('yaml-parse');

  _measureStructure(
    parsed,
    1,
    _maxDefinitionDepth,
    _maxDefinitionNodes,
    0,
    'The frontmatter',
  );
  builder.coverage.add('yaml-budgets');

  if (parsed is! Map) {
    builder.error(
      'FRONTMATTER_MAPPING',
      AgentDiagnosticCategory.specification,
      null,
      'The frontmatter must be a YAML mapping.',
    );
    return null;
  }
  for (final key in parsed.keys) {
    if (key is! String) {
      builder.error(
        'FRONTMATTER_KEYS',
        AgentDiagnosticCategory.product,
        null,
        'Top-level YAML mapping keys must be strings.',
      );
    }
  }
  return parsed;
}

_FrontmatterExtraction _extractFrontmatter(String content) {
  final firstNewline = content.indexOf('\n');
  final firstLineEnd = firstNewline < 0 ? content.length : firstNewline;
  if (_lineText(content, 0, firstLineEnd) != '---') {
    return const _FrontmatterExtraction(_FrontmatterStatus.missing);
  }
  if (firstNewline < 0) {
    return const _FrontmatterExtraction(_FrontmatterStatus.unterminated);
  }

  var lineStart = firstNewline + 1;
  while (lineStart <= content.length) {
    final newline = content.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? content.length : newline;
    if (_lineText(content, lineStart, lineEnd) == '---') {
      final body = newline < 0 ? '' : content.substring(newline + 1);
      return _FrontmatterExtraction(
        _FrontmatterStatus.complete,
        yamlText: content.substring(firstNewline + 1, lineStart),
        body: body,
      );
    }
    if (newline < 0) {
      break;
    }
    lineStart = newline + 1;
  }

  return const _FrontmatterExtraction(_FrontmatterStatus.unterminated);
}

String _lineText(String content, int start, int end) {
  final hasCarriageReturn = end > start && content.codeUnitAt(end - 1) == 0x0D;
  return content.substring(start, hasCarriageReturn ? end - 1 : end);
}

// ---------------------------------------------------------------------------
// YAML restriction scan (aliases/anchors, custom tags, merge keys)
// ---------------------------------------------------------------------------

final class _YamlRestriction {
  const _YamlRestriction(this.code, this.description, this.line);

  final String code;
  final String description;
  final int line;
}

/// Lexically detects YAML aliases/anchors, custom tags, and merge keys, which
/// this product blocks. This is a restriction detector, not a parser: it
/// skips quoted scalars, comments, and block-scalar content, and flags the
/// restricted tokens only at node-start positions. [loadYaml] performs the
/// real parse afterwards.
List<_YamlRestriction> _scanYamlRestrictions(String text) {
  final found = <_YamlRestriction>[];
  var inSingle = false;
  var inDouble = false;
  int? blockIndent;

  final lines = text.split('\n');
  for (var lineNumber = 0; lineNumber < lines.length; lineNumber++) {
    var line = lines[lineNumber];
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    final indent = _leadingSpaces(line);
    if (blockIndent != null) {
      if (line.trim().isEmpty) {
        continue;
      }
      if (indent > blockIndent) {
        continue; // Block-scalar content.
      }
      blockIndent = null;
    }

    var index = 0;
    while (index < line.length) {
      final char = line[index];
      if (inSingle) {
        if (char == "'") {
          if (index + 1 < line.length && line[index + 1] == "'") {
            index += 2;
            continue;
          }
          inSingle = false;
        }
        index++;
        continue;
      }
      if (inDouble) {
        if (char == '\\') {
          index += 2;
          continue;
        }
        if (char == '"') {
          inDouble = false;
        }
        index++;
        continue;
      }
      if (char == '#') {
        if (index == 0 || line[index - 1] == ' ' || line[index - 1] == '\t') {
          break; // Comment to end of line.
        }
        index++;
        continue;
      }
      if (char == "'") {
        inSingle = true;
        index++;
        continue;
      }
      if (char == '"') {
        inDouble = true;
        index++;
        continue;
      }
      final tokenStart =
          index == 0 ||
          line[index - 1] == ' ' ||
          line[index - 1] == '\t' ||
          line[index - 1] == '[' ||
          line[index - 1] == '{' ||
          line[index - 1] == ',';
      if ((char == '|' || char == '>') &&
          tokenStart &&
          _isBlockScalarHeader(line, index)) {
        blockIndent = indent;
        break;
      }
      if (tokenStart && (char == '&' || char == '*' || char == '!')) {
        final next = index + 1 < line.length ? line[index + 1] : ' ';
        if (char == '!') {
          if (next == '!' || next == '<' || _isAlphaNumeric(next)) {
            found.add(
              _YamlRestriction(
                'YAML_TAG',
                'Custom YAML tags are blocked',
                lineNumber + 1,
              ),
            );
            index++;
            continue;
          }
        } else if (_isAnchorChar(next)) {
          found.add(
            _YamlRestriction(
              char == '&' ? 'YAML_ANCHOR' : 'YAML_ALIAS',
              char == '&'
                  ? 'YAML anchors are blocked'
                  : 'YAML aliases are blocked',
              lineNumber + 1,
            ),
          );
          index++;
          continue;
        }
      }
      if (tokenStart &&
          char == '<' &&
          index + 1 < line.length &&
          line[index + 1] == '<') {
        var cursor = index + 2;
        while (cursor < line.length &&
            (line[cursor] == ' ' || line[cursor] == '\t')) {
          cursor++;
        }
        if (cursor < line.length && line[cursor] == ':') {
          found.add(
            _YamlRestriction(
              'YAML_MERGE_KEY',
              'YAML merge keys are blocked',
              lineNumber + 1,
            ),
          );
          index = cursor + 1;
          continue;
        }
      }
      index++;
    }
  }
  return found;
}

int _leadingSpaces(String line) {
  var count = 0;
  while (count < line.length && line[count] == ' ') {
    count++;
  }
  return count;
}

bool _isBlockScalarHeader(String line, int index) {
  final rest = line.substring(index + 1);
  return RegExp(r'^[+-]?[0-9]?[ \t]*(#.*)?$').hasMatch(rest);
}

bool _isAlphaNumeric(String char) => RegExp(r'^[A-Za-z0-9]$').hasMatch(char);

bool _isAnchorChar(String char) =>
    char != ' ' &&
    char != '\t' &&
    char != '[' &&
    char != ']' &&
    char != '{' &&
    char != '}' &&
    char != ',';

// ---------------------------------------------------------------------------
// TOML handling (Codex)
// ---------------------------------------------------------------------------

/// Parses a Codex candidate definition. Malformed syntax and duplicate keys
/// are failed-candidate diagnostics; budget exhaustion throws status 3.
Map<String, Object?>? _parseTomlCandidate(
  String text,
  _ReportBuilder builder,
  String what,
) {
  final Map<String, Object?> map;
  try {
    map = Map<String, Object?>.from(TomlDocument.parse(text).toMap());
  } on TomlRedefinitionException {
    builder.error(
      'TOML_DUPLICATE_KEY',
      AgentDiagnosticCategory.specification,
      null,
      '$what redefines a key; duplicate keys are blocking.',
    );
    return null;
  } on TomlException {
    builder.error(
      'TOML_INVALID',
      AgentDiagnosticCategory.specification,
      null,
      '$what is not valid TOML; parsing is non-repairing.',
    );
    return null;
  }
  builder.coverage.add('toml-parse');
  _measureStructure(
    map,
    1,
    _maxDefinitionDepth,
    _maxDefinitionNodes,
    0,
    'The definition document',
  );
  builder.coverage.add('toml-budgets');
  return map;
}

/// Parses the declaring Codex config. Its parse is required coverage, so
/// syntax and budget failures throw status 3 rather than yielding a report.
Map<String, Object?> _parseDeclaringConfig(String text, String configPath) {
  final Map<String, Object?> map;
  try {
    map = Map<String, Object?>.from(TomlDocument.parse(text).toMap());
  } on TomlException catch (error) {
    throw _incomplete(
      'The declaring config $configPath is not valid TOML (${error.message}); '
      'required parse coverage is incomplete.',
    );
  }
  _measureStructure(
    map,
    1,
    _maxConfigDepth,
    _maxConfigNodes,
    0,
    'The declaring config',
  );
  return map;
}

// ---------------------------------------------------------------------------
// Bound-role request inspection (Codex config-bound roles)
// ---------------------------------------------------------------------------

/// A validated version-1 bound-role request envelope.
final class _BoundRoleRequest {
  const _BoundRoleRequest({
    this.requestPath,
    required this.configFile,
    required this.roleKey,
    required this.workingDirectory,
  });

  final String? requestPath;
  final String configFile;
  final String roleKey;
  final String workingDirectory;
}

AgentInspectionReport _inspectBoundRole(
  String requestFile,
  String? cwd,
  bool showInstructions,
  AgentOperation operation,
) => _inspectBoundRoleSelection(
  _readRequest(requestFile, cwd, operation),
  showInstructions,
);

/// Inspects one explicitly selected Codex binding without a JSON request file.
///
/// Discovery uses this focused entry point so declaration and fallback logic
/// remains shared with request-driven inspection. The caller supplies native
/// context explicitly; no ambient configuration is consulted.
AgentInspectionReport inspectCodexBoundRole({
  required String configFile,
  required String roleKey,
  required String workingDirectory,
  String? requestFile,
  bool showInstructions = false,
}) {
  if (configFile.trim().isEmpty || roleKey.trim().isEmpty) {
    throw _usage('A bound role requires nonblank configFile and roleKey.');
  }
  return _inspectBoundRoleSelection(
    _BoundRoleRequest(
      requestPath: requestFile,
      configFile: configFile,
      roleKey: roleKey,
      workingDirectory: _resolveWorkingDirectory(workingDirectory),
    ),
    showInstructions,
  );
}

AgentInspectionReport _inspectBoundRoleSelection(
  _BoundRoleRequest request,
  bool showInstructions,
) => CodexBindingInspection.read(
  configFile: request.configFile,
  workingDirectory: request.workingDirectory,
  requestFile: request.requestPath,
).inspectRole(request.roleKey, showInstructions: showInstructions);

/// Observes a required metadata read before it occurs.
typedef AgentMetadataReadObserver = void Function(String path, int maxBytes);

/// One parsed Codex declaring config shared by one or more role inspections.
///
/// This keeps inventory from reparsing a mixed parent document for every role
/// while preserving the exact request-driven single-role behavior.
final class CodexBindingInspection {
  CodexBindingInspection._({
    required this.configFile,
    required this.workingDirectory,
    required this.requestFile,
    required this._config,
    required this._beforeRead,
  });

  factory CodexBindingInspection.read({
    required String configFile,
    required String workingDirectory,
    String? requestFile,
    AgentMetadataReadObserver? beforeRead,
  }) {
    if (configFile.trim().isEmpty) {
      throw _usage('The declaring config path must not be blank.');
    }
    final configPath = _resolvePath(workingDirectory, configFile);
    for (final component in skillPathComponents(
      configPath,
      base: workingDirectory,
    )) {
      if (_observeType(component, followLinks: false) ==
          FileSystemEntityType.link) {
        throw _refusal(
          'Refusing to read the linked declaring config path $component.',
        );
      }
    }
    final configType = _observeType(configPath, followLinks: false);
    if (configType == FileSystemEntityType.link) {
      throw _refusal(
        'Refusing to read the linked declaring config $configPath.',
      );
    }
    if (configType == FileSystemEntityType.notFound) {
      throw _usage('The declaring config does not exist: $configPath');
    }
    if (configType != FileSystemEntityType.file) {
      throw _usage(
        'The declaring config path is not a regular file: $configPath',
      );
    }
    beforeRead?.call(configPath, _maxConfigBytes);
    final configBytes = _readBounded(
      configPath,
      _maxConfigBytes,
      'declaring config',
    );
    final configText = _decodeStrictUtf8(configBytes);
    if (configText == null) {
      throw _incomplete(
        'The declaring config $configPath is not valid UTF-8; required read '
        'coverage is incomplete.',
      );
    }
    return CodexBindingInspection._(
      configFile: configPath,
      workingDirectory: workingDirectory,
      requestFile: requestFile,
      config: _parseDeclaringConfig(configText, configPath),
      beforeRead: beforeRead,
    );
  }

  final String configFile;
  final String workingDirectory;
  final String? requestFile;
  final Map<String, Object?> _config;
  final AgentMetadataReadObserver? _beforeRead;

  /// Sorted role-table keys in this declaring layer, excluding scalar global
  /// agents settings. No precedence is inferred.
  List<String> get roleKeys {
    final agents = _config['agents'];
    if (agents == null) return const <String>[];
    if (agents is! Map) {
      throw _incomplete('The declaring config agents value is not a table.');
    }
    final keys = <String>[];
    for (final key in agents.keys) {
      if (key is! String) {
        throw _incomplete(
          'The declaring config contains a non-string role key.',
        );
      }
      if (agents[key] is Map) keys.add(key);
    }
    return List<String>.unmodifiable(keys..sort());
  }

  /// Inspects one role using this already parsed declaring config.
  /// Inventory alone opts into [observeLinkedDefinition] to retain an incomplete
  /// linked occurrence. Explicit inspect/validate retain their status-4 refusal.
  AgentInspectionReport inspectRole(
    String roleKey, {
    bool showInstructions = false,
    bool observeLinkedDefinition = false,
  }) {
    if (roleKey.trim().isEmpty) {
      throw _usage('A bound role requires a nonblank roleKey.');
    }
    final agents = _config['agents'];
    final declaration = agents is Map && agents.containsKey(roleKey)
        ? agents[roleKey]
        : null;
    if (declaration is! Map) {
      throw _usage(
        'The declaring config $configFile declares no '
        '[agents.$roleKey] binding.',
      );
    }

    final builder = _ReportBuilder(
      form: 'codex-config-bound-role',
      profile: _codexProfile,
      evidence: <String, Object?>{
        ..._codexEvidence,
        'binding': 'codex-config-declared-role',
      },
    );
    builder.coverage.add('config-parse');
    builder.identityName['bindingHint'] = roleKey;
    builder.binding = <String, Object?>{
      'configFile': configFile,
      'roleKey': roleKey,
      'requestFile': requestFile,
    };

    final selection = _validateCodexDeclaration(
      Map<String, Object?>.from(declaration),
      builder,
      roleKey,
    );

    if (selection.configFile != null) {
      final definitionPath = _resolvePath(
        p.dirname(configFile),
        selection.configFile!,
      );
      builder.definitionFile = definitionPath;
      for (final component in skillPathComponents(
        definitionPath,
        base: p.dirname(configFile),
      )) {
        if (_observeType(component, followLinks: false) !=
            FileSystemEntityType.link) {
          continue;
        }
        if (!observeLinkedDefinition) {
          throw _refusal(
            'Refusing to read the linked role definition path $component.',
          );
        }
        builder.coverage.add('link-observation');
        builder.warn(
          'LINKED_CANDIDATE',
          AgentDiagnosticCategory.product,
          null,
          'The linked candidate was reported without reading its target.',
        );
        _applyBoundFallbacks(builder, roleKey, selection.description);
        return builder.finish(showInstructions: false);
      }
      final definitionType = _observeType(definitionPath, followLinks: false);
      if (definitionType == FileSystemEntityType.notFound) {
        throw _incomplete(
          'The referenced role definition does not exist: $definitionPath',
        );
      }
      if (definitionType != FileSystemEntityType.file) {
        throw _incomplete(
          'The referenced role definition is not a regular file: '
          '$definitionPath',
        );
      }
      builder.definitionFile = definitionPath;
      builder.coverage.add('definition-read');
      _beforeRead?.call(definitionPath, _maxDefinitionBytes);
      final bytes = _readBounded(
        definitionPath,
        _maxDefinitionBytes,
        'role definition',
      );
      final text = _decodeStrictUtf8(bytes);
      if (text == null) {
        builder.error(
          'UTF8_INVALID',
          AgentDiagnosticCategory.product,
          null,
          'The role definition file is not valid UTF-8; its content was not '
              'decoded, rewritten, or displayed.',
        );
      } else {
        final fields = _parseTomlCandidate(
          text,
          builder,
          'The role definition file',
        );
        if (fields != null) {
          builder.coverage.add('field-validation');
          _validateCodexFields(fields, builder, bound: true);
        }
      }
    }

    _applyBoundFallbacks(builder, roleKey, selection.description);
    return builder.finish(showInstructions: showInstructions);
  }
}

/// Validates the selected declaration's native field types and returns its
/// description and config_file values for fallback and resolution.
({String? description, String? configFile}) _validateCodexDeclaration(
  Map<String, Object?> declaration,
  _ReportBuilder builder,
  String roleKey,
) {
  const known = <String>{'description', 'config_file', 'nickname_candidates'};
  String? description;
  String? configFile;

  if (declaration.containsKey('description')) {
    final value = declaration['description'];
    if (value is String && value.trim().isNotEmpty) {
      description = value;
    } else if (value is String) {
      builder.error(
        'ROLE_DESCRIPTION_BLANK',
        AgentDiagnosticCategory.specification,
        'agents.$roleKey.description',
        'The declaration description must not be blank.',
      );
    } else {
      builder.error(
        'ROLE_DESCRIPTION_TYPE',
        AgentDiagnosticCategory.specification,
        'agents.$roleKey.description',
        'The declaration description must be a string.',
      );
    }
  }

  if (declaration.containsKey('config_file')) {
    final value = declaration['config_file'];
    if (value is String && value.trim().isNotEmpty) {
      configFile = value;
    } else if (value is String) {
      builder.error(
        'CONFIG_FILE_BLANK',
        AgentDiagnosticCategory.specification,
        'agents.$roleKey.config_file',
        'The declaration config_file must not be blank.',
      );
    } else {
      builder.error(
        'CONFIG_FILE_TYPE',
        AgentDiagnosticCategory.specification,
        'agents.$roleKey.config_file',
        'The declaration config_file must be a string.',
      );
    }
  }

  if (declaration.containsKey('nickname_candidates')) {
    _validateNicknameCandidates(
      declaration['nickname_candidates'],
      builder,
      'agents.$roleKey.nickname_candidates',
    );
  }

  final unknown = <String>[
    for (final key in declaration.keys)
      if (!known.contains(key)) key,
  ]..sort();
  for (final key in unknown) {
    builder.warn(
      'UNKNOWN_FIELD',
      AgentDiagnosticCategory.advisory,
      'agents.$roleKey.$key',
      'Unknown role declaration field of type '
          '${_typeName(declaration[key])}; the value is not reported.',
    );
  }

  return (description: description, configFile: configFile);
}

/// Applies binding fallbacks after definition processing: the role key
/// supplies fallback identity, the declaration description is the fallback
/// description, and a definition without developer_instructions retains the
/// inherited instruction state rather than fabricating instructions.
void _applyBoundFallbacks(
  _ReportBuilder builder,
  String roleKey,
  String? declarationDescription,
) {
  final declared = builder.identityName['declared'];
  if (builder.identityName['resolved'] == null) {
    builder.identityName['resolved'] = roleKey;
    builder.identityName['provenance'] = 'binding-fallback';
  } else if (declared is String && declared.trim() != roleKey) {
    builder.warn(
      'NAME_BINDING_DISAGREEMENT',
      AgentDiagnosticCategory.advisory,
      'name',
      'The file name disagrees with the role-key hint; the file name wins.',
    );
  }

  if (builder.identityDescription['resolved'] == null) {
    if (declarationDescription != null) {
      builder.identityDescription['resolved'] = declarationDescription;
      builder.identityDescription['provenance'] = 'declaration';
    } else {
      builder.error(
        'DESCRIPTION_REQUIRED',
        AgentDiagnosticCategory.specification,
        'description',
        'A bound role resolves no description: the file and the declaration '
            'both omit one.',
      );
    }
  }

  if (!builder.instructionsPresent) {
    builder.instructionsProvenance = 'inherited';
  }
}

// ---------------------------------------------------------------------------
// Request envelope reading and validation
// ---------------------------------------------------------------------------

_BoundRoleRequest _readRequest(
  String requestFile,
  String? cwd,
  AgentOperation operation,
) {
  final cliCwd = cwd == null ? null : _resolveWorkingDirectory(cwd);
  final requestBase = cliCwd ?? p.normalize(Directory.current.path);
  final requestPath = _resolvePath(requestBase, requestFile);

  final type = _observeType(requestPath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw _refusal(
      'Refusing to read the linked request document $requestPath.',
    );
  }
  if (type == FileSystemEntityType.notFound) {
    throw _usage('The request document does not exist: $requestPath');
  }
  if (type != FileSystemEntityType.file) {
    throw _usage('The request path is not a regular file: $requestPath');
  }

  final List<int> bytes;
  try {
    bytes = readBoundedSkillMarker(requestPath, maxBytes: _maxRequestBytes);
  } on MambaException catch (error) {
    throw _incomplete('Could not read the request document: ${error.message}');
  }
  if (bytes.length > _maxRequestBytes) {
    throw _incomplete(
      'The request document exceeds the $_maxRequestBytes-byte budget.',
    );
  }
  final text = _decodeStrictUtf8(bytes);
  if (text == null) {
    throw _usage('The request document is not valid UTF-8.');
  }

  // dart:convert assembles objects without reporting duplicate keys, so a
  // lexical scan records decoded keys per object frame first; it also bounds
  // depth before jsonDecode recurses.
  _scanJsonRequest(text);

  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw _usage('The request document is not valid JSON.');
  }
  try {
    _measureStructure(
      decoded,
      1,
      _maxRequestDepth,
      _maxRequestNodes,
      0,
      'The request document',
    );
  } on MambaException catch (error) {
    throw _incomplete(error.message);
  }

  if (decoded is! Map) {
    throw _usage('The request document must be a JSON object.');
  }
  const envelopeKeys = <String>{
    'schemaVersion',
    'operation',
    'source',
    'context',
  };
  for (final key in decoded.keys) {
    if (key is! String || !envelopeKeys.contains(key)) {
      throw _usage('The request envelope carries an unknown or invalid field.');
    }
  }
  for (final key in envelopeKeys) {
    if (!decoded.containsKey(key)) {
      throw _usage('The request envelope requires $key.');
    }
  }

  final schemaVersion = decoded['schemaVersion'];
  if (schemaVersion is! int || schemaVersion != 1) {
    throw _usage('The request schemaVersion must be 1.');
  }
  if (decoded['operation'] != operation.name) {
    throw _usage(
      'The request operation must match the selected command '
      '(${operation.name}).',
    );
  }

  final source = decoded['source'];
  if (source is! Map) {
    throw _usage('The request source must be an object.');
  }
  const sourceKeys = <String>{'kind', 'configFile', 'roleKey'};
  for (final key in source.keys) {
    if (key is! String || !sourceKeys.contains(key)) {
      throw _usage('The request source carries an unknown or invalid field.');
    }
  }
  for (final key in sourceKeys) {
    if (!source.containsKey(key)) {
      throw _usage('The request source requires $key.');
    }
  }
  if (source['kind'] != 'codex-role') {
    throw _usage("The request source kind must be 'codex-role'.");
  }
  final configFile = source['configFile'];
  if (configFile is! String || configFile.trim().isEmpty) {
    throw _usage('The request source configFile must be a nonblank string.');
  }
  final roleKey = source['roleKey'];
  if (roleKey is! String || roleKey.trim().isEmpty) {
    throw _usage('The request source roleKey must be a nonblank string.');
  }

  final context = decoded['context'];
  if (context is! Map) {
    throw _usage('The request context must be an object.');
  }
  for (final key in context.keys) {
    if (key != 'workingDirectory') {
      throw _usage('The request context carries an unknown or invalid field.');
    }
  }
  if (!context.containsKey('workingDirectory')) {
    throw _usage('The request context requires workingDirectory.');
  }
  final workingDirectoryValue = context['workingDirectory'];
  if (workingDirectoryValue is! String ||
      workingDirectoryValue.trim().isEmpty) {
    throw _usage(
      'The request context workingDirectory must be a nonblank string.',
    );
  }

  // Request-level relative paths resolve against the explicit CLI working
  // directory, or the captured process directory when --cwd is absent. The
  // request document's own location never supplies an implicit base.
  final workingDirectory = p.normalize(
    p.isAbsolute(workingDirectoryValue)
        ? workingDirectoryValue
        : p.join(requestBase, workingDirectoryValue),
  );
  final workingDirectoryType = _observeType(
    workingDirectory,
    followLinks: true,
  );
  if (workingDirectoryType == FileSystemEntityType.notFound) {
    throw _usage(
      'The request working directory does not exist: $workingDirectory',
    );
  }
  if (workingDirectoryType != FileSystemEntityType.directory) {
    throw _usage(
      'The request working directory is not a directory: $workingDirectory',
    );
  }
  if (cliCwd != null && !p.equals(cliCwd, workingDirectory)) {
    throw _usage(
      'The request workingDirectory conflicts with the --cwd context.',
    );
  }

  return _BoundRoleRequest(
    requestPath: requestPath,
    configFile: configFile,
    roleKey: roleKey,
    workingDirectory: cliCwd ?? workingDirectory,
  );
}

final class _JsonFrame {
  _JsonFrame({required this.isObject});

  final bool isObject;
  final Set<String> keys = <String>{};
  bool expectingKey = true;
}

/// Lexically scans a request document for duplicate object keys and over-depth
/// nesting. Duplicate keys are status-1 request failures and depth exhaustion
/// is status 3. This does not validate JSON grammar; [jsonDecode] performs full
/// validation afterwards on a bounded-depth input.
void _scanJsonRequest(String text) {
  var index = 0;
  final frames = <_JsonFrame>[];

  while (true) {
    while (index < text.length && _isJsonWhitespace(text.codeUnitAt(index))) {
      index++;
    }
    if (index >= text.length) {
      return;
    }
    final char = text[index];
    switch (char) {
      case '{':
        frames.add(_JsonFrame(isObject: true));
        if (frames.length > _maxRequestDepth) {
          throw _incomplete(
            'The request document exceeds the depth-$_maxRequestDepth budget.',
          );
        }
        index++;
      case '[':
        frames.add(_JsonFrame(isObject: false));
        if (frames.length > _maxRequestDepth) {
          throw _incomplete(
            'The request document exceeds the depth-$_maxRequestDepth budget.',
          );
        }
        index++;
      case '}' || ']':
        if (frames.isNotEmpty) {
          frames.removeLast();
        }
        index++;
      case ',':
        if (frames.isNotEmpty && frames.last.isObject) {
          frames.last.expectingKey = true;
        }
        index++;
      case ':':
        if (frames.isNotEmpty && frames.last.isObject) {
          frames.last.expectingKey = false;
        }
        index++;
      case '"':
        final decoded = _scanJsonString(text, index);
        index = decoded.end;
        if (frames.isNotEmpty &&
            frames.last.isObject &&
            frames.last.expectingKey &&
            !frames.last.keys.add(decoded.value)) {
          throw _usage('The request document contains a duplicate object key.');
        }
      default:
        while (index < text.length &&
            !_isJsonWhitespace(text.codeUnitAt(index)) &&
            !',}]:'.contains(text[index])) {
          index++;
        }
    }
  }
}

bool _isJsonWhitespace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

/// Reads the JSON string starting at the opening quote and returns its decoded
/// content and the index just past the closing quote. Malformed escapes decode
/// leniently; [jsonDecode] rejects them later.
({String value, int end}) _scanJsonString(String text, int start) {
  final buffer = StringBuffer();
  var index = start + 1;
  while (index < text.length) {
    final unit = text.codeUnitAt(index);
    if (unit == 0x22) {
      return (value: buffer.toString(), end: index + 1);
    }
    if (unit != 0x5C) {
      buffer.writeCharCode(unit);
      index++;
      continue;
    }
    index++;
    if (index >= text.length) {
      break;
    }
    final escape = text[index];
    switch (escape) {
      case '"':
        buffer.write('"');
        index++;
      case '\\':
        buffer.write('\\');
        index++;
      case '/':
        buffer.write('/');
        index++;
      case 'b':
        buffer.write('\b');
        index++;
      case 'f':
        buffer.write('\f');
        index++;
      case 'n':
        buffer.write('\n');
        index++;
      case 'r':
        buffer.write('\r');
        index++;
      case 't':
        buffer.write('\t');
        index++;
      case 'u':
        final hexEnd = index + 5 <= text.length ? index + 5 : text.length;
        final value = int.tryParse(
          text.substring(index + 1, hexEnd),
          radix: 16,
        );
        if (value == null || hexEnd != index + 5) {
          buffer.write(escape);
          index++;
          continue;
        }
        // Combine surrogate pairs when present.
        if (value >= 0xD800 &&
            value <= 0xDBFF &&
            text.startsWith('\\u', index + 5) &&
            index + 11 <= text.length) {
          final low = int.tryParse(
            text.substring(index + 7, index + 11),
            radix: 16,
          );
          if (low != null && low >= 0xDC00 && low <= 0xDFFF) {
            buffer.writeCharCode(
              0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00),
            );
            index += 11;
            continue;
          }
        }
        buffer.writeCharCode(value);
        index += 5;
      default:
        buffer.write(escape);
        index++;
    }
  }
  return (value: buffer.toString(), end: index);
}

// ---------------------------------------------------------------------------
// Claude native fields
// ---------------------------------------------------------------------------

const _claudeKnownFields = <String>{
  'name',
  'description',
  'tools',
  'disallowedTools',
  'model',
  'permissionMode',
  'maxTurns',
  'autoCompactWindow',
  'skills',
  'mcpServers',
  'hooks',
  'memory',
  'background',
  'omitClaudeMd',
  'effort',
  'isolation',
  'color',
  'initialPrompt',
  'experimental',
};

void _validateClaudeFields(
  Map<Object?, Object?> fields,
  _ReportBuilder builder,
) {
  // name: required string, 1-256 Unicode scalar values, no colon, no
  // leading hyphen. Skill naming rules are not borrowed.
  if (!fields.containsKey('name')) {
    builder.error(
      'NAME_REQUIRED',
      AgentDiagnosticCategory.specification,
      'name',
      'Frontmatter requires a name string.',
    );
  } else {
    final name = fields['name'];
    if (name is! String) {
      builder.error(
        'NAME_TYPE',
        AgentDiagnosticCategory.specification,
        'name',
        'name must be a string.',
      );
    } else {
      builder.identityName['declared'] = name;
      builder.identityName['resolved'] = name;
      builder.identityName['provenance'] = 'declared';
      final length = name.runes.length;
      if (length < 1 || length > 256) {
        builder.error(
          'NAME_LENGTH',
          AgentDiagnosticCategory.specification,
          'name',
          'name must contain 1-256 Unicode scalar values.',
        );
      }
      if (name.contains(':')) {
        builder.error(
          'NAME_COLON',
          AgentDiagnosticCategory.specification,
          'name',
          'name must not contain a colon.',
        );
      }
      if (name.startsWith('-')) {
        builder.error(
          'NAME_HYPHEN',
          AgentDiagnosticCategory.specification,
          'name',
          'name must not start with a hyphen.',
        );
      }
    }
  }

  // description: required string; empty remains permitted.
  if (!fields.containsKey('description')) {
    builder.error(
      'DESCRIPTION_REQUIRED',
      AgentDiagnosticCategory.specification,
      'description',
      'Frontmatter requires a description string.',
    );
  } else {
    final description = fields['description'];
    if (description is! String) {
      builder.error(
        'DESCRIPTION_TYPE',
        AgentDiagnosticCategory.specification,
        'description',
        'description must be a string.',
      );
    } else {
      builder.identityDescription['declared'] = description;
      builder.identityDescription['resolved'] = description;
      builder.identityDescription['provenance'] = 'declared';
    }
  }

  _claudeToolField(fields, builder, 'tools', 'tool-allowlist');
  _claudeToolField(fields, builder, 'disallowedTools', 'tool-denylist');

  if (fields.containsKey('model')) {
    final model = fields['model'];
    if (model is! String) {
      builder.error(
        'MODEL_TYPE',
        AgentDiagnosticCategory.specification,
        'model',
        'model must be a string.',
      );
    } else {
      builder.references.add(
        _reference(
          'model',
          model,
          'explicit',
          'Declared model selection; availability and resolution are '
              'runtime-dependent.',
        ),
      );
    }
  } else {
    builder.parentRequirements.add(
      _parentRequirement(
        'model-resolution',
        'runtime-dependent',
        'Omitting model defers resolution to invocation, environment, and '
            'parent configuration.',
      ),
    );
  }

  if (fields.containsKey('permissionMode')) {
    const modes = <String>{
      'default',
      'acceptEdits',
      'auto',
      'dontAsk',
      'bypassPermissions',
      'plan',
      'manual',
    };
    final mode = fields['permissionMode'];
    if (mode is! String) {
      builder.error(
        'PERMISSION_MODE_TYPE',
        AgentDiagnosticCategory.specification,
        'permissionMode',
        'permissionMode must be a string.',
      );
    } else if (!modes.contains(mode)) {
      builder.error(
        'PERMISSION_MODE_VALUE',
        AgentDiagnosticCategory.specification,
        'permissionMode',
        'permissionMode must be a documented mode; manual aliases default.',
      );
    } else {
      builder.capabilities.add(
        _capability(
          'permission-mode',
          mode,
          'explicit',
          'Declared mode is conditional on parent permission authority.',
        ),
      );
    }
  }

  if (fields.containsKey('maxTurns')) {
    final maxTurns = fields['maxTurns'];
    if (maxTurns is! int) {
      builder.error(
        'MAX_TURNS_TYPE',
        AgentDiagnosticCategory.specification,
        'maxTurns',
        'maxTurns must be an integer.',
      );
    } else if (maxTurns < 1) {
      builder.error(
        'MAX_TURNS_VALUE',
        AgentDiagnosticCategory.specification,
        'maxTurns',
        'maxTurns must be a positive integer.',
      );
    } else {
      builder.capabilities.add(
        _capability('turn-limit', '$maxTurns', 'explicit'),
      );
    }
  }

  if (fields.containsKey('autoCompactWindow')) {
    final window = fields['autoCompactWindow'];
    if (window is! int) {
      builder.error(
        'AUTO_COMPACT_WINDOW_TYPE',
        AgentDiagnosticCategory.specification,
        'autoCompactWindow',
        'autoCompactWindow must be an integer.',
      );
    } else if (window < 100000 || window > 1000000) {
      builder.error(
        'AUTO_COMPACT_WINDOW_RANGE',
        AgentDiagnosticCategory.specification,
        'autoCompactWindow',
        'autoCompactWindow must be between 100000 and 1000000.',
      );
    } else {
      builder.capabilities.add(
        _capability('auto-compact-window', '$window', 'explicit'),
      );
    }
  }

  if (fields.containsKey('skills')) {
    final skills = fields['skills'];
    if (skills is! List) {
      builder.error(
        'SKILLS_TYPE',
        AgentDiagnosticCategory.specification,
        'skills',
        'skills must be a list of skill names.',
      );
    } else {
      final names = <String>{};
      var typed = true;
      for (final entry in skills) {
        if (entry is String) {
          names.add(entry);
        } else {
          typed = false;
        }
      }
      if (!typed) {
        builder.error(
          'SKILLS_ENTRY_TYPE',
          AgentDiagnosticCategory.specification,
          'skills',
          'skills entries must be strings.',
        );
      }
      if (names.length > 32) {
        builder.error(
          'SKILLS_COUNT',
          AgentDiagnosticCategory.specification,
          'skills',
          'skills preloads at most 32 distinct names.',
        );
      }
      for (final name in names) {
        builder.references.add(
          _reference(
            'skill',
            name,
            'explicit',
            'Skill preload declaration; existence and enablement are '
                'unresolved.',
          ),
        );
      }
    }
  }

  if (fields.containsKey('mcpServers')) {
    final servers = fields['mcpServers'];
    if (servers is! List) {
      builder.error(
        'MCP_SERVERS_TYPE',
        AgentDiagnosticCategory.specification,
        'mcpServers',
        'mcpServers must be a list of server names or inline maps.',
      );
    } else {
      var inline = false;
      for (final entry in servers) {
        if (entry is String) {
          builder.references.add(
            _reference(
              'mcp-server',
              entry,
              'explicit',
              'Reference to a configured server; not an exclusive allowlist '
                  'or a new grant.',
            ),
          );
        } else if (entry is Map) {
          inline = true;
          final keys = entry.keys.whereType<String>().toList();
          final name = keys.length == 1 ? keys.single : '(inline)';
          final inlineValue = keys.length == 1 ? entry[keys.single] : null;
          final inlineType = inlineValue is Map && inlineValue['type'] is String
              ? inlineValue['type']! as String
              : null;
          builder.references.add(
            _reference(
              'mcp-server',
              name,
              'explicit',
              'Inline server${inlineType == null ? '' : ' ($inlineType)'}; '
                  'configuration is withheld and never connected.',
            ),
          );
        } else {
          builder.error(
            'MCP_SERVERS_ENTRY_TYPE',
            AgentDiagnosticCategory.specification,
            'mcpServers',
            'mcpServers entries must be strings or maps.',
          );
        }
      }
      if (inline) {
        builder.parentRequirements.add(
          _parentRequirement(
            'mcp-trust',
            'runtime-dependent',
            'Inline MCP servers require runtime trust for the defining '
                'folder; they are never connected during inspection.',
          ),
        );
      }
    }
  }

  if (fields.containsKey('hooks')) {
    final hooks = fields['hooks'];
    if (hooks is! Map) {
      builder.error(
        'HOOKS_TYPE',
        AgentDiagnosticCategory.specification,
        'hooks',
        'hooks must be a map.',
      );
    } else {
      for (final key in hooks.keys) {
        if (key is String) {
          builder.references.add(
            _reference(
              'hook',
              key,
              'explicit',
              'Lifecycle hook declaration; configuration is withheld and '
                  'never executed.',
            ),
          );
        }
      }
      builder.parentRequirements.add(
        _parentRequirement(
          'hook-trust',
          'runtime-dependent',
          'Frontmatter hooks require runtime trust for the defining folder; '
              'they are never executed during inspection.',
        ),
      );
    }
  }

  if (fields.containsKey('memory')) {
    const scopes = <String>{'user', 'project', 'local'};
    final memory = fields['memory'];
    if (memory is! String) {
      builder.error(
        'MEMORY_TYPE',
        AgentDiagnosticCategory.specification,
        'memory',
        'memory must be a string.',
      );
    } else if (!scopes.contains(memory)) {
      builder.error(
        'MEMORY_VALUE',
        AgentDiagnosticCategory.specification,
        'memory',
        'memory must be user, project, or local.',
      );
    } else {
      builder.capabilities.add(
        _capability(
          'memory',
          memory,
          'explicit',
          'Persistent memory scope; conditional on auto memory being '
              'enabled.',
        ),
      );
    }
  }

  for (final flag in <String>['background', 'omitClaudeMd']) {
    if (fields.containsKey(flag) && fields[flag] is! bool) {
      builder.error(
        '${flag == 'background' ? 'BACKGROUND' : 'OMIT_CLAUDE_MD'}_TYPE',
        AgentDiagnosticCategory.specification,
        flag,
        '$flag must be a boolean.',
      );
    } else if (fields[flag] == true) {
      builder.capabilities.add(_capability('flag', flag, 'explicit'));
    }
  }

  if (fields.containsKey('effort')) {
    const efforts = <String>{'low', 'medium', 'high', 'xhigh', 'max'};
    final effort = fields['effort'];
    if (effort is! String) {
      builder.error(
        'EFFORT_TYPE',
        AgentDiagnosticCategory.specification,
        'effort',
        'effort must be a string.',
      );
    } else if (!efforts.contains(effort)) {
      builder.error(
        'EFFORT_VALUE',
        AgentDiagnosticCategory.specification,
        'effort',
        'effort must be low, medium, high, xhigh, or max.',
      );
    }
  }

  if (fields.containsKey('isolation')) {
    final isolation = fields['isolation'];
    if (isolation is! String) {
      builder.error(
        'ISOLATION_TYPE',
        AgentDiagnosticCategory.specification,
        'isolation',
        'isolation must be a string.',
      );
    } else if (isolation != 'worktree') {
      builder.error(
        'ISOLATION_VALUE',
        AgentDiagnosticCategory.specification,
        'isolation',
        'isolation must be worktree.',
      );
    } else {
      builder.capabilities.add(
        _capability(
          'isolation',
          'worktree',
          'explicit',
          'Temporary git worktree isolation, not a sandbox policy.',
        ),
      );
    }
  }

  if (fields.containsKey('color')) {
    const colors = <String>{
      'red',
      'blue',
      'green',
      'yellow',
      'purple',
      'orange',
      'pink',
      'cyan',
    };
    final color = fields['color'];
    if (color is! String) {
      builder.error(
        'COLOR_TYPE',
        AgentDiagnosticCategory.specification,
        'color',
        'color must be a string.',
      );
    } else if (!colors.contains(color)) {
      builder.error(
        'COLOR_VALUE',
        AgentDiagnosticCategory.specification,
        'color',
        'color must be a documented color value.',
      );
    }
  }

  if (fields.containsKey('initialPrompt')) {
    final prompt = fields['initialPrompt'];
    if (prompt is! String) {
      builder.error(
        'INITIAL_PROMPT_TYPE',
        AgentDiagnosticCategory.specification,
        'initialPrompt',
        'initialPrompt must be a string.',
      );
    } else {
      builder.capabilities.add(
        _capability(
          'initial-prompt',
          'initialPrompt',
          'explicit',
          'Declared; the prompt text is withheld.',
        ),
      );
    }
  }

  if (fields.containsKey('experimental')) {
    final experimental = fields['experimental'];
    if (experimental is! Map) {
      builder.error(
        'EXPERIMENTAL_TYPE',
        AgentDiagnosticCategory.specification,
        'experimental',
        'experimental must be a map.',
      );
    } else {
      if (experimental.containsKey('cacheTtl')) {
        final cacheTtl = experimental['cacheTtl'];
        if (cacheTtl != '5m' && cacheTtl != '1h') {
          builder.error(
            'EXPERIMENTAL_CACHE_TTL',
            AgentDiagnosticCategory.specification,
            'experimental.cacheTtl',
            'cacheTtl must be 5m or 1h.',
          );
        }
      }
      for (final key in experimental.keys) {
        if (key is String && key != 'cacheTtl') {
          builder.warn(
            'EXPERIMENTAL_UNKNOWN_FIELD',
            AgentDiagnosticCategory.advisory,
            'experimental.$key',
            'Unknown experimental field of type '
                '${_typeName(experimental[key])}; the value is not reported.',
          );
        }
      }
    }
  }

  final unknown = <String>[
    for (final key in fields.keys)
      if (key is String && !_claudeKnownFields.contains(key)) key,
  ]..sort();
  for (final key in unknown) {
    builder.warn(
      'UNKNOWN_FIELD',
      AgentDiagnosticCategory.advisory,
      key,
      'Unknown top-level field of type ${_typeName(fields[key])}; the value '
          'is not reported.',
    );
  }

  builder.parentRequirements.add(
    _parentRequirement(
      'permission-authority',
      'inherited',
      'The subagent inherits parent permission rules; permissionMode is '
          'conditional on parent modes and cannot independently escalate.',
    ),
  );
  builder.parentRequirements.add(
    _parentRequirement(
      'instruction-context',
      'inherited',
      'The applicable CLAUDE.md hierarchy loads unless omitClaudeMd is set; '
          'it is context, not part of this definition.',
    ),
  );
  if (!fields.containsKey('tools')) {
    builder.parentRequirements.add(
      _parentRequirement(
        'tool-pool',
        'inherited',
        'Omitting tools inherits the available-to-subagents pool; declared '
            'lists are not proof of usable tools.',
      ),
    );
  }
}

void _claudeToolField(
  Map<Object?, Object?> fields,
  _ReportBuilder builder,
  String key,
  String kind,
) {
  if (!fields.containsKey(key)) {
    return;
  }
  final value = fields[key];
  final entries = <String>[];
  if (value is String) {
    entries.addAll(
      value.split(',').map((part) => part.trim()).where((e) => e.isNotEmpty),
    );
  } else if (value is List) {
    var typed = true;
    for (final entry in value) {
      if (entry is String) {
        entries.add(entry);
      } else {
        typed = false;
      }
    }
    if (!typed) {
      builder.error(
        '${key == 'tools' ? 'TOOLS' : 'DISALLOWED_TOOLS'}_ENTRY_TYPE',
        AgentDiagnosticCategory.specification,
        key,
        '$key list entries must be strings.',
      );
      return;
    }
  } else {
    builder.error(
      '${key == 'tools' ? 'TOOLS' : 'DISALLOWED_TOOLS'}_TYPE',
      AgentDiagnosticCategory.specification,
      key,
      '$key must be a comma-separated string or a list of strings.',
    );
    return;
  }
  for (final entry in entries) {
    builder.capabilities.add(
      _capability(
        kind,
        entry,
        'explicit',
        'Declared tool pattern; availability is not certified.',
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Codex native fields (standalone; bound-role leniency arrives with the
// request increment)
// ---------------------------------------------------------------------------

const _codexKnownFields = <String>{
  'name',
  'description',
  'developer_instructions',
  'model',
  'model_reasoning_effort',
  'model_reasoning_summary',
  'model_verbosity',
  'nickname_candidates',
  'features',
  'skills',
  'sandbox_mode',
  'approval_policy',
  'model_provider',
  'mcp_servers',
  'personality',
  'service_tier',
};

const _codexFeatureKeys = <String>{
  'shell_tool',
  'apps',
  'plugins',
  'memories',
  'request_permissions_tool',
};

const _codexParentAuthorityFields = <String>{
  'sandbox_mode',
  'approval_policy',
  'model_provider',
  'mcp_servers',
};

void _validateCodexFields(
  Map<String, Object?> fields,
  _ReportBuilder builder, {
  required bool bound,
}) {
  // name: standalone requires a nonblank string; the declared name is
  // preserved and the trimmed resolved identity reported separately.
  if (fields.containsKey('name')) {
    final name = fields['name'];
    if (name is! String) {
      builder.error(
        'NAME_TYPE',
        AgentDiagnosticCategory.specification,
        'name',
        'name must be a string.',
      );
    } else {
      builder.identityName['declared'] = name;
      final trimmed = name.trim();
      if (trimmed.isEmpty) {
        builder.error(
          'NAME_BLANK',
          AgentDiagnosticCategory.specification,
          'name',
          'name must not be blank.',
        );
      } else {
        builder.identityName['resolved'] = trimmed;
        builder.identityName['provenance'] = bound
            ? (trimmed == name ? 'file-declared' : 'file-declared-trimmed')
            : (trimmed == name ? 'declared' : 'declared-trimmed');
      }
    }
  } else if (!bound) {
    builder.error(
      'NAME_REQUIRED',
      AgentDiagnosticCategory.specification,
      'name',
      'A standalone Codex definition requires a name string.',
    );
  }

  if (fields.containsKey('description')) {
    final description = fields['description'];
    if (description is! String) {
      builder.error(
        'DESCRIPTION_TYPE',
        AgentDiagnosticCategory.specification,
        'description',
        'description must be a string.',
      );
    } else if (description.trim().isEmpty) {
      builder.error(
        'DESCRIPTION_BLANK',
        AgentDiagnosticCategory.specification,
        'description',
        'description must not be blank.',
      );
    } else {
      builder.identityDescription['declared'] = description;
      builder.identityDescription['resolved'] = description;
      builder.identityDescription['provenance'] = bound ? 'file' : 'declared';
    }
  } else if (!bound) {
    builder.error(
      'DESCRIPTION_REQUIRED',
      AgentDiagnosticCategory.specification,
      'description',
      'A standalone Codex definition requires a description string.',
    );
  }

  if (fields.containsKey('developer_instructions')) {
    final instructions = fields['developer_instructions'];
    if (instructions is! String) {
      builder.error(
        'DEVELOPER_INSTRUCTIONS_TYPE',
        AgentDiagnosticCategory.specification,
        'developer_instructions',
        'developer_instructions must be a string.',
      );
    } else if (instructions.trim().isEmpty) {
      builder.error(
        'DEVELOPER_INSTRUCTIONS_BLANK',
        AgentDiagnosticCategory.specification,
        'developer_instructions',
        'developer_instructions must not be blank.',
      );
    } else {
      builder.instructionsPresent = true;
      builder.instructionsProvenance = 'developer-instructions';
      builder.instructionText = instructions;
    }
  } else if (!bound) {
    builder.error(
      'DEVELOPER_INSTRUCTIONS_REQUIRED',
      AgentDiagnosticCategory.specification,
      'developer_instructions',
      'A standalone Codex definition requires developer_instructions.',
    );
  }

  for (final knob in <String>['model', 'model_reasoning_effort']) {
    if (fields.containsKey(knob)) {
      final value = fields[knob];
      if (value is! String) {
        builder.error(
          '${knob == 'model' ? 'MODEL' : 'MODEL_REASONING_EFFORT'}_TYPE',
          AgentDiagnosticCategory.specification,
          knob,
          '$knob must be a string.',
        );
      } else if (knob == 'model') {
        builder.references.add(
          _reference(
            'model',
            value,
            'explicit',
            'Declared model; availability depends on client, account, and '
                'provider.',
          ),
        );
      }
    }
  }

  if (fields.containsKey('model_reasoning_summary')) {
    const summaries = <String>{'auto', 'concise', 'detailed', 'none'};
    final value = fields['model_reasoning_summary'];
    if (value is! String) {
      builder.error(
        'MODEL_REASONING_SUMMARY_TYPE',
        AgentDiagnosticCategory.specification,
        'model_reasoning_summary',
        'model_reasoning_summary must be a string.',
      );
    } else if (!summaries.contains(value)) {
      builder.error(
        'MODEL_REASONING_SUMMARY_VALUE',
        AgentDiagnosticCategory.specification,
        'model_reasoning_summary',
        'model_reasoning_summary must be auto, concise, detailed, or none.',
      );
    }
  }

  if (fields.containsKey('model_verbosity')) {
    const verbosities = <String>{'low', 'medium', 'high'};
    final value = fields['model_verbosity'];
    if (value is! String) {
      builder.error(
        'MODEL_VERBOSITY_TYPE',
        AgentDiagnosticCategory.specification,
        'model_verbosity',
        'model_verbosity must be a string.',
      );
    } else if (!verbosities.contains(value)) {
      builder.error(
        'MODEL_VERBOSITY_VALUE',
        AgentDiagnosticCategory.specification,
        'model_verbosity',
        'model_verbosity must be low, medium, or high.',
      );
    }
  }

  if (fields.containsKey('nickname_candidates')) {
    _validateNicknameCandidates(
      fields['nickname_candidates'],
      builder,
      'nickname_candidates',
    );
  }

  if (fields.containsKey('features')) {
    _validateCodexFeatures(fields['features'], builder);
  }

  if (fields.containsKey('skills')) {
    _validateCodexSkills(fields['skills'], builder);
  }

  for (final key in _codexParentAuthorityFields) {
    if (fields.containsKey(key)) {
      builder.error(
        'PARENT_AUTHORITY_FIELD',
        AgentDiagnosticCategory.product,
        key,
        'Declaring $key in an agent file is a blocking known-ineffective '
            'declaration; the parent remains authoritative.',
      );
      builder.capabilities.add(
        _capability(
          'parent-authority-declaration',
          key,
          'explicit',
          'Declared but ineffective; parent authority is unchanged.',
        ),
      );
    }
  }

  for (final key in <String>['personality', 'service_tier']) {
    if (fields.containsKey(key)) {
      builder.warn(
        'SOURCE_ONLY_FIELD',
        AgentDiagnosticCategory.advisory,
        key,
        'Observed in pinned source only (commit $_codexSourceCommit); not a '
            'portable released-schema guarantee.',
      );
    }
  }

  final unknown = <String>[
    for (final key in fields.keys)
      if (!_codexKnownFields.contains(key)) key,
  ]..sort();
  for (final key in unknown) {
    builder.warn(
      'UNKNOWN_FIELD',
      AgentDiagnosticCategory.advisory,
      key,
      'Unknown top-level field of type ${_typeName(fields[key])}; the value '
          'is not reported.',
    );
  }

  builder.parentRequirements.addAll(<Map<String, Object?>>[
    _parentRequirement(
      'permissions-sandbox-approval',
      'inherited',
      'Agent definitions cannot override parent sandbox, approval, or '
          'permission authority; such declarations are ineffective.',
    ),
    _parentRequirement(
      'model-provider',
      'inherited',
      'The model provider is inherited from the parent configuration.',
    ),
    _parentRequirement(
      'mcp-servers',
      'inherited',
      'MCP servers are inherited from the parent configuration; per-agent '
          'grants are not supported.',
    ),
    _parentRequirement(
      'base-instructions',
      'inherited',
      'Role developer instructions do not replace base instructions or '
          'project guidance.',
    ),
    _parentRequirement(
      'discovery-trust',
      'runtime-dependent',
      'Runtime discovery depends on config layers, trust, and enabled state '
          'beyond this file.',
    ),
  ]);
}

void _validateNicknameCandidates(
  Object? value,
  _ReportBuilder builder,
  String field,
) {
  const note = ' (pinned-source evidence only, commit $_codexSourceCommit)';
  if (value is! List) {
    builder.error(
      'NICKNAME_CANDIDATES_TYPE',
      AgentDiagnosticCategory.specification,
      field,
      'nickname_candidates must be a list$note.',
    );
    return;
  }
  if (value.isEmpty) {
    builder.error(
      'NICKNAME_CANDIDATES_EMPTY',
      AgentDiagnosticCategory.specification,
      field,
      'nickname_candidates must not be empty$note.',
    );
    return;
  }
  final seen = <String>{};
  for (final entry in value) {
    if (entry is! String) {
      builder.error(
        'NICKNAME_ENTRY_TYPE',
        AgentDiagnosticCategory.specification,
        field,
        'nickname_candidates entries must be strings$note.',
      );
      continue;
    }
    final trimmed = entry.trim();
    if (trimmed.isEmpty) {
      builder.error(
        'NICKNAME_ENTRY_BLANK',
        AgentDiagnosticCategory.specification,
        field,
        'nickname_candidates entries must not be blank$note.',
      );
      continue;
    }
    if (!RegExp(r'^[A-Za-z0-9 _-]+$').hasMatch(trimmed)) {
      builder.error(
        'NICKNAME_ENTRY_CHARACTERS',
        AgentDiagnosticCategory.specification,
        field,
        'nickname_candidates entries use ASCII letters, digits, spaces, '
            'hyphens, and underscores$note.',
      );
    }
    if (!seen.add(trimmed)) {
      builder.error(
        'NICKNAME_ENTRY_DUPLICATE',
        AgentDiagnosticCategory.specification,
        field,
        'nickname_candidates entries must be unique$note.',
      );
    }
  }
}

void _validateCodexFeatures(Object? value, _ReportBuilder builder) {
  if (value is! Map) {
    builder.error(
      'FEATURES_TYPE',
      AgentDiagnosticCategory.specification,
      'features',
      'features must be a table.',
    );
    return;
  }
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      continue;
    }
    if (!_codexFeatureKeys.contains(key)) {
      builder.warn(
        'FEATURE_UNKNOWN',
        AgentDiagnosticCategory.advisory,
        'features.$key',
        'Undocumented features key observed; no capability change is '
            'inferred.',
      );
      continue;
    }
    final enabled = entry.value;
    if (enabled is! bool) {
      builder.error(
        'FEATURE_VALUE_TYPE',
        AgentDiagnosticCategory.product,
        'features.$key',
        'Supported feature reductions accept only the boolean false.',
      );
    } else if (enabled) {
      builder.error(
        'FEATURE_GRANT',
        AgentDiagnosticCategory.product,
        'features.$key',
        'Setting a supported feature to true is a blocking non-grant; '
            'features support reductions only.',
      );
    } else {
      builder.capabilities.add(
        _capability(
          'feature-reduction',
          key,
          'explicit',
          'Documented false-only reduction; not proof of runtime behavior.',
        ),
      );
    }
  }
}

void _validateCodexSkills(Object? value, _ReportBuilder builder) {
  if (value is! Map) {
    builder.error(
      'SKILLS_TYPE',
      AgentDiagnosticCategory.specification,
      'skills',
      'skills must be a table.',
    );
    return;
  }

  if (value.containsKey('config')) {
    final config = value['config'];
    if (config is! List) {
      builder.error(
        'SKILL_CONFIG_TYPE',
        AgentDiagnosticCategory.specification,
        'skills.config',
        'skills.config must be a list of tables.',
      );
    } else {
      for (final entry in config) {
        if (entry is! Map) {
          builder.error(
            'SKILL_CONFIG_ENTRY_TYPE',
            AgentDiagnosticCategory.specification,
            'skills.config',
            'skills.config entries must be tables.',
          );
          continue;
        }
        final path = entry['path'];
        final enabled = entry['enabled'];
        var valid = true;
        if (path is! String || path.trim().isEmpty) {
          builder.error(
            'SKILL_CONFIG_PATH',
            AgentDiagnosticCategory.specification,
            'skills.config',
            'skills.config entries require a nonblank string path.',
          );
          valid = false;
        }
        if (enabled != false) {
          builder.error(
            'SKILL_CONFIG_ENABLED',
            AgentDiagnosticCategory.product,
            'skills.config',
            'skills.config entries support only enabled = false; true is a '
                'blocking non-grant.',
          );
          valid = false;
        }
        for (final key in entry.keys) {
          if (key is String && key != 'path' && key != 'enabled') {
            builder.warn(
              'SKILL_CONFIG_UNKNOWN',
              AgentDiagnosticCategory.advisory,
              'skills.config.$key',
              'Unknown skill config key observed; the value is not reported.',
            );
          }
        }
        if (valid) {
          final skillPath = path! as String;
          builder.capabilities.add(
            _capability(
              'skill-disable',
              skillPath,
              'explicit',
              'Disabled skill declaration; the referenced path is not '
                  'inspected.',
            ),
          );
          builder.references.add(
            _reference(
              'skill',
              skillPath,
              'explicit',
              'Referenced by a disabled skill entry; existence is '
                  'unresolved.',
            ),
          );
        }
      }
    }
  }

  if (value.containsKey('bundled')) {
    final bundled = value['bundled'];
    if (bundled is! Map) {
      builder.error(
        'SKILLS_BUNDLED_TYPE',
        AgentDiagnosticCategory.specification,
        'skills.bundled',
        'skills.bundled must be a table.',
      );
    } else {
      if (bundled['enabled'] == false) {
        builder.capabilities.add(
          _capability(
            'bundled-skills-disable',
            'skills.bundled',
            'explicit',
            'Documented false-only reduction; not proof of runtime '
                'behavior.',
          ),
        );
      } else {
        builder.error(
          'SKILLS_BUNDLED_ENABLED',
          AgentDiagnosticCategory.product,
          'skills.bundled',
          'skills.bundled supports only enabled = false.',
        );
      }
      for (final key in bundled.keys) {
        if (key is String && key != 'enabled') {
          builder.warn(
            'SKILLS_BUNDLED_UNKNOWN',
            AgentDiagnosticCategory.advisory,
            'skills.bundled.$key',
            'Unknown bundled skills key observed; the value is not reported.',
          );
        }
      }
    }
  }

  if (value.containsKey('include_instructions')) {
    if (value['include_instructions'] == false) {
      builder.capabilities.add(
        _capability(
          'skill-instructions-omit',
          'skills.include_instructions',
          'explicit',
          'Omits the automatic skill instruction block; not a sandbox '
              'rule.',
        ),
      );
    } else {
      builder.error(
        'SKILLS_INCLUDE_INSTRUCTIONS',
        AgentDiagnosticCategory.product,
        'skills.include_instructions',
        'skills.include_instructions supports only false; true is a '
            'blocking non-grant.',
      );
    }
  }

  for (final key in value.keys) {
    if (key is String &&
        key != 'config' &&
        key != 'bundled' &&
        key != 'include_instructions') {
      builder.warn(
        'SKILLS_UNKNOWN',
        AgentDiagnosticCategory.advisory,
        'skills.$key',
        'Unknown skills key observed; the value is not reported.',
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Common Pi fields
// ---------------------------------------------------------------------------

const _piKnownFields = <String>{
  'name',
  'description',
  'model',
  'tools',
  'thinking',
};

/// Fields observed in one provider only; they never enter a union schema.
const _piProviderOnlyFields = <String>{
  'skills',
  'extensions',
  'memory',
  'excludeTools',
  'systemPromptMode',
  'inheritProjectContext',
  'inheritSkills',
  'async',
  'disallowed_tools',
  'prompt_mode',
  'inherit_context',
  'run_in_background',
};

const _piToolCatalog = <String>{'read', 'grep', 'find', 'ls'};

const _piThinkingLevels = <String>{
  'off',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
};

void _validatePiFields(Map<Object?, Object?> fields, _ReportBuilder builder) {
  if (!fields.containsKey('name')) {
    builder.error(
      'NAME_REQUIRED',
      AgentDiagnosticCategory.specification,
      'name',
      'The common Pi profile requires a name string.',
    );
  } else {
    final name = fields['name'];
    if (name is! String) {
      builder.error(
        'NAME_TYPE',
        AgentDiagnosticCategory.specification,
        'name',
        'name must be a string.',
      );
    } else {
      builder.identityName['declared'] = name;
      builder.identityName['resolved'] = name;
      builder.identityName['provenance'] = 'declared';
      if (name.trim().isEmpty) {
        builder.error(
          'NAME_BLANK',
          AgentDiagnosticCategory.specification,
          'name',
          'name must not be blank.',
        );
      }
      if (name.contains(':')) {
        builder.error(
          'NAME_COLON',
          AgentDiagnosticCategory.specification,
          'name',
          'name must not contain a colon.',
        );
      }
      if (name != name.trim()) {
        builder.error(
          'NAME_WHITESPACE',
          AgentDiagnosticCategory.specification,
          'name',
          'name must not have leading or trailing whitespace.',
        );
      }
    }
  }

  if (!fields.containsKey('description')) {
    builder.error(
      'DESCRIPTION_REQUIRED',
      AgentDiagnosticCategory.specification,
      'description',
      'The common Pi profile requires a description string.',
    );
  } else {
    final description = fields['description'];
    if (description is! String) {
      builder.error(
        'DESCRIPTION_TYPE',
        AgentDiagnosticCategory.specification,
        'description',
        'description must be a string.',
      );
    } else if (description.trim().isEmpty) {
      builder.error(
        'DESCRIPTION_BLANK',
        AgentDiagnosticCategory.specification,
        'description',
        'description must not be blank.',
      );
    } else {
      builder.identityDescription['declared'] = description;
      builder.identityDescription['resolved'] = description;
      builder.identityDescription['provenance'] = 'declared';
    }
  }

  if (!fields.containsKey('model')) {
    builder.error(
      'MODEL_REQUIRED',
      AgentDiagnosticCategory.specification,
      'model',
      'The common Pi profile requires an explicit provider/model-id.',
    );
  } else {
    final model = fields['model'];
    if (model is! String) {
      builder.error(
        'MODEL_TYPE',
        AgentDiagnosticCategory.specification,
        'model',
        'model must be a string.',
      );
    } else {
      _validatePiModel(model, builder);
    }
  }

  if (!fields.containsKey('tools')) {
    builder.error(
      'TOOLS_REQUIRED',
      AgentDiagnosticCategory.specification,
      'tools',
      'The common Pi profile requires a tools scalar.',
    );
  } else {
    final tools = fields['tools'];
    if (tools is List) {
      builder.error(
        'TOOLS_FORM',
        AgentDiagnosticCategory.product,
        'tools',
        'tools must be a comma-separated scalar, not a flow list.',
      );
    } else if (tools is! String) {
      builder.error(
        'TOOLS_TYPE',
        AgentDiagnosticCategory.specification,
        'tools',
        'tools must be a comma-separated string.',
      );
    } else {
      _validatePiTools(tools, builder);
    }
  }

  if (fields.containsKey('thinking')) {
    final thinking = fields['thinking'];
    if (thinking is! String) {
      builder.error(
        'THINKING_TYPE',
        AgentDiagnosticCategory.specification,
        'thinking',
        'thinking must be a string.',
      );
    } else if (!_piThinkingLevels.contains(thinking)) {
      builder.error(
        'THINKING_VALUE',
        AgentDiagnosticCategory.specification,
        'thinking',
        'thinking must be one of off, minimal, low, medium, high, xhigh, '
            'max.',
      );
    } else {
      builder.capabilities.add(
        _capability(
          'thinking',
          thinking,
          'explicit',
          'Configured level; precedence and shortcuts differ by provider.',
        ),
      );
    }
  }

  final keys = fields.keys.whereType<String>().toList();
  for (final key in keys) {
    if (_piKnownFields.contains(key)) {
      continue;
    }
    if (_piProviderOnlyFields.contains(key)) {
      builder.warn(
        'PROVIDER_ONLY_FIELD',
        AgentDiagnosticCategory.advisory,
        key,
        'Provider-only field observed; it is not part of the common Pi '
            'profile and no union schema is created.',
      );
    } else {
      builder.warn(
        'UNKNOWN_FIELD',
        AgentDiagnosticCategory.advisory,
        key,
        'Unknown top-level field of type ${_typeName(fields[key])}; the '
            'value is not reported.',
      );
    }
  }

  builder.parentRequirements.addAll(<Map<String, Object?>>[
    _parentRequirement(
      'effective-tool-set',
      'runtime-dependent',
      'Declared tools are configured metadata; ambient, extension, and '
          'runtime-injected tools may still be exposed by some providers.',
    ),
    _parentRequirement(
      'model-resolution',
      'runtime-dependent',
      'Model availability, fallback, and override order remain provider '
          'and environment dependent.',
    ),
    _parentRequirement(
      'discovery-trust',
      'unresolved',
      'Discovery roots, recursion, and project trust are provider-specific '
          'and are not established by this file.',
    ),
    _parentRequirement(
      'instruction-context',
      'runtime-dependent',
      'Surrounding system and context assembly differ by provider; body '
          'preservation is not runtime equivalence.',
    ),
  ]);
}

void _validatePiModel(String model, _ReportBuilder builder) {
  var qualified = true;
  if (model.trim().isEmpty) {
    builder.error(
      'MODEL_BLANK',
      AgentDiagnosticCategory.specification,
      'model',
      'model must not be blank.',
    );
    return;
  }
  if (RegExp(r'\s').hasMatch(model)) {
    builder.error(
      'MODEL_WHITESPACE',
      AgentDiagnosticCategory.product,
      'model',
      'model must not contain whitespace.',
    );
    qualified = false;
  }
  if (model == 'inherit') {
    builder.error(
      'MODEL_INHERIT',
      AgentDiagnosticCategory.product,
      'model',
      'model must be an explicit provider/model-id; inherit is not a '
          'portable pin.',
    );
    qualified = false;
  }
  final slash = model.indexOf('/');
  if (slash < 0) {
    builder.error(
      'MODEL_UNQUALIFIED',
      AgentDiagnosticCategory.product,
      'model',
      'model must be qualified as provider/model-id; fuzzy names are not '
          'portable.',
    );
    return;
  }
  if (slash == 0) {
    builder.error(
      'MODEL_PROVIDER_BLANK',
      AgentDiagnosticCategory.product,
      'model',
      'model requires a nonblank provider before the slash.',
    );
    qualified = false;
  }
  final modelId = model.substring(slash + 1);
  if (modelId.isEmpty) {
    builder.error(
      'MODEL_ID_BLANK',
      AgentDiagnosticCategory.product,
      'model',
      'model requires a nonblank model id after the slash.',
    );
    qualified = false;
  }
  if (modelId.contains(':')) {
    builder.error(
      'MODEL_SUFFIX',
      AgentDiagnosticCategory.product,
      'model',
      'model must not carry thinking or other suffix shortcuts.',
    );
    qualified = false;
  }
  if (qualified) {
    builder.references.add(
      _reference(
        'model',
        model,
        'explicit',
        'Qualified provider/model-id; availability and fallback remain '
            'runtime-dependent.',
      ),
    );
  }
}

void _validatePiTools(String tools, _ReportBuilder builder) {
  if (tools.trim().isEmpty) {
    builder.error(
      'TOOLS_EMPTY',
      AgentDiagnosticCategory.product,
      'tools',
      'tools must be a nonempty comma-separated scalar.',
    );
    return;
  }
  final entries = tools.split(',').map((entry) => entry.trim()).toList();
  if (entries.any((entry) => entry.isEmpty)) {
    builder.error(
      'TOOLS_ENTRY_EMPTY',
      AgentDiagnosticCategory.product,
      'tools',
      'tools entries must be nonempty.',
    );
  }
  final seen = <String>{};
  var duplicate = false;
  for (final entry in entries) {
    if (entry.isNotEmpty && !seen.add(entry)) {
      duplicate = true;
    }
  }
  if (duplicate) {
    builder.error(
      'TOOLS_DUPLICATE',
      AgentDiagnosticCategory.product,
      'tools',
      'tools entries must be unique.',
    );
  }
  for (final entry in seen) {
    if (_piToolCatalog.contains(entry)) {
      builder.capabilities.add(
        _capability(
          'tool-selection',
          entry,
          'explicit',
          'Configured metadata; the effective tool set remains provider and '
              'runtime dependent.',
        ),
      );
    } else {
      builder.error(
        'TOOLS_CATALOG',
        AgentDiagnosticCategory.product,
        'tools',
        'Tool entry "$entry" is outside the approved first catalog '
            '{read, grep, find, ls}; wildcards, all, none, mcp:, ext:, and '
            'other names receive product-profile diagnostics.',
      );
    }
  }
}
