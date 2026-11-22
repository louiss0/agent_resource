import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:agent_resource/src/services/prompt_inspection_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('PackLifecycleService discovery', () {
    late fslib.FileSystem fs;
    late fslib.Directory sandbox;
    late fslib.Directory project;
    late fslib.Directory home;
    late fslib.Directory source;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      sandbox = fs.directory('/sandbox')..createSync();
      project = fs.directory(fs.path.join(sandbox.path, 'project'))
        ..createSync();
      home = fs.directory(fs.path.join(sandbox.path, 'home'))..createSync();
      source = fs.directory(fs.path.join(sandbox.path, 'source'))..createSync();
      fs
          .file(fs.path.join(project.path, 'agent-resources.toml'))
          .writeAsStringSync('''
schema_version = 1
[cli.install]
targets = ["claude"]
[packs."local/demo".source]
kind = "local"
path = "../source"
[packs."local/demo".update]
track = { kind = "local" }
''');
    });

    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    PackDiscoveryRequest request({
      List<PackResourceType> types = const [],
      String? target,
      String pack = 'local/demo',
    }) => PackDiscoveryRequest(
      pack: pack,
      types: types,
      target: target,
      processWorkingDirectory: sandbox.path,
      environment: {
        'HOME': home.path,
        'USERPROFILE': home.path,
        'APPDATA': fs.path.join(home.path, 'AppData', 'Roaming'),
        'LOCALAPPDATA': fs.path.join(home.path, 'AppData', 'Local'),
      },
      scope: LifecycleScope.project,
      cwd: project.path,
      projectRoot: project.path,
      home: home.path,
    );

    /// Writes a skill package with the given frontmatter.
    void writeSkill(String relative, String frontmatter) {
      final directory = fs.directory(
        fs.path.joinAll([source.path, ...relative.split('/')]),
      )..createSync(recursive: true);
      fs
          .file(fs.path.join(directory.path, 'SKILL.md'))
          .writeAsStringSync(frontmatter);
    }

    /// Writes the source catalog of the pack.
    void writeCatalog(String content) {
      fs
          .file(fs.path.join(source.path, 'agent-resources.toml'))
          .writeAsStringSync(content);
    }

    test(
      'reports every discovered source once with its consumer views',
      () async {
        writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/manual"
[[catalog.skills]]
path = "skills/plain"
[[catalog.agents]]
path = "agents/reviewer.md"
profile = "claude"
''');
        writeSkill('skills/manual', '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual
''');
        writeSkill('skills/plain', '''
---
name: plain
description: An ordinary skill.
---
# Plain
''');
        fs.file(fs.path.join(source.path, 'agents', 'reviewer.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
---
name: reviewer
description: Reviews code.
---
Review changes.
''');
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        final report = await service.discover(request());

        expect(report.pack, 'local/demo');
        expect(report.candidates.map((candidate) => candidate.id).toList(), [
          'skills/manual',
          'skills/plain',
          'agents/reviewer.md',
        ]);
        final manual = report.candidates.firstWhere(
          (candidate) => candidate.id == 'skills/manual',
        );
        expect(manual.kind.name, 'skill');
        expect(manual.promptCandidate, isTrue);
        expect(
          manual.views
              .map(
                (view) => '${view.consumer.name}:${view.classification.name}',
              )
              .toList(),
          ['claude:prompt', 'codex:nonPrompt', 'pi:prompt'],
        );
        expect(
          manual.views
              .firstWhere((view) => view.consumer == PromptConsumer.claude)
              .installationSupported,
          isTrue,
        );
        expect(manual.admission, isNotNull);
        expect(manual.admission!['scope'], 'source-only');
        expect(manual.admission!['eligible'], isTrue);
        expect(
          manual.views
              .firstWhere((view) => view.consumer == PromptConsumer.pi)
              .installationSupported,
          isFalse,
        );
        final plain = report.candidates.firstWhere(
          (candidate) => candidate.id == 'skills/plain',
        );
        expect(plain.promptCandidate, isFalse);
        expect(plain.admission, isNotNull);
        final agent = report.candidates.firstWhere(
          (candidate) => candidate.id == 'agents/reviewer.md',
        );
        expect(agent.kind.name, 'agent');
        expect(agent.profile, 'claude');
        expect(agent.views, isEmpty);
        expect(agent.admission, isNull);
      },
    );

    test(
      'reports method-specific admission diagnostics for a Skill candidate',
      () async {
        writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/loose"
''');
        writeSkill('skills/loose', '''
---
name: loose
description: A skill with a loose root file.
---
See guide.md.
''');
        fs
            .file(fs.path.join(source.path, 'skills', 'loose', 'guide.md'))
            .writeAsStringSync('Guide');
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        final report = await service.discover(
          request(types: [PackResourceType.skill]),
        );

        final candidate = report.candidates.single;
        final admission = candidate.admission!;
        expect(admission['eligible'], isTrue);
        expect((admission['methods'] as Map)['copy'], isTrue);
        expect((admission['methods'] as Map)['canonical'], isTrue);
        expect((admission['methods'] as Map)['source-link'], isFalse);
        expect('${admission['diagnostics']}', contains('source-link'));
        expect(report.renderText(), contains('admission: eligible'));
      },
    );

    test('the selected kinds isolate the reported selections', () async {
      writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/manual"
[[catalog.skills]]
path = "skills/plain"
''');
      writeSkill('skills/manual', '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual
''');
      writeSkill('skills/plain', '''
---
name: plain
description: An ordinary skill.
---
# Plain
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final skills = await service.discover(
        request(types: const [PackResourceType.skill]),
      );
      expect(skills.candidates.map((candidate) => candidate.id).toList(), [
        'skills/manual',
        'skills/plain',
      ]);
      final prompts = await service.discover(
        request(types: const [PackResourceType.prompt]),
      );
      // The manual-only Skill is a Prompt candidate of the same source.
      expect(prompts.candidates.map((candidate) => candidate.id).toList(), [
        'skills/manual',
      ]);
    });

    test('discovers the Prompt sources of the configured root', () async {
      fs
          .file(fs.path.join(project.path, 'agent-resources.toml'))
          .writeAsStringSync('''
schema_version = 1
[cli.install]
targets = ["claude"]
[packs."local/demo".discovery]
prompts_directory = "prompt-pack"
[packs."local/demo".source]
kind = "local"
path = "../source"
[packs."local/demo".update]
track = { kind = "local" }
''');
      writeSkill('prompt-pack/assistant', '''
---
name: assistant
description: A manual-only prompt.
disable-model-invocation: true
---
# Assistant
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final report = await service.discover(request());

      expect(report.candidates.map((candidate) => candidate.id).toList(), [
        'prompt-pack/assistant',
      ]);
      expect(report.candidates.single.kind.name, 'prompt');
      expect(report.candidates.single.promptCandidate, isTrue);
    });

    test('a declared catalog never scans an undeclared path', () async {
      writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/declared"
''');
      writeSkill('skills/declared', '''
---
name: declared
description: A declared skill.
---
# Declared
''');
      writeSkill('skills/undeclared', '''
---
name: undeclared
description: An undeclared skill.
---
# Undeclared
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final report = await service.discover(request());

      expect(report.candidates.map((candidate) => candidate.id).toList(), [
        'skills/declared',
      ]);
    });

    test('a conflicting catalog declaration is refused', () async {
      writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/manual"
[[catalog.prompts]]
path = "skills/manual"
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      await expectLater(
        service.discover(request()),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('same source path'),
          ),
        ),
      );
    });

    test('a standalone template needs a declared profile', () async {
      writeCatalog('''
schema_version = 1
[[catalog.prompts]]
path = "prompts/assistant.md"
''');
      fs.file(fs.path.join(source.path, 'prompts', 'assistant.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''---
description: A Pi template.
---
Assist the user.
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final unclassified = await service.discover(request());
      final candidate = unclassified.candidates.single;
      expect(candidate.form.name, 'template');
      expect(candidate.views.map((view) => view.classification.name).toSet(), {
        'unclassified',
      });

      final targeted = await service.discover(request(target: 'pi'));
      expect(
        targeted.candidates.single.views
            .firstWhere((view) => view.consumer == PromptConsumer.pi)
            .classification,
        PromptClassification.prompt,
      );
    });

    test('a declared profile recognizes a standalone template', () async {
      writeCatalog('''
schema_version = 1
[[catalog.prompts]]
path = "prompts/assistant.md"
profile = "pi"
''');
      fs.file(fs.path.join(source.path, 'prompts', 'assistant.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''---
description: A Pi template.
---
Assist the user.
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final report = await service.discover(request());

      final candidate = report.candidates.single;
      expect(candidate.form.name, 'template');
      expect(candidate.profile, 'pi');
      expect(
        candidate.views
            .firstWhere((view) => view.consumer == PromptConsumer.pi)
            .classification,
        PromptClassification.prompt,
      );
      expect(candidate.validPrompt, isTrue);
    });

    test('the discovery never writes a management state', () async {
      writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/plain"
''');
      writeSkill('skills/plain', '''
---
name: plain
description: An ordinary skill.
---
# Plain
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      await service.discover(request());

      final state = fs.directory(fs.path.join(project.path, '.agent-resource'));
      expect(state.existsSync(), isFalse);
    });

    test('an operational inspection failure aborts the discovery', () async {
      writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/missing"
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      await expectLater(
        service.discover(request()),
        throwsA(isA<MambaException>()),
      );
    });

    test('an invalid Prompt view stays a diagnosable candidate', () async {
      writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/manual"
''');
      writeSkill('skills/manual', '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual
''');
      fs
          .directory(
            fs.path.join(source.path, 'skills', 'manual', 'references'),
          )
          .createSync(recursive: true);
      fs
          .file(
            fs.path.join(
              source.path,
              'skills',
              'manual',
              'references',
              'notes.md',
            ),
          )
          .writeAsStringSync('Notes.\n');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final report = await service.discover(request());

      final candidate = report.candidates.single;
      final claude = candidate.views.firstWhere(
        (view) => view.consumer == PromptConsumer.claude,
      );
      expect(claude.classification, PromptClassification.prompt);
      expect(claude.valid, isFalse);
      expect(claude.diagnostics, isNotEmpty);
    });

    test('an empty directory of the Prompt root is not a candidate', () async {
      fs
          .directory(fs.path.join(source.path, 'prompts', 'empty'))
          .createSync(recursive: true);
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final report = await service.discover(request());

      expect(report.candidates, isEmpty);
    });

    test('a linked entry of the Prompt root is refused', () async {
      final prompts = fs.directory(fs.path.join(source.path, 'prompts'))
        ..createSync(recursive: true);
      fs
          .link(fs.path.join(prompts.path, 'linked'))
          .createSync('/sandbox/elsewhere');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      await expectLater(
        service.discover(request()),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('linked source entries'),
          ),
        ),
      );
    });

    test('the Prompt root itself is a single candidate', () async {
      final prompts = fs.directory(fs.path.join(source.path, 'prompts'))
        ..createSync(recursive: true);
      fs.file(fs.path.join(prompts.path, 'SKILL.md')).writeAsStringSync('''---
name: prompts
description: A manual-only prompt.
disable-model-invocation: true
---
# Prompts
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final report = await service.discover(request());

      expect(report.candidates.map((candidate) => candidate.id).toList(), [
        'prompts',
      ]);
      expect(report.candidates.single.promptCandidate, isTrue);
    });

    test('a malformed control stays an unknown classification', () async {
      writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/manual"
''');
      writeSkill('skills/manual', '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: "yes"
---
# Manual
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final report = await service.discover(request());

      final candidate = report.candidates.single;
      expect(
        candidate.views
            .firstWhere((view) => view.consumer == PromptConsumer.claude)
            .classification,
        PromptClassification.malformed,
      );
      expect(candidate.promptCandidate, isTrue);
    });

    test('a blocked resource path invalidates the Prompt view', () async {
      writeCatalog('''
schema_version = 1
[[catalog.skills]]
path = "skills/manual"
''');
      writeSkill('skills/manual', '''
---
name: manual
description: A manual-only prompt.
disable-model-invocation: true
---
# Manual

Read scripts/run.sh for the steps.
''');
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      final report = await service.discover(request());

      final claude = report.candidates.single.views.firstWhere(
        (view) => view.consumer == PromptConsumer.claude,
      );
      expect(claude.classification, PromptClassification.prompt);
      expect(claude.valid, isFalse);
      expect(
        claude.diagnostics.map((diagnostic) => diagnostic.code),
        contains('RESOURCE_REFERENCE'),
      );
      // An invalid Prompt is not installable.
      expect(claude.installationSupported, isFalse);
    });
  });
}
