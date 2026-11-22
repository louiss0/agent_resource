import '../prompt/prompt_native_view.dart';
import '../services/pack_prompt_service.dart';
import '../services/prompt_inspection_service.dart';

/// The kind of a discovered pack candidate.
///
/// A source is reported once. A manual-only Skill is a Skill candidate that
/// also carries its per-harness Prompt views: the discovery never exposes a
/// duplicated Skill/Prompt resource.
enum PackDiscoveryKind { skill, agent, prompt, mcp }

/// The native form of a discovered candidate.
enum PackDiscoveryForm { skill, agentFile, template, mcpRegistration }

/// One candidate of the Prompt scope of a pack source.
///
/// The scope holds the declared Skill entries, the declared Prompt entries
/// and the discovered Prompt sources. The candidate carries its per-consumer
/// Prompt views.
final class PackScopeCandidate {
  const PackScopeCandidate({
    required this.kind,
    required this.id,
    required this.path,
    required this.name,
    required this.form,
    required this.view,
    this.profile,
    this.declared = false,
    this.discoveryRoot,
    this.discoveryGroup,
  });

  /// The declared kind of the candidate.
  final PackDiscoveryKind kind;

  /// The source-relative identity of the candidate.
  final String id;

  /// The absolute source path of the candidate.
  final String path;

  /// The native name of the candidate.
  final String name;

  /// The native form of the candidate.
  final PackDiscoveryForm form;

  /// The inspected Prompt views of the candidate.
  final PackPromptCandidate view;

  /// The declared native profile of the candidate.
  final String? profile;

  /// Whether the source is declared as a Prompt source.
  final bool declared;

  /// The discovery root the source was found under.
  final String? discoveryRoot;

  /// The discovery group the source was found in.
  final String? discoveryGroup;

  /// Whether the candidate belongs to the Prompt selection.
  ///
  /// A source is a Prompt candidate when a consumer view classifies it as a
  /// Prompt, or when the evidence is insufficient to classify it. An
  /// ordinary Skill view is not a Prompt candidate.
  bool get promptCandidate => view.promptCandidate;
}

/// One discovered candidate of a pack source.
///
/// The candidate reports the native form of the source, its declared profile
/// and its per-consumer Prompt views. It never discloses an instruction body
/// and it never claims an installed placement.
final class PackDiscoveryCandidate {
  const PackDiscoveryCandidate({
    required this.id,
    required this.path,
    required this.kind,
    required this.form,
    this.profile,
    this.views = const <PromptNativeView>[],
    this.globalCompatibility,
    this.placement = PromptPlacement.uninstalled,
    this.diagnostics = const <PromptDiagnostic>[],
    this.admission,
  });

  /// The source-relative identity of the candidate.
  final String id;

  /// The absolute source path of the candidate.
  final String path;

  /// The declared kind of the candidate.
  final PackDiscoveryKind kind;

  /// The native form of the candidate.
  final PackDiscoveryForm form;

  /// The declared native profile of the candidate.
  final String? profile;

  /// The per-consumer Prompt views of the candidate.
  final List<PromptNativeView> views;

  /// The global compatibility of the native form.
  ///
  /// The global form and the placement are independent: a globally compatible
  /// source of a pack is not an installed occurrence.
  final PromptCompatibility? globalCompatibility;

  /// The observed placement of the source.
  final PromptPlacement placement;

  /// The candidate-level diagnostics.
  final List<PromptDiagnostic> diagnostics;

  /// The source-only installation admission of a Skill candidate, reported
  /// separately from its native views. Null for non-Skill kinds.
  final Map<String, Object?>? admission;

  /// Returns a copy carrying the installation [admission] report.
  PackDiscoveryCandidate withAdmission(Map<String, Object?> admission) =>
      PackDiscoveryCandidate(
        id: id,
        path: path,
        kind: kind,
        form: form,
        profile: profile,
        views: views,
        globalCompatibility: globalCompatibility,
        placement: placement,
        diagnostics: diagnostics,
        admission: admission,
      );

