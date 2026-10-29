import 'dart:convert';

import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:test/test.dart';

void main() {
  group('InstallationPlan', () {
    final provenance = AcquisitionProvenance(
      kind: AcquisitionLocatorKind.local,
      requestedLocator: 'collection',
      resolvedLocator: 'collection',
      subpath: null,
      temporary: false,
      directFile: false,
      durableLocalDirectory: true,
      configDigest: 'a' * 64,
    );

    InstallationUnitPlan unit({String id = 'review'}) => InstallationUnitPlan(
      resourceType: InstallationResourceType.skill,
      resourceId: id,
      nativeName: 'review',
      profile: null,
      method: InstallationMethod.canonical,
      status: InstallationUnitStatus.planned,
      installationIds: const ['ins_00000000000000000000000000000000'],
      entries: const [
        InstallationEntryPlan(
          path: '/home/.agents/skills/review',
          kind: InstallationEntryKind.content,
          action: InstallationEntryAction.createContent,
          target: 'codex',
        ),
        InstallationEntryPlan(
          path: '/home/.claude/skills/review',
          kind: InstallationEntryKind.link,
          action: InstallationEntryAction.createLink,
          target: 'claude',
          linkTarget: '/home/.agents/skills/review',
          nativeLinkKind: 'posix-directory-symlink',
        ),
      ],
      sourcePath: '/source/review',
      sourceDigest: 'b' * 64,
      origin: const {'status': 'evidenced'},
    );

    test(
      'creates a deterministic versioned identity from request observations',
      () {
        final first = InstallationPlan.create(
          command: 'skill install',
          source: provenance,
          scope: 'user',
          units: [unit()],
        );
        final second = InstallationPlan.create(
          command: 'skill install',
          source: provenance,
          scope: 'user',
          units: [unit()],
        );
        final different = InstallationPlan.create(
          command: 'skill install',
          source: provenance,
          scope: 'user',
          units: [unit(id: 'other')],
        );

        expect(first.planId, second.planId);
        expect(first.planId, startsWith('plan_v2_'));
        expect(different.planId, isNot(first.planId));
      },
    );

    test('serializes the exact success-only schema-version-2 envelope', () {
      final plan = InstallationPlan.create(
        command: 'skill install',
        source: provenance,
        scope: 'user',
        units: [unit()],
      );
      final envelope = plan.envelope(InstallationOutcome.planned);
      final decoded = jsonDecode(jsonEncode(envelope)) as Map<String, Object?>;

      expect(decoded.keys, [
        'schemaVersion',
        'command',
        'outcome',
        'data',
        'diagnostics',
      ]);
      expect(decoded['schemaVersion'], 2);
      expect(decoded['command'], 'skill install');
      expect(decoded['outcome'], 'planned');
      final data = decoded['data']! as Map<String, Object?>;
      expect(data.keys, ['planId', 'source', 'scope', 'units', 'summary']);
      expect(data['source'], isNot(contains('sourcePath')));
      final units = data['units']! as List<Object?>;
      final jsonUnit = units.single! as Map<String, Object?>;
      expect(jsonUnit['resourceType'], 'skill');
      expect(jsonUnit['resourceId'], 'review');
      expect(jsonUnit['nativeName'], 'review');
      expect(jsonUnit.containsKey('profile'), isFalse);
      expect(jsonUnit['method'], 'canonical');
      expect(jsonUnit['status'], 'planned');
      expect(jsonUnit['installationIds'], [
        'ins_00000000000000000000000000000000',
      ]);
      final entries = jsonUnit['entries']! as List<Object?>;
      expect((entries[0]! as Map<String, Object?>)['action'], 'create-content');
      expect(
        (entries[1]! as Map<String, Object?>)['linkTarget'],
        '/home/.agents/skills/review',
      );
      expect(
        (entries[1]! as Map<String, Object?>)['nativeLinkKind'],
        'posix-directory-symlink',
      );
      final summary = data['summary']! as Map<String, Object?>;
      expect(summary['requestedUnits'], 1);
      expect(summary['planned'], 1);
      expect(summary['ownedEntryEffects'], 2);
    });

    test(
      'renders complete human plan facts without source instruction bodies',
      () {
        final plan = InstallationPlan.create(
          command: 'skill install',
          source: provenance,
          scope: 'user',
          units: [unit()],
        );
        final text = plan.renderText(InstallationOutcome.planned);
        expect(text, contains('skill install: planned'));
        expect(text, contains('Scope: user'));
        expect(text, contains('Method: canonical'));
        expect(text, contains('/home/.claude/skills/review'));
        expect(text, contains('-> /home/.agents/skills/review'));
      },
    );
  });
}
