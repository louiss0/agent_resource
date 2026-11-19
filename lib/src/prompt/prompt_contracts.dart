/// The native form of a Prompt source.
///
/// The form is the caller's context: it is never inferred from the file
/// extension.
enum PromptForm { skill, template }

/// The classification of a Prompt source in one consumer view.
enum PromptClassification { prompt, nonPrompt, unclassified, malformed }

/// The consuming harness of a Prompt view.
enum PromptConsumer {
  claude,
  codex,
  pi,

  /// Antigravity has no Prompt facet. The value exists so an explicit
  /// target can be recognized and refused instead of parsed as unknown.
  antigravity;

  /// Consumers with a native inspection view. Antigravity deliberately has
  /// none; its prompt commands refuse before a view is built.
  static const List<PromptConsumer> inspectable = <PromptConsumer>[
    claude,
    codex,
    pi,
  ];
}

/// Caller-supplied placement evidence, not a claim of discovery or activation.
enum PromptPlacement { project, user, uninstalled, unknown }

/// The compatibility of the native form of a Prompt source.
enum PromptCompatibility { compatible, incompatible, unknown }

/// One diagnostic of a native Prompt view.
typedef PromptDiagnostic = ({
  String code,
  String message,
  String path,
  int? line,
  int? column,
});

/// The inspected view of a Prompt source in one consumer.
typedef PromptView = ({
  PromptConsumer consumer,
  PromptClassification classification,
  bool valid,
  List<String> argumentExpressions,
  bool dynamicShell,
  bool argumentsAppended,
  List<PromptDiagnostic> diagnostics,
});

/// The complete inspection of one native Prompt source.
typedef PromptInspection = ({
  String path,
  PromptForm form,
  PromptConsumer? selectedConsumer,
  PromptView? selectedView,
  Map<PromptConsumer, PromptView> views,
  PromptCompatibility globalCompatibility,
  PromptPlacement placement,
  Map<String, Object?> fields,
  Map<String, Object?> sidecarFields,
});
