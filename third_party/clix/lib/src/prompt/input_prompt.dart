/// Input Prompt - Text input with validation and defaults
library;

import 'prompt.dart';
import '../core/io/cli_io.dart';
import '../core/style/theme.dart';

/// **Input Class - Text input prompt with validation**
///
/// Collects text input from users with optional validation and default values.
/// Extends the base Prompt class to provide string input functionality.
class Input extends Prompt<String> {
  /// **Prompt Text** - Question or instruction shown to user
  final String prompt;

  /// **Default Value** - Value used when user provides empty input
  final String? defaultValue;

  /// **Validator Function** - Optional validation with error messages
  ///
  /// Return `null` for valid input, or error message string for invalid input:
  /// ```dart
  /// validator: (value) {
  ///   if (value.length < 3) return 'Must be at least 3 characters';
  ///   if (value.contains('@')) return 'Email addresses not allowed';
  ///   return null; // Valid
  /// }
  /// ```
  final String? Function(String)? validator;

  /// **Constructor** - Create input prompt with optional features
  ///
  /// ```dart
  /// // Basic prompt
  /// final input = Input(prompt: 'Enter value');
  ///
  /// // With default and validation
  /// final input = Input(
  ///   prompt: 'Enter username',
  ///   defaultValue: 'guest',
  ///   validator: (v) => v.length < 3 ? 'Too short' : null,
  /// );
  /// ```
  Input({required this.prompt, this.defaultValue, this.validator});

  /// **Run Prompt** - Execute the input prompt with user interaction
  ///
  /// Displays the prompt, collects user input, validates it, and returns the result.
  /// Automatically retries on validation failures until valid input is provided.
  @override
  Future<String> run(CliIO io, CliTheme theme) async {
    while (true) {
      var promptText = theme.primary(prompt);
      if (defaultValue != null) {
        promptText = '$promptText [$defaultValue]';
      }

      io.write('$promptText: ');
      final input = io.readLine().trim();

      final value = input.isEmpty && defaultValue != null
          ? defaultValue!
          : input;

      if (validator != null) {
        final error = validator!(value);
        if (error != null) {
          io.writeln(theme.error(error));
          continue;
        }
      }

      // Show confirmation by replacing the prompt line
      _showConfirmation(io, theme, value, promptText);
      return value;
    }
  }

  void _showConfirmation(
    CliIO io,
    CliTheme theme,
    String result,
    String originalPrompt,
  ) {
    // Clear the input line and show confirmation (same as Confirm prompt)
    io.write('\x1B[1A\x1B[2K'); // Move up and clear line

    final checkmark = theme.success('✓');
    final question = theme.primary(prompt);
    final answer = theme.plain(result);

    io.writeln('$checkmark $question $answer');
  }
}
