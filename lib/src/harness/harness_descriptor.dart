import 'agent_harness_spec.dart';
import 'context_harness_spec.dart';
import 'harness_facet.dart';
import 'harness_id.dart';
import 'harness_user_roots.dart';
import 'mcp_harness_spec.dart';
import 'prompt_harness_spec.dart';
import 'skill_harness_spec.dart';

/// One registered harness and the composed capabilities it supports.
final class HarnessDescriptor {
  const HarnessDescriptor({
    required this.id,
    required this.rootResolver,
    required this.configRootResolver,
    this.context,
    this.mcp,
    this.skill,
    this.prompt,
    this.agent,
  });

  /// Composes the five category facets of one harness in registration order.
  /// A missing category is represented by a null facet.
  factory HarnessDescriptor.composed(
    HarnessId id, {
    required HarnessRootResolver userRoot,
    HarnessRootResolver? userConfigRoot,
    required ContextHarnessSpec context,
    required SkillHarnessSpec skill,
    required AgentHarnessSpec agent,
    McpHarnessSpec? mcp,
    PromptHarnessSpec? prompt,
  }) => HarnessDescriptor(
    id: id,
    rootResolver: userRoot,
    configRootResolver: userConfigRoot ?? userRoot,
    context: context,
    mcp: mcp,
    skill: skill,
    prompt: prompt,
    agent: agent,
  );

  final HarnessId id;
  final HarnessRootResolver rootResolver;
  final HarnessRootResolver configRootResolver;
  final ContextHarnessSpec? context;
  final McpHarnessSpec? mcp;
  final SkillHarnessSpec? skill;
  final PromptHarnessSpec? prompt;
  final AgentHarnessSpec? agent;

  String get wireName => id.wireName;

  String userRoot(HarnessUserRoots roots) => rootResolver(roots);

  String userConfigRoot(HarnessUserRoots roots) => configRootResolver(roots);

  HarnessFacetSpec? facet(HarnessFacet facet) => switch (facet) {
    HarnessFacet.context => context,
    HarnessFacet.mcp => mcp,
    HarnessFacet.skill => skill,
    HarnessFacet.prompt => prompt,
    HarnessFacet.agent => agent,
  };

  bool supports(HarnessFacet category) => facet(category) != null;
}
