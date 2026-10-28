import 'package:mamba/mamba.dart';

/// Clix text input for an omitted installation source. Blank cancels.
/// Stock Clix EOF behavior is not a distinct cancellation signal.
final class InstallationSourceComponent {
  const InstallationSourceComponent({
    this.label = 'Resource source (Ctrl+C to cancel)',
  });

  final String label;

  Future<String?> render() async {
    final value = await ClixInput(prompt: label).interact();
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
