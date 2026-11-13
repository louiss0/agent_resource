import 'dart:convert';

import 'package:agent_resource/src/conversion/conversion_evidence.dart';
import 'package:agent_resource/src/pack/pack_models.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('PackLifecycleService', () {
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
          .file(fs.path.join(source.path, 'agent-resources.toml'))
          .writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/prompt"
[[catalog.skills]]
path = "skills/plain"
''');
      final prompt = fs.directory(fs.path.join(source.path, 'skills', 'prompt'))
        ..createSync(recursive: true);
      fs.file(fs.path.join(prompt.path, 'SKILL.md')).writeAsStringSync('''
---
name: prompt
description: A manual-only prompt.
disable-model-invocation: true
---
# Prompt
''');
      final plain = fs.directory(fs.path.join(source.path, 'skills', 'plain'))
        ..createSync(recursive: true);
      fs.file(fs.path.join(plain.path, 'SKILL.md')).writeAsStringSync('''
---
name: plain
description: An ordinary skill.
---
# Plain
''');
      fs
          .file(fs.path.join(project.path, 'agent-resources.toml'))
          .writeAsStringSync('''
schema_version = 1
[cli.install]
targets = ["claude"]
skill_method = "copy"
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

    PackLifecycleRequest request(
      PackOperation operation, {
      List<PackResourceType>? resourceTypes,
      String? target = 'claude',
      List<String> only = const [],
      bool dryRun = false,
      bool yes = true,
    }) => PackLifecycleRequest(
      operation: operation,
      resourceType: PackResourceType.skill,
      resourceTypes: resourceTypes ?? const [],
      pack: 'local/demo',
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
      only: only,
      method:
          resourceTypes != null &&
              resourceTypes.contains(PackResourceType.agent)
          ? null
          : 'copy',
      target: target,
      dryRun: dryRun,
      yes: yes,
    );

    /// The live installation records of the project scope.
    List<Map<String, Object?>> ledger() {
      final path = fs.path.join(
        project.path,
        '.agent-resource',
        'installations.json',
      );
      if (!fs.file(path).existsSync()) return const <Map<String, Object?>>[];
      final document = jsonDecode(fs.file(path).readAsStringSync()) as Map;
      return [
        for (final record in document['installations']! as List)
          Map<String, Object?>.from(record as Map),
      ];
    }

    /// The installed native files of the project scope.
    List<String> installedFiles() {
      final root = fs.path.join(project.path, '.claude', 'skills');
      if (!fs.directory(root).existsSync()) return const <String>[];
      return [
        for (final entry in fs.directory(root).listSync(recursive: true))
          if (entry is fslib.File) entry.path,
      ]..sort();
    }

    /// The whole lock document of the project scope.
    Map<String, Object?> lockDocument() {
      final path = fs.path.join(
        project.path,
        '.agent-resource',
        'installations.json',
      );
      if (!fs.file(path).existsSync()) return const <String, Object?>{};
      return Map<String, Object?>.from(
        jsonDecode(fs.file(path).readAsStringSync()) as Map,
      );
    }

    /// The recorded source tree of the pack.
    List<String> sourceFiles() => [
      for (final entry in fs.directory(source.path).listSync(recursive: true))
        if (entry is fslib.File) entry.path,
    ]..sort();

    /// The recorded configuration of the project scope.
    String configurationText() => fs
        .file(fs.path.join(project.path, 'agent-resources.toml'))
        .readAsStringSync();

    void seedInvalidPrompt() {
      final prompt = fs.directory(
        fs.path.join(source.path, 'skills', 'prompt'),
      );
      fs
          .directory(fs.path.join(prompt.path, 'references'))
          .createSync(recursive: true);
      fs
          .file(fs.path.join(prompt.path, 'references', 'notes.md'))
          .writeAsStringSync('Notes.\n');
    }

    void seedMigratedRootFile() {
      final prompt = fs.directory(
        fs.path.join(source.path, 'skills', 'prompt'),
      );
      fs
          .file(fs.path.join(prompt.path, 'notes.md'))
          .writeAsStringSync('Notes.\n');
    }

    /// Records a pending coordinated transaction that reserves the pack.
    void seedPendingConversion() {
      const transactionId = 'cvx_0123456789abcdef0123456789abcdef';
      final sourceOwnership = ConversionOwnership(
        managed: true,
        installationId: 'ins_pending_source',
        nativeForm: 'skill-copy',
        location: fs.path.join(project.path, '.claude', 'skills', 'prompt'),
        nativeRoot: fs.path.join(project.path, '.claude', 'skills'),
        scope: 'project',
        provenance: const <String, Object?>{},
      );
      final targetOwnership = ConversionOwnership(
        managed: true,
        installationId: 'ins_pending_target',
        nativeForm: 'skill-copy',
        location: fs.path.join(project.path, '.agents', 'skills', 'prompt'),
        nativeRoot: fs.path.join(project.path, '.agents', 'skills'),
        scope: 'project',
        provenance: const <String, Object?>{},
      );
      final evidence = ConversionEvidence(
        transactionId: transactionId,
        operation: 'convert',
        phase: ConversionEvidencePhase.prepared,
        createdScope: 'project',
        source: ConversionParticipant(
          role: ConversionParticipantRole.source,
          intent: ConversionParticipantIntent.retired,
          artifactKind: 'skill-copy',
          location: sourceOwnership.location,
          scope: 'project',
          ownershipBefore: sourceOwnership,
        ),
        target: ConversionParticipant(
          role: ConversionParticipantRole.target,
          intent: ConversionParticipantIntent.created,
          artifactKind: 'skill-copy',
          location: targetOwnership.location,
          scope: 'project',
          ownershipAfter: targetOwnership,
        ),
        observations: const <String, Object?>{
          'coordinatorSourceRecord': <String, Object?>{
            'origin': <String, Object?>{'packKey': 'local/demo'},
          },
        },
      );
      final directory = fs.directory(
        fs.path.join(project.path, '.agent-resource', 'conversions'),
      )..createSync(recursive: true);
      fs
          .file(fs.path.join(directory.path, '$transactionId.json'))
          .writeAsStringSync(evidence.encode());
    }

    test(
      'installs a supported skill-backed Prompt through the Skill installation',
      () async {
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        final result = await service.execute(
          request(
            PackOperation.install,
            resourceTypes: const <PackResourceType>[PackResourceType.prompt],
            only: const <String>['prompt'],
          ),
        );

        expect(result.outcome, 'completed');
        expect(result.resources, hasLength(1));
        expect(result.resources.single.name, 'prompt');
        // The Prompt selection enrolls no extra source and no extra
        // membership: it keeps the Skill record and its one selection.
        final document = lockDocument();
        expect(document['packs'], isEmpty);
        final selections = document['selections']! as List;
        expect(selections, hasLength(1));
        expect((selections.single as Map)['membership'], 'selected');
        final operations = document['operations']! as List;
        expect(operations, hasLength(1));
        expect((operations.single as Map)['operation'], 'skills.install');
        final records = ledger();
        expect(records, hasLength(1));
        expect(records.single['artifactKind'], 'skill-copy');
        expect(
          records.single['location'],
          fs.path.join(project.path, '.claude', 'skills', 'prompt'),
        );
        expect(
          installedFiles(),
          contains(
            fs.path.join(
              project.path,
              '.claude',
              'skills',
              'prompt',
              'SKILL.md',
            ),
          ),
        );
      },
    );

    test('refuses a mixed selection before any installation effect', () async {
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      await expectLater(
        service.execute(
          request(
            PackOperation.install,
            resourceTypes: const <PackResourceType>[PackResourceType.prompt],
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.exitCode,
            'status',
            PackProcessStatus.invalidInput.code,
          ),
        ),
      );
      expect(ledger(), isEmpty);
      expect(installedFiles(), isEmpty);
    });

    test(
      'refuses a mixed kind selection before any installation effect',
      () async {
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        await expectLater(
          service.execute(
            request(
              PackOperation.install,
              resourceTypes: const <PackResourceType>[
                PackResourceType.prompt,
                PackResourceType.skill,
              ],
              only: const <String>['prompt'],
            ),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'diagnostic',
              contains('cannot be combined'),
            ),
          ),
        );
        expect(ledger(), isEmpty);
        expect(installedFiles(), isEmpty);
      },
    );

    test('refuses a Pi target before any installation effect', () async {
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      await expectLater(
        service.execute(
          request(
            PackOperation.install,
            resourceTypes: const <PackResourceType>[PackResourceType.prompt],
            target: 'pi',
            only: const <String>['prompt'],
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('Pi'),
          ),
        ),
      );
      expect(ledger(), isEmpty);
      expect(installedFiles(), isEmpty);
    });

    test(
      'refuses an invalid Prompt without an ordinary Skill fallback',
      () async {
        seedInvalidPrompt();
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        await expectLater(
          service.execute(
            request(
              PackOperation.install,
              resourceTypes: const <PackResourceType>[PackResourceType.prompt],
              only: const <String>['prompt'],
            ),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              PackProcessStatus.invalidInput.code,
            ),
          ),
        );
        expect(ledger(), isEmpty);
        expect(installedFiles(), isEmpty);

        // The ordinary Skill selection does not fall back to installing the
        // invalid Prompt as an ordinary Skill.
        await expectLater(
          service.execute(
            request(
              PackOperation.install,
              resourceTypes: const <PackResourceType>[PackResourceType.skill],
              only: const <String>['prompt'],
            ),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              PackProcessStatus.invalidInput.code,
            ),
          ),
        );
        expect(ledger(), isEmpty);
        expect(installedFiles(), isEmpty);
      },
    );

    test(
      'the root Markdown migration cannot disguise an invalid Prompt',
      () async {
        seedMigratedRootFile();
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        await expectLater(
          service.execute(
            request(
              PackOperation.install,
              resourceTypes: const <PackResourceType>[PackResourceType.prompt],
              only: const <String>['prompt'],
            ),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              PackProcessStatus.invalidInput.code,
            ),
          ),
        );
        expect(ledger(), isEmpty);
        expect(installedFiles(), isEmpty);
      },
    );

    test(
      'the untyped installation keeps the Skill and Agent defaults',
      () async {
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        final result = await service.execute(
          request(
            PackOperation.install,
            resourceTypes: packDefaultResourceTypes,
            only: const <String>['prompt', 'plain'],
          ),
        );

        expect(result.outcome, 'completed');
        expect(result.resources, hasLength(2));
        // A valid skill-backed Prompt is consumed by the ordinary Skill
        // selection as a native Skill.
        expect(
          installedFiles(),
          contains(
            fs.path.join(
              project.path,
              '.claude',
              'skills',
              'prompt',
              'SKILL.md',
            ),
          ),
        );
      },
    );

    test('the prompt type applies to pack install and validate only', () async {
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      await expectLater(
        service.execute(
          request(
            PackOperation.remove,
            resourceTypes: const <PackResourceType>[PackResourceType.prompt],
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'diagnostic',
            contains('pack install and pack validate only'),
          ),
        ),
      );
      expect(ledger(), isEmpty);
    });

    test(
      'a dry run reports the Prompt selection without publishing it',
      () async {
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        final result = await service.execute(
          request(
            PackOperation.install,
            resourceTypes: const <PackResourceType>[PackResourceType.prompt],
            only: const <String>['prompt'],
            dryRun: true,
          ),
        );

        expect(result.outcome, 'preview');
        expect(ledger(), isEmpty);
        expect(installedFiles(), isEmpty);
      },
    );

    test(
      'the validation of the prompt kind reports the Prompt failures',
      () async {
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        final valid = await service.execute(
          request(
            PackOperation.validate,
            resourceTypes: const <PackResourceType>[PackResourceType.prompt],
            target: null,
            only: const <String>['prompt'],
          ),
        );
        expect(valid.outcome, 'valid');
        expect(valid.resources, hasLength(1));

        seedInvalidPrompt();
        await expectLater(
          service.execute(
            request(
              PackOperation.validate,
              resourceTypes: const <PackResourceType>[PackResourceType.prompt],
              target: null,
              only: const <String>['prompt'],
            ),
          ),
          throwsA(
            isA<MambaException>()
                .having(
                  (error) => error.exitCode,
                  'status',
                  PackProcessStatus.invalidInput.code,
                )
                .having(
                  (error) => error.message,
                  'diagnostic',
                  contains('is an invalid Prompt for the claude target'),
                ),
          ),
        );
      },
    );

    test(
      'the validation of the prompt kind inspects the staged output',
      () async {
        // The root Markdown file makes the source invalid, and the staged
        // output carries it into references/. The validation sees the same
        // refusal as the installation.
        seedMigratedRootFile();
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        await expectLater(
          service.execute(
            request(
              PackOperation.validate,
              resourceTypes: const <PackResourceType>[PackResourceType.prompt],
              target: null,
              only: const <String>['prompt'],
            ),
          ),
          throwsA(
            isA<MambaException>()
                .having(
                  (error) => error.exitCode,
                  'status',
                  PackProcessStatus.invalidInput.code,
                )
                .having(
                  (error) => error.message,
                  'diagnostic',
                  contains('is an invalid Prompt for the claude target'),
                ),
          ),
        );
      },
    );

    test('an installed Prompt keeps the Skill lifecycle selectors', () async {
      final service = PackLifecycleService.withDependencies(fileSystem: fs);

      await service.execute(
        request(
          PackOperation.install,
          resourceTypes: const <PackResourceType>[PackResourceType.prompt],
          only: const <String>['prompt'],
        ),
      );
      expect(ledger(), hasLength(1));

      // The removal of an installed Prompt is reached through the Skill
      // selectors.
      final removed = await service.execute(
        request(
          PackOperation.remove,
          resourceTypes: const <PackResourceType>[PackResourceType.skill],
          only: const <String>['prompt'],
        ),
      );

      expect(removed.outcome, 'completed');
      // The removed record is retained with its removed lifecycle.
      expect(ledger().single['lifecycle'], 'removed');
      expect(installedFiles(), isEmpty);
    });

    test(
      'a pending coordinated transaction refuses the Prompt selection',
      () async {
        seedPendingConversion();
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        await expectLater(
          service.execute(
            request(
              PackOperation.install,
              resourceTypes: const <PackResourceType>[PackResourceType.prompt],
              only: const <String>['prompt'],
            ),
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 6)
                .having(
                  (error) => error.message,
                  'diagnostic',
                  contains('Pending coordinated transaction'),
                ),
          ),
        );
        expect(ledger(), isEmpty);
        expect(installedFiles(), isEmpty);
      },
    );

    test(
      'a refusal leaves the source, the state and the lock document unchanged',
      () async {
        seedInvalidPrompt();
        final service = PackLifecycleService.withDependencies(fileSystem: fs);
        final source = sourceFiles();
        final configuration = configurationText();

        await expectLater(
          service.execute(
            request(
              PackOperation.install,
              resourceTypes: const <PackResourceType>[PackResourceType.prompt],
              only: const <String>['prompt'],
            ),
          ),
          throwsA(isA<MambaException>()),
        );

        expect(sourceFiles(), source);
        expect(configurationText(), configuration);
        expect(lockDocument(), isEmpty);
        expect(installedFiles(), isEmpty);
      },
    );

    test(
      'a mixed Prompt selection installs no resource of the selection',
      () async {
        // A second prompt candidate that is not a Prompt.
        final other = fs.directory(fs.path.join(source.path, 'skills', 'other'))
          ..createSync(recursive: true);
        fs.file(fs.path.join(other.path, 'SKILL.md')).writeAsStringSync('''
---
name: other
description: An ordinary skill.
---
# Other
''');
        fs
            .file(fs.path.join(source.path, 'agent-resources.toml'))
            .writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/prompt"
[[catalog.skills]]
path = "skills/other"
''');
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        await expectLater(
          service.execute(
            request(
              PackOperation.install,
              resourceTypes: const <PackResourceType>[PackResourceType.prompt],
              only: const <String>['prompt', 'other'],
            ),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              PackProcessStatus.invalidInput.code,
            ),
          ),
        );
        // The atomic selection installs neither resource.
        expect(ledger(), isEmpty);
        expect(installedFiles(), isEmpty);
      },
    );

    test(
      'the ordinary Skill selector installs a valid skill-backed Prompt',
      () async {
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        final result = await service.execute(
          request(
            PackOperation.install,
            resourceTypes: const <PackResourceType>[PackResourceType.skill],
            only: const <String>['prompt'],
          ),
        );

        expect(result.outcome, 'completed');
        expect(ledger(), hasLength(1));
        expect(
          installedFiles(),
          contains(
            fs.path.join(
              project.path,
              '.claude',
              'skills',
              'prompt',
              'SKILL.md',
            ),
          ),
        );
      },
    );

    test(
      'an installed Prompt is updated through the Skill selectors',
      () async {
        final service = PackLifecycleService.withDependencies(fileSystem: fs);

        await service.execute(
          request(
            PackOperation.install,
            resourceTypes: const <PackResourceType>[PackResourceType.prompt],
            only: const <String>['prompt'],
          ),
        );
        fs
            .file(fs.path.join(source.path, 'skills', 'prompt', 'SKILL.md'))
            .writeAsStringSync('''
---
name: prompt
description: A manual-only prompt.
disable-model-invocation: true
---
# Prompt

Updated content.
''');

        final updated = await service.execute(
          request(
            PackOperation.update,
            resourceTypes: const <PackResourceType>[PackResourceType.skill],
            only: const <String>['prompt'],
          ),
        );

        expect(updated.outcome, 'completed');
        expect(
          fs
              .file(
                fs.path.join(
                  project.path,
                  '.claude',
                  'skills',
                  'prompt',
                  'SKILL.md',
                ),
              )
              .readAsStringSync(),
          contains('Updated content.'),
        );
        expect(ledger(), hasLength(1));
      },
    );
  });
}
