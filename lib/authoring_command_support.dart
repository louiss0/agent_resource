import 'dart:convert';

import 'package:mamba/mamba.dart';

import 'components/installation_approval.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/harness/harness_id.dart';
import 'src/services/lifecycle_state_service.dart';

typedef AuthoringConfirmation = Future<bool> Function(String prompt);

/// The harness spelling of the native target of an authoring request.
///
/// It overrides the request's `target.harness` without changing the request
/// document; an omitted flag keeps the reviewed request authoritative.
final authoringHarnessOption = ChoiceOption(
  'harness',
  choices: HarnessId.values,
  description: 'The harness whose native target is authored or converted.',
);

String? authoringHarnessOverride(ValueOf valueOf) =>
    valueOf(authoringHarnessOption)?.wireName;

Future<bool> defaultAuthoringConfirmation(String prompt) =>
    InstallationApprovalComponent(label: prompt).render();

String selectOperationRequest(String? positional, String? named) {
  if (positional != null && named != null) {
    throw MambaException(
      'Provide the request positionally or with --request, not both.',
    );
  }
  final selected = positional ?? named;
  if (selected == null) {
    throw MambaException('An operation request is required.');
  }
  return selected;
}

void validateAuthoringMode({
  required bool interactive,
  required LifecycleOutputFormat format,
}) {
  if (interactive && format == LifecycleOutputFormat.json) {
    throw MambaException('--interactive and --format json conflict.');
  }
}

String renderAuthoringResult(
  LifecycleResult result,
  LifecycleOutputFormat format,
) => switch (format) {
  LifecycleOutputFormat.json => jsonEncode(result.envelope()),
  LifecycleOutputFormat.text => result.renderText(),
};
