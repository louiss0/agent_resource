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
    required PromptView view,
    fs.FileSystem? fs,
  }) {
    final reasons = <String>[
      for (final entry in extraSkillEntries(skillDirectory, fs: fs))
        'carries an entry a Prompt cannot carry: $entry',
      if (PromptResourcePathScanner.scan(instructions).isNotEmpty)
        'references a bundled resource path',
      if (view.argumentExpressions.isNotEmpty || view.dynamicShell)
        'uses active template arguments or dynamic shell',
    ];
    return reasons;
  }
}

/// Renders native Markdown frontmatter and body, keeping only fields the
/// matrix supports.
///
/// Fields the matrix has no spec for are collected in [unsupported] and
/// dropped rather than silently discarded. The body is preserved exactly.
String renderNativeMarkdown({
  required Map<String, Object?> fields,
  required String body,
  required NativeFieldMatrix matrix,
  List<String>? unsupported,
}) {
  final rendered = <String, Object?>{...fields};
  for (final key in fields.keys) {
    if (matrix.specFor(key) == null) {
      unsupported?.add(key);
      rendered.remove(key);
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

/// Whether a requested installation target can host a derived Prompt
/// template, derived from the catalog rather than a hardcoded harness.
bool isPromptCapableTarget(String target) {
  for (final id in HarnessId.values) {
    if (id.wireName != target) continue;
    final facet = HarnessCatalog.instance.facet(id, HarnessFacet.prompt);
    return facet is PromptHarnessSpec &&
        facet.skillConversionForm == PromptConversionForm.template;
  }
  return false;
}

/// The native Prompt template root for the scope of [context].
///
/// Every prompt-capable target currently resolves to the same catalog facet;
/// the target parameter keeps the resolution honest if a second
/// template-form harness appears.
String derivedPromptRoot(LifecycleContext context, String target) {
  if (!isPromptCapableTarget(target)) {
    throw ArgumentError.value(target, 'target', 'Not prompt capable');
  }
  final paths = const local.LocalFileSystem().path;
  return context.scope == LifecycleScope.project
      ? paths.join(context.projectRoot, '.pi', 'prompts')
      : paths.join(context.piAgentRoot(), 'prompts');
}

/// The derived-Prompt assessment of one staged Skill source.
final class DerivedPromptAssessment {
  const DerivedPromptAssessment({
    required this.manualOnly,
    required this.reasons,
    this.content,
    this.unsupportedFields = const <String>[],
  });

  /// Whether the Skill is a valid manual-only Prompt for the target view.
  final bool manualOnly;

  /// Human-readable ineligibility reasons; empty means eligible.
  final List<String> reasons;

  /// Rendered template markdown; present when the Skill is eligible.
  final String? content;

  /// Source fields the target profile cannot translate.
  final List<String> unsupportedFields;

  bool get eligible => manualOnly && reasons.isEmpty && content != null;
}

/// Assesses [skillDirectory] for derived Prompt template publication.
///
/// [inspection] is the `PromptForm.skill` inspection of the same directory.
/// The manual-only view is evaluated for every prompt-capable consumer.
DerivedPromptAssessment assessDerivedPrompt({
  required String skillDirectory,
  required PromptInspection inspection,
  required List<PromptConsumer> consumers,
  required NativeFieldMatrix matrix,
  fs.FileSystem? fileSystem,
}) {
  final fileSystem2 = fileSystem ?? const local.LocalFileSystem();
  var manualOnly = consumers.isNotEmpty;
  final diagnostics = <String>[];
  var argsActive = false;
  for (final consumer in consumers) {
    final view = inspection.views[consumer];
    if (view == null ||
        view.classification != PromptClassification.prompt ||
        !view.valid) {
      manualOnly = false;
      if (view != null) {
        diagnostics.addAll([
          for (final diagnostic in view.diagnostics) diagnostic.message,
        ]);
      }
    } else {
      argsActive =
          argsActive ||
          view.argumentExpressions.isNotEmpty ||
          view.dynamicShell;
    }
  }
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
  final reasons = <String>[
    if (!manualOnly) 'is not a valid manual-only Prompt for the target harness',
    ...DerivedPromptEligibility.ineligibility(
      skillDirectory: skillDirectory,
      instructions: body,
      view: (
        consumer: consumers.firstOrNull ?? PromptConsumer.pi,
        classification: PromptClassification.prompt,
        valid: true,
        argumentExpressions: argsActive
            ? const <String>['*']
            : const <String>[],
        dynamicShell: false,
        argumentsAppended: false,
        diagnostics: const <PromptDiagnostic>[],
      ),
      fs: fileSystem2,
    ),
  ];
  if (reasons.isNotEmpty) {
    return DerivedPromptAssessment(manualOnly: manualOnly, reasons: reasons);
  }
  final fields = <String, Object?>{...inspection.fields}..remove('name');
  final unsupported = <String>[];
  final content = renderNativeMarkdown(
    fields: fields,
    body: body,
    matrix: matrix,
    unsupported: unsupported,
  );
  return DerivedPromptAssessment(
    manualOnly: true,
    reasons: const <String>[],
    content: content,
    unsupportedFields: unsupported,
  );
}
