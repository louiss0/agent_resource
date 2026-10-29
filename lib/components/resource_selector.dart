import 'package:interact2/interact2.dart' as interact;

import 'prompt_support.dart';

/// Native checkbox selection. Ctrl+C is a process interrupt, not a typed
/// cancellation result; an empty list is never treated as approval.
final class ResourceSelectorComponent {
  const ResourceSelectorComponent({
    required this.options,
    this.label = 'Select resources (Ctrl+C to cancel)',
    this.select,
  });

  final List<String> options;
  final String label;
  final List<int> Function(interact.MultiSelect)? select;

  Future<List<int>?> render() async {
    if (options.isEmpty) return [];
    final prompt = interact.MultiSelect(prompt: label, options: options);
    return runPrompt(
      () => select == null ? prompt.interact() : select!(prompt),
    );
  }
}
