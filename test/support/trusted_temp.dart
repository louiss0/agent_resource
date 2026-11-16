import 'dart:io';

/// Creates a host temporary directory and returns the path the storage reports.
///
/// A managed-storage guard refuses a linked ancestor on purpose, and a host
/// reaches its temporary root through an OS-level alias: macOS resolves
/// `/var` to `/private/var`, and a container or runner may mount `/tmp` the
/// same way. A sandbox built under the alias is refused before the guard ever
/// reaches the managed area, so the test reports the alias instead of the
/// behavior it exercises.
///
/// Canonicalizing the directory that the OS just created for this test keeps
/// the refusal meaningful: the fixture works on a real path while a linked
/// root that a caller supplies is still refused. Only a directory created
/// here is trusted this way; paths from test input, the environment or an
/// unknown root are never canonicalized.
Future<String> createTrustedTempPath(String prefix) async {
  final created = await Directory.systemTemp.createTemp(prefix);
  return created.resolveSymbolicLinks();
}

/// The synchronous form of [createTrustedTempPath].
String createTrustedTempPathSync(String prefix) =>
    Directory.systemTemp.createTempSync(prefix).resolveSymbolicLinksSync();