  /// Whether the candidate belongs to the Prompt selection.
  ///
  /// A source is a Prompt candidate when a consumer view classifies it as a
  /// Prompt, or when the evidence is insufficient to classify it. An
  /// ordinary Skill view is not a Prompt candidate.
  bool get promptCandidate => views.any(
    (view) => view.classification != PromptClassification.nonPrompt,
  );

  /// Whether the candidate is a valid Prompt in at least one consumer view.
  bool get validPrompt => views.any(
    (view) => view.classification == PromptClassification.prompt && view.valid,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'path': path,
    'kind': kind.name,
    'form': form.name,
    if (profile != null) 'profile': profile,
    'promptCandidate': promptCandidate,
    if (globalCompatibility != null)
      'globalCompatibility': globalCompatibility!.name,
    'placement': placement.name,
    if (admission != null) 'installationAdmission': admission,
    'views': [for (final view in views) view.toJson()],
    'diagnostics': [
      for (final diagnostic in diagnostics)
        <String, Object?>{
          'code': diagnostic.code,
          'message': diagnostic.message,
          'path': diagnostic.path,
          if (diagnostic.line != null) 'line': diagnostic.line,
          if (diagnostic.column != null) 'column': diagnostic.column,
        },
    ],
  };

  /// The text rendering of the candidate.
  String renderText() {
    final lines = <String>[];
    final head = StringBuffer('${kind.name} $id');
    if (profile != null) head.write(' profile=$profile');
    if (views.isNotEmpty) {
      head.write(
        ' ${views.map((view) => '${view.consumer.name}=${_classification(view)}').join(' ')}',
      );
    }
    if (globalCompatibility != null) {
      head.write(' global=${globalCompatibility!.name}');
    }
    head.write(' placement=${placement.name}');
    lines.add(head.toString());
    if (admission != null) {
      lines.add(
        '  admission: ${admission!['eligible'] == true ? 'eligible' : 'ineligible'}',
      );
      for (final diagnostic
          in (admission!['diagnostics'] as List? ?? const <Object?>[])) {
        if (diagnostic is Map<String, Object?>) {
          lines.add('  admission: ${diagnostic['message']}');
        }
      }
    }
    for (final view in views) {
      if (!view.installationSupported &&
          view.classification == PromptClassification.prompt) {
        lines.add(
          '  ${view.consumer.name}: installation is not supported for this '
          'Prompt form',
        );
      }
      for (final diagnostic in view.diagnostics) {
        lines.add(
          '  ${view.consumer.name}[${diagnostic.code}]: ${diagnostic.message}',
        );
      }
    }
    for (final diagnostic in diagnostics) {
      lines.add('  [${diagnostic.code}]: ${diagnostic.message}');
    }
    return lines.join('\n');
  }

  static String _classification(PromptNativeView view) {
    final name = view.classification.name;
    return view.valid ? '$name(valid)' : '$name(invalid)';
  }
}

/// The read-only discovery report of one pack source.
///
/// The report never writes management state, never enrolls a membership and
/// never advances an inventory.
final class PackDiscoveryReport {
  const PackDiscoveryReport({
    required this.pack,
    required this.source,
    required this.candidates,
    required this.types,
  });

  /// The configured pack key.
  final String pack;

  /// The resolved source evidence of the pack.
  final Map<String, Object?> source;

  /// The discovered candidates, in deterministic order.
  final List<PackDiscoveryCandidate> candidates;

  /// The selected resource kinds of the report.
  final List<String> types;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'operation': 'pack.discover',
    'outcome': 'discovered',
    'pack': pack,
    'source': source,
    'types': types,
    'candidates': [for (final candidate in candidates) candidate.toJson()],
    'summary': <String, Object?>{
      'total': candidates.length,
      'prompts': candidates.where((c) => c.promptCandidate).length,
    },
  };

  /// The text rendering of the report.
  String renderText() {
    final lines = <String>[
      'pack.discover: discovered',
      '  pack: $pack',
      '  source: ${source.entries.map((e) => '${e.key}=${e.value ?? '-'}').join(' ')}',
      '  types: ${types.join(',')}',
    ];
    for (final candidate in candidates) {
      lines.addAll(candidate.renderText().split('\n'));
    }
    lines.add('summary: ${candidates.length} candidate(s)');
    return lines.join('\n');
  }
}
