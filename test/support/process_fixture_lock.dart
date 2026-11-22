import 'dart:io';

import 'package:path/path.dart' as p;

/// Serializes compiled-CLI process fixtures across concurrent test suites.
///
/// The kernel artifact of each suite is private, but compiling and launching
/// the real executable is resource intensive. Under a loaded runner several
/// suites can compile and spawn at once, which makes the long process test
/// in `agent_list_test` timing sensitive. One host-wide lock file keeps that
/// fixture deterministic without changing what the test observes.
Future<T> withSerializedProcessFixture<T>(Future<T> Function() body) async {
  final lock = File(
    p.join(
      Directory.systemTemp.resolveSymbolicLinksSync(),
      'agent_resource_process_fixture.lock',
    ),
  );
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  while (true) {
    try {
      lock.createSync(exclusive: true);
      break;
    } on FileSystemException {
      try {
        final age = DateTime.now().difference(lock.statSync().modified);
        if (age > const Duration(minutes: 2)) {
          // A crashed test must not hold the fixture forever.
          lock.deleteSync();
        }
      } on FileSystemException {
        // Another waiter removed it first; the next loop retries.
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Timed out waiting for the CLI process fixture lock.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }
  try {
    return await body();
  } finally {
    if (lock.existsSync()) lock.deleteSync();
  }
}
