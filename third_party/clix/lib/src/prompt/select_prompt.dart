/// Selection Prompt - Interactive single-choice menu
library;

import 'dart:io';
import 'prompt.dart';
import '../core/io/cli_io.dart';
import '../core/style/theme.dart';

/// **Select Class - Single selection menu prompt**
///
/// Interactive menu allowing users to select one option from a list using arrow keys.
/// Returns the index of the selected option for flexible result handling.
class Select extends Prompt<int> {
  /// **Prompt Text** - Instructions or question shown above menu
  final String prompt;

  /// **Options List** - Available choices for selection
  final List<String> options;

  /// **Default Index** - Initially selected option (0-based index)
  final int defaultIndex;

  /// **Constructor** - Create selection prompt with options
  ///
  /// ```dart
  /// final select = Select(
  ///   prompt: 'Choose option:',
  ///   options: ['Option 1', 'Option 2', 'Option 3'],
  ///   defaultIndex: 1, // Start with Option 2 selected
  /// );
  /// ```
  Select({required this.prompt, required this.options, this.defaultIndex = 0});

  /// **Run Prompt** - Execute interactive selection
  @override
  Future<int> run(CliIO io, CliTheme theme) async {
    io.writeln(theme.primary(prompt));

    int selectedIndex = defaultIndex;

    // Enable raw mode for capturing arrow keys
    stdin.echoMode = false;
    stdin.lineMode = false;

    try {
      while (true) {
        _renderOptions(io, theme, selectedIndex);

        final input = stdin.readByteSync();

        if (input == 27) {
          // Escape sequence (arrow keys)
          final next1 = stdin.readByteSync();
          final next2 = stdin.readByteSync();

          if (next1 == 91) {
            if (next2 == 65) {
              // Up arrow
              selectedIndex =
                  (selectedIndex - 1 + options.length) % options.length;
            } else if (next2 == 66) {
              // Down arrow
              selectedIndex = (selectedIndex + 1) % options.length;
            }
          }
        } else if (input == 10 || input == 13) {
          // Enter key
          _showConfirmation(io, theme, selectedIndex, options[selectedIndex]);
          return selectedIndex;
        }
      }
    } finally {
      stdin.echoMode = true;
      stdin.lineMode = true;
    }
  }

  void _renderOptions(CliIO io, CliTheme theme, int selectedIndex) {
    // Move cursor up to redraw options
    io.write('\x1B[${options.length}A');

    // Render options
    for (int i = 0; i < options.length; i++) {
      // Clear the line first
      io.write('\x1B[2K');

      final isSelected = i == selectedIndex;
      final prefix = isSelected ? '❯' : ' ';
      final option = options[i];

      if (isSelected) {
        io.writeln('  ${theme.primary(prefix)} ${theme.primary(option)}');
      } else {
        io.writeln('  $prefix $option');
      }
    }
  }

  void _showConfirmation(
    CliIO io,
    CliTheme theme,
    int selectedIndex,
    String selectedOption,
  ) {
    // Move up to prompt line and clear everything below
    io.write('\x1B[${options.length + 1}A\x1B[2K');

    final checkmark = theme.success('✓');
    final question = theme.primary(prompt);
    final answer = theme.plain(selectedOption);

    io.writeln('$checkmark $question $answer');
  }
}
