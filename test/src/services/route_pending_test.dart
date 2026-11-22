import 'dart:convert';

import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

import '../conversion/route_journal_evidence_test.dart' as fixture;

void main() {
  late MemoryFileSystem fs;
  late LifecycleContext context;
  late LifecycleStateService service;
  late Map<String, Object?> document;
  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/project').createSync();
    context = LifecycleContext.resolve(
      const LifecycleOptions(processWorkingDirectory: '/project'),
      fileSystem: fs,
    );
    service = LifecycleStateService(io: LifecycleIO(fs: fs));
    document = fixture.evidence();
  });
  void write(String value) {
    final file = fs.file(
      '${context.stateRoot()}/transactions/${document['transactionId']}.json',
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(value);
  }

  test('pending route journal reserves its non-anchor destination', () {
    write(jsonEncode(document));
    expect(
      () => service.checkPendingMutations(
        context,
        locations: ['/new/skill/child'],
      ),
      throwsA(isA<Exception>()),
    );
  });
  test('pending route journal reserves both installation identities', () {
    write(jsonEncode(document));
    for (final id in ['ins_${'a' * 32}', 'ins_${'b' * 32}']) {
      expect(
        () => service.checkPendingConversions(context, installationIds: {id}),
        throwsA(isA<Exception>()),
      );
    }
    service.checkPendingConversions(
      context,
      installationIds: {'ins_${'d' * 32}'},
    );
  });
  test('pending route journal reserves its pack identity', () {
    for (final key in ['oldRecords', 'newRecords']) {
      for (final record in document[key] as List) {
        ((record as Map)['installationRoute'] as Map)['packKey'] = 'owner/pack';
      }
    }
    write(jsonEncode(document));
    expect(
      () => service.checkPendingConversions(context, packKeys: {'owner/pack'}),
      throwsA(isA<Exception>()),
    );
  });
  test('malformed route journal fails closed even for unrelated paths', () {
    final encoded = jsonEncode(document).replaceFirst(
      '"phase":"prepared"',
      '"phase":"prepared","phase":"prepared"',
    );
    write(encoded);
    expect(
      () => service.checkPendingMutations(context, locations: ['/unrelated']),
      throwsA(isA<Exception>()),
    );
  });
  test('route evidence in the wrong scope fails closed', () {
    document['scope'] = 'user';
    for (final key in ['oldRecords', 'newRecords']) {
      for (final record in document[key] as List) {
        (record as Map)['scope'] = 'user';
        (record['installationRoute'] as Map)['scope'] = 'user';
      }
    }
    write(jsonEncode(document));
    expect(
      () => service.checkPendingMutations(context, locations: ['/unrelated']),
      throwsA(isA<Exception>()),
    );
  });
  test('route recovery is refused without changing evidence', () async {
    final encoded = jsonEncode(document);
    write(encoded);
    final skills = SkillLifecycleService(state: service);
    await expectLater(
      () => skills.recover(
        const LifecycleOptions(
          processWorkingDirectory: '/project',
          approved: true,
        ),
        transactionId: document['transactionId'] as String,
        action: 'rollback',
      ),
      throwsA(isA<Exception>()),
    );
    expect(
      fs
          .file(
            '${context.stateRoot()}/transactions/${document['transactionId']}.json',
          )
          .readAsStringSync(),
      encoded,
    );
  });
}
