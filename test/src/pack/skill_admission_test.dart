import 'dart:io';

import 'package:agent_resource/src/pack/skill_admission.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SkillAdmission', () {
    late Directory sandbox;
    late String skill;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('skill-admission-test-');
      skill = p.join(sandbox.path, 'demo');
      Directory(skill).createSync();
      File(p.join(skill, 'SKILL.md')).writeAsStringSync('''---
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
        Directory(p.join(skill, folder)).createSync();
      }

      final report = const SkillAdmission().inspect(skill);

      expect(report.name, 'demo');
      expect(report.approvedExtraFolders, isEmpty);
    });

    test('returns only explicitly approved extra root folders', () {
      Directory(p.join(skill, 'rules')).createSync();
      Directory(p.join(skill, 'templates')).createSync();

      final report = const SkillAdmission().inspect(
        skill,
        approvedExtraFolders: const {'rules', 'templates'},
      );

      expect(report.approvedExtraFolders, {'rules', 'templates'});
    });

    test('rejects an extra root folder without bounded approval', () {
      Directory(p.join(skill, 'rules')).createSync();

      expect(
        () => const SkillAdmission().inspect(skill),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('rules'),
          ),
        ),
      );
    });

    test('rejects the complete Skill for an unexpected loose root file', () {
      File(p.join(skill, 'README.md')).writeAsStringSync('Not admitted.');

      expect(
        () => const SkillAdmission().inspect(
          skill,
          approvedExtraFolders: const {'README.md'},
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('README.md'),
          ),
        ),
      );
    });

    test('recursively rejects links even inside an approved folder', () {
      final rules = Directory(p.join(skill, 'rules'))..createSync();
      final outside = File(p.join(sandbox.path, 'outside.txt'))
        ..writeAsStringSync('outside');
      Link(p.join(rules.path, 'escape.txt')).createSync(outside.path);

      expect(
        () => const SkillAdmission().inspect(
          skill,
          approvedExtraFolders: const {'rules'},
        ),
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
