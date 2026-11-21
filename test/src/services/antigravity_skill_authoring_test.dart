import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('Antigravity Skill authoring operations', () {
    late MemoryFileSystem fs;
    late LifecycleOptions options;

    setUp(() {
      fs = MemoryFileSystem.test(style: FileSystemStyle.posix);
      for (final path in const [
        '/sandbox/project',
        '/sandbox/home',
        '/sandbox/state',
        '/sandbox/gemini/config',
        '/sandbox/source',
      ]) {
        fs.directory(path).createSync(recursive: true);
      }
      fs
          .file('/sandbox/source/SKILL.md')
          .writeAsStringSync(
            '---\nname: source\ndescription: Source skill.\n---\nBody.\n',
          );
      options = LifecycleOptions(
        processWorkingDirectory: '/sandbox/project',
        scope: LifecycleScope.user,
        cwd: '/sandbox/project',
        projectRoot: '/sandbox/project',
        home: '/sandbox/home',
        geminiDir: '/sandbox/gemini',
        stateDir: '/sandbox/state',
      );
    });

    Future<AuthoringPlan> planFor(
      AuthoringOperation operation, {
      String? bodyText,
      String name = 'copied',
    }) {
      final service = AuthoringPlanService(fileSystem: fs);
      final inputs = parseAuthoringInputs(
        operation: operation,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.antigravity,
        scope: LifecycleScope.user,
        sourcePath: '/sandbox/source',
        bodyText: bodyText,
        fields: <String, Object?>{'name': name, 'description': 'Copied skill.'},
      );
      return service.plan(inputs, options);
    }

    test('clone plans into the Antigravity config-skill root', () async {
      final plan = await planFor(AuthoringOperation.clone);
      expect(plan.profile, AuthoringProfile.antigravity);
      expect(plan.ready, isTrue);
      expect(plan.output, '/sandbox/gemini/config/skills/copied/SKILL.md');
    });

    test('edit plans an in-place Antigravity Skill change', () async {
      final plan = await planFor(
        AuthoringOperation.edit,
        bodyText: 'Edited body.',
        name: 'source',
      );
      expect(plan.ready, isTrue);
      expect(plan.output, '/sandbox/source/SKILL.md');
    });
  });
}
