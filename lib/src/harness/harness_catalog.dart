import 'harness_descriptor.dart';
import 'harness_facet.dart';
import 'harness_facet_refusal.dart';
import 'harness_id.dart';
import 'harness_user_roots.dart';

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
      HarnessDescriptor.composed(HarnessId.claude, userRoot: _claudeUserRoot),
      HarnessDescriptor.composed(HarnessId.codex, userRoot: _codexUserRoot),
      HarnessDescriptor.composed(HarnessId.pi, userRoot: _piUserRoot),
      HarnessDescriptor.composed(
        HarnessId.antigravity,
        userRoot: _geminiUserRoot,
        userConfigRoot: _geminiUserConfigRoot,
        prompt: false,
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
