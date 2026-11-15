import 'package:mamba/mamba.dart';

/// Encapsulates a Clix-backed prompt behind one async `render`.
final class GuidedValueComponent {
  const GuidedValueComponent({this.label = 'Project name'});

  /// The question shown to the reader.
  final String label;

  /// Shows the prompt and returns what the reader typed.
  ///
  /// Returns `null` when the reader submits a blank line.
  Future<String?> render() async {
    final value = await ClixInput(prompt: label).interact();
    return value.isEmpty ? null : value;
  }
}
