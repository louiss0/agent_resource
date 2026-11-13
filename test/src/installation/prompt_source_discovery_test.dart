import 'package:agent_resource/src/installation/prompt_source_discovery.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('discoverPromptSource', () {
    late fslib.FileSystem fs;
    late fslib.Directory root;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      root = fs.directory('/source/prompts')..createSync(recursive: true);
    });

    /// Writes a skill-backed Prompt package.
    void writePackage(String name) {
      final directory = fs.directory(fs.path.join(root.path, name))
        ..createSync(recursive: true);
      fs
          .file(fs.path.join(directory.path, 'SKILL.md'))
          .writeAsStringSync('---\nname: $name\ndescription: A prompt.\n---\n');
    }

    test('discovers the direct packages and one group level', () async {
      writePackage('direct');
      writePackage('group/nested');

      final offerings = await discoverPromptSource(
        root: root.path,
        relativeRoot: 'prompts',
        fileSystem: fs,
      );

      expect(offerings.map((offering) => offering.path).toList(), [
        'prompts/direct',
        'prompts/group/nested',
      ]);
      expect(offerings.first.template, isFalse);
    });

    test('discovers a standalone template', () async {
      fs
          .file(fs.path.join(root.path, 'assistant.md'))
          .writeAsStringSync('---\ndescription: A template.\n---\n');

      final offerings = await discoverPromptSource(
        root: root.path,
        relativeRoot: 'prompts',
        fileSystem: fs,
      );

      expect(offerings.single.path, 'prompts/assistant.md');
      expect(offerings.single.template, isTrue);
    });

    test('refuses a linked package marker', () async {
      final directory = fs.directory(fs.path.join(root.path, 'linked'))
        ..createSync(recursive: true);
      fs
          .link(fs.path.join(directory.path, 'SKILL.md'))
          .createSync('/elsewhere/SKILL.md');

      await expectLater(
        discoverPromptSource(
          root: root.path,
          relativeRoot: 'prompts',
          refuseLinkedEntries: true,
          fileSystem: fs,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('linked source entries'),
          ),
        ),
      );
    });

    test('refuses the entry budget', () async {
      writePackage('direct');

      await expectLater(
        discoverPromptSource(
          root: root.path,
          relativeRoot: 'prompts',
          budget: PromptDiscoveryBudget(maxEntries: 0),
          fileSystem: fs,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('20,000-entry budget'),
          ),
        ),
      );
    });

    test('refuses the directory budget', () async {
      writePackage('direct');

      await expectLater(
        discoverPromptSource(
          root: root.path,
          relativeRoot: 'prompts',
          budget: PromptDiscoveryBudget(maxDirectories: 0),
          fileSystem: fs,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('2,000-directory budget'),
          ),
        ),
      );
    });
  });
}
