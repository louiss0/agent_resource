import 'package:agent_resource/src/pack/skill_admission.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('SkillAdmission', () {
    late fslib.FileSystem fs;
    late fslib.Directory sandbox;
    late String skill;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      sandbox = fs.directory('/sandbox')..createSync();
      skill = fs.path.join(sandbox.path, 'demo');
      fs.directory(skill).createSync();
      fs.file(fs.path.join(skill, 'SKILL.md')).writeAsStringSync('''---
name: demo
description: Demonstrates admission.
---
# Demo
''');
    });

    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    test('admits every supported native root and reports the native name', () {
      for (final folder in const [
        'references',
        'scripts',
        'assets',
        'agents',
      ]) {
        fs.directory(fs.path.join(skill, folder)).createSync();
      }

      final report = SkillAdmission(fileSystem: fs).inspect(skill);

      expect(report.name, 'demo');
      expect(report.approvedExtraFolders, isEmpty);
    });

    test('returns only explicitly approved extra root folders', () {
      fs.directory(fs.path.join(skill, 'rules')).createSync();
      fs.directory(fs.path.join(skill, 'templates')).createSync();

      final report = SkillAdmission(fileSystem: fs)
          .inspect(skill, approvedExtraFolders: const {'rules', 'templates'});

      expect(report.approvedExtraFolders, {'rules', 'templates'});
    });

    test('rejects an extra root folder without bounded approval', () {
      fs.directory(fs.path.join(skill, 'rules')).createSync();

      expect(
        () => SkillAdmission(fileSystem: fs).inspect(skill),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('rules'),
          ),
        ),
      );
    });

    test('recursively rejects links even inside an approved folder', () {
      final rules = fs.directory(fs.path.join(skill, 'rules'))..createSync();
      final outside = fs.file(fs.path.join(sandbox.path, 'outside.txt'))
        ..writeAsStringSync('outside');
      fs.link(fs.path.join(rules.path, 'escape.txt')).createSync(outside.path);

      expect(
        () =>
            SkillAdmission(fileSystem: fs)
                .inspect(skill, approvedExtraFolders: const {'rules'}),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('escape.txt'),
          ),
        ),
      );
    });
  });
}
