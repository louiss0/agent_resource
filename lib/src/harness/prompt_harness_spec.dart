import 'package:mamba/mamba.dart';

import '../services/lifecycle_state_service.dart';
import 'harness_catalog.dart';

/// Native output supported when converting a Skill to a Prompt.
enum PromptConversionForm { skillBacked, template }

/// The Prompt capability declared by one harness.
abstract interface class PromptHarnessSpec implements HarnessFacetSpec {
  /// The documented explanation carried by the facet itself.
  String get nativeExplanation;
  PromptConversionForm get skillConversionForm;
  bool get supportsSkillBackedInstallation;

  /// The native template root a template-conversion Prompt publishes to for
  /// the scope of [context], or null when the harness has none.
  String? templateRoot(LifecycleContext context);
}

/// A concrete Prompt facet with its own declarative refusal explanation.
final class PromptHarnessFacet implements PromptHarnessSpec {
  const PromptHarnessFacet(
    this.harness,
    this.nativeExplanation,
    this.skillConversionForm, {
    this.supportsSkillBackedInstallation = false,
    this.templateRootResolver,
  });

  final String? Function(LifecycleContext context)? templateRootResolver;

  @override
  String? templateRoot(LifecycleContext context) =>
      templateRootResolver?.call(context);

  @override
  final HarnessId harness;

  @override
  HarnessFacet get facet => HarnessFacet.prompt;

  @override
  final String nativeExplanation;

  @override
  final PromptConversionForm skillConversionForm;

  @override
  final bool supportsSkillBackedInstallation;
}

String? _piTemplateRoot(LifecycleContext context) =>
    context.scope == LifecycleScope.project
    ? context.fs.path.join(context.projectRoot, '.pi', 'prompts')
    : context.fs.path.join(context.piAgentRoot(), 'prompts');

/// The registered Prompt facets. Antigravity deliberately has none: version
/// 2.12.0+ replaced workflows with ordinary Skills and exposes no native
/// control that disables automatic model invocation.
const promptHarnessFacets = <HarnessId, PromptHarnessSpec>{
  HarnessId.claude: PromptHarnessFacet(
    HarnessId.claude,
    'Claude declares its native Prompt controls.',
    PromptConversionForm.skillBacked,
    supportsSkillBackedInstallation: true,
  ),
  HarnessId.codex: PromptHarnessFacet(
    HarnessId.codex,
    'Codex declares its native Prompt controls.',
    PromptConversionForm.skillBacked,
    supportsSkillBackedInstallation: true,
  ),
  HarnessId.pi: PromptHarnessFacet(
    HarnessId.pi,
    'Pi declares its native Prompt controls.',
    PromptConversionForm.template,
    templateRootResolver: _piTemplateRoot,
  ),
};

/// Prompt target authorization derived from the catalog's null facet.
///
/// Every command that names a Prompt target goes through this check so the
/// refusal has one explanation and one exit code.
extension PromptHarnessTargets on HarnessCatalog {
  void requirePromptFacet(HarnessId id, {int exitCode = 4}) {
    final prompt = facet(id, HarnessFacet.prompt);
    if (prompt != null) return;
    final missing = refusal(id, HarnessFacet.prompt, exitCode: exitCode)!;
    const explanation =
        'Antigravity 2.12.0+ unifies slash-command invocation with ordinary '
        'Skills in .agents/skills/ and has no native frontmatter control '
        'to disable automatic model invocation; a manual-only Prompt '
        'form is not fabricated.';
    throw MambaException('${missing.message} $explanation', exitCode: exitCode);
  }
}
