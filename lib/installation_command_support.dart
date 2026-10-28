import 'dart:convert';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/installation/installation_request.dart';

String renderInstallationResult(
  InstallationWorkflowResult result,
  LifecycleOutputFormat format,
) => switch (result) {
  InstallationCancelledResult(command: final command) =>
    '$command: cancelled\nNo installation writes occurred.',
  InstallationCompletedResult(:final plan, :final outcome) => switch (format) {
    LifecycleOutputFormat.json => jsonEncode(plan.envelope(outcome)),
    LifecycleOutputFormat.text => plan.renderText(outcome),
  },
};
