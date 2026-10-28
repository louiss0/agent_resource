import 'dart:async';
import 'dart:io';

import 'prompt.dart';
import '../core/io/cli_io.dart';
import '../core/io/console_io.dart';
import '../core/style/theme.dart';

/// Escape or Ctrl-C cancels without confirming the current selection.
final class CliPromptCancelledException implements Exception {
  const CliPromptCancelledException();

  @override
  String toString() => 'The interactive selection was cancelled.';
}

class MultiSelect extends Prompt<List<int>> {
  final String prompt;
  final List<String> options;
  final List<int> defaults;
  final bool help;

  /// Optional raw byte stream for deterministic component tests. Production
  /// uses stdin and restores its exact prior terminal modes.
  final Stream<List<int>>? input;

  MultiSelect({
    required this.prompt,
    required this.options,
    this.defaults = const [],
    this.help = true,
    this.input,
  });

  @override
  Future<List<int>> run(CliIO io, CliTheme theme) async {
    if (options.isEmpty) return const <int>[];
    final bytes = StreamIterator<int>(
      (input ?? stdin).expand((chunk) => chunk),
    );
    final manageTerminal = input == null;
    var previousEcho = true;
    var previousLine = true;
    if (manageTerminal) {
      previousEcho = stdin.echoMode;
      previousLine = stdin.lineMode;
      stdin.echoMode = false;
      stdin.lineMode = false;
    }
    io.write('\x1B[?25l');
    var rendered = false;
    try {
      io.writeln(theme.primary(prompt));
      if (help) {
        io.writeln(
          theme.primary(
            '(↑/↓ navigate, Space toggle/Select All, Enter confirm, Esc cancel)',
          ),
        );
      }
      var currentIndex = 0;
      final selected = List<bool>.generate(
        options.length,
        (index) => defaults.contains(index),
      );
      while (true) {
        _renderOptions(io, theme, currentIndex, selected, moveUp: rendered);
        rendered = true;
        final byte = await _readByte(bytes);
        if (byte == 3) throw const CliPromptCancelledException();
        if (byte == 27) {
          // Escape starts an arrow sequence; a standalone Escape cancels.
          final int next;
          try {
            next = await _readByte(
              bytes,
              timeout: const Duration(milliseconds: 50),
            );
          } on TimeoutException {
            throw const CliPromptCancelledException();
          } on CliInputClosedException {
            throw const CliPromptCancelledException();
          }
          if (next != 91) throw const CliPromptCancelledException();
          final direction = await _readByte(bytes);
          final count = options.length + 1;
          if (direction == 65) {
            currentIndex = (currentIndex - 1 + count) % count;
          } else if (direction == 66) {
            currentIndex = (currentIndex + 1) % count;
          }
        } else if (byte == 32) {
          if (currentIndex == options.length) {
            final all = !selected.every((value) => value);
            selected.setAll(0, List<bool>.filled(options.length, all));
          } else {
            selected[currentIndex] = !selected[currentIndex];
          }
        } else if (byte == 10 || byte == 13) {
          _clearOptions(io);
          final result = <int>[
            for (var index = 0; index < options.length; index++)
              if (selected[index]) index,
          ];
          _showConfirmation(io, theme, result);
          return result;
        }
      }
    } on Exception {
      _clearOptions(io);
      rethrow;
    } finally {
      await bytes.cancel();
      io.write('\x1B[?25h');
      if (manageTerminal) {
        stdin.echoMode = previousEcho;
        stdin.lineMode = previousLine;
      }
    }
  }

  Future<int> _readByte(StreamIterator<int> bytes, {Duration? timeout}) async {
    final future = bytes.moveNext();
    final hasByte = timeout == null
        ? await future
        : await future.timeout(timeout);
    if (!hasByte) throw const CliInputClosedException();
    return bytes.current;
  }

  void _renderOptions(
    CliIO io,
    CliTheme theme,
    int currentIndex,
    List<bool> selected, {
    required bool moveUp,
  }) {
    final count = options.length + 1;
    if (moveUp) io.write('\x1B[${count + 2}A');
    io.write('\x1B[2K');
    io.writeln(theme.primary(prompt));
    if (help) {
      io.write('\x1B[2K');
      io.writeln(
        theme.primary(
          '(↑/↓ navigate, Space toggle/Select All, Enter confirm, Esc cancel)',
        ),
      );
    }
    for (var index = 0; index < count; index++) {
      io.write('\x1B[2K');
      final current = index == currentIndex;
      final pointer = current ? '❯' : ' ';
      if (index == options.length) {
        io.writeln('  $pointer [Select All]');
        continue;
      }
      final checkbox = selected[index] ? '☑' : '☐';
      final option = options[index];
      io.writeln(
        current
            ? '  ${theme.primary(pointer)} ${theme.primary(checkbox)} ${theme.primary(option)}'
            : '  $pointer $checkbox $option',
      );
    }
  }

  void _clearOptions(CliIO io) {
    final lines = options.length + 3;
    for (var index = 0; index < lines; index++) {
      io.write('\x1B[2K\x1B[1A');
    }
  }

  void _showConfirmation(CliIO io, CliTheme theme, List<int> selectedIndices) {
    final checkmark = theme.success('✓');
    final question = theme.primary(prompt);
    final answer = selectedIndices.isEmpty
        ? 'None selected'
        : selectedIndices.map((index) => options[index]).join(', ');
    io.writeln('$checkmark $question ${theme.plain(answer)}');
  }
}
