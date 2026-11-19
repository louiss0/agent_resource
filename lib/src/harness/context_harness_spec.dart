import 'package:mamba/mamba.dart';

import '../context/context_types.dart';
import '../services/lifecycle_state_service.dart';
import 'harness_facet.dart';
import 'harness_id.dart';

/// The Context capability declared by one harness.
abstract interface class ContextHarnessSpec implements HarnessFacetSpec {}

/// The target-path algorithm owned by each harness's Context facet.
///
/// This is the single authority for resolving a `(harness, scope, variant)`
/// tuple to a native context file path. The command resolver delegates here
/// rather than keeping a parallel per-harness switch: the harness identity is
/// the one carried by the descriptor's facet. User-scope roots come from the
/// shared [LifecycleContext], which implements the catalog's user-root
/// contract. Every unsupported tuple refuses the whole invocation with exit
/// code 4 before any target is written.
extension ContextHarnessTargetSpec on ContextHarnessSpec {
  /// Resolves one supported tuple, or throws an exit-4 refusal.
  String resolveTargetPath({
    required LifecycleContext context,
    required ContextScope scope,
    required ContextVariant variant,
    required String projectTargetDir,
  }) {
    final p = context.fs.path;
    return switch ((harness, scope, variant)) {
      (HarnessId.claude, ContextScope.project, ContextVariant.standard) =>
        p.join(projectTargetDir, 'CLAUDE.md'),
      (HarnessId.claude, ContextScope.project, ContextVariant.local) => p.join(
        projectTargetDir,
        'CLAUDE.local.md',
      ),
      (HarnessId.claude, ContextScope.project, ContextVariant.dotClaude) =>
        p.join(projectTargetDir, '.claude', 'CLAUDE.md'),
      (HarnessId.claude, ContextScope.user, ContextVariant.standard) => p.join(
        context.claudeConfigRoot(),
        'CLAUDE.md',
      ),
      (HarnessId.codex, ContextScope.project, ContextVariant.standard) =>
        p.join(projectTargetDir, 'AGENTS.md'),
      (HarnessId.codex, ContextScope.project, ContextVariant.override) =>
        p.join(projectTargetDir, 'AGENTS.override.md'),
      (HarnessId.codex, ContextScope.user, ContextVariant.standard) => p.join(
        context.codexRoot(),
        'AGENTS.md',
      ),
      (HarnessId.codex, ContextScope.user, ContextVariant.override) => p.join(
        context.codexRoot(),
        'AGENTS.override.md',
      ),
      (HarnessId.pi, ContextScope.project, ContextVariant.standard) => p.join(
        projectTargetDir,
        'AGENTS.md',
      ),
      (HarnessId.pi, ContextScope.project, ContextVariant.override) => p.join(
        projectTargetDir,
        'AGENTS.override.md',
      ),
      (HarnessId.pi, ContextScope.user, ContextVariant.standard) => p.join(
        context.piAgentRoot(),
        'AGENTS.md',
      ),
      (HarnessId.pi, ContextScope.user, ContextVariant.override) => p.join(
        context.piAgentRoot(),
        'AGENTS.override.md',
      ),
      _ => throw MambaException(
        'UNSUPPORTED_CONTEXT_VARIANT: Variant "${variant.wireName}" is not '
        'supported for harness "${harness.wireName}" at ${scope.name} scope.',
        exitCode: 4,
      ),
    };
  }
}
