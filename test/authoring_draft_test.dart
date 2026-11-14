import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/authoring/instruction_draft.dart';
import 'package:agent_resource/src/services/instruction_draft_service.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('authoring draft', () {
    late MemoryFileSystem fs;
    late InstructionDraftService drafts;
    late LifecycleOptions options;
    late InstructionDraft retained;
    const secret = 'PRIVATE INSTRUCTIONS\r\nKeep exact whitespace.  \n';

    setUp(() async {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      fs.directory('/project').createSync();
      fs.directory('/home').createSync();
      fs.currentDirectory = '/project';
      options = const LifecycleOptions(
        processWorkingDirectory: '/project',
        environment: {},
        projectRoot: '/project',
        home: '/home',
        scope: LifecycleScope.project,
      );
      drafts = InstructionDraftService(fileSystem: fs, verifier: (_) {});
      retained = await drafts.prepare(
        options,
        parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          bodyText: secret,
          fields: {'name': 'demo', 'description': 'A draft example.'},
          output: '/project/source/demo',
        ),
      );
    });

    Future<MambaExecutionResult> run(List<String> args) => createExecutor(
      fileSystem: fs,
      instructionDrafts: drafts,
    ).fake().execute(['authoring', 'draft', ...args]);

    Map<String, Object?> decode(MambaExecutionResult result) {
      expect(
        result,
        isA<MambaSuccessResult>(),
        reason: result is MambaFailureResult ? result.message : null,
      );
      return jsonDecode((result as MambaSuccessResult).output!)
          as Map<String, Object?>;
    }

    Map<String, String> snapshot() => {
      for (final entity
          in fs
              .directory('/project')
              .listSync(recursive: true, followLinks: false))
        entity.path: fs.isFileSync(entity.path)
            ? base64Encode(fs.file(entity.path).readAsBytesSync())
            : 'directory',
    };

    test('help exposes the actual registered recovery surface', () async {
      final before = snapshot();
      final result = await run(['--help']);
      expect(result, isA<MambaSuccessResult>());
      final output = (result as MambaSuccessResult).output!;
      for (final command in ['list', 'inspect', 'resume', 'discard']) {
        expect(output, contains(command));
      }
      expect(output, isNot(contains(secret)));
      expect(snapshot(), before);
    });

    test(
      'list and inspect are body-free and preserve all state bytes',
      () async {
        final before = snapshot();
        final listed = decode(await run(['list', '--format', 'json']));
        final data = listed['data'] as Map;
        expect(data['count'], 1);
        expect(
          (data['drafts'] as List).single,
          containsPair('draftId', retained.draftId),
        );
        final inspected = decode(
          await run(['inspect', retained.draftId, '--format', 'json']),
        );
        expect((inspected['data'] as Map)['bodySha256'], retained.bodySha256);
        expect(jsonEncode(listed), isNot(contains('PRIVATE INSTRUCTIONS')));
        expect(jsonEncode(inspected), isNot(contains('PRIVATE INSTRUCTIONS')));
        expect(snapshot(), before);
      },
    );

    test(
      'restart resume rebuilds a fresh plan without publishing or leaking text',
      () async {
        drafts = InstructionDraftService(fileSystem: fs, verifier: (_) {});
        final before = snapshot();
        final first = decode(
          await run(['resume', retained.draftId, '--format', 'json']),
        );
        final firstData = first['data'] as Map;
        expect(firstData['ready'], true);
        expect(firstData['publicationApprovalRequired'], true);
        expect(firstData['published'], false);
        expect(jsonEncode(first), isNot(contains('PRIVATE INSTRUCTIONS')));
        expect(snapshot(), before);
        fs.directory('/project/source/demo').createSync(recursive: true);
        fs
            .file('/project/source/demo/sentinel')
            .writeAsStringSync('new occupant');
        final changed = snapshot();
        final second = decode(
          await run(['resume', retained.draftId, '--format', 'json']),
        );
        final secondData = second['data'] as Map;
        expect(secondData['planId'], isNot(firstData['planId']));
        expect(secondData['ready'], false);
        expect(snapshot(), changed);
        expect(
          fs.file('/project/source/demo/sentinel').readAsStringSync(),
          'new occupant',
        );
      },
    );

    test('resume explicitly projects a body-free report even if planner includes text', () async {
      drafts = InstructionDraftService(
        fileSystem: fs,
        verifier: (_) {},
        plans: _InstructionShowingPlans(AuthoringPlanService(fileSystem: fs)),
      );
      final result = decode(
        await run(['resume', retained.draftId, '--format', 'json']),
      );
      expect(jsonEncode(result), isNot(contains('PRIVATE INSTRUCTIONS')));
      final plan = (result['data'] as Map)['plan'] as Map;
      expect((plan['candidate'] as Map).keys.toSet(), {'sha256', 'byteLength'});
    });

    test(
      'discard defaults to read-only preview; apply needs explicit consent',
      () async {
        final before = snapshot();
        final preview = decode(
          await run([
            'discard',
            retained.draftId,
            '--dry-run',
            '--format',
            'json',
          ]),
        );
        expect((preview['data'] as Map)['cleaned'], false);
        expect(snapshot(), before);
        final unapproved = await run(['discard', retained.draftId, '--apply']);
        expect(unapproved, isA<MambaFailureResult>());
        expect(snapshot(), before);
        final applied = decode(
          await run([
            'discard',
            retained.draftId,
            '--apply',
            '--yes',
            '--format',
            'json',
          ]),
        );
        expect((applied['data'] as Map)['cleaned'], true);
        expect(fs.directory(retained.path).existsSync(), false);
        expect(fs.directory('/project/source/demo').existsSync(), false);
      },
    );

    test('parser refuses missing IDs, unknown options and conflicting apply before effects', () async {
      final before = snapshot();
      for (final args in [
        ['resume'],
        ['discard', retained.draftId, '--apply', '--dry-run'],
        ['inspect', retained.draftId, '--body-text', 'forbidden'],
      ]) {
        final result = await run(args);
        expect(
          result,
          isA<MambaFailureResult>().having(
            (r) => r.error.phase,
            'phase',
            MambaExecutionPhase.parse,
          ),
        );
        expect(snapshot(), before);
      }
    });

    test(
      'one native metadata IO fault remains a body-free unresolved draft',
      () async {
        var failReads = false;
        final guarded = MemoryFileSystem(
          style: FileSystemStyle.posix,
          opHandle: (context, operation) {
            if (failReads &&
                operation == FileSystemOp.open &&
                context.endsWith('/draft.json')) {
              throw FileSystemException(
                'injected metadata read failure',
                context,
              );
            }
          },
        );
        guarded.directory('/project').createSync();
        guarded.directory('/home').createSync();
        guarded.currentDirectory = '/project';
        final service = InstructionDraftService(
          fileSystem: guarded,
          verifier: (_) {},
        );
        final created = await service.prepare(
          options,
          parseAuthoringInputs(
            operation: AuthoringOperation.create,
            kind: AuthoringKind.skill,
            profile: AuthoringProfile.claude,
            bodyText: secret,
            fields: {'name': 'demo', 'description': 'Example.'},
          ),
        );
        final before = guarded.file('${created.path}/body').readAsBytesSync();
        failReads = true;
        final result = await createExecutor(
          fileSystem: guarded,
          instructionDrafts: service,
        ).fake().execute(['authoring', 'draft', 'list', '--format', 'json']);
        failReads = false;
        final report = decode(result);
        final data = report['data'] as Map;
        expect(data['count'], 1);
        final entry = (data['drafts'] as List).single as Map;
        expect(entry['resolved'], false);
        expect(entry['reason'], 'The instruction draft could not be read.');
        expect(jsonEncode(report), isNot(contains('PRIVATE INSTRUCTIONS')));
        expect(guarded.file('${created.path}/body').readAsBytesSync(), before);
      },
    );

    test(
      'path escape and wrong identity cannot discard unowned inputs',
      () async {
        final original = fs.file('/project/original.txt')
          ..writeAsStringSync(secret);
        final before = snapshot();
        final result = await run([
          'discard',
          '../original.txt',
          '--apply',
          '--yes',
        ]);
        expect(result, isA<MambaFailureResult>());
        expect(original.readAsStringSync(), secret);
        expect(snapshot(), before);
      },
    );
  });
}

final class _InstructionShowingPlans(final AuthoringPlanService delegate)
    implements AuthoringPlanService {
  @override
  Future<String> Function()? get standardInput => null;

  @override
  Future<AuthoringPlan> plan(
    AuthoringInputs inputs,
    LifecycleOptions options, {
    bool showInstructions = false,
  }) => delegate.plan(inputs, options, showInstructions: true);
}
