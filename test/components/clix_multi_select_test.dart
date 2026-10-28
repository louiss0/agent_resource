import 'dart:async';

import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

final class _Output implements CliIO {
  final buffer = StringBuffer();

  @override
  bool get isTTY => false;

  @override
  String readLine() => throw const CliInputClosedException();

  @override
  void write(String text) => buffer.write(text);

  @override
  void writeln([String text = '']) => buffer.writeln(text);
}

Stream<List<int>> _bytes(List<int> values) =>
    Stream<List<int>>.fromIterable([values]);

MultiSelect _select(List<int> bytes, {List<int> defaults = const []}) =>
    MultiSelect(
      prompt: 'Resources',
      options: const ['one', 'two'],
      defaults: defaults,
      input: _bytes(bytes),
    );

void main() {
  group('Clix MultiSelect', () {
    test('maps selected indices and preserves preselection', () async {
      expect(await _select([32, 27, 91, 66, 32, 13]).interact(_Output()), [
        0,
        1,
      ]);
      expect(await _select([13], defaults: [1]).interact(_Output()), [1]);
      expect(await _select([13]).interact(_Output()), isEmpty);
    });

    test('provides an explicit Select All action', () async {
      final output = _Output();
      final result = await _select([27, 91, 66, 27, 91, 66, 32, 13])
          .interact(output);
      expect(result, [0, 1]);
      expect(output.buffer.toString(), contains('[Select All]'));
      expect(output.buffer.toString(), contains('☑'));
    });

    for (final testCase in [
      (name: 'Escape', bytes: [27]),
      (name: 'Ctrl-C', bytes: [3]),
    ]) {
      test('${testCase.name} cancels instead of confirming', () async {
        final output = _Output();
        await expectLater(
          _select(testCase.bytes).interact(output),
          throwsA(isA<CliPromptCancelledException>()),
        );
        expect(output.buffer.toString(), contains('\x1B[?25h'));
      });
    }

    test('EOF fails and restores cursor visibility', () async {
      final output = _Output();
      await expectLater(
        _select(const []).interact(output),
        throwsA(isA<CliInputClosedException>()),
      );
      expect(output.buffer.toString(), contains('\x1B[?25h'));
    });
  });
}
