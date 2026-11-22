import 'dart:io';

import 'package:test/test.dart';

final _auditId = RegExp(r'PA-\d+\.\d+');
final _evidenceEntry = RegExp('`(test/[^`]+_test\\.dart)`\\s*—\\s*`([^`]+)`');
final _row = RegExp(
  r'^\|\s*(PA-\d+\.\d+)\s*\|\s*#\d+\s*\|(.+)\|\s*([^|]+?)\s*\|\s*$',
  multiLine: true,
);

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('release qualification audit index', () {
    test('every audit finding ID appears in the evidence table', () {
      final auditIds = _auditId
          .allMatches(_read('docs/product-audit.md'))
          .map((match) => match.group(0)!)
          .toSet();
      expect(
        auditIds,
        isNotEmpty,
        reason: 'product-audit.md must carry PA-x.y finding IDs',
      );
      final tableIds = _row
          .allMatches(_read('docs/release-qualification.md'))
          .map((match) => match.group(1)!)
          .toSet();
      final missing = auditIds.difference(tableIds);
      expect(
        missing,
        isEmpty,
        reason:
            'Audit findings missing from the release-qualification '
            'evidence table: ${missing.join(', ')}',
      );
      final extra = tableIds.difference(auditIds);
      expect(
        extra,
        isEmpty,
        reason: 'Evidence table cites unknown audit IDs: ${extra.join(', ')}',
      );
    });

    test('every cited regression test file and name exists', () {
      final rows = _row.allMatches(_read('docs/release-qualification.md'));
      expect(rows, isNotEmpty);
      final failures = <String>[];
      for (final match in rows) {
        final id = match.group(1)!;
        final cell = match.group(2)!;
        final status = match.group(3)!.trim();
        expect(
          const {'resolved', 'intentional boundary'},
          contains(status),
          reason: '$id has unrecognized status "$status"',
        );
        final entries = _evidenceEntry.allMatches(cell).toList();
        expect(
          entries,
          isNotEmpty,
          reason: '$id cites no `test/..._test.dart` — `name` pairs',
        );
        for (final entry in entries) {
          final file = File(entry.group(1)!);
          if (!file.existsSync()) {
            failures.add('$id: missing file ${entry.group(1)}');
            continue;
          }
          final name = entry.group(2)!;
          if (!file.readAsStringSync().contains(name)) {
            failures.add('$id: ${entry.group(1)} has no test named "$name"');
          }
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  });
}
