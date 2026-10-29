import 'package:interact2/interact2.dart' as interact;

import 'prompt_support.dart';

/// Text input for an omitted installation source. Blank cancels.
final class InstallationSourceComponent {
  const InstallationSourceComponent({
    this.label = 'Resource source (Ctrl+C to cancel)',
    this.input,
  });

  final String label;
  final String Function(interact.Input)? input;

  Future<String?> render() async {
    final prompt = interact.Input(prompt: label);
    final value = runPrompt(
      () => input == null ? prompt.interact() : input!(prompt),
    );
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
