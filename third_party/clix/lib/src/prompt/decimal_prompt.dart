import 'prompt.dart';
import '../core/io/cli_io.dart';
import '../core/style/theme.dart';

class Decimal extends Prompt<double> {
  final String prompt;
  final double? min;
  final double? max;
  final double? defaultValue;

  Decimal({required this.prompt, this.min, this.max, this.defaultValue});

  @override
  Future<double> run(CliIO io, CliTheme theme) async {
    while (true) {
      var promptText = theme.primary(prompt);
      if (min != null || max != null) {
        final range = 'Range: ${min ?? '-∞'} to ${max ?? '∞'}';
        promptText = '$promptText ($range)';
      }
      if (defaultValue != null) {
        promptText = '$promptText [$defaultValue]';
      }

      io.write('$promptText: ');
      final input = io.readLine().trim();

      if (input.isEmpty && defaultValue != null) {
        // Show confirmation for default value
        _showConfirmation(io, theme, defaultValue!);
        return defaultValue!;
      }

      final value = double.tryParse(input);

      if (value == null) {
        io.writeln(theme.error('Invalid decimal number. Please try again.'));
        continue;
      }

      if (min != null && value < min!) {
        io.writeln(theme.error('Number must be at least $min'));
        continue;
      }

      if (max != null && value > max!) {
        io.writeln(theme.error('Number must be at most $max'));
        continue;
      }

      // Show confirmation
      _showConfirmation(io, theme, value);
      return value;
    }
  }

  void _showConfirmation(CliIO io, CliTheme theme, double result) {
    // Clear the input line and show confirmation
    io.write('\x1B[1A\x1B[2K'); // Move up and clear line

    final checkmark = theme.success('✓');
    final question = theme.primary(prompt);
    final answer = theme.plain(result.toString());

    io.writeln('$checkmark $question $answer');
    io.writeln(''); // Add extra line to prevent deletion by next output
  }
}
