/// Confirmation Prompt - Yes/No questions with smart defaults
library;

import 'prompt.dart';
import '../core/io/cli_io.dart';
import '../core/style/theme.dart';

/// **Confirm Class - Yes/No confirmation prompt**
///
/// Boolean prompt for collecting yes/no decisions from users.
/// Provides smart default handling and multiple input format support.
class Confirm extends Prompt<bool> {
  /// **Prompt Text** - Question shown to user
  final String prompt;

  /// **Default Value** - Default choice when user provides empty input
  ///
  /// When `true`: Shows (Y/n) - Yes is default
  /// When `false`: Shows (y/N) - No is default
  /// When `null`: Shows (y/n) - No default, requires explicit choice
  final bool? defaultValue;

  /// **Constructor** - Create confirmation prompt
  ///
  /// ```dart
  /// // Requires explicit choice
  /// final confirm = Confirm(prompt: 'Are you sure?');
  ///
  /// // With default Yes
  /// final confirm = Confirm(prompt: 'Save file?', defaultValue: true);
  /// ```
  Confirm({required this.prompt, this.defaultValue});

  /// **Run Prompt** - Execute confirmation with user interaction
  @override
  Future<bool> run(CliIO io, CliTheme theme) async {
    // Build prompt with default indication
    String promptText = theme.primary(prompt).toString();

    if (defaultValue != null) {
      final defaultText = defaultValue! ? 'Y/n' : 'y/N';
      promptText = '$promptText ($defaultText)';
    } else {
      promptText = '$promptText (y/n)';
    }

    io.write('$promptText: ');
    final input = io.readLine().trim().toLowerCase();

    // Handle empty input with default
    bool result;
    if (input.isEmpty && defaultValue != null) {
      result = defaultValue!;
    } else {
      // Handle explicit input
      result = input == 'y' || input == 'yes';
    }

    // Show confirmation
    _showConfirmation(io, theme, result);
    return result;
  }

  void _showConfirmation(CliIO io, CliTheme theme, bool result) {
    // Clear the input line and show confirmation
    io.write('\x1B[1A\x1B[2K'); // Move up and clear line

    final checkmark = theme.success('✓');
    final question = theme.primary(prompt);
    final answer = theme.plain(result ? 'Yes' : 'No');

    io.writeln('$checkmark $question $answer');
  }
}
