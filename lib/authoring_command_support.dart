import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/lifecycle_state_service.dart';

typedef AuthoringConfirmation = Future<bool> Function(String prompt);

Future<bool> defaultAuthoringConfirmation(String prompt) async {
  stderr.write('$prompt [y/N] ');
  final answer = stdin.readLineSync()?.trim().toLowerCase();
  return answer == 'y' || answer == 'yes';
}

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
  required bool apply,
  required bool dryRun,
  required bool interactive,
  required LifecycleOutputFormat format,
}) {
  if (interactive && format == LifecycleOutputFormat.json) {
    throw MambaException('--interactive and --format json conflict.');
  }
  if (apply && dryRun) {
    throw MambaException('--apply and --dry-run conflict.');
  }
}

String renderAuthoringResult(
  LifecycleResult result,
  LifecycleOutputFormat format,
) => switch (format) {
  LifecycleOutputFormat.json => jsonEncode(result.envelope()),
  LifecycleOutputFormat.text => result.renderText(),
};
