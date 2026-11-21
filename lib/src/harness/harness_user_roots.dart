/// The shared lifecycle roots a descriptor may use to resolve user paths.
abstract interface class HarnessUserRoots {
  String claudeConfigRoot();
  String codexRoot();
  String piAgentRoot();
  String geminiRoot();
  String geminiConfigRoot();
}

/// Resolves one harness root from the shared lifecycle context.
typedef HarnessRootResolver = String Function(HarnessUserRoots roots);
