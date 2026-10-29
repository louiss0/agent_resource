import 'dart:io';

import 'package:interact2/interact2.dart' as interact;

import 'prompt_support.dart';

final class InstallationApprovalComponent {
  const InstallationApprovalComponent({
    this.label = 'Apply this reviewed installation plan? (Ctrl+C to cancel)',
    this.confirm,
    this.hasTerminal,
  });

  final String label;
  final bool Function(interact.Confirm)? confirm;
  final bool Function()? hasTerminal;

  Future<bool> render() async {
    if (!(hasTerminal?.call() ?? (stdin.hasTerminal && stdout.hasTerminal))) {
      return false;
    }
    final prompt = interact.Confirm(
      prompt: label,
      defaultValue: false,
      waitForNewLine: true,
    );
    return runPrompt(
      () => confirm == null ? prompt.interact() : confirm!(prompt),
    );
  }
}
