import 'package:agent_resource/skill_update_command.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('skill update', () {
      test('requires an explicit scope', () async {
        final result = await Executor('agent_resource', 'Test.', '1.0.0', [
          SkillUpdateCommand(
            SkillLifecycleService(fileSystem: MemoryFileSystem()),
          ),
        ]).fake().execute(['update', 'id']);
        expect(
          result,
          isA<MambaFailureResult>().having(
            (v) => v.message,
            'message',
            'Skill update requires --scope project or user.',
          ),
        );
      });
    });
  });
}
