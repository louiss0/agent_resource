import 'dart:io';

import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/services/editor_interaction_service.dart';
import 'package:agent_resource/src/services/instruction_draft_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/trusted_temp.dart';

void main() {
  group('the editor session over protected storage', () {
    test(
      'the edited draft is read back through a real program launch',
      () async {
        final root = Directory(
          createTrustedTempPathSync('agent resource editor session '),
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final project = Directory(p.join(root.path, 'project'))
          ..createSync(recursive: true);
        final home = Directory(p.join(root.path, 'home'))
          ..createSync(recursive: true);
        final helper = File(p.join(root.path, 'helper.dart'));
        helper.writeAsStringSync('''
import 'dart:io';

void main(List<String> arguments) {
  final record = Platform.environment['HELPER_RECORD'];
  if (record != null) {
    File(record).writeAsStringSync(arguments.join('\\n'));
  }
  File(arguments.last).writeAsStringSync('Edited by the helper\\n');
}
''');
        final record = File(p.join(root.path, 'arguments.txt'));
        final fileSystem = const LocalFileSystem();
        final drafts = InstructionDraftService(
          fileSystem: fileSystem,
          state: LifecycleStateService(io: LifecycleIO(fs: fileSystem)),
        );
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          environment: <String, String>{'HELPER_RECORD': record.path},
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
        );
        final inputs = parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          scope: LifecycleScope.project,
          bodyText: 'First line\nSecond line\n',
          fields: const <String, Object?>{
            'name': 'demo',
            'description': 'Demo resource',
          },
        );
        final draft = await drafts.prepare(options, inputs);
        final service = EditorInteractionService(
          drafts: drafts,
          environment: const EditorSessionEnvironment(
            hasTerminal: true,
            hasDisplay: true,
          ),
          acknowledge: (request) async {
            // The helper program runs in the background: the confirmation waits
            // for its record so that the test observes a finished session.
            for (var attempt = 0; attempt < 100; attempt++) {
              if (record.existsSync()) return true;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            return false;
          },
        );

        final outcome = await service.edit(
          options,
          draft.draftId,
          editorChoice: '"${Platform.resolvedExecutable}" "${helper.path}"',
        );

        expect(outcome, isA<EditorEditCompleted>());
        final completed = outcome as EditorEditCompleted;
        expect(completed.body.text, 'Edited by the helper\n');
        expect(completed.body.edited, isTrue);
        // The program received the working copy as one argument, although its
        // path carries spaces.
        final arguments = (await record.readAsString()).split('\n');
        expect(arguments, hasLength(1));
        expect(arguments.single, completed.path);
        expect(completed.path, contains(' '));
      },
    );
  });
}
