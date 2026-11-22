import 'dart:convert';
import 'dart:io' show FileSystemEntityType;

import 'package:file/file.dart' as fs;
import 'package:file/local.dart' as local;

import '../authoring/native_field_matrix.dart';
import '../harness/harness_catalog.dart';
import '../prompt/prompt_contracts.dart';
import '../prompt_resource_path_scanner.dart';
import '../services/lifecycle_state_service.dart';
import '../skill_files.dart';

/// Shared checks and rendering for a Skill that is published as a native
/// Prompt template.
///
/// A Skill is an eligible derived-Prompt source when it carries no extra
/// entries a Prompt cannot carry, references no resource paths, and has no
/// active template arguments or dynamic shell. The same checks guard the
/// Skill to Prompt conversion flow.
final class DerivedPromptEligibility {
  const DerivedPromptEligibility._();

  /// Entries of a Skill directory a Prompt cannot carry.
  static List<String> extraSkillEntries(String directory, {fs.FileSystem? fs}) {
    final fileSystem = fs ?? const local.LocalFileSystem();
    final entries = <String>[];
    final names = listSkillDirectory(
      directory,
      fs: fileSystem,
    ).map((entry) => fileSystem.path.basename(entry.path)).toList();
    for (final name in names) {
      if (name == 'SKILL.md' || name == 'agents') continue;
      entries.add(name);
    }
    final agents = fileSystem.path.join(directory, 'agents');
    if (skillEntityType(agents, followLinks: false, fs: fileSystem) ==
        FileSystemEntityType.directory) {
      for (final entry in listSkillDirectory(agents, fs: fileSystem)) {
        if (fileSystem.path.basename(entry.path) != 'openai.yaml') {
          entries.add('agents/${fileSystem.path.basename(entry.path)}');
        }
      }
    }
    entries.sort();
    return entries;
  }

  /// Human-readable reasons the Skill cannot become a Prompt template; an
  /// empty list means eligible.
  static List<String> ineligibility({
    required String skillDirectory,
    required String instructions,
    required bool activeTemplate,
    fs.FileSystem? fs,
  }) {
    final reasons = <String>[
      for (final entry in extraSkillEntries(skillDirectory, fs: fs))
        'carries an entry a Prompt cannot carry: $entry',
      if (PromptResourcePathScanner.scan(instructions).isNotEmpty)
        'references a bundled resource path',
      if (activeTemplate) 'uses active template arguments or dynamic shell',
    ];
    return reasons;
  }
}

/// Renders native Markdown frontmatter and body.
///
/// When [unsupported] is provided, fields the matrix has no spec for are
/// collected into it and dropped rather than silently discarded; otherwise
/// every field is emitted. The body is preserved exactly.
String renderNativeMarkdown({
  required Map<String, Object?> fields,
  required String body,
  required NativeFieldMatrix matrix,
  List<String>? unsupported,
}) {
  final rendered = <String, Object?>{...fields};
  if (unsupported != null) {
    for (final key in fields.keys) {
      if (matrix.specFor(key) == null) {
        unsupported.add(key);
        rendered.remove(key);
      }
    }
  }
  final entries = rendered.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  final frontmatter = entries
      .map(
        (entry) =>
            '${entry.key}: ${_yamlValue(entry.value, matrix.specFor(entry.key))}',
      )
      .join('\n');
  return '---\n$frontmatter\n---\n$body';
}

String _yamlValue(Object? value, NativeFieldSpec? spec) {
  if (value is List) {
    return spec?.listForm == NativeListForm.scalar
        ? jsonEncode(value.join(', '))
        : jsonEncode(value);
  }
  if (value is Map) {
    return jsonEncode(
      value.map((key, item) => MapEntry(key.toString(), item.toString())),
    );
  }
  return jsonEncode(value);
}

/// The catalog harnesses that publish derived native Prompt templates.
///
/// Derived from the catalog's Prompt facets, never hardcoded to one harness.
List<String> promptCapableHarnesses() => [
  for (final entry in promptHarnessFacets.entries)
    if (entry.value.skillConversionForm == PromptConversionForm.template)
      entry.key.wireName,
]..sort();

