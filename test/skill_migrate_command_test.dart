import 'package:agent_resource/skill_migrate_command.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('skill migrate', () {
      test('requires an explicit method', () async {
        final result = await Executor('agent_resource', 'Test.', '1.0.0', [
          SkillMigrateCommand(
            SkillLifecycleService(fileSystem: MemoryFileSystem()),
          ),
        ]).fake().execute(['migrate', 'id', '--scope', 'project']);
        expect(
          result,
          isA<MambaFailureResult>().having(
            (v) => v.message,
            'message',
            'Skill migrate requires --method.',
          ),
        );
      });
    });
  });
}
