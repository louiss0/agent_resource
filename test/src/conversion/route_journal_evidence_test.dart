import 'dart:convert';

import 'package:agent_resource/src/conversion/route_journal_evidence.dart';
import 'package:path/path.dart' as p;
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:test/test.dart';

import 'installation_path_diff_test.dart' as fixture;

void main() {
  test('round trips typed old and new path and action evidence', () {
    final doc = evidence();
    expect(RouteJournalEvidence.decode(jsonEncode(doc), p.posix).toJson(), doc);
  });
  test('rejects malformed, duplicate and mismatched evidence', () {
    void rejected(void Function(Map<String, Object?>) change) {
      final doc = evidence();
      change(doc);
      expect(
        () => RouteJournalEvidence.decode(jsonEncode(doc), p.posix),
        throwsFormatException,
      );
    }

    rejected((d) => d['extra'] = true);
    rejected(
      (d) =>
          (((d['newRecords'] as List).first as Map)['installationRoute']
                  as Map)['sourceRelativePath'] =
              'other',
    );
    rejected((d) => d['phase'] = 'committed');
    rejected((d) => d['completedActions'] = ['1-publish']);
    rejected((d) => d['completedActions'] = ['0-remove', '0-remove']);
    rejected((d) => (d['actions'] as List).add((d['actions'] as List).first));
    rejected(
      (d) => ((d['actions'] as List).first as Map)['oldKind'] = 'skillLink',
    );
    rejected((d) => ((d['actions'] as List).first as Map)['path'] = '/foreign');
    rejected(
      (d) => (d['oldRecords'] as List).add((d['oldRecords'] as List).first),
    );
    rejected(
      (d) => ((d['oldRecords'] as List).first as Map)['location'] =
          '/old/../foreign',
    );
    rejected(
      (d) => ((d['oldRecords'] as List).first as Map)['surprise'] = true,
    );
  });
  test('rejects unrelated records and invalid action progress', () {
    final doc = evidence();
    ((doc['newRecords'] as List).first as Map)['name'] = 'other';
    expect(
      () => RouteJournalEvidence.decode(jsonEncode(doc), p.posix),
      throwsFormatException,
    );
    final valid = evidence();
    valid['phase'] = 'applying';
    valid['completedActions'] = ['0-remove'];
    expect(
      RouteJournalEvidence.decode(jsonEncode(valid), p.posix).toJson(),
      valid,
    );
    valid['phase'] = 'published';
    expect(
      () => RouteJournalEvidence.decode(jsonEncode(valid), p.posix),
      throwsFormatException,
    );
  });
  test('retains both typed sides of an in-place replacement', () {
    final doc = evidence();
    final next = (doc['newRecords'] as List).first as Map;
    next['location'] = '/old/skill';
    next['nativeRoot'] = '/old';
    next['artifactKind'] = 'skill-link';
    next['installationRoute'] = fixture
        .route(InstallationMethod.sourceLink)
        .toJson();
    doc['actions'] = [
      {'path': '/old/skill', 'oldKind': 'skillCopy', 'newKind': 'skillLink'},
    ];
    doc['phase'] = 'published';
    doc['completedActions'] = ['0-remove', '0-publish'];
    expect(RouteJournalEvidence.decode(jsonEncode(doc), p.posix).toJson(), doc);
  });
  test('validates durable reverse prefix and rollback phases', () {
    final doc = evidence();
    doc['completedActions'] = ['0-remove', '1-publish'];
    doc['phase'] = 'rollingBack';
    doc['rolledBackActions'] = ['1-publish'];
    expect(RouteJournalEvidence.decode(jsonEncode(doc), p.posix).toJson(), doc);
    void rejected(Object? value, String phase) {
      doc['rolledBackActions'] = value;
      doc['phase'] = phase;
      expect(
        () => RouteJournalEvidence.decode(jsonEncode(doc), p.posix),
        throwsFormatException,
      );
    }

    rejected(null, 'rollingBack');
    rejected(['0-remove'], 'rollingBack');
    rejected(['1-publish', '1-publish'], 'rollingBack');
    rejected(['1-publish', '0-remove', '0-remove'], 'rollingBack');
    rejected(['1-publish'], 'rolledBack');
    rejected([], 'published');
    rejected([], 'committed');
    doc.remove('rolledBackActions');
    doc['phase'] = 'rolledBack';
    expect(
      () => RouteJournalEvidence.decode(jsonEncode(doc), p.posix),
      throwsFormatException,
    );
    doc['rolledBackActions'] = ['1-publish', '0-remove'];
    expect(RouteJournalEvidence.decode(jsonEncode(doc), p.posix).toJson(), doc);
  });
  test('rejects duplicate JSON object keys', () {
    final encoded = jsonEncode(evidence()).replaceFirst(
      '"phase":"prepared"',
      '"phase":"committed","phase":"prepared"',
    );
    expect(
      () => RouteJournalEvidence.decode(encoded, p.posix),
      throwsFormatException,
    );
  });
}

Map<String, Object?> evidence() {
  final old = fixture.oldRecord(id: 'ins_${'a' * 32}').toJson();
  final next = {
    ...(jsonDecode(jsonEncode(old)) as Map<String, dynamic>),
    'installationId': 'ins_${'b' * 32}',
    'location': '/new/skill',
    'nativeRoot': '/new',
  };
  return {
    'schemaVersion': 1,
    'operation': 'cross-route',
    'transactionId': 'trx_${'c' * 32}',
    'scope': 'project',
    'phase': 'prepared',
    'oldRecords': [old],
    'newRecords': [next],
    'actions': [
      {'path': '/old/skill', 'oldKind': 'skillCopy', 'newKind': null},
      {'path': '/new/skill', 'oldKind': null, 'newKind': 'skillCopy'},
    ],
    'completedActions': <String>[],
  };
}
