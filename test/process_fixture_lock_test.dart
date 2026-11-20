import 'dart:async';

import 'package:test/test.dart';

import 'support/process_fixture_lock.dart';

void main() {
  test('process fixture lock keeps two fixtures from overlapping', () async {
    final entered = <int>[];
    final firstStarted = Completer<void>();
    final firstGate = Completer<void>();

    final first = withSerializedProcessFixture(() async {
      entered.add(1);
      if (!firstStarted.isCompleted) firstStarted.complete();
      await firstGate.future;
      entered.add(1);
    });
    await firstStarted.future;

    final secondStarted = Completer<void>();
    final second = withSerializedProcessFixture(() async {
      entered.add(2);
      if (!secondStarted.isCompleted) secondStarted.complete();
    });
    // The first fixture still holds the lock, so the second cannot enter.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(secondStarted.isCompleted, isFalse);
    firstGate.complete();
    await secondStarted.future;
    await Future.wait<Object?>(<Future<Object?>>[first, second]);
    expect(entered, <int>[1, 1, 2]);
  });
}
