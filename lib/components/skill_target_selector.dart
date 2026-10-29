import 'package:interact2/interact2.dart' as interact;

import 'prompt_support.dart';

final class SkillTargetSelectorComponent {
  const SkillTargetSelectorComponent({
    required this.options,
    this.defaults = const <int>[],
    this.label = 'Select consuming harnesses (Ctrl+C to cancel)',
    this.select,
  });

  final List<String> options;
  final List<int> defaults;
  final String label;
  final List<int> Function(interact.MultiSelect)? select;

  Future<List<int>?> render() async {
    if (options.isEmpty) return [];
    final prompt = interact.MultiSelect(
      prompt: label,
      options: options,
      defaults: List.generate(
        options.length,
        (index) => defaults.contains(index),
      ),
    );
    return runPrompt(
      () => select == null ? prompt.interact() : select!(prompt),
    );
  }
}
