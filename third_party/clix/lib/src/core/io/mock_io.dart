/// Mock CLI input/output implementation for testing
///
/// Provides a fake I/O implementation that captures output in memory and
/// returns predefined responses for input operations. Essential for testing
/// CLI applications without actual console interaction.
///
/// Features:
/// - Output capture in memory buffer
/// - Predefined input responses queue
/// - No actual console interaction
/// - Always returns false for isTTY
///
/// Usage:
/// ```dart
/// final mockIO = MockIO();
/// mockIO.responses.addAll(['yes', 'John']);
///
/// mockIO.writeln('Are you ready?');
/// String answer = mockIO.readLine(); // Returns 'yes'
///
/// // Check captured output
/// print(mockIO.buffer); // ['Are you ready?']
/// ```
library;

import 'cli_io.dart';

class MockIO implements CliIO {
  final buffer = <String>[];
  final responses = <String>[];

  @override
  void write(String text) => buffer.add(text);

  @override
  void writeln([String text = '']) => buffer.add(text);

  @override
  String readLine() => responses.isNotEmpty ? responses.removeAt(0) : '';

  @override
  bool get isTTY => false;
}
