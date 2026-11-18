import 'package:mamba/mamba.dart';

/// Encapsulates a numbered, line-based template selector behind one async
/// `render`.
final class ContextTemplateSelectorComponent {
  const ContextTemplateSelectorComponent({
    required this.options,
    this.label = 'Select a context template',
  });

  /// The stored template names offered in display order.
  final List<String> options;

  /// The question shown above the numbered choices.
  final String label;

  /// Returns the selected name, or null when the reader cancels.
  Future<String?> render() async =>
      ClixSelector(prompt: label, options: options).interact();
}
