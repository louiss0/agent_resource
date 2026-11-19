import 'agent_harness_spec.dart';
import 'context_harness_spec.dart';
import 'harness_facet.dart';
import 'harness_id.dart';
import 'mcp_harness_spec.dart';
import 'prompt_harness_spec.dart';
import 'skill_harness_spec.dart';

/// One registered harness and the composed capabilities it supports.
final class HarnessDescriptor {
  const HarnessDescriptor({
    required this.id,
    this.context,
    this.mcp,
    this.skill,
    this.prompt,
    this.agent,
  });

  /// Composes the five category facets of one harness in registration order.
  /// A missing category is represented by a null facet.
  factory HarnessDescriptor.composed(HarnessId id, {bool prompt = true}) =>
      HarnessDescriptor(
        id: id,
        context: _HarnessCapability(id, HarnessFacet.context),
        mcp: _HarnessCapability(id, HarnessFacet.mcp),
        skill: _HarnessCapability(id, HarnessFacet.skill),
        prompt: prompt ? _HarnessCapability(id, HarnessFacet.prompt) : null,
        agent: _HarnessCapability(id, HarnessFacet.agent),
      );

  final HarnessId id;
  final ContextHarnessSpec? context;
  final McpHarnessSpec? mcp;
  final SkillHarnessSpec? skill;
  final PromptHarnessSpec? prompt;
  final AgentHarnessSpec? agent;

  String get wireName => id.wireName;

  HarnessFacetSpec? facet(HarnessFacet facet) => switch (facet) {
    HarnessFacet.context => context,
    HarnessFacet.mcp => mcp,
    HarnessFacet.skill => skill,
    HarnessFacet.prompt => prompt,
    HarnessFacet.agent => agent,
  };

  bool supports(HarnessFacet category) => facet(category) != null;
}

final class _HarnessCapability
    implements
        ContextHarnessSpec,
        McpHarnessSpec,
        SkillHarnessSpec,
        PromptHarnessSpec,
        AgentHarnessSpec {
  const _HarnessCapability(this.harness, this.facet);

  @override
  final HarnessId harness;

  @override
  final HarnessFacet facet;
}
