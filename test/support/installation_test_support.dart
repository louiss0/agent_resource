import 'package:agent_resource/src/installation/installation_interaction.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/installation/resource_catalog.dart';

Future<T> noInstallationProgress<T>(String label, Future<T> Function() work) =>
    work();

final class ScriptedInstallationInteraction implements InstallationInteraction {
  ScriptedInstallationInteraction({this.interactive = true});

  final bool interactive;
  final sources = <String?>[];
  final resourceSelections = <List<String>>[];
  final targetSelections = <List<InstallationTarget>>[];
  final profiles = <NativeAgentProfile?>[];
  final approvals = <bool>[];
  final presentedPlans = <String>[];

  @override
  bool get isInteractive => interactive;

  @override
  Future<InteractionAnswer<String>> requestSource() async {
    final answer = sources.removeAt(0);
    return answer == null
        ? InteractionAnswer.cancelled()
        : InteractionAnswer.value(answer);
  }

  @override
  Future<InteractionAnswer<List<CatalogOffering>>> selectResources(
    List<CatalogOffering> offerings,
  ) async {
    final ids = resourceSelections.removeAt(0);
    if (ids.isEmpty) return InteractionAnswer.empty();
    return InteractionAnswer.value([
      for (final id in ids)
        offerings.singleWhere((offering) => offering.id == id),
    ]);
  }

  @override
  Future<InteractionAnswer<List<InstallationTarget>>> selectTargets(
    List<InstallationTarget> compatible,
    Set<InstallationTarget> detected,
  ) async {
    final targets = targetSelections.removeAt(0);
    if (targets.isEmpty) return InteractionAnswer.empty();
    return InteractionAnswer.value(targets);
  }

  @override
  Future<InteractionAnswer<NativeAgentProfile>> requestAgentProfile() async {
    final profile = profiles.removeAt(0);
    return profile == null
        ? InteractionAnswer.cancelled()
        : InteractionAnswer.value(profile);
  }

  @override
  void presentPlan(String completePlanPreview) {
    presentedPlans.add(completePlanPreview);
  }

  @override
  Future<InteractionAnswer<bool>> approve(String completePlanPreview) async =>
      InteractionAnswer.value(approvals.removeAt(0));
}
