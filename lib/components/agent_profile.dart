import 'package:mamba/mamba.dart';

final class AgentProfileComponent {
  const AgentProfileComponent({this.label = 'Native agent profile'});

  final String label;

  Future<String?> render() async {
    final value = await ClixInput(
      prompt: '$label (claude, codex, pi-common)',
      validator: (value) =>
          value.trim().isEmpty ||
              const {'claude', 'codex', 'pi-common'}.contains(value)
          ? null
          : 'Choose claude, codex, or pi-common.',
    ).interact();
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
