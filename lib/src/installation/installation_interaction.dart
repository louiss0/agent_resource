import 'dart:io';

import 'package:mamba/mamba.dart';

import '../../components/agent_profile.dart';
import '../../components/installation_approval.dart';
import '../../components/installation_source.dart';
import '../../components/resource_selector.dart';
import '../../components/skill_target_selector.dart';
import 'installation_plan.dart';
import 'resource_catalog.dart';

enum InteractionAnswerStatus { value, empty, cancelled }

final class InteractionAnswer<T> {
  const InteractionAnswer._(this.status, this.value);

  factory InteractionAnswer.value(T value) =>
      InteractionAnswer._(InteractionAnswerStatus.value, value);
  factory InteractionAnswer.empty() =>
      InteractionAnswer._(InteractionAnswerStatus.empty, null);
  factory InteractionAnswer.cancelled() =>
      InteractionAnswer._(InteractionAnswerStatus.cancelled, null);

  final InteractionAnswerStatus status;
  final T? value;
}

/// Typed interaction seam. Display strings and raw indices never cross it.
abstract interface class InstallationInteraction {
  bool get isInteractive;

  Future<InteractionAnswer<String>> requestSource();

  Future<InteractionAnswer<List<CatalogOffering>>> selectResources(
    List<CatalogOffering> offerings,
  );

  Future<InteractionAnswer<List<InstallationTarget>>> selectTargets(
    List<InstallationTarget> compatible,
    Set<InstallationTarget> detected,
  );

  Future<InteractionAnswer<NativeAgentProfile>> requestAgentProfile();

  void presentPlan(String completePlanPreview);

  Future<InteractionAnswer<bool>> approve(String completePlanPreview);
}

final class ClixInstallationInteraction implements InstallationInteraction {
  ClixInstallationInteraction({bool Function()? terminal})
    : _terminal = terminal ?? (() => stdin.hasTerminal && stdout.hasTerminal);

  final bool Function() _terminal;

  @override
  bool get isInteractive => _terminal();

  @override
  Future<InteractionAnswer<String>> requestSource() => _guard(() async {
    final source = await const InstallationSourceComponent().render();
    return source == null
        ? InteractionAnswer.cancelled()
        : InteractionAnswer.value(source);
  });

  @override
  Future<InteractionAnswer<List<CatalogOffering>>> selectResources(
    List<CatalogOffering> offerings,
  ) => _guard(() async {
    final selected = await ResourceSelectorComponent(
      options: [for (final offering in offerings) _offeringLabel(offering)],
    ).render();
    if (selected == null) return InteractionAnswer.cancelled();
    if (selected.isEmpty) return InteractionAnswer.empty();
    return InteractionAnswer.value([
      for (final index in selected) offerings[index],
    ]);
  });

  @override
  Future<InteractionAnswer<List<InstallationTarget>>> selectTargets(
    List<InstallationTarget> compatible,
    Set<InstallationTarget> detected,
  ) async {
    final preselected = compatible.where(detected.contains).toList();
    if (preselected.length == 1) {
      return InteractionAnswer.value(preselected);
    }
    return _guard(() async {
      final selected = await SkillTargetSelectorComponent(
        options: [for (final target in compatible) target.name],
        defaults: [
          for (var index = 0; index < compatible.length; index++)
            if (detected.contains(compatible[index])) index,
        ],
      ).render();
      if (selected == null) return InteractionAnswer.cancelled();
      if (selected.isEmpty) return InteractionAnswer.empty();
      return InteractionAnswer.value([
        for (final index in selected) compatible[index],
      ]);
    });
  }

  @override
  Future<InteractionAnswer<NativeAgentProfile>> requestAgentProfile() =>
      _guard(() async {
        final profile = await const AgentProfileComponent().render();
        if (profile == null) return InteractionAnswer.cancelled();
        return InteractionAnswer.value(
          NativeAgentProfile.values.singleWhere(
            (candidate) => candidate.wireName == profile,
          ),
        );
      });

  @override
  void presentPlan(String completePlanPreview) {
    stdout.writeln(completePlanPreview);
  }

  @override
  Future<InteractionAnswer<bool>> approve(String completePlanPreview) =>
      _guard(() async {
        return InteractionAnswer.value(
          await const InstallationApprovalComponent().render(),
        );
      });

  Future<InteractionAnswer<T>> _guard<T>(
    Future<InteractionAnswer<T>> Function() body,
  ) async {
    try {
      return await body();
    } on CliInputClosedException {
      throw MambaException(
        'Interactive input closed unexpectedly; no installation was approved.',
      );
    }
  }
}

String _offeringLabel(CatalogOffering offering) {
  final label = offering.label == null ? '' : ' — ${offering.label}';
  final profile = offering is AgentOffering
      ? ' [${offering.profile.wireName}]'
      : '';
  return '${offering.id}$label ($profile${offering.path})'.replaceAll(
    RegExp(r'[\x00-\x1F\x7F]'),
    '?',
  );
}
