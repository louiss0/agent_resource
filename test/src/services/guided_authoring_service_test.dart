import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/authoring/editor_process.dart';
import 'package:agent_resource/src/services/editor_interaction_service.dart';
import 'package:agent_resource/src/services/guided_authoring_service.dart';
import 'package:agent_resource/src/services/instruction_draft_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('guided authoring', () {
    late MemoryFileSystem fs;
    late LifecycleOptions options;
    late List<EditorProcessRequest> requests;
    late List<String> questions;
    late List<String> confirmations;

    setUp(() {
      fs = MemoryFileSystem();
      fs.directory('/work/project').createSync(recursive: true);
      fs.directory('/home/user').createSync(recursive: true);
      options = LifecycleOptions(
        processWorkingDirectory: '/work/project',
        environment: const <String, String>{},
        scope: LifecycleScope.project,
        cwd: '/work/project',
        projectRoot: '/work/project',
        home: '/home/user',
      );
      requests = <EditorProcessRequest>[];
      questions = <String>[];
      confirmations = <String>[];
    });

    InstructionDraftService buildDrafts() => InstructionDraftService(
      fileSystem: fs,
      state: LifecycleStateService(io: LifecycleIO(fs: fs)),
      privacy: (_) {},
      verifier: (_) {},
    );

    EditorInteractionService buildEditor({
      EditorProcessRunner? processRunner,
    }) => EditorInteractionService(
      drafts: buildDrafts(),
      processRunner:
          processRunner ??
          (request) async {
            requests.add(request);
            fs
                .file(request.arguments.last)
                .writeAsStringSync('Edited instructions.\n');
            return const EditorProcessOutcome(started: true, exitCode: 0);
          },
      environment: const EditorSessionEnvironment(
        hasTerminal: true,
        hasDisplay: true,
      ),
      acknowledge: (request) async => true,
      recover: (request) async => const EditorRecoveryCancel(),
      executables: const _FakeResolver(),
      fileSystem: fs,
    );

    GuidedAuthoringService buildService({
      EditorInteractionService? editor,
      String? answer,
    }) => GuidedAuthoringService(
      fileSystem: fs,
      drafts: buildDrafts(),
      editor: editor ?? buildEditor(),
      terminal: () => true,
      ask: (label) async {
        questions.add(label);
        return answer;
      },
      confirm: (summary) async {
        confirmations.add(summary);
        return true;
      },
    );

    AuthoringInputs createInputs({
      String? name = 'demo',
      String? description = 'Demo resource.',
      String? bodyText,
    }) => parseAuthoringInputs(
      operation: AuthoringOperation.create,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      scope: LifecycleScope.project,
      bodyText: bodyText,
      fields: <String, Object?>{'name': ?name, 'description': ?description},
      allowDeferredBody: true,
    );

    test(
      'the editor supplies the body and the publication cleans the draft',
      () async {
        final service = buildService();

        final outcome = await service.run(
          GuidedAuthoringRequest(
            command: 'skill create',
            inputs: createInputs(),
            apply: true,
            interactive: true,
            editorChoice: 'code --wait',
          ),
          options.copyWith(approved: true),
        );

        expect(outcome.outcome, 'published');
        expect(outcome.data['published'], isTrue);
        expect(outcome.data['draftCleaned'], isTrue);
        expect(outcome.data['draftCleanupFailure'], isNull);
        expect(requests, hasLength(1));
        expect(
          fs
              .file(
                fs.path.join(
                  '/work/project',
                  '.claude',
                  'skills',
                  'demo',
                  'SKILL.md',
                ),
              )
              .readAsStringSync(),
          contains('Edited instructions.'),
        );
        final drafts = fs.directory(
          fs.path.join(
            '/work/project',
            '.agent-resource',
            'instruction-drafts',
          ),
        );
        expect(
          drafts.existsSync() ? drafts.listSync() : const <Object>[],
          isEmpty,
          reason: 'A published output removes its own retained draft.',
        );
      },
    );

    test('an unchanged editor result is not a cancellation', () async {
      final service = buildService(
        editor: buildEditor(
          processRunner: (request) async {
            requests.add(request);
            return const EditorProcessOutcome(started: true, exitCode: 0);
          },
        ),
      );

      final outcome = await service.run(
        GuidedAuthoringRequest(
          command: 'skill create',
          inputs: createInputs(bodyText: 'Original instructions.\n'),
          apply: true,
          interactive: true,
          editorChoice: 'code --wait',
        ),
        options.copyWith(approved: true),
      );

      expect(outcome.outcome, 'published');
      expect(
        fs
            .file(
              fs.path.join(
                '/work/project',
                '.claude',
                'skills',
                'demo',
                'SKILL.md',
              ),
            )
            .readAsStringSync(),
        contains('Original instructions.'),
      );
    });

    test(
      'a cancelled session retains the draft and reports its location',
      () async {
        final service = buildService(
          editor: buildEditor(
            processRunner: (request) async {
              requests.add(request);
              return const EditorProcessOutcome.failed(
                'The editor is missing.',
              );
            },
          ),
        );

        await expectLater(
          service.run(
            GuidedAuthoringRequest(
              command: 'skill create',
              inputs: createInputs(),
              apply: true,
              interactive: true,
              editorChoice: 'code --wait',
            ),
            options.copyWith(approved: true),
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'exit code', 7)
                .having(
                  (error) => error.message,
                  'message',
                  contains('retained draft is at'),
                ),
          ),
        );
        final drafts = fs.directory(
          fs.path.join(
            '/work/project',
            '.agent-resource',
            'instruction-drafts',
          ),
        );
        expect(drafts.existsSync(), isTrue);
        expect(drafts.listSync(), hasLength(1));
      },
    );

    test('a failed cleanup is reported truthfully', () async {
      final service = buildService(
        editor: buildEditor(
          processRunner: (request) async {
            requests.add(request);
            fs
                .file(request.arguments.last)
                .writeAsStringSync('Edited instructions.\n');
            // An unexpected entry in the protected storage makes the
            // verified cleanup refuse instead of removing something else.
            fs
                .file(
                  fs.path.join(fs.path.dirname(request.arguments.last), 'x'),
                )
                .writeAsStringSync('unexpected');
            return const EditorProcessOutcome(started: true, exitCode: 0);
          },
        ),
      );

      final outcome = await service.run(
        GuidedAuthoringRequest(
          command: 'skill create',
          inputs: createInputs(),
          apply: true,
          interactive: true,
          editorChoice: 'code --wait',
        ),
        options.copyWith(approved: true),
      );

      expect(outcome.outcome, 'published');
      expect(outcome.data['published'], isTrue);
      expect(outcome.data['draftCleaned'], isFalse);
      expect(outcome.data['draftCleanupFailure'], isNotNull);
    });

    test('the guided flow collects a missing native field', () async {
      final service = buildService(answer: 'Collected description.');

      final outcome = await service.run(
        GuidedAuthoringRequest(
          command: 'skill create',
          inputs: createInputs(description: null),
          apply: true,
          interactive: true,
          editorChoice: 'code --wait',
        ),
        options.copyWith(approved: true),
      );

      expect(outcome.outcome, 'published');
      expect(questions, hasLength(1));
      expect(questions.single, contains('description'));
      expect(
        fs
            .file(
              fs.path.join(
                '/work/project',
                '.claude',
                'skills',
                'demo',
                'SKILL.md',
              ),
            )
            .readAsStringSync(),
        contains('Collected description.'),
      );
    });

    test('an unattended run never asks a question', () async {
      final service = buildService();

      await expectLater(
        service.run(
          GuidedAuthoringRequest(
            command: 'skill create',
            inputs: createInputs(),
            interactive: false,
          ),
          options,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('--body-file'),
          ),
        ),
      );
      expect(questions, isEmpty);
      expect(confirmations, isEmpty);
      expect(requests, isEmpty);
    });

    test(
      'a dry run never prepares a draft and never launches an editor',
      () async {
        final service = buildService();

        final outcome = await service.run(
          GuidedAuthoringRequest(
            command: 'skill create',
            inputs: createInputs(bodyText: 'Body.'),
            interactive: true,
            editorChoice: 'code --wait',
          ),
          options.copyWith(dryRun: true),
        );

        expect(outcome.outcome, 'planned');
        expect(outcome.data['published'], isFalse);
        expect(requests, isEmpty);
        expect(
          fs
              .directory(
                fs.path.join(
                  '/work/project',
                  '.agent-resource',
                  'instruction-drafts',
                ),
              )
              .existsSync(),
          isFalse,
        );
      },
    );
  });
}

/// A resolver that finds every editor program.
final class _FakeResolver implements EditorProgramResolver {
  const _FakeResolver();

  @override
  EditorExecutableResolution resolve(
    String executable, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) => EditorExecutableResolution(
    requested: executable,
    resolvedPath: '/programs/$executable',
    isBatchLauncher: false,
  );
}
