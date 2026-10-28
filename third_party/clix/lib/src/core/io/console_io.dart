/// Console-based CLI input/output implementation using Dart console streams.
library;

import 'dart:io';
import 'cli_io.dart';

/// Closed input is distinct from a blank answer or a prompt default.
final class CliInputClosedException implements Exception {
  const CliInputClosedException();

  @override
  String toString() => 'The interactive input stream closed unexpectedly.';
}

class ConsoleIO implements CliIO {
  @override
  void write(String text) => stdout.write(text);

  @override
  void writeln([String text = '']) => stdout.writeln(text);

  @override
  String readLine() {
    final line = stdin.readLineSync();
    if (line == null) throw const CliInputClosedException();
    return line;
  }

  @override
  bool get isTTY => stdin.hasTerminal;
}
