import 'package:mamba/mamba.dart';

final class SkillTargetSelectorComponent {
  const SkillTargetSelectorComponent({
    required this.options,
    this.defaults = const <int>[],
    this.label = 'Select consuming harnesses',
  });

  final List<String> options;
  final List<int> defaults;
  final String label;

  Future<List<int>?> render() async {
    try {
      return await MultiSelect(
        prompt: label,
        options: options,
        defaults: defaults,
      ).interact();
    } on CliPromptCancelledException {
      return null;
    }
  }
}
