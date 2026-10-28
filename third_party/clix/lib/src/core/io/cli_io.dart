/// Abstract CLI input/output interface
///
/// Defines the core interface for CLI input/output operations. This abstraction
/// allows for different implementations (console, mock, etc.) to be used
/// interchangeably throughout the CLI application.
///
/// Core methods:
/// - `write()`: Output text without newline
/// - `writeln()`: Output text with newline
/// - `readLine()`: Read user input
/// - `isTTY`: Check if running in terminal
///
/// Usage:
/// ```dart
/// CliIO io = ConsoleIO();
/// io.write('Enter name: ');
/// String name = io.readLine();
/// io.writeln('Hello $name');
/// ```
library;

abstract class CliIO {
  void write(String text);
  void writeln([String text = '']);
  String readLine();
  bool get isTTY;
}
