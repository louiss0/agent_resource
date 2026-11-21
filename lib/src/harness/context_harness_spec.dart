import 'package:mamba/mamba.dart';

import '../context/context_types.dart';
import '../services/lifecycle_state_service.dart';
import 'harness_facet.dart';
import 'harness_id.dart';

/// The user root that backs one native Context target.
enum ContextUserRoot { claudeConfig, codex, pi, gemini, geminiConfig }

/// One declarative native Context target of a harness facet.
final class ContextTarget {
  const ContextTarget(this.segments, {this.userRoot});

  final List<String> segments;
  final ContextUserRoot? userRoot;

  String resolve(LifecycleContext context, String projectTargetDir) {
    final p = context.fs.path;
    final base = switch (userRoot) {
      null => projectTargetDir,
      ContextUserRoot.claudeConfig => context.claudeConfigRoot(),
      ContextUserRoot.codex => context.codexRoot(),
      ContextUserRoot.pi => context.piAgentRoot(),
      ContextUserRoot.gemini => context.geminiRoot(),
      ContextUserRoot.geminiConfig => context.geminiConfigRoot(),
    };
    return p.joinAll(<String>[base, ...segments]);
  }
}

/// The Context capability declared by one harness.
///
/// The facet owns its metadata and the target-path algorithm: registering a
/// harness supplies one [ContextHarnessFacet] instead of adding a branch to a
/// shared switch.
abstract interface class ContextHarnessSpec implements HarnessFacetSpec {
  Map<(ContextScope scope, ContextVariant variant), ContextTarget> get targets;

  String resolveTargetPath({
    required LifecycleContext context,
    required ContextScope scope,
    required ContextVariant variant,
    required String projectTargetDir,
  });
}

/// A concrete, declarative Context facet.
final class ContextHarnessFacet implements ContextHarnessSpec {
  const ContextHarnessFacet(this.harness, this.targets);

  @override
  final HarnessId harness;

  @override
  HarnessFacet get facet => HarnessFacet.context;

  @override
  final Map<(ContextScope scope, ContextVariant variant), ContextTarget>
  targets;

  /// Resolves one supported tuple, or throws an exit-4 refusal.
  ///
  /// User-scope roots come from the shared [LifecycleContext], which
  /// implements the catalog's user-root contract. Every unsupported tuple
  /// refuses the whole invocation before any target is written.
  @override
  String resolveTargetPath({
    required LifecycleContext context,
    required ContextScope scope,
    required ContextVariant variant,
    required String projectTargetDir,
  }) {
    final target = targets[(scope, variant)];
    if (target == null) {
      throw MambaException(
        'UNSUPPORTED_CONTEXT_VARIANT: Variant "${variant.wireName}" is not '
        'supported for harness "${harness.wireName}" at ${scope.name} scope.',
        exitCode: 4,
      );
    }
    return target.resolve(context, projectTargetDir);
  }
}

const _claudeContextTargets = <(ContextScope, ContextVariant), ContextTarget>{
  (ContextScope.project, ContextVariant.standard): ContextTarget(['CLAUDE.md']),
  (ContextScope.project, ContextVariant.local): ContextTarget([
    'CLAUDE.local.md',
  ]),
  (ContextScope.project, ContextVariant.dotClaude): ContextTarget([
    '.claude',
    'CLAUDE.md',
  ]),
  (ContextScope.user, ContextVariant.standard): ContextTarget([
    'CLAUDE.md',
  ], userRoot: ContextUserRoot.claudeConfig),
};

const _codexContextTargets = <(ContextScope, ContextVariant), ContextTarget>{
  (ContextScope.project, ContextVariant.standard): ContextTarget(['AGENTS.md']),
  (ContextScope.project, ContextVariant.override): ContextTarget([
    'AGENTS.override.md',
  ]),
  (ContextScope.user, ContextVariant.standard): ContextTarget([
    'AGENTS.md',
  ], userRoot: ContextUserRoot.codex),
  (ContextScope.user, ContextVariant.override): ContextTarget([
    'AGENTS.override.md',
  ], userRoot: ContextUserRoot.codex),
};

const _piContextTargets = <(ContextScope, ContextVariant), ContextTarget>{
  (ContextScope.project, ContextVariant.standard): ContextTarget(['AGENTS.md']),
  (ContextScope.project, ContextVariant.override): ContextTarget([
    'AGENTS.override.md',
  ]),
  (ContextScope.user, ContextVariant.standard): ContextTarget([
    'AGENTS.md',
  ], userRoot: ContextUserRoot.pi),
  (ContextScope.user, ContextVariant.override): ContextTarget([
    'AGENTS.override.md',
  ], userRoot: ContextUserRoot.pi),
};

const _antigravityContextTargets =
    <(ContextScope, ContextVariant), ContextTarget>{
      (ContextScope.project, ContextVariant.standard): ContextTarget([
        'AGENTS.md',
      ]),
      (ContextScope.project, ContextVariant.gemini): ContextTarget([
        'GEMINI.md',
      ]),
      (ContextScope.project, ContextVariant.dotAgents): ContextTarget([
        '.agents',
        'AGENTS.md',
      ]),
      (ContextScope.user, ContextVariant.standard): ContextTarget([
        'AGENTS.md',
      ], userRoot: ContextUserRoot.gemini),
      (ContextScope.user, ContextVariant.gemini): ContextTarget([
        'GEMINI.md',
      ], userRoot: ContextUserRoot.gemini),
      (ContextScope.user, ContextVariant.dotAgents): ContextTarget([
        'AGENTS.md',
      ], userRoot: ContextUserRoot.geminiConfig),
    };

/// The registered Context facets, one per harness identity.
const contextHarnessFacets = <HarnessId, ContextHarnessSpec>{
  HarnessId.claude: ContextHarnessFacet(
    HarnessId.claude,
    _claudeContextTargets,
  ),
  HarnessId.codex: ContextHarnessFacet(HarnessId.codex, _codexContextTargets),
  HarnessId.pi: ContextHarnessFacet(HarnessId.pi, _piContextTargets),
  HarnessId.antigravity: ContextHarnessFacet(
    HarnessId.antigravity,
    _antigravityContextTargets,
  ),
};
