import 'dart:io';
import 'prompt.dart';
import '../core/io/cli_io.dart';
import '../core/style/theme.dart';

class Password extends Prompt<String> {
  final String prompt;
  final String? defaultValue;
  final String? Function(String)? validator;
  final bool confirmation;
  final String? confirmPrompt;
  final String? confirmError;

  Password({
    required this.prompt,
    this.defaultValue,
    this.validator,
    this.confirmation = false,
    this.confirmPrompt,
    this.confirmError,
  });

  @override
  Future<String> run(CliIO io, CliTheme theme) async {
    while (true) {
      // Get the main password
      final password = await _promptPassword(io, theme, prompt);

      // Validate the password if validator is provided
      if (validator != null) {
        final error = validator!(password);
        if (error != null) {
          io.writeln(theme.error(error));
          continue; // Ask for password again
        }
      }

      // If confirmation is required
      if (confirmation) {
        final confirmMsg =
            confirmPrompt ?? 'Confirm ${prompt.replaceAll(':', '')}';
        final confirmPassword = await _promptPassword(io, theme, confirmMsg);

        if (password != confirmPassword) {
          final error = confirmError ?? 'Passwords do not match';
          io.writeln(theme.error(error));
          continue; // Ask for both passwords again
        }
      }

      return password;
    }
  }

  /// Helper method to prompt for a single password
  Future<String> _promptPassword(
    CliIO io,
    CliTheme theme,
    String promptMessage,
  ) async {
    io.write('${theme.primary(promptMessage)}: ');

    // Save the terminal settings
    stdin.echoMode = false;
    stdin.lineMode = false;

    final password = StringBuffer();

    try {
      while (true) {
        final char = stdin.readByteSync();

        if (char == 10 || char == 13) {
          // Enter key
          break;
        } else if (char == 127 || char == 8) {
          // Backspace
          if (password.isNotEmpty) {
            final temp = password.toString();
            password.clear();
            password.write(temp.substring(0, temp.length - 1));
          }
        } else if (char >= 32 && char <= 126) {
          // Printable characters
          password.writeCharCode(char);
        }
      }
    } finally {
      // Restore terminal settings
      stdin.echoMode = true;
      stdin.lineMode = true;
    }

    io.writeln('');

    final result = password.toString();
    return result.isEmpty && defaultValue != null ? defaultValue! : result;
  }
}
