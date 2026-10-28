import 'package:mamba/mamba.dart';

/// Native stock-Clix checkbox selection. Ctrl+C is a process interrupt, not
/// a typed cancellation result; an empty list is never treated as approval.
final class ResourceSelectorComponent {
  const ResourceSelectorComponent({
    required this.options,
    this.label = 'Select resources (Ctrl+C to cancel)',
  });

  final List<String> options;
  final String label;

  Future<List<int>?> render() =>
      MultiSelect(prompt: label, options: options).interact();
}
