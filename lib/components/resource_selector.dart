import 'package:mamba/mamba.dart';

/// Native Clix checkbox selection. Null is explicit cancellation; an empty
/// list is an empty submission and is never treated as approval.
final class ResourceSelectorComponent {
  const ResourceSelectorComponent({
    required this.options,
    this.label = 'Select resources',
  });

  final List<String> options;
  final String label;

  Future<List<int>?> render() async {
    try {
      return await MultiSelect(prompt: label, options: options).interact();
    } on CliPromptCancelledException {
      return null;
    }
  }
}
