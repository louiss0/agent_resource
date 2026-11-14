import 'package:agent_resource/src/authoring/editor_interaction.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('editor command grammar', () {
    test('an executable and its arguments keep their boundaries', () {
      final command = EditorCommandGrammar.parse('code --wait --new-window');

      expect(command.executable, 'code');
      expect(command.arguments, <String>['--wait', '--new-window']);
    });

    test('a quoted argument is one literal argument', () {
      final command = EditorCommandGrammar.parse(
        '"C:\\Program Files\\Editor\\code.exe" --wait',
      );

      expect(command.executable, r'C:\Program Files\Editor\code.exe');
      expect(command.arguments, <String>['--wait']);
    });

    test('a quoted argument keeps the whitespace of the path', () {
      final command = EditorCommandGrammar.parse('"/opt/my editor/bin/edit"');

      expect(command.executable, '/opt/my editor/bin/edit');
      expect(command.arguments, isEmpty);
    });

    test('a shell expression is refused', () {
      expect(
        () => EditorCommandGrammar.parse('code --wait && rm -rf /'),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('shell expression'),
          ),
        ),
      );
    });

    test('a shell substitution is refused', () {
      expect(
        () => EditorCommandGrammar.parse(r'code $(whoami)'),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('shell expression'),
          ),
        ),
      );
    });

    test('a shell interpreter is refused', () {
      expect(
        () => EditorCommandGrammar.parse('cmd /c code'),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('command interpreter'),
          ),
        ),
      );
    });
  });

  group('editor selection', () {
    test('an explicit choice wins over the configured variables', () {
      final selection = selectEditor(
        explicitChoice: 'code --wait',
        environment: const <String, String>{'VISUAL': 'vim', 'EDITOR': 'nano'},
      );

      expect(selection.source, EditorSelectionSource.explicitChoice);
      expect(selection.command?.executable, 'code');
      expect(selection.command?.arguments, <String>['--wait']);
    });

    test('the configured visual variable wins over the editor variable', () {
      final selection = selectEditor(
        environment: const <String, String>{'VISUAL': 'vim', 'EDITOR': 'nano'},
      );

      expect(selection.source, EditorSelectionSource.visualVariable);
      expect(selection.command?.executable, 'vim');
    });

    test('the configured editor variable is used when no visual variable is '
        'configured', () {
      final selection = selectEditor(
        environment: const <String, String>{'EDITOR': 'nano'},
      );

      expect(selection.source, EditorSelectionSource.editorVariable);
      expect(selection.command?.executable, 'nano');
    });

    test('the platform default is selected when nothing is configured', () {
      final selection = selectEditor(environment: const <String, String>{});

      expect(selection.source, EditorSelectionSource.platformDefault);
      expect(selection.command, isNull);
      expect(
        selection.completion,
        EditorCompletionMode.savedAndFinishedAcknowledgement,
      );
    });

    test('an unusable configured visual variable does not fall through', () {
      expect(
        () => selectEditor(
          environment: const <String, String>{
            'VISUAL': 'code --wait && other',
            'EDITOR': 'nano',
          },
        ),
        throwsA(isA<MambaException>()),
      );
    });

    test('an unusable explicit choice does not fall through', () {
      expect(
        () => selectEditor(
          explicitChoice: 'sh -c code',
          environment: const <String, String>{'VISUAL': 'vim'},
        ),
        throwsA(isA<MambaException>()),
      );
    });
  });

  group('editor completion contract', () {
    test('a documented wait option is recognized', () {
      expect(
        editorWaitContract(EditorCommandGrammar.parse('code --wait')),
        EditorWaitContract.documented,
      );
    });

    test('a waiting client is recognized without an option', () {
      expect(
        editorWaitContract(EditorCommandGrammar.parse('emacsclient')),
        EditorWaitContract.documented,
      );
    });

    test('an editor without a documented wait is not assumed to wait', () {
      expect(
        editorWaitContract(EditorCommandGrammar.parse('code')),
        EditorWaitContract.none,
      );
    });

    test('a disabled wait is not a documented wait', () {
      expect(
        editorWaitContract(EditorCommandGrammar.parse('emacsclient --no-wait')),
        EditorWaitContract.none,
      );
    });

    test('a disabled wait with a value is not a documented wait', () {
      expect(
        editorWaitContract(
          EditorCommandGrammar.parse('emacsclient --no-wait=frames'),
        ),
        EditorWaitContract.none,
      );
    });

    test('a new frame does not wait for the editing', () {
      expect(
        editorWaitContract(EditorCommandGrammar.parse('emacsclient -n')),
        EditorWaitContract.none,
      );
    });

    test('an unknown program is never assumed to wait', () {
      expect(
        editorWaitContract(EditorCommandGrammar.parse('my-editor --wait')),
        EditorWaitContract.none,
      );
    });

    test('a terminal editor is recognized', () {
      expect(
        editorProgramKind(EditorCommandGrammar.parse('vim')),
        EditorProgramKind.terminal,
      );
    });

    test('an unknown program is not assumed to be a terminal editor', () {
      expect(
        editorProgramKind(EditorCommandGrammar.parse('my-editor')),
        EditorProgramKind.unknown,
      );
    });
  });
}
