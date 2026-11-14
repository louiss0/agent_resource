import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/authoring_publication_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

/// An IO seam that fails one selected durable operation.
class _FaultyIO extends LifecycleIO {
  _FaultyIO(this.memory) : super(fs: memory);

  final MemoryFileSystem memory;
  String? failingOperation;
  String? failingPath;

  @override
  void before(String operation, String path) {
    if (failingOperation != operation) return;
    if (failingPath != null && !path.contains(failingPath!)) return;
    throw FileSystemException('Injected failure', path);
  }
}

void main() {
  late MemoryFileSystem fs;
  late _FaultyIO io;
  late LifecycleStateService state;
  late AuthoringPlanService plans;
  late AuthoringPublicationService publication;
  late LifecycleOptions options;

  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/work/project').createSync(recursive: true);
    fs.directory('/home/user').createSync(recursive: true);
    io = _FaultyIO(fs);
    state = LifecycleStateService(io: io);
    plans = AuthoringPlanService(fileSystem: fs, state: state);
    publication = AuthoringPublicationService(fileSystem: fs, state: state);
    options = LifecycleOptions(
      processWorkingDirectory: '/work/project',
      environment: const <String, String>{},
      scope: LifecycleScope.project,
      cwd: '/work/project',
      projectRoot: '/work/project',
      home: '/home/user',
      stateDir: '/work/state',
    );
  });

  /// The skill package of one source directory.
  void seedSkill(
    String directory, {
    String name = 'demo',
    String description = 'Demonstrates the authoring publication.',
    String body = 'Original instructions.',
    Map<String, String> members = const <String, String>{},
    bool prompt = false,
  }) {
    fs.directory(directory).createSync(recursive: true);
    fs
        .file('$directory/SKILL.md')
        .writeAsStringSync(
          '---\nname: $name\ndescription: $description\n'
          '${prompt ? 'disable-model-invocation: true\n' : ''}---\n$body',
        );
    members.forEach((relative, content) {
      final path = '$directory/$relative';
      fs.file(path).parent.createSync(recursive: true);
      fs.file(path).writeAsStringSync(content);
    });
  }

  Future<AuthoringPlan> plan(
    AuthoringInputs inputs, {
    LifecycleOptions? selected,
  }) => plans.plan(inputs, selected ?? options);

  Future<AuthoringPublicationOutcome> publish(
    AuthoringPlan plan, {
    String? planId,
    bool approved = true,
    LifecycleOptions? selected,
  }) => publication.publish(
    AuthoringPublicationRequest(
      plan: plan,
      options: selected ?? options,
      planId: planId ?? plan.planId,
      approved: approved,
    ),
  );

  /// The live installation records of the selected scope.
  List<Map<String, Object?>> ledger() {
    final path = '/work/project/.agent-resource/installations.json';
    if (!fs.file(path).existsSync()) return const <Map<String, Object?>>[];
    final document =
        jsonDecode(fs.file(path).readAsStringSync()) as Map<String, Object?>;
    return [
      for (final record in document['installations']! as List)
        Map<String, Object?>.from(record as Map),
    ];
  }

  group('authoring publication', () {
    test(
      'publishes an author-only Skill package without an installation record',
      () async {
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          scope: LifecycleScope.project,
          bodyText: 'Do the work.',
          fields: const <String, Object?>{
            'name': 'demo',
            'description': 'Demonstrates the authoring publication.',
          },
        );
        final reviewed = await plan(inputs);
        expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

        final outcome = await publish(reviewed);

        expect(outcome.ownership, PublicationOwnership.authorOnly);
        expect(outcome.installationId, isNull);
        expect(outcome.receiptId, isNotNull);
        expect(
          fs
              .file('/work/project/.claude/skills/demo/SKILL.md')
              .readAsStringSync(),
          contains('Do the work.'),
        );
        expect(ledger(), isEmpty);
        // The authoring receipt is persisted as evidence of the authoring act.
        final receipt = fs
            .file(
              '/work/project/.agent-resource/authoring-receipts/'
              '${outcome.receiptId}.json',
            )
            .readAsStringSync();
        final document = jsonDecode(receipt) as Map<String, Object?>;
        expect(document['ownership'], 'authorOnly');
        expect(
          document['target'],
          '/work/project/.claude/skills/demo/SKILL.md',
        );
        expect(document['inheritedTracking'], isFalse);
        expect(document['packMembership'], isNull);
      },
    );

    test(
      'publishes an author-only Agent file without an installation record',
      () async {
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.agent,
          profile: AuthoringProfile.claude,
          scope: LifecycleScope.project,
          bodyText: 'Review the change.',
          fields: const <String, Object?>{
            'name': 'reviewer',
            'description': 'Reviews the change.',
          },
        );
        final reviewed = await plan(inputs);
        expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

        final outcome = await publish(reviewed);

        expect(outcome.ownership, PublicationOwnership.authorOnly);
        expect(
          fs
              .file('/work/project/.claude/agents/reviewer.md')
              .readAsStringSync(),
          contains('Review the change.'),
        );
        expect(ledger(), isEmpty);
      },
    );

    test('publishes an author-only Pi Prompt template', () async {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        scope: LifecycleScope.project,
        bodyText: 'Summarize the change.',
        fields: const <String, Object?>{
          'name': 'summary',
          'description': 'Summarizes the change.',
        },
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

      final outcome = await publish(reviewed);

      expect(outcome.ownership, PublicationOwnership.authorOnly);
      expect(
        fs.file('/work/project/.pi/prompts/summary.md').existsSync(),
        isTrue,
      );
      expect(ledger(), isEmpty);
    });

    test('clones the owned package members and preserves the body', () async {
      seedSkill(
        '/work/source/demo',
        body: 'Original instructions.',
        members: const <String, String>{
          'scripts/run.sh': '#!/bin/sh\necho run\n',
          'references/notes.md': 'Notes.\n',
        },
      );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.clone,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        fields: const <String, Object?>{'name': 'clone'},
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

      final outcome = await publish(reviewed);

      expect(outcome.ownership, PublicationOwnership.authorOnly);
      expect(
        fs
            .file('/work/project/.claude/skills/clone/SKILL.md')
            .readAsStringSync(),
        contains('Original instructions.'),
      );
      expect(
        fs
            .file('/work/project/.claude/skills/clone/scripts/run.sh')
            .readAsStringSync(),
        '#!/bin/sh\necho run\n',
      );
      expect(
        fs
            .file('/work/project/.claude/skills/clone/references/notes.md')
            .readAsStringSync(),
        'Notes.\n',
      );
      // The source is untouched by a clone.
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Original instructions.'),
      );
      expect(ledger(), isEmpty);
    });

    test('refuses an occupied target and keeps the occupant', () async {
      seedSkill('/work/project/.claude/skills/demo');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        bodyText: 'Do the work.',
        fields: const <String, Object?>{
          'name': 'demo',
          'description': 'Demonstrates the authoring publication.',
        },
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isFalse);
      expect(
        () => publish(reviewed),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 4)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('not ready'),
              ),
        ),
      );
      expect(
        fs
            .file('/work/project/.claude/skills/demo/SKILL.md')
            .readAsStringSync(),
        contains('Original instructions.'),
      );
    });

    test('refuses a stale plan identity and a missing approval', () async {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        bodyText: 'Do the work.',
        fields: const <String, Object?>{
          'name': 'demo',
          'description': 'Demonstrates the authoring publication.',
        },
      );
      final reviewed = await plan(inputs);

      await expectLater(
        publish(reviewed, planId: 'authoring-plan-stale'),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('current plan identity'),
          ),
        ),
      );
      await expectLater(
        publish(reviewed, approved: false),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('explicit approval'),
          ),
        ),
      );
      expect(
        fs.file('/work/project/.claude/skills/demo/SKILL.md').existsSync(),
        isFalse,
      );
    });

    test('publishes a managed Skill installation with its record', () async {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        bodyText: 'Do the work.',
        manage: true,
        fields: const <String, Object?>{
          'name': 'demo',
          'description': 'Demonstrates the authoring publication.',
        },
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

      final outcome = await publish(reviewed);

      expect(outcome.ownership, PublicationOwnership.managed);
      expect(outcome.installationId, isNotNull);
      final records = ledger();
      expect(records, hasLength(1));
      expect(records.single['installationId'], outcome.installationId);
      expect(records.single['location'], '/work/project/.claude/skills/demo');
      expect(
        fs
            .file('/work/project/.claude/skills/demo/SKILL.md')
            .readAsStringSync(),
        contains('Do the work.'),
      );
    });

    test(
      'refuses a managed Prompt publication without an author-only fallback',
      () async {
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.prompt,
          profile: AuthoringProfile.claude,
          scope: LifecycleScope.project,
          bodyText: 'Do the work.',
          manage: true,
          fields: const <String, Object?>{
            'name': 'demo',
            'description': 'Demonstrates the authoring publication.',
          },
        );
        final reviewed = await plan(inputs);
        expect(reviewed.ready, isFalse);
        expect(
          () => publish(reviewed),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              4,
            ),
          ),
        );
        expect(
          fs.file('/work/project/.claude/skills/demo/SKILL.md').existsSync(),
          isFalse,
        );
        expect(ledger(), isEmpty);
      },
    );

    test('replaces an ordinary source and retains a recovery copy', () async {
      seedSkill('/work/source/demo');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        bodyText: 'Updated instructions.',
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

      final outcome = await publish(reviewed);

      expect(outcome.ownership, PublicationOwnership.authorOnly);
      expect(outcome.installationId, isNull);
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Updated instructions.'),
      );
      expect(outcome.recoveryPath, isNotNull);
      expect(
        fs.file('${outcome.recoveryPath}/SKILL.md').readAsStringSync(),
        contains('Original instructions.'),
      );
      expect(ledger(), isEmpty);
    });

    test('refuses an edit whose source changed after the review', () async {
      seedSkill('/work/source/demo');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        bodyText: 'Updated instructions.',
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');
      fs
          .file('/work/source/demo/SKILL.md')
          .writeAsStringSync(
            '---\nname: demo\ndescription: Changed.\n---\nOther.',
          );

      await expectLater(
        publish(reviewed),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('changed since the plan was built'),
          ),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Other.'),
      );
    });

    test('reclassifies an ordinary Skill into a Prompt in place', () async {
      seedSkill('/work/source/demo');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');
      expect(reviewed.data['conversion'], 'skillToPrompt');

      final outcome = await publish(reviewed);

      expect(outcome.ownership, PublicationOwnership.authorOnly);
      final published = fs
          .file('/work/source/demo/SKILL.md')
          .readAsStringSync();
      expect(published, contains('disable-model-invocation: true'));
      expect(published, contains('Original instructions.'));
      expect(outcome.recoveryPath, isNotNull);
      expect(ledger(), isEmpty);
    });

    test('refuses a Prompt to Skill reclassification', () async {
      seedSkill(
        '/work/source/demo',
        body: 'Original instructions.',
        prompt: true,
      );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isFalse);
      expect(
        reviewed.diagnostics.map((diagnostic) => diagnostic['code']).toList(),
        contains('PROMPT_TO_SKILL_UNSUPPORTED'),
      );
      await expectLater(
        publish(reviewed),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 4),
        ),
      );
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Original instructions.'),
      );
    });

    test('converts a tracked Skill into a managed Prompt in place', () async {
      final create = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        bodyText: 'Original instructions.',
        manage: true,
        fields: const <String, Object?>{
          'name': 'demo',
          'description': 'Demonstrates the authoring publication.',
        },
      );
      final created = await plan(create);
      expect(created.ready, isTrue, reason: '${created.diagnostics}');
      final installed = await publish(created);
      expect(installed.installationId, isNotNull);

      final edit = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        installationId: installed.installationId,
      );
      final reviewed = await plan(edit);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');
      expect(reviewed.data['conversion'], 'skillToPrompt');

      final outcome = await publish(reviewed);

      expect(outcome.ownership, PublicationOwnership.managed);
      expect(outcome.sourceRetired, isTrue);
      final records = ledger();
      expect(records, hasLength(1));
      expect(records.single['installationId'], installed.installationId);
      expect(
        fs
            .file('/work/project/.claude/skills/demo/SKILL.md')
            .readAsStringSync(),
        contains('disable-model-invocation: true'),
      );
    });

    test(
      'reports a failed publication without a partial native output',
      () async {
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          scope: LifecycleScope.project,
          bodyText: 'Do the work.',
          fields: const <String, Object?>{
            'name': 'demo',
            'description': 'Demonstrates the authoring publication.',
          },
        );
        final reviewed = await plan(inputs);
        expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');
        io.failingOperation = 'write';
        io.failingPath = 'SKILL.md';

        await expectLater(
          publish(reviewed),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              6,
            ),
          ),
        );
        expect(
          fs.file('/work/project/.claude/skills/demo/SKILL.md').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'converts an ordinary Prompt into an Agent and retires the source',
      () async {
        seedSkill(
          '/work/source/demo',
          body: 'Original instructions.',
          prompt: true,
        );
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.convert,
          kind: AuthoringKind.agent,
          profile: AuthoringProfile.claude,
          scope: LifecycleScope.project,
          sourcePath: '/work/source/demo',
          conversion: ConversionDirection.promptToAgent,
          fields: const <String, Object?>{
            'name': 'worker',
            'description': 'Works on the selected task.',
          },
        );
        final reviewed = await plan(inputs);
        expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

        final outcome = await publish(reviewed);

        expect(outcome.ownership, PublicationOwnership.authorOnly);
        expect(outcome.sourceRetired, isTrue);
        final published = fs
            .file('/work/project/.claude/agents/worker.md')
            .readAsStringSync();
        expect(published, contains('Original instructions.'));
        expect(fs.directory('/work/source/demo').existsSync(), isFalse);
        expect(
          fs.file('${outcome.recoveryPath}/SKILL.md').readAsStringSync(),
          contains('Original instructions.'),
        );
        expect(ledger(), isEmpty);
      },
    );

    test(
      'converts an ordinary Skill into a Pi template and removes the source',
      () async {
        seedSkill('/work/source/demo', body: 'Original instructions.');
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.convert,
          kind: AuthoringKind.prompt,
          profile: AuthoringProfile.pi,
          scope: LifecycleScope.project,
          sourcePath: '/work/source/demo',
          conversion: ConversionDirection.skillToPrompt,
        );
        final reviewed = await plan(inputs);
        expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');
        expect(reviewed.data['sourceRemovalRequired'], isTrue);

        final outcome = await publish(reviewed);

        expect(outcome.ownership, PublicationOwnership.authorOnly);
        expect(outcome.sourceRetired, isTrue);
        expect(
          fs.file('/work/project/.pi/prompts/demo.md').readAsStringSync(),
          contains('Original instructions.'),
        );
        expect(fs.directory('/work/source/demo').existsSync(), isFalse);
        expect(ledger(), isEmpty);
      },
    );

    test('refuses an author-only native placement that collides with a visible name', () async {
      seedSkill('/home/user/.claude/skills/demo');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        bodyText: 'Do the work.',
        fields: const <String, Object?>{
          'name': 'demo',
          'description': 'Demonstrates the authoring publication.',
        },
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

      await expectLater(
        publish(reviewed),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 4),
        ),
      );
      expect(
        fs.file('/work/project/.claude/skills/demo/SKILL.md').existsSync(),
        isFalse,
      );
    });

    test(
      'publishes a source-folder output without the installed-name constraint',
      () async {
        seedSkill('/home/user/.claude/skills/demo');
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          scope: LifecycleScope.project,
          bodyText: 'Do the work.',
          output: '/work/source/clone',
          fields: const <String, Object?>{
            'name': 'demo',
            'description': 'Demonstrates the authoring publication.',
          },
        );
        final reviewed = await plan(inputs);
        expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

        final outcome = await publish(reviewed);

        expect(outcome.ownership, PublicationOwnership.authorOnly);
        expect(
          fs.file('/work/source/clone/SKILL.md').readAsStringSync(),
          contains('Do the work.'),
        );
        expect(ledger(), isEmpty);
      },
    );

    test('publishes a managed Agent installation with its record', () async {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.agent,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        bodyText: 'Review the change.',
        manage: true,
        fields: const <String, Object?>{
          'name': 'reviewer',
          'description': 'Reviews the change.',
        },
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

      final outcome = await publish(reviewed);

      expect(outcome.ownership, PublicationOwnership.managed);
      expect(outcome.installationId, isNotNull);
      final records = ledger();
      expect(records, hasLength(1));
      expect(
        records.single['location'],
        '/work/project/.claude/agents/reviewer.md',
      );
      expect(records.single['artifactKind'], 'agent-file');
    });

    test('publishes a managed clone with the owned package members', () async {
      seedSkill(
        '/work/source/demo',
        body: 'Original instructions.',
        members: const <String, String>{
          'scripts/run.sh': '#!/bin/sh\necho run\n',
        },
      );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.clone,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        sourcePath: '/work/source/demo',
        manage: true,
        fields: const <String, Object?>{'name': 'clone'},
      );
      final reviewed = await plan(inputs);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');

      final outcome = await publish(reviewed);

      expect(outcome.ownership, PublicationOwnership.managed);
      expect(
        fs
            .file('/work/project/.claude/skills/clone/scripts/run.sh')
            .readAsStringSync(),
        '#!/bin/sh\necho run\n',
      );
      expect(
        fs
            .file('/work/project/.claude/skills/clone/SKILL.md')
            .readAsStringSync(),
        contains('Original instructions.'),
      );
      // The source is untouched and stays untracked.
      expect(
        fs.file('/work/source/demo/SKILL.md').readAsStringSync(),
        contains('Original instructions.'),
      );
      expect(ledger(), hasLength(1));
    });

    test('migrates a tracked Skill into a tracked Pi template', () async {
      final create = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        bodyText: 'Original instructions.',
        manage: true,
        fields: const <String, Object?>{
          'name': 'demo',
          'description': 'Demonstrates the authoring publication.',
        },
      );
      final created = await plan(create);
      expect(created.ready, isTrue, reason: '${created.diagnostics}');
      final installed = await publish(created);
      expect(installed.installationId, isNotNull);

      final convert = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        scope: LifecycleScope.project,
        installationId: installed.installationId,
        conversion: ConversionDirection.skillToPrompt,
      );
      final reviewed = await plan(convert);
      expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');
      expect(reviewed.ownership, AuthoringOwnership.managedReplacement);

      final outcome = await publish(reviewed);

      expect(outcome.ownership, PublicationOwnership.managed);
      expect(outcome.sourceRetired, isTrue);
      expect(
        fs.file('/work/project/.pi/prompts/demo.md').readAsStringSync(),
        contains('Original instructions.'),
      );
      expect(
        fs.directory('/work/project/.claude/skills/demo').existsSync(),
        isFalse,
      );
      final records = ledger();
      expect(records, hasLength(2));
      expect(
        records.any(
          (record) => record['location'] == '/work/project/.pi/prompts/demo.md',
        ),
        isTrue,
      );
    });

    test(
      'retains the recovery copy when a conversion publication fails',
      () async {
        seedSkill('/work/source/demo', body: 'Original instructions.');
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.convert,
          kind: AuthoringKind.prompt,
          profile: AuthoringProfile.pi,
          scope: LifecycleScope.project,
          sourcePath: '/work/source/demo',
          conversion: ConversionDirection.skillToPrompt,
        );
        final reviewed = await plan(inputs);
        expect(reviewed.ready, isTrue, reason: '${reviewed.diagnostics}');
        io.failingOperation = 'write';
        io.failingPath = 'prompts';

        await expectLater(
          publish(reviewed),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              6,
            ),
          ),
        );
        // The source survives an interrupted publication and the recovery copy
        // of the previous bytes is retained.
        expect(fs.directory('/work/source/demo').existsSync(), isTrue);
        final recovery = fs
            .directory('/work/project/.agent-resource/authoring-recovery')
            .listSync();
        expect(recovery, hasLength(1));
        expect(
          fs.file('${recovery.single.path}/SKILL.md').readAsStringSync(),
          contains('Original instructions.'),
        );
      },
    );
  });
}