/// Whether a harness can host a derived Prompt template.
bool isPromptCapableTarget(String harness) =>
    promptCapableHarnesses().contains(harness);

/// The native Prompt template root of [harness] for the scope of [context].
String derivedPromptRoot(LifecycleContext context, String harness) {
  if (!isPromptCapableTarget(harness)) {
    throw ArgumentError.value(harness, 'harness', 'Not prompt capable');
  }
  final id = HarnessId.values.singleWhere((value) => value.wireName == harness);
  final spec = HarnessCatalog.instance.requireFacet(id, HarnessFacet.prompt);
  final root = spec is PromptHarnessSpec ? spec.templateRoot(context) : null;
  if (root != null) {
    return root;
  }
  throw ArgumentError.value(harness, 'harness', 'No template root');
}

/// The derived-Prompt assessment of one staged Skill source for one harness.
final class DerivedPromptAssessment {
  const DerivedPromptAssessment({
    required this.harness,
    required this.manualOnly,
    required this.reasons,
    this.content,
    this.unsupportedFields = const <String>[],
  });

  /// The prompt-capable harness this assessment belongs to.
  final String harness;

  /// Whether the Skill is a valid manual-only Prompt for the harness view.
  final bool manualOnly;

  /// Human-readable ineligibility reasons; empty means eligible.
  final List<String> reasons;

  /// Rendered template markdown; present when the Skill is eligible.
  final String? content;

  /// Source fields the harness profile cannot translate.
  final List<String> unsupportedFields;

  bool get eligible => manualOnly && reasons.isEmpty && content != null;
}

/// Assesses [skillDirectory] for derived Prompt template publication in each
/// of [harnesses], keyed by harness wire name.
///
/// [inspection] is the `PromptForm.skill` inspection of the same directory.
Map<String, DerivedPromptAssessment> assessDerivedPrompts({
  required String skillDirectory,
  required PromptInspection inspection,
  required List<String> harnesses,
  fs.FileSystem? fileSystem,
}) {
  final fileSystem2 = fileSystem ?? const local.LocalFileSystem();
  final marker = fileSystem2.path.join(skillDirectory, 'SKILL.md');
  var body = '';
  try {
    final content = fileSystem2.file(marker).readAsStringSync();
    final lines = content.split('\n');
    if (lines.isNotEmpty && lines.first.trimRight() == '---') {
      var end = 1;
      while (end < lines.length && lines[end].trimRight() != '---') {
        end++;
      }
      if (end < lines.length) {
        body = lines.sublist(end + 1).join('\n');
      }
    } else {
      body = content;
    }
  } on fs.FileSystemException {
    body = '';
  }
  final shape = DerivedPromptEligibility.ineligibility(
    skillDirectory: skillDirectory,
    instructions: body,
    activeTemplate: false,
    fs: fileSystem2,
  );
  final result = <String, DerivedPromptAssessment>{};
  for (final harness in harnesses) {
    final consumer = PromptConsumer.values.byName(harness);
    final view = inspection.views[consumer];
    final manualOnly =
        view != null &&
        view.classification == PromptClassification.prompt &&
        view.diagnostics.every(
          (diagnostic) => diagnostic.code == 'EXTRA_ENTRY',
        );
    final reasons = <String>[
      if (!manualOnly)
        'is not a valid manual-only Prompt for the $harness target',
      ...shape,
      if (view != null &&
          (view.argumentExpressions.isNotEmpty || view.dynamicShell))
        'uses active template arguments or dynamic shell',
    ];
    if (reasons.isNotEmpty) {
      result[harness] = DerivedPromptAssessment(
        harness: harness,
        manualOnly: manualOnly,
        reasons: reasons,
      );
      continue;
    }
    final fields = <String, Object?>{...inspection.fields}..remove('name');
    final unsupported = <String>[];
    final content = renderNativeMarkdown(
      fields: fields,
      body: body,
      matrix: NativeFieldMatrix.forKind(
        AuthoringKind.prompt,
        AuthoringProfile.values.byName(harness),
      ),
      unsupported: unsupported,
    );
    result[harness] = DerivedPromptAssessment(
      harness: harness,
      manualOnly: true,
      reasons: const <String>[],
      content: content,
      unsupportedFields: unsupported,
    );
  }
  return result;
}
