import 'dart:convert';

import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/authoring/instruction_draft.dart';
import 'package:agent_resource/src/authoring/instruction_draft_document.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/instruction_draft_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late _RecordingIO io;
  late LifecycleOptions options;
  late List<String> privacyCalls;
  late List<String> verifierCalls;
  late bool privacyFails;
  late bool verifierFails;
  late InstructionDraftService service;

  const body = 'First line\nSecond line\n';

  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/work/project').createSync(recursive: true);
    fs.directory('/home/user').createSync(recursive: true);
    io = _RecordingIO(fs: fs);
    options = LifecycleOptions(
      processWorkingDirectory: '/work/project',
      environment: const <String, String>{},
      scope: LifecycleScope.project,
      cwd: '/work/project',
      projectRoot: '/work/project',
      home: '/home/user',
    );
    privacyCalls = <String>[];
    verifierCalls = <String>[];
    privacyFails = false;
    verifierFails = false;
    service = InstructionDraftService(
      fileSystem: fs,
      state: LifecycleStateService(io: io),
      plans: AuthoringPlanService(fileSystem: fs),
      privacy: (path) {
        privacyCalls.add(path);
        if (privacyFails) {
          throw MambaException(
            'The private draft storage could not be protected: $path',
            exitCode: 4,
          );
        }
      },
      verifier: (path) {
        verifierCalls.add(path);
        if (verifierFails) {
          throw MambaException(
            'The privacy of the private draft storage could not be verified: '
            '$path',
            exitCode: 4,
          );
        }
      },
    );
  });

  AuthoringInputs createInputs({
    String bodyText = body,
    Map<String, Object?> fields = const <String, Object?>{
      'name': 'demo',
      'description': 'Demo resource',
    },
    String? output,
    LifecycleScope scope = LifecycleScope.project,
  }) => parseAuthoringInputs(
    operation: AuthoringOperation.create,
    kind: AuthoringKind.skill,
    profile: AuthoringProfile.claude,
    scope: scope,
    bodyText: bodyText,
    fields: fields,
    output: output,
  );

  AuthoringInputs editInputs({
    String sourcePath = 'demo',
    String bodyText = body,
  }) => parseAuthoringInputs(
    operation: AuthoringOperation.edit,
    kind: AuthoringKind.skill,
    profile: AuthoringProfile.claude,
    sourcePath: sourcePath,
    bodyText: bodyText,
    fields: const <String, Object?>{},
  );

  void writeSource(String directory, {String content = 'Original body\n'}) {
    fs.directory(directory).createSync(recursive: true);
    fs
        .file('$directory/SKILL.md')
        .writeAsStringSync(
          '---\nname: demo\ndescription: Source\n---\n$content',
        );
  }

  String draftsRoot() => '/work/project/.agent-resource/instruction-drafts';

  LifecycleOptions optionsAt(String cwd) => LifecycleOptions(
    processWorkingDirectory: cwd,
    environment: const <String, String>{},
    scope: LifecycleScope.project,
    cwd: cwd,
    projectRoot: '/work/project',
    home: '/home/user',
  );

  group('preparation', () {
    test('a prepared draft retains the exact multiline body', () async {
      final draft = await service.prepare(options, createInputs());

      expect(draft.draftId, matches(RegExp(r'^drf_[a-f0-9]{32}$')));
      expect(draft.bodyOrigin, InstructionDraftBodyOrigin.literal);
      expect(draft.bodyByteLength, body.length);
      expect(
        fs
            .file('${draft.path}/$instructionDraftBodyFileName')
            .readAsStringSync(),
        body,
      );
    });

    test('the metadata document never carries the instruction body', () async {
      final draft = await service.prepare(options, createInputs());
      final metadata = fs
          .file('${draft.path}/$instructionDraftMetadataFileName')
          .readAsStringSync();

      expect(metadata, isNot(contains(body)));
      expect(metadata, contains(draft.draftId));
      expect(metadata, isNot(contains('approved')));
      expect(metadata, isNot(contains('consent')));
    });

    test('the listed summary never carries the instruction body', () async {
      final draft = await service.prepare(options, createInputs());
      final summaries = await service.list(options);

      expect(summaries, hasLength(1));
      expect(summaries.single.draftId, draft.draftId);
      expect(summaries.single.resolved, isTrue);
      expect(summaries.single.bodyOrigin, InstructionDraftBodyOrigin.literal);
      expect(summaries.single.bodySha256, draft.bodySha256);
      expect(summaries.single.toString(), isNot(contains(body)));
    });

    test('a file body is read and the original input is left intact', () async {
      fs.file('/work/project/notes.md').writeAsStringSync(body);
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        bodyFile: 'notes.md',
        fields: const <String, Object?>{'name': 'demo', 'description': 'Demo'},
      );

      final draft = await service.prepare(options, inputs);

      expect(draft.bodyOrigin, InstructionDraftBodyOrigin.file);
      expect(draft.bodySourcePath, '/work/project/notes.md');
      expect(fs.file('/work/project/notes.md').readAsStringSync(), body);
    });

    test('an explicit standard input body is read once', () async {
      final reads = <int>[];
      final reader = InstructionDraftService(
        fileSystem: fs,
        state: LifecycleStateService(io: io),
        standardInput: () async {
          reads.add(1);
          return body;
        },
        privacy: (path) {},
        verifier: (path) {},
      );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        bodyStandardInput: true,
        fields: const <String, Object?>{'name': 'demo', 'description': 'Demo'},
      );

      final draft = await reader.prepare(options, inputs);

      expect(draft.bodyOrigin, InstructionDraftBodyOrigin.standardInput);
      expect(reads, hasLength(1));
      expect(
        fs
            .file('${draft.path}/$instructionDraftBodyFileName')
            .readAsStringSync(),
        body,
      );
    });

    test('a standard input body without a reader is refused', () async {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        bodyStandardInput: true,
        fields: const <String, Object?>{'name': 'demo', 'description': 'Demo'},
      );

      await expectLater(
        service.prepare(options, inputs),
        throwsA(isA<MambaException>()),
      );
      expect(fs.directory(draftsRoot()).existsSync(), isFalse);
    });

    test('two body inputs are refused before a draft exists', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          bodyFile: 'notes.md',
          bodyText: body,
          fields: const <String, Object?>{
            'name': 'demo',
            'description': 'Demo',
          },
        ),
        throwsA(isA<MambaException>()),
      );
    });

    test('a preparation without a body input is refused', () async {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        sourcePath: 'source',
        fields: const <String, Object?>{},
      );

      await expectLater(
        service.prepare(options, inputs),
        throwsA(isA<MambaException>()),
      );
      expect(fs.directory(draftsRoot()).existsSync(), isFalse);
    });

    test('a clone preparation is refused', () async {
      writeSource('/work/project/source');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.clone,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        sourcePath: 'source',
      );

      await expectLater(
        service.prepare(options, inputs),
        throwsA(isA<MambaException>()),
      );
    });

    test('a scope that disagrees with the resolved scope is refused', () async {
      await expectLater(
        service.prepare(options, createInputs(scope: LifecycleScope.user)),
        throwsA(isA<MambaException>()),
      );
    });

    test('an oversized intent refuses before the sensitive body', () async {
      final inputs = createInputs(
        fields: <String, Object?>{
          'name': 'demo',
          'description': 'x' * (maxInstructionDraftDocumentBytes + 1),
        },
      );

      await expectLater(
        service.prepare(options, inputs),
        throwsA(isA<MambaException>()),
      );
      expect(fs.directory(draftsRoot()).existsSync(), isFalse);
      expect(
        io.operations.where((operation) => operation.startsWith('write:')),
        isEmpty,
      );
    });

    test('a metadata write failure leaves no sensitive body', () async {
      final failing = InstructionDraftService(
        fileSystem: fs,
        state: LifecycleStateService(
          io: _FailingWriteIO(fs: fs, failure: 'draft.json'),
        ),
        plans: AuthoringPlanService(fileSystem: fs),
        privacy: (path) {},
        verifier: (path) {},
      );

      await expectLater(
        failing.prepare(options, createInputs()),
        throwsA(isA<Exception>()),
      );
      expect(_storedText(fs, draftsRoot()), isNot(contains(body)));
    });

    test('a body write failure retains the ownership document', () async {
      final failing = InstructionDraftService(
        fileSystem: fs,
        state: LifecycleStateService(
          io: _FailingWriteIO(fs: fs, failure: 'body'),
        ),
        plans: AuthoringPlanService(fileSystem: fs),
        privacy: (path) {},
        verifier: (path) {},
      );

      await expectLater(
        failing.prepare(options, createInputs()),
        throwsA(isA<Exception>()),
      );
      final summaries = await service.list(options);
      expect(summaries, hasLength(1));
      expect(summaries.single.resolved, isFalse);
      expect(summaries.single.reason, contains('missing'));
      expect(_storedText(fs, draftsRoot()), isNot(contains(body)));
    });
  });

  group('privacy', () {
    test('a privacy failure writes no instruction', () async {
      privacyFails = true;

      await expectLater(
        service.prepare(options, createInputs()),
        throwsA(isA<MambaException>()),
      );

      final written = io.operations.where(
        (operation) =>
            operation.startsWith('write:') || operation.startsWith('copy:'),
      );
      expect(written, isEmpty);
      expect(_storedText(fs, draftsRoot()), isNot(contains(body)));
    });

    test('a privacy failure is confirmed before the sensitive write', () async {
      final draft = await service.prepare(options, createInputs());

      expect(privacyCalls, containsAll(<String>[draftsRoot(), draft.path]));
      final write = io.operations.indexWhere(
        (operation) =>
            operation.startsWith('write:') && operation.endsWith('body'),
      );
      expect(write, greaterThan(0));
      expect(verifierCalls.indexOf(draft.path), lessThan(write));
    });

    test('an unverifiable container refuses the body read', () async {
      final draft = await service.prepare(options, createInputs());
      verifierFails = true;

      await expectLater(
        service.read(options, draft.draftId),
        throwsA(isA<MambaException>()),
      );
    });

    test('a read-only operation never protects the storage again', () async {
      final draft = await service.prepare(options, createInputs());
      final protections = privacyCalls.length;
      final verifications = verifierCalls.length;

      await service.inspect(options, draft.draftId);
      await service.read(options, draft.draftId);
      await service.list(options);
      await service.find(options, draft.draftId);

      expect(privacyCalls, hasLength(protections));
      expect(verifierCalls.length, greaterThan(verifications));
    });
  });

  group('dry run', () {
    test('a dry-run preparation refuses before any write', () async {
      await expectLater(
        service.prepare(options.copyWith(dryRun: true), createInputs()),
        throwsA(isA<MambaException>()),
      );

      expect(fs.directory(draftsRoot()).existsSync(), isFalse);
      expect(
        io.operations.where(
          (operation) =>
              operation.startsWith('write:') ||
              operation.startsWith('createDirectory:'),
        ),
        isEmpty,
      );
    });

    test('a dry-run working copy refuses before any write', () async {
      final draft = await service.prepare(options, createInputs());

      await expectLater(
        service.prepareWorkingCopy(
          options.copyWith(dryRun: true),
          draft.draftId,
        ),
        throwsA(isA<MambaException>()),
      );
      expect(
        fs.file('${draft.path}/$instructionDraftWorkingFileName').existsSync(),
        isFalse,
      );
    });

    test('a dry-run inspection and resume change nothing', () async {
      final draft = await service.prepare(options, createInputs());
      final before = io.operations.length;

      await service.inspect(options.copyWith(dryRun: true), draft.draftId);
      await service.read(options.copyWith(dryRun: true), draft.draftId);
      await service.resume(options.copyWith(dryRun: true), draft.draftId);
      await service.list(options.copyWith(dryRun: true));

      final after = io.operations.skip(before);
      expect(
        after.where((operation) => !operation.startsWith('read:')),
        isEmpty,
      );
    });
  });

  group('resume', () {
    test('a resume rebuilds a fresh plan from the retained intent', () async {
      final draft = await service.prepare(options, createInputs());

      final resume = await service.resume(options, draft.draftId);

      expect(resume.plan.ready, isTrue);
      expect(resume.plan.candidate, contains('First line'));
      expect(resume.plan.candidate, contains('Second line'));
      expect(resume.inputs.operation, AuthoringOperation.create);
      expect(resume.inputs.body?.kind, BodyInputKind.literal);
      expect(resume.inputs.fields['name'], isA<TextFieldValue>());
      expect(resume.draft.draftId, draft.draftId);
    });

    test('a resume survives a service reconstruction', () async {
      final draft = await service.prepare(options, createInputs());
      final restarted = InstructionDraftService(
        fileSystem: fs,
        state: LifecycleStateService(io: io),
        plans: AuthoringPlanService(fileSystem: fs),
        privacy: (path) {},
        verifier: (path) {},
      );

      final resume = await restarted.resume(options, draft.draftId);

      expect(resume.plan.ready, isTrue);
      expect(resume.body.text, body);
    });

    test('a resume never reuses an approval', () async {
      final draft = await service.prepare(options, createInputs());
      final metadata = fs
          .file('${draft.path}/$instructionDraftMetadataFileName')
          .readAsStringSync();

      expect(metadata, isNot(contains('approved')));
      expect(metadata, isNot(contains('planId')));
      expect(metadata, isNot(contains('authoring-plan')));

      final resume = await service.resume(
        options.copyWith(approved: true),
        draft.draftId,
      );
      expect(resume.plan.data['writes'], isFalse);
    });

    test('a resume observes the current state and not an old plan', () async {
      writeSource('/work/project/demo');
      final draft = await service.prepare(options, editInputs());

      final first = await service.resume(options, draft.draftId);
      expect(first.plan.ready, isTrue);
      final firstIdentity = first.plan.planId;

      fs
          .file('/work/project/demo/SKILL.md')
          .writeAsStringSync('---\nname: demo\ndescription: Changed\n---\nNew');

      final second = await service.resume(options, draft.draftId);
      expect(second.plan.planId, isNot(firstIdentity));
      expect(
        (second.plan.data['source']! as Map<String, Object?>)['bodySha256'],
        isNot(
          (first.plan.data['source']! as Map<String, Object?>)['bodySha256'],
        ),
      );
      expect(second.plan.candidate, contains('First line'));
    });

    test('a resume keeps the selected paths of the preparation', () async {
      writeSource('/work/project/demo');
      final draft = await service.prepare(options, editInputs());
      expect(draft.intent.sourcePath, '/work/project/demo');

      final elsewhere = optionsAt('/work/project/other');
      fs.directory('/work/project/other').createSync(recursive: true);
      final resume = await service.resume(elsewhere, draft.draftId);

      expect(resume.inputs.source.path, '/work/project/demo');
      expect(
        (resume.plan.data['source']! as Map<String, Object?>)['path'],
        '/work/project/demo',
      );
    });

    test('an output override keeps the path of the preparation', () async {
      final draft = await service.prepare(
        options,
        createInputs(output: 'out/demo'),
      );
      expect(draft.intent.output, '/work/project/out/demo');

      fs.directory('/work/project/other').createSync(recursive: true);
      final resume = await service.resume(
        optionsAt('/work/project/other'),
        draft.draftId,
      );

      expect(
        (resume.plan.data['target']! as Map<String, Object?>)['output'],
        '/work/project/out/demo/SKILL.md',
      );
    });
  });

  group('the working copy', () {
    test(
      'an editor replacement is readable and marks the draft edited',
      () async {
        final draft = await service.prepare(options, createInputs());
        final working = await service.prepareWorkingCopy(
          options,
          draft.draftId,
        );

        expect(fs.file(working).readAsStringSync(), body);
        _replaceAtomically(fs, working, 'Edited body\n');

        final read = await service.read(options, draft.draftId);
        expect(read.text, 'Edited body\n');
        expect(read.edited, isTrue);
        expect(
          fs
              .file('${draft.path}/$instructionDraftBodyFileName')
              .readAsStringSync(),
          body,
        );
      },
    );

    test('an unchanged saved text is accepted', () async {
      final draft = await service.prepare(options, createInputs());
      final working = await service.prepareWorkingCopy(options, draft.draftId);
      _replaceAtomically(fs, working, body);

      final read = await service.read(options, draft.draftId);
      expect(read.text, body);
      expect(read.edited, isFalse);
    });

    test('a second working copy is refused', () async {
      final draft = await service.prepare(options, createInputs());
      await service.prepareWorkingCopy(options, draft.draftId);

      await expectLater(
        service.prepareWorkingCopy(options, draft.draftId),
        throwsA(isA<MambaException>()),
      );
    });
  });

  group('integrity', () {
    test('a substituted body is refused', () async {
      final draft = await service.prepare(options, createInputs());
      fs
          .file('${draft.path}/$instructionDraftBodyFileName')
          .writeAsStringSync('Substituted body\n');

      await expectLater(
        service.read(options, draft.draftId),
        throwsA(isA<MambaException>()),
      );
    });

    test('a substituted working copy link is refused', () async {
      final draft = await service.prepare(options, createInputs());
      final working = await service.prepareWorkingCopy(options, draft.draftId);
      fs.file(working).deleteSync();
      fs.link(working).createSync('/work/project/notes.md');

      await expectLater(
        service.read(options, draft.draftId),
        throwsA(isA<MambaException>()),
      );
    });

    test('a working copy that is a directory refuses the read', () async {
      final draft = await service.prepare(options, createInputs());
      fs
          .directory('${draft.path}/$instructionDraftWorkingFileName')
          .createSync(recursive: true);

      await expectLater(
        service.read(options, draft.draftId),
        throwsA(isA<MambaException>()),
      );
    });

    test(
      'a tampered snapshot refuses even with a valid working copy',
      () async {
        final draft = await service.prepare(options, createInputs());
        final working = await service.prepareWorkingCopy(
          options,
          draft.draftId,
        );
        _replaceAtomically(fs, working, 'Edited body\n');
        fs
            .file('${draft.path}/$instructionDraftBodyFileName')
            .writeAsStringSync('Tampered snapshot\n');

        await expectLater(
          service.read(options, draft.draftId),
          throwsA(isA<MambaException>()),
        );
      },
    );

    test('a corrupted metadata document is refused', () async {
      final draft = await service.prepare(options, createInputs());
      fs
          .file('${draft.path}/$instructionDraftMetadataFileName')
          .writeAsStringSync('{"schemaVersion":1,"draftId":"drf_x"}');

      await expectLater(
        service.inspect(options, draft.draftId),
        throwsA(isA<MambaException>()),
      );
      final summaries = await service.list(options);
      expect(summaries.single.resolved, isFalse);
      expect(summaries.single.reason, isNotNull);
    });

    test(
      'a substituted metadata document of another draft is refused',
      () async {
        final first = await service.prepare(options, createInputs());
        final second = await service.prepare(options, createInputs());
        fs
            .file('${first.path}/$instructionDraftMetadataFileName')
            .writeAsStringSync(
              fs
                  .file('${second.path}/$instructionDraftMetadataFileName')
                  .readAsStringSync(),
            );

        await expectLater(
          service.inspect(options, first.draftId),
          throwsA(isA<MambaException>()),
        );
      },
    );

    test('a linked draft directory is refused', () async {
      final draft = await service.prepare(options, createInputs());
      final path = draft.path;
      fs.directory(path).deleteSync(recursive: true);
      fs.link(path).createSync('/work/project/demo');

      await expectLater(
        service.inspect(options, draft.draftId),
        throwsA(isA<MambaException>()),
      );
    });

    test('a malformed identity is refused', () async {
      await expectLater(
        service.find(options, '../../etc/passwd'),
        throwsA(isA<MambaException>()),
      );
      await expectLater(
        service.read(options, 'drf_nothexadecimal'),
        throwsA(isA<MambaException>()),
      );
      await expectLater(
        service.discard(options, '../other'),
        throwsA(isA<MambaException>()),
      );
    });

    test('a linked storage ancestor is refused before a write', () async {
      final root = draftsRoot();
      fs.directory('/work/project/.agent-resource').createSync(recursive: true);
      fs.link(root).createSync('/work/project/.agent-resource/drafts');

      await expectLater(
        service.prepare(options, createInputs()),
        throwsA(isA<MambaException>()),
      );
      expect(
        io.operations.where((operation) => operation.startsWith('write:')),
        isEmpty,
      );
    });

    test('a linked ancestor above the state root refuses the write', () async {
      fs.directory('/work').deleteSync(recursive: true);
      fs.directory('/elsewhere/project').createSync(recursive: true);
      fs.link('/work').createSync('/elsewhere');

      await expectLater(
        service.prepare(options, createInputs()),
        throwsA(isA<MambaException>()),
      );
      expect(
        io.operations.where((operation) => operation.startsWith('write:')),
        isEmpty,
      );
    });

    test('a linked ancestor above the state root refuses the read', () async {
      final draft = await service.prepare(options, createInputs());
      fs.directory('/work/project/.agent-resource').renameSync('/elsewhere');
      fs.link('/work/project/.agent-resource').createSync('/elsewhere');

      await expectLater(
        service.inspect(options, draft.draftId),
        throwsA(isA<MambaException>()),
      );
      await expectLater(service.list(options), throwsA(isA<MambaException>()));
    });

    test('an occupied draft identity refuses the preparation', () async {
      final colliding = InstructionDraftService(
        fileSystem: fs,
        state: LifecycleStateService(io: io),
        plans: AuthoringPlanService(fileSystem: fs),
        privacy: (path) {},
        verifier: (path) {},
        newId: () => 'drf_${'a' * 32}',
      );

      final first = await colliding.prepare(options, createInputs());
      final retained = fs
          .file('${first.path}/$instructionDraftBodyFileName')
          .readAsStringSync();

      await expectLater(
        colliding.prepare(options, createInputs()),
        throwsA(isA<MambaException>()),
      );
      expect(
        fs
            .file('${first.path}/$instructionDraftBodyFileName')
            .readAsStringSync(),
        retained,
      );
    });
  });

  group('removal', () {
    test('a discarded draft removes only its own directory', () async {
      fs.file('/work/project/notes.md').writeAsStringSync(body);
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        bodyFile: 'notes.md',
        fields: const <String, Object?>{'name': 'demo', 'description': 'Demo'},
      );
      final draft = await service.prepare(options, inputs);

      final cleanup = await service.discard(
        options.copyWith(approved: true),
        draft.draftId,
      );

      expect(cleanup.cleaned, isTrue);
      expect(fs.directory(draft.path).existsSync(), isFalse);
      expect(fs.file('/work/project/notes.md').existsSync(), isTrue);
      expect(fs.file('/work/project/notes.md').readAsStringSync(), body);
      expect(await service.list(options), isEmpty);
    });

    test('a cleanup after a publication removes the owned draft', () async {
      final draft = await service.prepare(options, createInputs());

      final cleanup = await service.cleanupOwned(options, draft.draftId);

      expect(cleanup.cleaned, isTrue);
      expect(fs.directory(draft.path).existsSync(), isFalse);
    });

    test('a cleanup failure reports itself and throws nothing', () async {
      final draft = await service.prepare(options, createInputs());
      final failing = InstructionDraftService(
        fileSystem: fs,
        state: LifecycleStateService(io: _FailingDeleteIO(fs: fs)),
        privacy: (path) {},
        verifier: (path) {},
      );

      final cleanup = await failing.cleanupOwned(options, draft.draftId);

      expect(cleanup.cleaned, isFalse);
      expect(cleanup.reason, isNotNull);
      expect(fs.directory(draft.path).existsSync(), isTrue);
    });

    test('an unexpected entry refuses the removal', () async {
      final draft = await service.prepare(options, createInputs());
      fs.file('${draft.path}/extra.txt').writeAsStringSync('extra');

      await expectLater(
        service.discard(options.copyWith(approved: true), draft.draftId),
        throwsA(isA<MambaException>()),
      );
      expect(fs.directory(draft.path).existsSync(), isTrue);
      expect(fs.file('${draft.path}/extra.txt').existsSync(), isTrue);
    });

    test('a changed prepared snapshot refuses the removal', () async {
      final draft = await service.prepare(options, createInputs());
      fs
          .file('${draft.path}/$instructionDraftBodyFileName')
          .writeAsStringSync('Changed snapshot\n');

      await expectLater(
        service.discard(options.copyWith(approved: true), draft.draftId),
        throwsA(isA<MambaException>()),
      );
      expect(fs.directory(draft.path).existsSync(), isTrue);
      expect(
        fs.file('${draft.path}/$instructionDraftBodyFileName').existsSync(),
        isTrue,
      );
    });

    test('an edited working copy does not refuse the removal', () async {
      final draft = await service.prepare(options, createInputs());
      final working = await service.prepareWorkingCopy(options, draft.draftId);
      _replaceAtomically(fs, working, 'Edited body\n');

      final cleanup = await service.cleanupOwned(options, draft.draftId);

      expect(cleanup.cleaned, isTrue);
      expect(fs.directory(draft.path).existsSync(), isFalse);
    });

    test('a discarded draft is retained until it is discarded', () async {
      final draft = await service.prepare(options, createInputs());

      final summaries = await service.list(options);
      final found = await service.find(options, draft.draftId);

      expect(summaries, hasLength(1));
      expect(found?.draftId, draft.draftId);
      expect(fs.directory(draft.path).existsSync(), isTrue);
    });

    test('a missing draft is refused by a discard', () async {
      await expectLater(
        service.discard(options.copyWith(approved: true), 'drf_${'0' * 32}'),
        throwsA(isA<MambaException>()),
      );
    });

    test('a discard without the consent of the operator is refused', () async {
      final draft = await service.prepare(options, createInputs());

      await expectLater(
        service.discard(options, draft.draftId),
        throwsA(isA<MambaException>()),
      );
      expect(fs.directory(draft.path).existsSync(), isTrue);
      expect(
        fs.file('${draft.path}/$instructionDraftBodyFileName').existsSync(),
        isTrue,
      );
    });

    test('an unverifiable container refuses the discard', () async {
      final draft = await service.prepare(options, createInputs());
      final body = fs
          .file('${draft.path}/$instructionDraftBodyFileName')
          .readAsStringSync();
      final metadata = fs
          .file('${draft.path}/$instructionDraftMetadataFileName')
          .readAsStringSync();
      verifierFails = true;

      await expectLater(
        service.discard(options.copyWith(approved: true), draft.draftId),
        throwsA(isA<MambaException>()),
      );
      expect(fs.directory(draft.path).existsSync(), isTrue);
      expect(
        fs
            .file('${draft.path}/$instructionDraftBodyFileName')
            .readAsStringSync(),
        body,
      );
      expect(
        fs
            .file('${draft.path}/$instructionDraftMetadataFileName')
            .readAsStringSync(),
        metadata,
      );
    });

    test('an unverifiable container refuses the cleanup', () async {
      final draft = await service.prepare(options, createInputs());
      final body = fs
          .file('${draft.path}/$instructionDraftBodyFileName')
          .readAsStringSync();
      verifierFails = true;

      final cleanup = await service.cleanupOwned(options, draft.draftId);

      expect(cleanup.cleaned, isFalse);
      expect(cleanup.reason, isNotNull);
      expect(fs.directory(draft.path).existsSync(), isTrue);
      expect(
        fs
            .file('${draft.path}/$instructionDraftBodyFileName')
            .readAsStringSync(),
        body,
      );
    });
  });

  group('the windows access control parser', () {
    test('the current account, the system account and the administrators are private', () {
      const output = r'''
C:\drafts BUILTIN\Administrators:(OI)(CI)(F)
        NT AUTHORITY\SYSTEM:(OI)(CI)(F)
        DESKTOP-O018JMQ\bvlou:(OI)(CI)(F)
''';

      final grants = parseWindowsAccessGrants(output, path: r'C:\drafts');

      expect(grants, hasLength(3));
      expect(windowsAccessIsPrivate(grants, r'desktop-o018jmq\bvlou'), isTrue);
    });

    test('a short user name is not the account of the process', () {
      const output = r'''
C:\drafts BUILTIN\Administrators:(OI)(CI)(F)
        NT AUTHORITY\SYSTEM:(OI)(CI)(F)
        bvlou:(OI)(CI)(F)
''';

      final grants = parseWindowsAccessGrants(output, path: r'C:\drafts');

      expect(windowsAccessIsPrivate(grants, r'desktop-o018jmq\bvlou'), isFalse);
    });

    test('an arbitrary other principal refuses the storage', () {
      const output = r'''
C:\drafts BUILTIN\Administrators:(OI)(CI)(F)
        NT AUTHORITY\SYSTEM:(OI)(CI)(F)
        DESKTOP-O018JMQ\bvlou:(OI)(CI)(F)
        OTHERACCOUNT:(OI)(CI)(F)
''';

      final grants = parseWindowsAccessGrants(output, path: r'C:\drafts');

      expect(grants, hasLength(4));
      expect(grants.last.principal, 'OTHERACCOUNT');
      expect(windowsAccessIsPrivate(grants, r'desktop-o018jmq\bvlou'), isFalse);
    });

    test('an unexpected broad principal refuses the storage', () {
      const output = r'''
C:\drafts Everyone:(OI)(CI)(F)
        DESKTOP-O018JMQ\bvlou:(OI)(CI)(F)
''';

      final grants = parseWindowsAccessGrants(output, path: r'C:\drafts');

      expect(windowsAccessIsPrivate(grants, r'desktop-o018jmq\bvlou'), isFalse);
    });

    test('an empty access control list refuses the storage', () {
      expect(
        windowsAccessIsPrivate(
          const <WindowsAccessGrant>[],
          r'desktop-o018jmq\bvlou',
        ),
        isFalse,
      );
    });

    test('an entry that is not parsable is refused', () {
      const output = r'C:\drafts SOMEONE WITHOUT RIGHTS';

      expect(
        () => parseWindowsAccessGrants(output, path: r'C:\drafts'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a path with spaces keeps the principal', () {
      const output = r'C:\my drafts BUILTIN\Administrators:(OI)(CI)(F)';

      final grants = parseWindowsAccessGrants(output, path: r'C:\my drafts');

      expect(grants.single.principal, r'BUILTIN\Administrators');
      expect(grants.single.rights, '(OI)(CI)(F)');
    });

    test('a trailing separator keeps the principal', () {
      const output = r'C:\drafts\ BUILTIN\Administrators:(OI)(CI)(F)';

      final grants = parseWindowsAccessGrants(output, path: r'C:\drafts');

      expect(grants.single.principal, r'BUILTIN\Administrators');
    });
  });

  group('the document', () {
    test('a document round trips its intent', () {
      final document = InstructionDraftDocument(
        draftId: 'drf_${'a' * 32}',
        createdAt: '2026-01-01T00:00:00.000Z',
        intent: InstructionDraftIntent.from(createInputs()),
        bodyOrigin: InstructionDraftBodyOrigin.literal,
        bodySha256: 'a' * 64,
        bodyByteLength: 12,
      );

      final decoded = InstructionDraftDocument.decode(document.encode());

      expect(decoded.draftId, document.draftId);
      expect(decoded.intent.operation, AuthoringOperation.create);
      expect(decoded.intent.fields['name'], isA<TextFieldValue>());
      expect(decoded.bodyByteLength, 12);
    });

    test('an unknown document field is refused', () {
      final document = InstructionDraftDocument(
        draftId: 'drf_${'a' * 32}',
        createdAt: '2026-01-01T00:00:00.000Z',
        intent: InstructionDraftIntent.from(createInputs()),
        bodyOrigin: InstructionDraftBodyOrigin.literal,
        bodySha256: 'a' * 64,
        bodyByteLength: 12,
      );
      final body = jsonDecode(document.encode()) as Map<String, Object?>;
      body['consent'] = true;

      expect(
        () => InstructionDraftDocument.decode(jsonEncode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a document with a broken digest is refused', () {
      final document = InstructionDraftDocument(
        draftId: 'drf_${'a' * 32}',
        createdAt: '2026-01-01T00:00:00.000Z',
        intent: InstructionDraftIntent.from(createInputs()),
        bodyOrigin: InstructionDraftBodyOrigin.literal,
        bodySha256: 'a' * 64,
        bodyByteLength: 12,
      );
      final body = jsonDecode(document.encode()) as Map<String, Object?>;
      body['digest'] = 'b' * 64;

      expect(
        () => InstructionDraftDocument.decode(jsonEncode(body)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

/// The text that the storage holds below one directory.
String _storedText(FileSystem fileSystem, String root) {
  if (!fileSystem.directory(root).existsSync()) return '';
  final buffer = StringBuffer();
  for (final entry in fileSystem.directory(root).listSync(recursive: true)) {
    if (entry is File) {
      buffer.write(entry.readAsStringSync());
    }
  }
  return buffer.toString();
}

/// Replaces one file the way an editor saves it.
void _replaceAtomically(FileSystem fileSystem, String path, String content) {
  final temporary = '$path.editor';
  fileSystem.file(temporary).writeAsStringSync(content);
  fileSystem.file(path).deleteSync();
  fileSystem.file(temporary).renameSync(path);
}

/// A lifecycle IO seam that records every operation.
class _RecordingIO extends LifecycleIO {
  _RecordingIO({required super.fs});

  final List<String> operations = <String>[];

  @override
  void before(String operation, String path) {
    operations.add('$operation:$path');
  }
}

/// A lifecycle IO seam whose deletion fails.
class _FailingDeleteIO extends LifecycleIO {
  _FailingDeleteIO({required super.fs});

  @override
  void delete(String path) {
    throw FileSystemException('The deletion failed', path);
  }
}

/// A lifecycle IO seam whose write of one named file fails.
class _FailingWriteIO extends LifecycleIO {
  _FailingWriteIO({required super.fs, required this.failure});

  /// The end of the path whose write fails.
  final String failure;

  @override
  void write(String path, List<int> bytes) {
    if (path.endsWith(failure)) {
      throw FileSystemException('The write failed', path);
    }
    super.write(path, bytes);
  }
}
