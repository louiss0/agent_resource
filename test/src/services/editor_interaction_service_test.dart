import 'dart:io';

import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/authoring/editor_process.dart';
import 'package:agent_resource/src/services/editor_interaction_service.dart';
import 'package:agent_resource/src/services/instruction_draft_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('editor interaction', () {
    late MemoryFileSystem fs;
    late LifecycleOptions options;
    late InstructionDraftService drafts;
    late List<EditorProcessRequest> requests;
    late List<EditorAcknowledgementRequest> acknowledgements;
    late List<EditorRecoveryRequest> recoveries;
    late EditorInteractionService service;

    const body = 'First line\nSecond line\n';

    EditorInteractionService buildService({
      EditorProcessRunner? processRunner,
      EditorPlatformLauncher? platformLauncher,
      EditorAcknowledgement? acknowledge,
      EditorRecoveryPrompt? recover,
      EditorSessionEnvironment? environment,
      EditorProgramResolver? executables,
    }) => EditorInteractionService(
      drafts: drafts,
      processRunner:
          processRunner ??
          (request) async {
            requests.add(request);
            return const EditorProcessOutcome(started: true, exitCode: 0);
          },
      platformLauncher: platformLauncher,
      environment:
          environment ??
          const EditorSessionEnvironment(hasTerminal: true, hasDisplay: true),
      acknowledge:
          acknowledge ??
          (request) async {
            acknowledgements.add(request);
            return true;
          },
      recover:
          recover ??
          (request) async {
            recoveries.add(request);
            return const EditorRecoveryCancel();
          },
      executables: executables ?? const _FakeResolver(),
      fileSystem: fs,
    );

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
      drafts = InstructionDraftService(
        fileSystem: fs,
        state: LifecycleStateService(io: LifecycleIO(fs: fs)),
        privacy: (_) {},
        verifier: (_) {},
      );
      requests = <EditorProcessRequest>[];
      acknowledgements = <EditorAcknowledgementRequest>[];
      recoveries = <EditorRecoveryRequest>[];
      service = buildService();
    });

    Future<String> prepareDraft({String text = body}) async {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.project,
        bodyText: text,
        fields: const <String, Object?>{
          'name': 'demo',
          'description': 'Demo resource',
        },
      );
      final draft = await drafts.prepare(options, inputs);
      return draft.draftId;
    }

    test('a configured editor opens the editable working copy', () async {
      final draftId = await prepareDraft();

      final outcome = await service.edit(
        options,
        draftId,
        editorChoice: 'code --wait',
      );

      expect(outcome, isA<EditorEditCompleted>());
      final completed = outcome as EditorEditCompleted;
      expect(requests.single.executable, '/programs/code');
      expect(requests.single.arguments.first, '--wait');
      expect(requests.single.arguments.last, endsWith('working.txt'));
      expect(completed.path, endsWith('working.txt'));
      expect(completed.completion, EditorCompletionMode.documentedWait);
    });

    test(
      'the edited working copy becomes the effective instructions',
      () async {
        final draftId = await prepareDraft();
        service = buildService(
          processRunner: (request) async {
            requests.add(request);
            fs
                .file(request.arguments.last)
                .writeAsStringSync('Edited instructions\n');
            return const EditorProcessOutcome(started: true, exitCode: 0);
          },
        );

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'code --wait',
        );

        final completed = outcome as EditorEditCompleted;
        expect(completed.body.text, 'Edited instructions\n');
        expect(completed.body.edited, isTrue);
      },
    );

    group('completion evidence', () {
      test(
        'an editor without a documented wait asks the operator to confirm the '
        'saved and finished editing',
        () async {
          final draftId = await prepareDraft();

          final outcome = await service.edit(
            options,
            draftId,
            editorChoice: 'nano',
          );

          expect(acknowledgements.single.draftId, draftId);
          expect(acknowledgements.single.path, endsWith('working.txt'));
          expect(outcome, isA<EditorEditCompleted>());
          expect(
            (outcome as EditorEditCompleted).completion,
            EditorCompletionMode.savedAndFinishedAcknowledgement,
          );
        },
      );

      test('an editor without a documented wait does not complete without the '
          'confirmation', () async {
        final draftId = await prepareDraft();
        service = buildService(
          acknowledge: (request) async {
            acknowledgements.add(request);
            return false;
          },
        );

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'nano',
        );

        expect(outcome, isA<EditorEditNotFinished>());
        expect(
          (outcome as EditorEditNotFinished).path,
          endsWith('working.txt'),
        );
      });

      test(
        'an existing working copy is reused and its edits are preserved',
        () async {
          final draftId = await prepareDraft();
          service = buildService(
            processRunner: (request) async {
              requests.add(request);
              fs.file(request.arguments.last).writeAsStringSync('Edited\n');
              return const EditorProcessOutcome(started: true, exitCode: 0);
            },
          );

          final first = await service.edit(
            options,
            draftId,
            editorChoice: 'code --wait',
          );
          final second = await service.edit(
            options,
            draftId,
            editorChoice: 'code --wait',
          );

          expect(
            (first as EditorEditCompleted).path,
            (second as EditorEditCompleted).path,
          );
          expect(second.body.text, 'Edited\n');
        },
      );

      test('a substituted working copy refuses the launch', () async {
        final draftId = await prepareDraft();
        fs
            .link(
              '/work/project/.agent-resource/instruction-drafts/'
              '$draftId/working.txt',
            )
            .createSync('/other/file.txt');

        await expectLater(
          service.edit(options, draftId, editorChoice: 'code --wait'),
          throwsA(isA<MambaException>()),
        );

        expect(requests, isEmpty);
      });

      test('a changed snapshot refuses the launch', () async {
        final draftId = await prepareDraft();
        fs
            .file(
              '/work/project/.agent-resource/instruction-drafts/'
              '$draftId/body',
            )
            .writeAsStringSync('Replaced\n');

        await expectLater(
          service.edit(options, draftId, editorChoice: 'code --wait'),
          throwsA(isA<MambaException>()),
        );

        expect(requests, isEmpty);
      });

      test('a terminal editor inherits the terminal and its exit is not an '
          'acceptance', () async {
        final draftId = await prepareDraft();
        service = buildService(
          processRunner: (request) async {
            requests.add(request);
            return const EditorProcessOutcome(started: true, exitCode: 0);
          },
          acknowledge: (request) async {
            acknowledgements.add(request);
            return false;
          },
        );

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'vim',
        );

        expect(requests.single.inheritTerminal, isTrue);
        expect(requests.single.awaitCompletion, isTrue);
        expect(acknowledgements, hasLength(1));
        expect(outcome, isA<EditorEditNotFinished>());
      });

      test('an unknown program is not awaited', () async {
        final draftId = await prepareDraft();

        await service.edit(options, draftId, editorChoice: 'my-editor');

        expect(requests.single.inheritTerminal, isFalse);
        expect(requests.single.awaitCompletion, isFalse);
      });

      test('a documented wait is awaited', () async {
        final draftId = await prepareDraft();

        await service.edit(options, draftId, editorChoice: 'code --wait');

        expect(requests.single.awaitCompletion, isTrue);
        expect(requests.single.inheritTerminal, isFalse);
      });

      test('a documented wait is the completion evidence and needs no '
          'acknowledgement', () async {
        final draftId = await prepareDraft();

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'Code.exe --wait',
        );

        expect(requests.single.executable, '/programs/Code.exe');
        expect(acknowledgements, isEmpty);
        expect(outcome, isA<EditorEditCompleted>());
        expect(
          (outcome as EditorEditCompleted).completion,
          EditorCompletionMode.documentedWait,
        );
      });

      test('an unchanged edited draft is not a cancellation', () async {
        final draftId = await prepareDraft();

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'code --wait',
        );

        final completed = outcome as EditorEditCompleted;
        expect(completed.body.text, body);
        expect(completed.body.edited, isFalse);
      });

      test('the platform default editor is launched through the platform '
          'action', () async {
        final draftId = await prepareDraft();
        final launched = <EditorPlatformRequest>[];
        service = buildService(
          platformLauncher: (request) async {
            launched.add(request);
            return const EditorPlatformOutcome(launched: true);
          },
        );

        final outcome = await service.edit(options, draftId);

        expect(launched.single.path, endsWith('working.txt'));
        expect(requests, isEmpty);
        expect(acknowledgements, hasLength(1));
        expect(outcome, isA<EditorEditCompleted>());
      });
    });

    group('recovery', () {
      test(
        'a failed launch keeps the draft and asks how to continue',
        () async {
          final draftId = await prepareDraft();
          service = buildService(
            processRunner: (request) async {
              requests.add(request);
              return const EditorProcessOutcome.failed(
                'The editor could not be started.',
              );
            },
          );

          final outcome = await service.edit(
            options,
            draftId,
            editorChoice: 'code --wait',
          );

          expect(recoveries.single.reason, contains('could not be started'));
          expect(outcome, isA<EditorEditCancelled>());
          expect(await drafts.find(options, draftId), isNotNull);
        },
      );

      test('a retry launches the editor again', () async {
        final draftId = await prepareDraft();
        var attempts = 0;
        service = buildService(
          processRunner: (request) async {
            requests.add(request);
            attempts++;
            if (attempts == 1) {
              return const EditorProcessOutcome.failed('The editor failed.');
            }
            return const EditorProcessOutcome(started: true, exitCode: 0);
          },
          recover: (request) async {
            recoveries.add(request);
            return const EditorRecoveryRetry();
          },
        );

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'code --wait',
        );

        expect(requests, hasLength(2));
        expect(outcome, isA<EditorEditCompleted>());
      });

      test('the number of the attempts is reported', () async {
        final draftId = await prepareDraft();
        service = buildService(
          processRunner: (request) async {
            requests.add(request);
            return const EditorProcessOutcome.failed('The editor failed.');
          },
          recover: (request) async {
            recoveries.add(request);
            return const EditorRecoveryRetry();
          },
        );

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'code --wait',
        );

        expect(requests, hasLength(maxEditorSessionAttempts));
        expect(
          (outcome as EditorEditCancelled).reason,
          'The editor did not start after $maxEditorSessionAttempts attempts.',
        );
      });

      test('another editor is launched instead', () async {
        final draftId = await prepareDraft();
        service = buildService(
          processRunner: (request) async {
            requests.add(request);
            if (request.executable == '/programs/code') {
              return const EditorProcessOutcome.failed('The editor failed.');
            }
            return const EditorProcessOutcome(started: true, exitCode: 0);
          },
          recover: (request) async {
            recoveries.add(request);
            return const EditorRecoveryOtherEditor('other --wait');
          },
        );

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'code --wait',
        );

        expect(requests, hasLength(2));
        expect(requests.last.executable, '/programs/other');
        expect(outcome, isA<EditorEditCompleted>());
      });

      test('a session without a display offers the alternatives instead of '
          'opening the platform default editor', () async {
        final draftId = await prepareDraft();
        service = buildService(
          environment: const EditorSessionEnvironment(
            hasTerminal: true,
            hasDisplay: false,
          ),
        );

        final outcome = await service.edit(options, draftId);

        expect(recoveries.single.reason, contains('display'));
        expect(requests, isEmpty);
        expect(outcome, isA<EditorEditCancelled>());
        expect(await drafts.find(options, draftId), isNotNull);
      });

      test('an alternative editor that cannot be used offers the alternatives '
          'again', () async {
        final draftId = await prepareDraft();
        service = buildService(
          processRunner: (request) async {
            requests.add(request);
            return const EditorProcessOutcome.failed('The editor failed.');
          },
          recover: (request) async {
            recoveries.add(request);
            if (recoveries.length == 1) {
              return const EditorRecoveryOtherEditor('other --wait && more');
            }
            return const EditorRecoveryCancel();
          },
        );

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'code --wait',
        );

        expect(recoveries, hasLength(2));
        expect(recoveries.last.reason, contains('shell expression'));
        expect(requests, hasLength(1));
        expect(outcome, isA<EditorEditCancelled>());
      });

      test(
        'the body file alternative offers the protected working copy',
        () async {
          final draftId = await prepareDraft();
          service = buildService(
            processRunner: (request) async {
              requests.add(request);
              return const EditorProcessOutcome.failed('The editor failed.');
            },
            recover: (request) async {
              recoveries.add(request);
              return const EditorRecoveryBodyFile();
            },
          );

          final outcome = await service.edit(
            options,
            draftId,
            editorChoice: 'code --wait',
          );

          final bodyFile = outcome as EditorEditBodyFile;
          expect(bodyFile.path, endsWith('working.txt'));
          expect(fs.file(bodyFile.path).existsSync(), isTrue);
        },
      );
    });

    group('refusals', () {
      test(
        'a dry-run session launches nothing and prepares no working copy',
        () async {
          final draftId = await prepareDraft();

          await expectLater(
            service.edit(
              options.copyWith(dryRun: true),
              draftId,
              editorChoice: 'code --wait',
            ),
            throwsA(isA<MambaException>()),
          );

          expect(requests, isEmpty);
          expect(
            fs
                .file(
                  '/work/project/.agent-resource/instruction-drafts/'
                  '$draftId/working.txt',
                )
                .existsSync(),
            isFalse,
          );
        },
      );

      test('an unattended session asks nothing and launches nothing', () async {
        final draftId = await prepareDraft();
        service = buildService(
          environment: const EditorSessionEnvironment(
            hasTerminal: false,
            hasDisplay: false,
          ),
        );

        await expectLater(
          service.edit(options, draftId, editorChoice: 'code --wait'),
          throwsA(isA<MambaException>()),
        );

        expect(requests, isEmpty);
        expect(acknowledgements, isEmpty);
        expect(recoveries, isEmpty);
        expect(
          fs
              .file(
                '/work/project/.agent-resource/instruction-drafts/'
                '$draftId/working.txt',
              )
              .existsSync(),
          isFalse,
        );
      });

      test('a batch launcher is refused before it is launched', () async {
        final draftId = await prepareDraft();
        service = buildService(executables: EditorExecutableResolver());

        final outcome = await service.edit(
          options,
          draftId,
          editorChoice: 'helper.cmd',
        );

        expect(outcome, isA<EditorEditCancelled>());
        expect(
          (outcome as EditorEditCancelled).reason,
          contains('batch launcher'),
        );
        expect(requests, isEmpty);
      });

      test('a batch launcher of the search path is not resolved', () async {
        final draftId = await prepareDraft();
        final directory = Directory.systemTemp.createTempSync(
          'agent resource editor ',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        File('${directory.path}/helper.cmd').writeAsStringSync('@echo off\n');
        service = buildService(executables: EditorExecutableResolver());

        final searched = LifecycleOptions(
          processWorkingDirectory: '/work/project',
          environment: <String, String>{'PATH': directory.path},
          scope: LifecycleScope.project,
          cwd: '/work/project',
          projectRoot: '/work/project',
          home: '/home/user',
        );

        final outcome = await service.edit(
          searched,
          draftId,
          editorChoice: 'helper',
        );

        expect(outcome, isA<EditorEditCancelled>());
        expect((outcome as EditorEditCancelled).reason, contains('not found'));
        expect(requests, isEmpty);
      });

      test(
        'the launched program is the resolved program of the supplied search '
        'path',
        () async {
          final draftId = await prepareDraft();
          final directory = Directory.systemTemp.createTempSync(
            'agent resource editor path ',
          );
          addTearDown(() => directory.deleteSync(recursive: true));
          File(p.join(directory.path, 'code.exe')).writeAsBytesSync(<int>[1]);
          final searched = LifecycleOptions(
            processWorkingDirectory: '/work/project',
            environment: <String, String>{'PATH': directory.path},
            scope: LifecycleScope.project,
            cwd: '/work/project',
            projectRoot: '/work/project',
            home: '/home/user',
          );
          service = buildService(executables: EditorExecutableResolver());

          await service.edit(searched, draftId, editorChoice: 'code --wait');

          expect(
            requests.single.executable,
            p.join(directory.path, 'code.exe'),
          );
          expect(requests.single.environment['PATH'], directory.path);
          expect(
            requests.single.workingDirectory,
            searched.processWorkingDirectory,
          );
        },
      );

      test(
        'an unusable editor configuration offers the alternatives',
        () async {
          final draftId = await prepareDraft();

          final outcome = await service.edit(
            options,
            draftId,
            editorChoice: 'code --wait && other',
          );

          expect(outcome, isA<EditorEditCancelled>());
          expect(
            (outcome as EditorEditCancelled).reason,
            contains('shell expression'),
          );
          expect(recoveries, hasLength(1));
          expect(requests, isEmpty);
        },
      );
    });
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
