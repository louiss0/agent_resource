import 'dart:io';

import 'package:agent_resource/src/authoring/editor_interaction.dart';
import 'package:agent_resource/src/authoring/editor_platform.dart';
import 'package:test/test.dart';

void main() {
  group('the platform default editor', () {
    test('a platform without a documented default text editor action fails '
        'clearly', () async {
      if (Platform.isWindows || Platform.isMacOS) {
        markTestSkipped(
          'The launch of the platform default text editor is not exercised: '
          'it would open a program on the machine of the operator.',
        );
        return;
      }

      final outcome = await const PlatformEditorLauncher().launch(
        EditorPlatformRequest(path: '/tmp/agent-resource-draft.txt'),
      );

      expect(outcome.launched, isFalse);
      expect(
        outcome.reason,
        contains('no documented default text editor action'),
      );
    });
  });
}
