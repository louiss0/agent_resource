import '../mcp/mcp_types.dart';
import 'agent_harness_spec.dart';
import 'context_harness_spec.dart';
import 'harness_descriptor.dart';
import 'harness_facet.dart';
import 'harness_facet_refusal.dart';
import 'harness_id.dart';
import 'harness_user_roots.dart';
import 'mcp_harness_spec.dart';
import 'mcp_harness_specs.dart';
import 'prompt_harness_spec.dart';
import 'skill_harness_spec.dart';

export 'agent_conversion_claims.dart';
export 'agent_harness_spec.dart';
export 'context_harness_spec.dart';
export 'harness_descriptor.dart';
export 'harness_facet.dart';
export 'harness_facet_refusal.dart';
export 'harness_id.dart';
export 'harness_user_roots.dart';
export 'mcp_harness_spec.dart';
export 'prompt_harness_spec.dart';
export 'skill_harness_spec.dart';

String _claudeUserRoot(HarnessUserRoots roots) => roots.claudeConfigRoot();

String _codexUserRoot(HarnessUserRoots roots) => roots.codexRoot();

String _piUserRoot(HarnessUserRoots roots) => roots.piAgentRoot();

String _geminiUserRoot(HarnessUserRoots roots) => roots.geminiRoot();

String _geminiUserConfigRoot(HarnessUserRoots roots) =>
    roots.geminiConfigRoot();

/// The single registry of harness identities and their composed descriptors.
final class HarnessCatalog {
  const HarnessCatalog._(this._descriptors);

  static final HarnessCatalog instance = HarnessCatalog._(
    List<HarnessDescriptor>.unmodifiable(<HarnessDescriptor>[
      for (final id in HarnessId.values)
        HarnessDescriptor.composed(
          id,
          userRoot: switch (id) {
            HarnessId.claude => _claudeUserRoot,
            HarnessId.codex => _codexUserRoot,
            HarnessId.pi => _piUserRoot,
            HarnessId.antigravity => _geminiUserRoot,
          },
          userConfigRoot: id == HarnessId.antigravity
              ? _geminiUserConfigRoot
              : null,
          context: contextHarnessFacets[id]!,
          skill: skillHarnessFacets[id]!,
          agent: agentHarnessFacets[id]!,
          prompt: promptHarnessFacets[id],
          mcp: mcpHarnessSpecs[id]!,
        ),
    ]),
  );

  final List<HarnessDescriptor> _descriptors;

  List<HarnessDescriptor> get descriptors => _descriptors;

  HarnessDescriptor byId(HarnessId id) =>
      _descriptors.firstWhere((descriptor) => descriptor.id == id);

  HarnessDescriptor byWireName(String wireName) =>
      byId(HarnessId.fromWire(wireName));

  List<HarnessId> harnessesSupporting(HarnessFacet facet) =>
      List<HarnessId>.unmodifiable(<HarnessId>[
        for (final descriptor in _descriptors)
          if (descriptor.supports(facet)) descriptor.id,
      ]);

  bool supports(HarnessId id, HarnessFacet facet) => byId(id).supports(facet);

  HarnessFacetSpec? facet(HarnessId id, HarnessFacet facet) =>
      byId(id).facet(facet);

  /// The composed Agent facet of one registered harness identity.
  AgentHarnessSpec agentSpecById(HarnessId id) =>
      requireFacet(id, HarnessFacet.agent) as AgentHarnessSpec;

  /// The composed MCP facet of one registered harness identity.
  McpHarnessSpec mcpSpecById(HarnessId id) =>
      requireFacet(id, HarnessFacet.mcp) as McpHarnessSpec;

  /// The composed MCP facet selected by the MCP wire name.
  McpHarnessSpec mcpSpec(McpHarness harness) =>
      mcpSpecById(HarnessId.of(harness));

  HarnessFacetRefusal? refusal(
    HarnessId id,
    HarnessFacet facet, {
    int exitCode = 4,
  }) {
    final unsupported = HarnessFacetRefusal.unsupported(
      id,
      facet,
      exitCode: exitCode,
    );
    return supports(id, facet) ? null : unsupported;
  }

  HarnessFacetSpec requireFacet(
    HarnessId id,
    HarnessFacet facet, {
    int refusalExitCode = 4,
  }) {
    final spec = this.facet(id, facet);
    if (spec != null) return spec;
    throw refusal(id, facet, exitCode: refusalExitCode)!.toException();
  }

  String userRoot(HarnessId id, HarnessUserRoots roots) =>
      byId(id).userRoot(roots);

  String userConfigRoot(HarnessId id, HarnessUserRoots roots) =>
      byId(id).userConfigRoot(roots);
}
