import 'package:mamba/mamba.dart';

/// Clix text input for an omitted installation source. Blank cancels; the
/// patched ConsoleIO keeps EOF distinct as an exception.
final class InstallationSourceComponent {
  const InstallationSourceComponent({this.label = 'Resource source'});

  final String label;

  Future<String?> render() async {
    final value = await ClixInput(prompt: label).interact();
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
