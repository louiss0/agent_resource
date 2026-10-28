import 'package:mamba/mamba.dart';

final class AgentProfileComponent {
  const AgentProfileComponent({
    this.label = 'Native agent profile (Ctrl+C to cancel)',
  });

  final String label;

  Future<String?> render() =>
      Select(
        prompt: label,
        options: const ['claude', 'codex', 'pi-common'],
      ).interact().then(
        (index) =>
            index < 0 ? null : const ['claude', 'codex', 'pi-common'][index],
      );
}
