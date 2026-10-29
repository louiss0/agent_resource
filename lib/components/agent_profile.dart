import 'package:interact2/interact2.dart' as interact;

import 'prompt_support.dart';

final class AgentProfileComponent {
  const AgentProfileComponent({
    this.label = 'Native agent profile (Ctrl+C to cancel)',
    this.select,
  });

  final String label;
  final int Function(interact.Select)? select;

  Future<String?> render() async {
    const options = ['claude', 'codex', 'pi-common'];
    final prompt = interact.Select(prompt: label, options: options);
    final index = runPrompt(
      () => select == null ? prompt.interact() : select!(prompt),
    );
    return index < 0 ? null : options[index];
  }
}
