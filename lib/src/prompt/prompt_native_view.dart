import '../harness/harness_catalog.dart';
import 'prompt_contracts.dart';

/// The native view of one source in one consuming harness.
///
/// The view is per consumer: a source can be a Prompt for Claude and an
/// ordinary Skill for Codex. The view never carries a universal
/// classification.
final class PromptNativeView {
  const PromptNativeView({
    required this.consumer,
    required this.classification,
    required this.valid,
    required this.installationSupported,
    required this.diagnostics,
  });

  /// Projects a parser result into the public body-free native view.
  factory fromInspection(PromptView view, PromptForm form) => PromptNativeView(
    consumer: view.consumer,
    classification: view.classification,
    valid: view.valid,
    installationSupported: supportsInstallation(view, form, view.consumer),
    diagnostics: view.diagnostics,
  );

  /// The consuming harness of the view.
  final PromptConsumer consumer;

  /// The classification of the source in the consumer view.
  final PromptClassification classification;

  /// Whether the source is a valid resource in the consumer view.
  final bool valid;

  /// Whether the native installation supports this Prompt view.
  ///
  /// Recognition and installation support are separate: a Pi skill-backed
  /// Prompt is recognized and validated, and it is not installable.
  final bool installationSupported;

  /// The blocking diagnostics of the view.
  final List<PromptDiagnostic> diagnostics;

  /// Whether the source is a Prompt in this consumer view.
  bool get isPrompt => classification == PromptClassification.prompt;

  /// Whether the native installation supports one inspected view.
  ///
  /// The Pi Prompt installation is not supported, and an invalid Prompt is
  /// never installable.
  static bool supportsInstallation(
    PromptView view,
    PromptForm form,
    PromptConsumer consumer,
  ) =>
      form == PromptForm.skill &&
      HarnessCatalog.instance
              .byId(HarnessId.fromWire(consumer.name))
              .prompt
              ?.supportsSkillBackedInstallation ==
          true &&
      view.classification == PromptClassification.prompt &&
      view.valid;

  Map<String, Object?> toJson() => <String, Object?>{
    'consumer': consumer.name,
    'classification': classification.name,
    'valid': valid,
    'installationSupported': installationSupported,
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
}

/// The native views of one inspected source.
///
/// The views are per consumer, and the global compatibility of the native form
/// is reported separately from the observed placement.
final class PromptNativeViews {
  const PromptNativeViews({
    required this.path,
    required this.form,
    required this.views,
    required this.globalCompatibility,
    required this.placement,
    this.selectedConsumer,
  });

  factory fromInspection(PromptInspection inspection) => PromptNativeViews(
    path: inspection.path,
    form: inspection.form,
    views: {
      for (final entry in inspection.views.entries)
        entry.key: PromptNativeView.fromInspection(
          entry.value,
          inspection.form,
        ),
    },
    globalCompatibility: inspection.globalCompatibility,
    placement: inspection.placement,
    selectedConsumer: inspection.selectedConsumer,
  );

  /// The inspected path.
  final String path;

  /// The native form of the source.
  final PromptForm form;

  /// The per-consumer views of the source.
  final Map<PromptConsumer, PromptNativeView> views;

  /// The global compatibility of the native form.
  final PromptCompatibility globalCompatibility;

  /// The observed placement of the source.
  final PromptPlacement placement;

  /// The explicitly selected consuming harness, if supplied.
  final PromptConsumer? selectedConsumer;

  /// Whether the source belongs to the Prompt selection.
  ///
  /// A source is a Prompt candidate when a consumer view classifies it as a
  /// Prompt, or when the evidence is insufficient to classify it. An ordinary
  /// Skill view is not a Prompt candidate.
  bool get promptCandidate => views.values.any(
    (view) => view.classification != PromptClassification.nonPrompt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'form': form.name,
    if (selectedConsumer != null) 'selectedConsumer': selectedConsumer!.name,
    'globalCompatibility': globalCompatibility.name,
    'placement': placement.name,
    'views': [
      for (final consumer in PromptConsumer.inspectable)
        if (views[consumer] != null) views[consumer]!.toJson(),
    ],
  };
}
