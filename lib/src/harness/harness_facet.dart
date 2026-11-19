import 'harness_id.dart';

/// The managed Resource categories a harness may support.
///
/// Standalone hooks are deliberately absent: ADR-0001 keeps them as a
/// subordinate native field on Agent and Skill definitions, not a category.
enum HarnessFacet {
  context('context'),
  mcp('mcp'),
  skill('skill'),
  prompt('prompt'),
  agent('agent');

  const HarnessFacet(this.wireName);

  /// Stable wire name used in requests and refusal diagnostics.
  final String wireName;
}

/// The common identity of one declared harness capability facet.
abstract interface class HarnessFacetSpec {
  HarnessId get harness;
  HarnessFacet get facet;
}
