import 'package:mamba/mamba.dart';

import 'harness_catalog.dart';

/// The Prompt capability declared by one harness.
abstract interface class PromptHarnessSpec implements HarnessFacetSpec {}

/// Prompt target authorization derived from the catalog's null facet.
///
/// Antigravity has no Prompt facet: version 2.12.0+ replaced workflows with
/// ordinary Skills and exposes no native control that disables automatic
/// model invocation. Every command that names a Prompt target goes through
/// this check so the refusal has one explanation and one exit code.
extension PromptHarnessTargets on HarnessCatalog {
  void requirePromptFacet(HarnessId id, {int exitCode = 4}) {
    if (facet(id, HarnessFacet.prompt) != null) return;
    final missing = refusal(id, HarnessFacet.prompt, exitCode: exitCode)!;
    throw MambaException(
      '${missing.message} Antigravity 2.12.0+ unifies slash-command '
      'invocation with ordinary Skills in .agents/skills/ and has no native '
      'frontmatter control to disable automatic model invocation; a '
      'manual-only Prompt form is not fabricated.',
      exitCode: exitCode,
    );
  }
}
