import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/agent_inspection.dart';
import 'package:agent_resource/src/conversion/conversion_evidence.dart';
import 'package:agent_resource/src/services/agent_lifecycle_service.dart';
import 'package:agent_resource/src/services/conversion_coordinator_service.dart';
import 'package:agent_resource/src/services/conversion_evidence_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:agent_resource/src/services/parent_config_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

/// One durable boundary of the coordinated transition.
class _Boundary {
  const _Boundary(
    this.operation,
    this.path,
    this.expectRecovery, {
    this.afterCommit = false,
  });

  final String operation;
  final String? path;

  /// Whether the boundary leaves the transaction in recovery.
  final bool expectRecovery;

  /// Whether the boundary is reached after the commit decision.
  final bool afterCommit;
}

/// An IO seam that fails one selected durable operation.
class _FaultyIO extends LifecycleIO {
  _FaultyIO(this.memory) : super(fs: memory);

  final MemoryFileSystem memory;
  String? failingOperation;
  String? failingPath;
  bool interrupt = false;
  bool interruptEvidenceUpgrade = false;
  int evidenceWrites = 0;
  void Function(String operation, String path)? after;

  @override
  void write(String path, List<int> bytes) {
    if (interruptEvidenceUpgrade &&
        path.endsWith('.json') &&
        path.contains('conversions/cvx_') &&
        !path.endsWith('initial-intent.json')) {
      evidenceWrites++;
      if (evidenceWrites == 2) {
        memory.file(path).writeAsStringSync('{partial');
        throw StateError('Interrupted evidence replacement');
      }
    }
    super.write(path, bytes);
    after?.call('write', path);
  }

  @override
  void delete(String path) {
    super.delete(path);
    after?.call('delete', path);
  }

  @override
  void rename(String source, String destination) {
    super.rename(source, destination);
    after?.call('rename', source);
  }

  @override
  void before(String operation, String path) {
    if (failingOperation != operation) return;
    if (failingPath != null && !path.contains(failingPath!)) return;
    if (interrupt) throw StateError('Simulated process interruption');
    throw FileSystemException('Injected failure', path);
  }
}

void main() {
  late MemoryFileSystem fs;
  late _FaultyIO io;
  late LifecycleStateService state;
  late ConversionCoordinator coordinator;
  late LifecycleOptions options;

  const sourceInstallationId = 'ins_0123456789abcdef0123456789abcdef';

  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/work/project').createSync(recursive: true);
    fs.directory('/home/user').createSync(recursive: true);
    io = _FaultyIO(fs);
    state = LifecycleStateService(io: io);
    coordinator = ConversionCoordinator(
      io: io,
      state: state,
      evidence: ConversionEvidenceService(fileSystem: fs),
    );
    options = LifecycleOptions(
      processWorkingDirectory: '/work/project',
      environment: const <String, String>{},
      scope: LifecycleScope.project,
      cwd: '/work/project',
      projectRoot: '/work/project',
      home: '/home/user',
      stateDir: '/work/state',
    );
  });

  void seedLedger({
    required String location,
    required String nativeRoot,
    ArtifactKind kind = ArtifactKind.agentFile,
    String nativeForm = 'claude-agent-file',
  }) {
    final record = InstallationRecord(
      installationId: sourceInstallationId,
      kind: kind,
      scope: LifecycleScope.project,
      nativeDestination: 'claude',
      nativeForm: nativeForm,
      location: location,
      nativeRoot: nativeRoot,
      name: location.split('/').last,
      nativeProfile: 'claude',
      validatedProfiles: const <String>['claude'],
      knownConsumers: const <String>['claude'],
      baseline: const ArtifactBaseline(<BaselineEntry>[]),
      lifecycle: 'live',
      origin: const <String, Object?>{'status': 'unknown'},
      backupIds: const <String>[],
      transactionId: null,
    );
    final stateRoot = '/work/project/.agent-resource';
    fs.directory(stateRoot).createSync(recursive: true);
    fs
        .file('$stateRoot/installations.json')
        .writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 1,
            'installations': <Object?>[record.toJson()],
          }),
        );
  }

  ConversionParticipant sourceParticipant({
    required String location,
    required String nativeRoot,
    required String artifactKind,
    required String nativeForm,
  }) {
    final baseline = ConversionBaseline(
      entries: conversionManifestEntries(io, location),
    );
    return ConversionParticipant(
      role: ConversionParticipantRole.source,
      intent: ConversionParticipantIntent.retired,
      artifactKind: artifactKind,
      nativeForm: nativeForm,
      nativeProfile: 'claude',
      location: location,
      nativeRoot: nativeRoot,
      scope: 'project',
      ownershipBefore: ConversionOwnership(
        managed: true,
        installationId: sourceInstallationId,
        nativeForm: nativeForm,
        nativeProfile: 'claude',
        location: location,
        nativeRoot: nativeRoot,
        scope: 'project',
      ),
      baseline: baseline,
    );
  }

  ConversionParticipant targetParticipant({
    required String location,
    required String nativeRoot,
    required String artifactKind,
    required String nativeForm,
    String installationId = sourceInstallationId,
    String scope = 'project',
  }) => ConversionParticipant(
    role: ConversionParticipantRole.target,
    intent: ConversionParticipantIntent.created,
    artifactKind: artifactKind,
    nativeForm: nativeForm,
    nativeProfile: 'claude',
    location: location,
    nativeRoot: nativeRoot,
    scope: scope,
    ownershipAfter: ConversionOwnership(
      managed: true,
      installationId: installationId,
      nativeForm: nativeForm,
      nativeProfile: 'claude',
      location: location,
      nativeRoot: nativeRoot,
      scope: scope,
    ),
  );

  ConversionTransitionRequest seedRequest({
    bool inPlace = false,
    bool userTarget = false,
  }) {
    const source = '/work/project/.claude/agents/reviewer.md';
    fs.file(source)
      ..createSync(recursive: true)
      ..writeAsStringSync('original');
    seedLedger(location: source, nativeRoot: '/work/project/.claude/agents');
    final targetRoot = userTarget
        ? '/home/user/.pi/prompts'
        : '/work/project/.pi/prompts';
    return ConversionTransitionRequest(
      transactionId: 'cvx_0123456789abcdef0123456789abcdef',
      options: userTarget
          ? options.copyWith(scope: LifecycleScope.user)
          : options,
      source: sourceParticipant(
        location: source,
        nativeRoot: '/work/project/.claude/agents',
        artifactKind: 'agent-file',
        nativeForm: 'claude-agent-file',
      ),
      target: targetParticipant(
        location: inPlace ? source : '$targetRoot/reviewer.md',
        nativeRoot: inPlace ? '/work/project/.claude/agents' : targetRoot,
        artifactKind: inPlace ? 'agent-file' : 'prompt-template',
        nativeForm: inPlace ? 'claude-agent-file' : 'pi-prompt-template',
        scope: userTarget ? 'user' : 'project',
      ),
      targetFiles: {'reviewer.md': utf8.encode('converted')},
    );
  }

  group('agent_resource', () {
    group('agent', () {
      for (final action in ['remove', 'replace']) {
        group(action, () {
          test('refuses a pending participant after occupant changes and reconstruction', () async {
            final request = seedRequest();
            fs
                .file(request.source.location)
                .writeAsStringSync(
                  '---\nname: reviewer\ndescription: Review.\n---\nOriginal.\n',
                );
            final ledger = fs.file(
              '/work/project/.agent-resource/installations.json',
            );
            final document = jsonDecode(ledger.readAsStringSync()) as Map;
            final record = (document['installations'] as List).single as Map;
            record['nativeDestination'] = 'native';
            record['name'] = 'reviewer';
            record['baseline'] = state
                .baselineFor(request.source.location, ArtifactKind.agentFile)
                .toJson();
            ledger.writeAsStringSync(jsonEncode(document));
            final updated = ConversionTransitionRequest(
              transactionId: request.transactionId,
              options: options,
              source: sourceParticipant(
                location: request.source.location,
                nativeRoot: request.source.nativeRoot!,
                artifactKind: 'agent-file',
                nativeForm: 'claude-agent-file',
              ),
              target: request.target,
              targetFiles: request.targetFiles,
            );
            io.after = (operation, path) {
              if (operation == 'write' &&
                  path.endsWith('/conversions/${request.transactionId}.json')) {
                throw StateError('Interrupted after intent');
              }
            };
            await expectLater(coordinator.execute(updated), throwsStateError);
            io.after = null;
            // Even rebaselining the current occupant externally cannot release
            // the persisted participant's path or installation identity.
            fs
                .file(request.source.location)
                .writeAsStringSync(
                  '---\nname: reviewer\ndescription: Review.\n---\nChanged occupant.\n',
                );
            record['baseline'] = state
                .baselineFor(request.source.location, ArtifactKind.agentFile)
                .toJson();
            ledger.writeAsStringSync(jsonEncode(document));
            fs
                .file('/replacement.md')
                .writeAsStringSync(
                  '---\nname: reviewer\ndescription: Review.\n---\nReplacement.\n',
                );
            final before = ledger.readAsStringSync();
            final result = await createExecutor(fileSystem: fs).fake().execute([
              'agent',
              action,
              sourceInstallationId,
              if (action == 'replace') '/replacement.md',
              '--scope',
              'project',
              '--cwd',
              '/work/project/',
              '--project-root',
              '/work/project/',
              '--home',
              '/home/user/',
              '--state-dir',
              '/work/state/',
              '--yes',
              '--format',
              'json',
            ]);
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'status', 6)
                  .having(
                    (value) => value.message,
                    'diagnostic',
                    contains('Pending coordinated transaction'),
                  )
                  .having((value) => value.output, 'output', isNull)
                  .having(
                    (value) => value.error.phase,
                    'phase',
                    MambaExecutionPhase.run,
                  )
                  .having((value) => value.error.commandPath, 'command', [
                    'agent_resource',
                    'agent',
                    action,
                  ]),
            );
            expect(ledger.readAsStringSync(), before);
            expect(
              fs.file(request.source.location).readAsStringSync(),
              contains('Changed occupant.'),
            );
          });
        });
      }
    });
  });

  group('ConversionCoordinator', () {
    for (final fault in [
      'missing coordinator',
      'corrupt participant',
      'unknown schema',
    ]) {
      test('legacy origin update preserves state with $fault', () async {
        final request = seedRequest();
        io.after = (operation, path) {
          if (operation == 'write' &&
              path.endsWith('/conversions/${request.transactionId}.json')) {
            throw StateError('Interrupted after intent');
          }
        };
        await expectLater(coordinator.execute(request), throwsStateError);
        io.after = null;
        final authority = fs.file(
          '/work/project/.agent-resource/conversions/${request.transactionId}.json',
        );
        if (fault == 'missing coordinator') {
          authority.deleteSync();
        } else if (fault == 'corrupt participant') {
          fs
              .file(
                '/work/state/conversion-participants/${request.transactionId}.json',
              )
              .writeAsStringSync('{broken');
        } else {
          final document = jsonDecode(authority.readAsStringSync()) as Map;
          document['schemaVersion'] = 999;
          authority.writeAsStringSync(jsonEncode(document));
        }
        final ledger = fs.file(
          '/work/project/.agent-resource/installations.json',
        );
        final before = ledger.readAsStringSync();
        final restarted = LifecycleStateService(io: LifecycleIO(fs: fs));
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            restarted.updateOrigin(
              context: LifecycleContext.resolve(
                options.copyWith(approved: true),
                fileSystem: fs,
              ),
              installationId: sourceInstallationId,
              expectedOrigin: const {'status': 'unknown'},
              origin: const {'status': 'known'},
            ),
            throwsA(
              isA<MambaException>().having(
                (error) => error.exitCode,
                'status',
                6,
              ),
            ),
          );
        }
        expect(ledger.readAsStringSync(), before);
        expect(fs.file(request.source.location).readAsStringSync(), 'original');
        expect(fs.file(request.target.location).existsSync(), isFalse);
      });
    }

    test('a substituted terminal coordinator cannot release a pending participant', () async {
      final request = seedRequest();
      io.after = (operation, path) {
        if (operation == 'write' &&
            path.endsWith('/conversions/${request.transactionId}.json')) {
          throw StateError('Interrupted after intent');
        }
      };
      await expectLater(coordinator.execute(request), throwsStateError);
      io.after = null;
      final authority = fs.file(
        '/work/project/.agent-resource/conversions/${request.transactionId}.json',
      );
      final pending = ConversionEvidence.decode(authority.readAsStringSync());
      authority.writeAsStringSync(
        pending
            .copyWith(
              phase: ConversionEvidencePhase.rolledBack,
              observations: {...pending.observations, 'substituted': true},
            )
            .encode(),
      );
      final ledger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final before = ledger.readAsStringSync();
      await expectLater(
        LifecycleStateService(io: LifecycleIO(fs: fs)).updateOrigin(
          context: LifecycleContext.resolve(
            options.copyWith(approved: true),
            fileSystem: fs,
          ),
          installationId: sourceInstallationId,
          expectedOrigin: const {'status': 'unknown'},
          origin: const {'status': 'known'},
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      expect(ledger.readAsStringSync(), before);
    });

    test(
      'Agent install reserves unpublished native names, not unrelated names',
      () async {
        final original = seedRequest();
        fs
            .file(original.source.location)
            .writeAsStringSync(
              '---\nname: reviewer\ndescription: Review.\n---\nOriginal.\n',
            );
        final request = ConversionTransitionRequest(
          transactionId: original.transactionId,
          options: options,
          source: sourceParticipant(
            location: original.source.location,
            nativeRoot: original.source.nativeRoot!,
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.claude/agents/team/different-filename.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          targetFiles: {
            'different-filename.md': utf8.encode(
              '---\nname: reserved\ndescription: Reserved.\n---\nWork.\n',
            ),
          },
        );
        io.after = (operation, path) {
          if (operation == 'write' &&
              path.endsWith('/conversions/${request.transactionId}.json')) {
            throw StateError('Interrupted before publication');
          }
        };
        await expectLater(coordinator.execute(request), throwsStateError);
        io.after = null;
        Future<LifecycleResult> install(String name) {
          fs.file('/incoming/$name.md')
            ..createSync(recursive: true)
            ..writeAsStringSync(
              '---\nname: $name\ndescription: Work.\n---\nWork.\n',
            );
          return AgentLifecycleService(fileSystem: fs).install(
            AgentInstallInput(
              options: options,
              source: '/incoming/$name.md',
              harness: AgentHarness.claude,
            ),
          );
        }

        final ledger = fs.file(
          '/work/project/.agent-resource/installations.json',
        );
        final before = ledger.readAsStringSync();
        await expectLater(
          install('reserved'),
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
        expect(
          fs.file('/work/project/.claude/agents/reserved.md').existsSync(),
          isFalse,
        );
        expect(ledger.readAsStringSync(), before);
        expect((await install('writer')).outcome, 'installed');
        final freshCoordinator = ConversionCoordinator(
          io: LifecycleIO(fs: fs),
          state: LifecycleStateService(io: LifecycleIO(fs: fs)),
        );
        final review = await freshCoordinator.recoverReviewed(
          options.copyWith(dryRun: true),
          request.transactionId,
        );
        await freshCoordinator.recoverReviewed(
          options.copyWith(approved: true),
          request.transactionId,
          planId: review.data['planId'] as String,
        );
        expect((await install('reserved')).outcome, 'installed');
      },
    );

    test('Skill install reserves pending names across visible roots, not unrelated names', () async {
      final original = seedRequest();
      final request = ConversionTransitionRequest(
        transactionId: original.transactionId,
        options: options,
        source: original.source,
        target: targetParticipant(
          location: '/work/project/.agents/skills/reviewer',
          nativeRoot: '/work/project/.agents/skills',
          artifactKind: 'skill-copy',
          nativeForm: 'skill-directory',
        ),
        targetFiles: {
          'SKILL.md': utf8.encode(
            '---\nname: reviewer\ndescription: Review.\n---\nReview.\n',
          ),
        },
      );
      io.after = (operation, path) {
        if (operation == 'write' &&
            path.endsWith('${request.transactionId}.json')) {
          throw StateError('Interrupted before publication');
        }
      };
      await expectLater(
        coordinator.execute(request),
        throwsA(isA<StateError>()),
      );
      io.after = null;
      Future<LifecycleResult> install(String name) {
        fs.file('/incoming/$name/SKILL.md')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '---\nname: $name\ndescription: Work.\n---\nWork.\n',
          );
        return SkillLifecycleService(fileSystem: fs).install(
          SkillInstallInput(
            options: options,
            source: '/incoming/$name',
            destination: SkillDestination.claude,
          ),
        );
      }

      await expectLater(
        install('reviewer'),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      expect(
        fs.directory('/work/project/.claude/skills/reviewer').existsSync(),
        isFalse,
      );
      expect((await install('writer')).outcome, 'installed');
    });

    test('parent apply cannot change inheritance of a pending Agent', () async {
      final request = seedRequest();
      final settings = fs.file('/work/project/.claude/settings.json')
        ..writeAsStringSync('{"model":"sonnet"}');
      final parent = ParentConfigService(fileSystem: fs);
      ParentRequest parentRequest(
        ParentOperation operation, {
        String? planId,
      }) => ParentRequest(
        operation: operation,
        harness: ParentHarness.claude,
        scope: LifecycleScope.project,
        layer: ParentLayer.project,
        file: settings.path,
        adopt: true,
        clientsStopped: true,
        changes: const [
          ParentChange(unit: 'model', action: ParentAction.set, value: 'opus'),
        ],
        planId: planId,
      );
      final plan = await parent.plan(
        request: parentRequest(ParentOperation.plan),
        options: options,
      );
      io.after = (operation, path) {
        if (operation == 'write' &&
            path.endsWith('${request.transactionId}.json')) {
          throw StateError('Interrupted after intent');
        }
      };
      await expectLater(
        coordinator.execute(request),
        throwsA(isA<StateError>()),
      );
      io.after = null;
      await expectLater(
        parent.apply(
          request: parentRequest(
            ParentOperation.apply,
            planId: plan.data['planId'] as String,
          ),
          options: options.copyWith(approved: true),
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      expect(settings.readAsStringSync(), '{"model":"sonnet"}');
      expect(
        fs
            .directory('/work/project/.agent-resource/parent-backups')
            .existsSync(),
        isFalse,
      );
    });

    test('pack cleanup cannot publish metadata for a pending member', () async {
      final request = seedRequest();
      final ledger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final document = jsonDecode(ledger.readAsStringSync()) as Map;
      (document['installations'] as List).single['origin'] = {
        'status': 'known',
        'packKey': 'local/demo',
        'resourceType': 'agent',
      };
      ledger.writeAsStringSync(jsonEncode(document));
      fs.file('/work/project/agent-resources.toml').writeAsStringSync('''
schema_version = 1
[packs."local/demo".source]
kind = "local"
path = "."
[packs."local/demo".update]
track = { kind = "local" }
''');
      io.after = (operation, path) {
        if (operation == 'write' &&
            path.endsWith('${request.transactionId}.json')) {
          throw StateError('Interrupted after intent');
        }
      };
      await expectLater(
        coordinator.execute(request),
        throwsA(isA<StateError>()),
      );
      io.after = null;
      final before = ledger.readAsStringSync();
      await expectLater(
        PackLifecycleService(fileSystem: fs).execute(
          PackLifecycleRequest(
            operation: PackOperation.cleanup,
            resourceType: PackResourceType.agent,
            pack: 'local/demo',
            processWorkingDirectory: '/work/project',
            environment: const {'APPDATA': '/home/user/appdata'},
            scope: LifecycleScope.project,
            cwd: '/work/project',
            projectRoot: '/work/project',
            home: '/home/user',
            stateDir: '/work/state',
            yes: true,
          ),
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      expect(ledger.readAsStringSync(), before);
    });

    test(
      'pending conversion blocks legacy origin updates after restart',
      () async {
        final request = seedRequest();
        io.after = (operation, path) {
          if (operation == 'write' &&
              path.endsWith('${request.transactionId}.json')) {
            throw StateError('Interrupted after intent');
          }
        };
        await expectLater(
          coordinator.execute(request),
          throwsA(isA<StateError>()),
        );
        io.after = null;
        final restarted = LifecycleStateService(io: LifecycleIO(fs: fs));
        final context = LifecycleContext.resolve(
          options.copyWith(approved: true),
          fileSystem: fs,
        );
        final before = fs
            .file('/work/project/.agent-resource/installations.json')
            .readAsStringSync();
        await expectLater(
          restarted.updateOrigin(
            context: context,
            installationId: sourceInstallationId,
            expectedOrigin: const {'status': 'unknown'},
            origin: const {'status': 'known', 'packKey': 'new-source'},
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              6,
            ),
          ),
        );
        expect(
          fs
              .file('/work/project/.agent-resource/installations.json')
              .readAsStringSync(),
          before,
        );
        expect(fs.file(request.source.location).readAsStringSync(), 'original');
      },
    );

    test(
      'pending participant identity survives changed ledger location',
      () async {
        final request = seedRequest();
        io.after = (operation, path) {
          if (operation == 'write' &&
              path.endsWith('${request.transactionId}.json')) {
            throw StateError('Interrupted after intent');
          }
        };
        await expectLater(
          coordinator.execute(request),
          throwsA(isA<StateError>()),
        );
        io.after = null;
        final ledger = fs.file(
          '/work/project/.agent-resource/installations.json',
        );
        final document = jsonDecode(ledger.readAsStringSync()) as Map;
        (document['installations'] as List).single['location'] =
            '/work/project/.claude/agents/renamed.md';
        ledger.writeAsStringSync(jsonEncode(document));
        final before = ledger.readAsStringSync();
        await expectLater(
          LifecycleStateService(io: LifecycleIO(fs: fs)).updateOrigin(
            context: LifecycleContext.resolve(
              options.copyWith(approved: true),
              fileSystem: fs,
            ),
            installationId: sourceInstallationId,
            expectedOrigin: const {'status': 'unknown'},
            origin: const {'status': 'known'},
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              6,
            ),
          ),
        );
        expect(ledger.readAsStringSync(), before);
      },
    );

    test('user participant stays guarded from another project during partial publication', () async {
      final original = seedRequest();
      final userSource = '/home/user/.claude/agents/reviewer.md';
      fs.file(userSource)
        ..createSync(recursive: true)
        ..writeAsStringSync('original');
      final projectLedger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final document = jsonDecode(projectLedger.readAsStringSync()) as Map;
      final record = (document['installations'] as List).single as Map;
      record['scope'] = 'user';
      record['location'] = userSource;
      record['nativeRoot'] = '/home/user/.claude/agents';
      fs.file('/work/state/installations.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(document));
      projectLedger.deleteSync();
      final request = ConversionTransitionRequest(
        transactionId: original.transactionId,
        options: options,
        source: ConversionParticipant(
          role: ConversionParticipantRole.source,
          intent: ConversionParticipantIntent.retired,
          artifactKind: 'agent-file',
          nativeForm: 'claude-agent-file',
          nativeProfile: 'claude',
          location: userSource,
          nativeRoot: '/home/user/.claude/agents',
          scope: 'user',
          ownershipBefore: ConversionOwnership(
            managed: true,
            installationId: sourceInstallationId,
            nativeForm: 'claude-agent-file',
            nativeProfile: 'claude',
            location: userSource,
            nativeRoot: '/home/user/.claude/agents',
            scope: 'user',
          ),
          baseline: ConversionBaseline(
            entries: conversionManifestEntries(io, userSource),
          ),
        ),
        target: original.target,
        targetFiles: original.targetFiles,
      );
      io.after = (operation, path) {
        if (operation == 'write' &&
            path.endsWith('${request.transactionId}.json')) {
          throw StateError('Interrupted at first participant publication');
        }
      };
      await expectLater(
        coordinator.execute(request),
        throwsA(isA<StateError>()),
      );
      io.after = null;
      fs.directory('/work/other').createSync();
      final otherOptions = LifecycleOptions(
        processWorkingDirectory: '/work/other',
        environment: const {},
        scope: LifecycleScope.user,
        projectRoot: '/work/other',
        cwd: '/work/other',
        home: '/home/user',
        stateDir: '/work/state',
        approved: true,
      );
      await expectLater(
        LifecycleStateService(io: LifecycleIO(fs: fs)).updateOrigin(
          context: LifecycleContext.resolve(otherOptions, fileSystem: fs),
          installationId: sourceInstallationId,
          expectedOrigin: const {'status': 'unknown'},
          origin: const {'status': 'known'},
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      expect(
        fs.file('/work/state/installations.json').readAsStringSync(),
        jsonEncode(document),
      );
    });

    test('user coordinator reserves its target from other projects at the first intent write', () async {
      final original = seedRequest();
      final request = ConversionTransitionRequest(
        transactionId: original.transactionId,
        options: options.copyWith(scope: LifecycleScope.user),
        source: original.source,
        target: targetParticipant(
          location: '/home/user/.claude/skills/reserved',
          nativeRoot: '/home/user/.claude/skills',
          artifactKind: 'skill-copy',
          nativeForm: 'skill-directory',
          scope: 'user',
        ),
        targetFiles: {
          'SKILL.md': utf8.encode(
            '---\nname: reserved\ndescription: Work.\n---\nWork.\n',
          ),
        },
      );
      io.after = (operation, path) {
        if (operation == 'write' &&
            path.endsWith('${request.transactionId}.json')) {
          throw StateError('Interrupted at first intent publication');
        }
      };
      await expectLater(coordinator.execute(request), throwsStateError);
      io.after = null;
      fs.directory('/work/other').createSync();
      fs.file('/incoming/reserved/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '---\nname: reserved\ndescription: Work.\n---\nWork.\n',
        );
      final sourceLedger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final before = sourceLedger.readAsStringSync();
      await expectLater(
        SkillLifecycleService(fileSystem: fs).install(
          SkillInstallInput(
            options: LifecycleOptions(
              processWorkingDirectory: '/work/other',
              environment: const {},
              scope: LifecycleScope.user,
              cwd: '/work/other',
              projectRoot: '/work/other',
              home: '/home/user',
              stateDir: '/work/state',
              approved: true,
            ),
            source: '/incoming/reserved',
            destination: SkillDestination.claude,
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
      expect(fs.directory(request.target.location).existsSync(), isFalse);
      expect(fs.file('/work/state/installations.json').existsSync(), isFalse);
      expect(sourceLedger.readAsStringSync(), before);
      expect(fs.file(request.source.location).readAsStringSync(), 'original');
    });

    test('missing committed decision stays blocked on repeated recovery', () async {
      final request = seedRequest();
      io.after = (operation, path) {
        if (operation == 'write' &&
            path.endsWith('${request.transactionId}.json') &&
            (jsonDecode(fs.file(path).readAsStringSync()) as Map)['phase'] ==
                'committed') {
          throw StateError('Interrupted before reconciliation');
        }
      };
      await expectLater(
        coordinator.execute(request),
        throwsA(isA<StateError>()),
      );
      io.after = null;
      fs
          .file(
            '/work/project/.agent-resource/conversions/${request.transactionId}/commit.json',
          )
          .deleteSync();
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          coordinator.resume(
            options: options,
            transactionId: request.transactionId,
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              6,
            ),
          ),
        );
      }
      expect(fs.file(request.target.location).readAsStringSync(), 'converted');
      expect(fs.file(request.source.location).readAsStringSync(), 'original');
    });

    for (final boundary in [
      ('write', '/home/user/.pi/prompts/reviewer.md', false),
      ('write', 'commit.json', true),
      ('rename', '/work/state/installations.json', true),
      ('rename', '/work/project/.agent-resource/installations.json', true),
      ('delete', '/work/project/.claude/agents/reviewer.md', true),
      ('delete', '/target', true),
    ]) {
      test('cross-scope restart after ${boundary.$1} ${boundary.$2}', () async {
        final request = seedRequest(userTarget: true);
        io.after = (operation, path) {
          if (operation == boundary.$1 && path.contains(boundary.$2)) {
            throw StateError('Interrupted after durable effect');
          }
        };
        await expectLater(
          coordinator.execute(request),
          throwsA(isA<StateError>()),
        );
        io.after = null;
        final outcome =
            await ConversionCoordinator(
              io: io,
              state: LifecycleStateService(io: io),
            ).resume(
              options: request.options,
              transactionId: request.transactionId,
            );
        expect(
          outcome.phase,
          boundary.$3
              ? ConversionEvidencePhase.completed
              : ConversionEvidencePhase.rolledBack,
        );
        expect(fs.file(request.source.location).existsSync(), !boundary.$3);
        expect(fs.file(request.target.location).existsSync(), boundary.$3);
        final sourceRecords = state.records(
          LifecycleContext.resolve(options, fileSystem: fs),
        );
        final targetRecords = state.records(
          LifecycleContext.resolve(request.options, fileSystem: fs),
        );
        expect(
          sourceRecords.single.lifecycle,
          boundary.$3 ? 'removed' : 'live',
        );
        expect(targetRecords.length, boundary.$3 ? 1 : 0);
        if (boundary.$3) {
          expect(
            fs.file(request.target.location).readAsStringSync(),
            'converted',
          );
          expect(
            fs.file(outcome.recoveryPayloadPath!).readAsStringSync(),
            'original',
          );
        }
        await expectLater(
          coordinator.resume(
            options: request.options,
            transactionId: request.transactionId,
          ),
          throwsA(isA<MambaException>()),
        );
      });
    }

    test('missing commit decision cannot roll back materialized ownership', () async {
      final request = seedRequest();
      io.after = (operation, path) {
        if (operation == 'rename' && path.contains('installations.json')) {
          throw StateError('Interrupted after ledger publication');
        }
      };
      await expectLater(
        coordinator.execute(request),
        throwsA(isA<StateError>()),
      );
      io.after = null;
      final ledger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final before = ledger.readAsStringSync();
      fs
          .file(
            '/work/project/.agent-resource/conversions/${request.transactionId}/commit.json',
          )
          .deleteSync();
      await expectLater(
        coordinator.resume(
          options: options,
          transactionId: request.transactionId,
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      expect(ledger.readAsStringSync(), before);
      expect(fs.file(request.target.location).readAsStringSync(), 'converted');
      expect(fs.file(request.source.location).readAsStringSync(), 'original');
      expect(
        fs
            .file(
              '/work/project/.agent-resource/conversions/${request.transactionId}/source-payload/reviewer.md',
            )
            .readAsStringSync(),
        'original',
      );
    });

    test(
      'conversion preserves ledger groups and same-identity history',
      () async {
        final request = seedRequest(inPlace: true);
        final ledger = fs.file(
          '/work/project/.agent-resource/installations.json',
        );
        final document =
            jsonDecode(ledger.readAsStringSync()) as Map<String, dynamic>;
        final groups = {
          'packs': [
            {'key': 'unrelated/pack'},
          ],
          'snapshots': [
            {
              'ref': '20261108T120000Z-abcdef',
              'installationId': sourceInstallationId,
              'installedAt': '2026-11-08T12:00:00Z',
              'activations': ['2026-11-08T12:00:00Z'],
              'contentDigest': 'a' * 64,
              'baseline': <Object?>[],
              'sourceEvidence': <String, Object?>{},
              'contentAvailable': true,
            },
          ],
          'approvals': [
            {'folder': 'extras'},
          ],
          'selections': [
            {'name': 'unrelated'},
          ],
          'operations': [
            {'status': 'completed'},
          ],
        };
        document.addAll(groups);
        final record = (document['installations'] as List).single as Map;
        record['origin'] = {'status': 'known', 'source': 'reviewed-origin'};
        record['backupIds'] = ['bak_0123456789abcdef0123456789abcdef'];
        ledger.writeAsStringSync(jsonEncode(document));
        expect((await coordinator.execute(request)).succeeded, isTrue);
        final after = jsonDecode(ledger.readAsStringSync()) as Map;
        for (final group in groups.entries) {
          expect(after[group.key], group.value, reason: group.key);
        }
        final installed = (after['installations'] as List).single as Map;
        expect(installed['backupIds'], [
          'bak_0123456789abcdef0123456789abcdef',
        ]);
        expect((installed['origin'] as Map)['source'], 'reviewed-origin');
      },
    );

    test('a linked target ancestor cannot redirect publication', () async {
      final request = seedRequest();
      fs.directory('/outside/prompts').createSync(recursive: true);
      fs.link('/work/project/.pi').createSync('/outside');
      await expectLater(
        coordinator.execute(request),
        throwsA(isA<MambaException>()),
      );
      expect(fs.file('/outside/prompts/reviewer.md').existsSync(), isFalse);
      expect(fs.file(request.source.location).readAsStringSync(), 'original');
      expect(
        fs.directory('/work/project/.agent-resource/conversions').existsSync(),
        isFalse,
      );
    });

    test('commit binds participant membership, not only file bytes', () async {
      final request = seedRequest();
      io.after = (operation, path) {
        if (operation == 'write' && path.endsWith('commit.json')) {
          throw StateError('Interrupted after commit');
        }
      };
      await expectLater(
        coordinator.execute(request),
        throwsA(isA<StateError>()),
      );
      io.after = null;
      final service = ConversionEvidenceService(fileSystem: fs);
      const root = '/work/project/.agent-resource';
      final evidence = (await service.readPersisted(
        root,
        request.transactionId,
      ))!;
      final changed = evidence.copyWith(
        target: evidence.target.copyWith(
          membershipAfter: const ConversionMembership(
            kind: 'pack',
            state: 'active',
            source: 'unreviewed',
          ),
        ),
      );
      fs
          .file(service.evidencePath(root, request.transactionId))
          .writeAsStringSync(changed.encode());
      await expectLater(
        coordinator.resume(
          options: options,
          transactionId: request.transactionId,
        ),
        throwsA(
          isA<MambaException>().having((error) => error.exitCode, 'status', 6),
        ),
      );
      expect(fs.file(request.source.location).readAsStringSync(), 'original');
      expect(
        state.records(LifecycleContext.resolve(options, fileSystem: fs)),
        hasLength(1),
      );
    });

    for (final conflict in ['context', 'other-scope-owner', 'target-record']) {
      test('restart refuses changed authority: $conflict', () async {
        final request = seedRequest();
        io.after = (operation, path) {
          if (operation == 'write' && path.endsWith('commit.json')) {
            throw StateError('Interrupted after commit');
          }
        };
        await expectLater(
          coordinator.execute(request),
          throwsA(isA<StateError>()),
        );
        io.after = null;
        final evidence = (await ConversionEvidenceService(fileSystem: fs)
            .readPersisted(
              '/work/project/.agent-resource',
              request.transactionId,
            ))!;
        final ledger = fs.file(
          '/work/project/.agent-resource/installations.json',
        );
        final document =
            jsonDecode(ledger.readAsStringSync()) as Map<String, dynamic>;
        final record = Map<String, dynamic>.from(
          (document['installations'] as List).single as Map,
        );
        if (conflict != 'context') {
          record['installationId'] = conflict == 'target-record'
              ? evidence.target.identity!.installationId
              : 'ins_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
          record['location'] = request.target.location;
          record['nativeRoot'] = request.target.nativeRoot;
          if (conflict == 'other-scope-owner') {
            record['scope'] = 'user';
            fs.file('/work/state/installations.json')
              ..createSync(recursive: true)
              ..writeAsStringSync(
                jsonEncode({
                  'schemaVersion': 1,
                  'installations': [record],
                }),
              );
          } else {
            (document['installations'] as List).add(record);
            ledger.writeAsStringSync(jsonEncode(document));
          }
        }
        final before = ledger.readAsStringSync();
        await expectLater(
          ConversionCoordinator(
            io: io,
            state: LifecycleStateService(io: io),
          ).resume(
            options: conflict == 'context'
                ? LifecycleOptions(
                    processWorkingDirectory: '/work/project',
                    environment: const {},
                    scope: LifecycleScope.project,
                    projectRoot: '/work/project',
                    home: '/home/user',
                    stateDir: '/work/other-state',
                  )
                : options,
            transactionId: request.transactionId,
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              6,
            ),
          ),
        );
        expect(ledger.readAsStringSync(), before);
        expect(fs.file(request.source.location).readAsStringSync(), 'original');
        expect(
          fs.file(request.target.location).readAsStringSync(),
          'converted',
        );
      });
    }

    for (final inPlace in [false, true]) {
      test('restart completes source removal (in-place: $inPlace)', () async {
        final request = seedRequest(inPlace: inPlace);
        io.after = (operation, path) {
          if (operation == 'delete' &&
              path ==
                  (inPlace
                      ? '/work/project/.agent-resource/conversions/${request.transactionId}/quarantine'
                      : request.source.location)) {
            throw StateError('Interrupted after source removal');
          }
        };
        await expectLater(
          coordinator.execute(request),
          throwsA(isA<StateError>()),
        );
        io.after = null;
        final outcome = await ConversionCoordinator(
          io: io,
          state: LifecycleStateService(io: io),
        ).resume(options: options, transactionId: request.transactionId);
        expect(outcome.phase, ConversionEvidencePhase.completed);
        expect(
          fs.file(request.target.location).readAsStringSync(),
          'converted',
        );
        expect(
          fs.file(outcome.recoveryPayloadPath!).readAsStringSync(),
          'original',
        );
        if (!inPlace) {
          expect(fs.file(request.source.location).existsSync(), isFalse);
        }
      });

      test(
        'rollback refuses changed original before deleting target (in-place: $inPlace)',
        () async {
          final request = seedRequest(inPlace: inPlace);
          io.failingOperation = 'write';
          io.failingPath = 'commit.json';
          io.interrupt = true;
          await expectLater(
            coordinator.execute(request),
            throwsA(isA<StateError>()),
          );
          io.failingOperation = null;
          final original = inPlace
              ? '/work/project/.agent-resource/conversions/${request.transactionId}/quarantine'
              : request.source.location;
          fs.file(original).writeAsStringSync('later user edits');
          await expectLater(
            ConversionCoordinator(
              io: io,
              state: LifecycleStateService(io: io),
            ).resume(options: options, transactionId: request.transactionId),
            throwsA(
              isA<MambaException>().having(
                (error) => error.exitCode,
                'status',
                6,
              ),
            ),
          );
          expect(fs.file(original).readAsStringSync(), 'later user edits');
          expect(
            fs.file(request.target.location).readAsStringSync(),
            'converted',
          );
        },
      );
    }

    test(
      'existing pre-intent staging is preserved and ID reuse refused',
      () async {
        const id = 'cvx_0123456789abcdef0123456789abcdef';
        const sourcePath = '/work/project/.claude/agents/reviewer.md';
        const staging = '/work/project/.agent-resource/conversions/$id';
        fs.file(sourcePath)
          ..createSync(recursive: true)
          ..writeAsStringSync('original');
        seedLedger(
          location: sourcePath,
          nativeRoot: '/work/project/.claude/agents',
        );
        fs.file('$staging/evidence')
          ..createSync(recursive: true)
          ..writeAsStringSync('preserve');
        final request = ConversionTransitionRequest(
          transactionId: id,
          options: options,
          source: sourceParticipant(
            location: sourcePath,
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/reviewer.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
          ),
          targetFiles: {'reviewer.md': utf8.encode('Review.')},
        );
        await expectLater(
          coordinator.execute(request),
          throwsA(isA<MambaException>()),
        );
        expect(fs.file('$staging/evidence').readAsStringSync(), 'preserve');
        expect(fs.file(sourcePath).readAsStringSync(), 'original');
      },
    );

    test('restart rolls back interruptions throughout preparation', () async {
      const id = 'cvx_0123456789abcdef0123456789abcdef';
      const source = '/work/project/.claude/agents/reviewer.md';
      const target = '/work/project/.pi/prompts/reviewer.md';
      for (final boundary in <(String, String)>[
        ('createDirectory', 'conversions/$id'),
        ('createDirectory', 'source-payload'),
        ('copy', source),
        ('write', '/target/'),
      ]) {
        fs = MemoryFileSystem();
        fs.directory('/work/project').createSync(recursive: true);
        fs.directory('/home/user').createSync(recursive: true);
        io = _FaultyIO(fs);
        state = LifecycleStateService(io: io);
        coordinator = ConversionCoordinator(
          io: io,
          state: state,
          evidence: ConversionEvidenceService(fileSystem: fs),
        );
        fs.file(source)
          ..createSync(recursive: true)
          ..writeAsStringSync('original');
        seedLedger(
          location: source,
          nativeRoot: '/work/project/.claude/agents',
        );
        final ledger = fs
            .file('/work/project/.agent-resource/installations.json')
            .readAsStringSync();
        io.failingOperation = boundary.$1;
        io.failingPath = boundary.$2;
        io.interrupt = true;
        await expectLater(
          coordinator.execute(
            ConversionTransitionRequest(
              transactionId: id,
              options: options,
              source: sourceParticipant(
                location: source,
                nativeRoot: '/work/project/.claude/agents',
                artifactKind: 'agent-file',
                nativeForm: 'claude-agent-file',
              ),
              target: targetParticipant(
                location: target,
                nativeRoot: '/work/project/.pi/prompts',
                artifactKind: 'prompt-template',
                nativeForm: 'pi-prompt-template',
                installationId: 'ins_fedcba9876543210fedcba9876543210',
              ),
              targetFiles: {'reviewer.md': utf8.encode('Review.')},
            ),
          ),
          throwsA(isA<StateError>()),
        );
        io.failingOperation = null;
        final resumed = await ConversionCoordinator(
          io: io,
          state: LifecycleStateService(io: io),
          evidence: ConversionEvidenceService(fileSystem: fs),
        ).resume(options: options, transactionId: id);
        expect(
          resumed.phase,
          ConversionEvidencePhase.rolledBack,
          reason: '$boundary',
        );
        expect(fs.file(source).readAsStringSync(), 'original');
        expect(fs.file(target).existsSync(), isFalse);
        expect(
          fs
              .file('/work/project/.agent-resource/installations.json')
              .readAsStringSync(),
          ledger,
        );
      }
    });

    test('interrupted evidence upgrade uses immutable intent; corrupt fallback fails closed', () async {
      const id = 'cvx_0123456789abcdef0123456789abcdef';
      const source = '/work/project/.claude/agents/reviewer.md';
      const target = '/work/project/.pi/prompts/reviewer.md';
      const stage = '/work/project/.agent-resource/conversions/$id';
      for (final corruptFallback in [false, true]) {
        fs = MemoryFileSystem();
        fs.directory('/work/project').createSync(recursive: true);
        fs.directory('/home/user').createSync(recursive: true);
        io = _FaultyIO(fs)..interruptEvidenceUpgrade = true;
        state = LifecycleStateService(io: io);
        coordinator = ConversionCoordinator(
          io: io,
          state: state,
          evidence: ConversionEvidenceService(fileSystem: fs),
        );
        fs.file(source)
          ..createSync(recursive: true)
          ..writeAsStringSync('original');
        seedLedger(
          location: source,
          nativeRoot: '/work/project/.claude/agents',
        );
        await expectLater(
          coordinator.execute(
            ConversionTransitionRequest(
              transactionId: id,
              options: options,
              source: sourceParticipant(
                location: source,
                nativeRoot: '/work/project/.claude/agents',
                artifactKind: 'agent-file',
                nativeForm: 'claude-agent-file',
              ),
              target: targetParticipant(
                location: target,
                nativeRoot: '/work/project/.pi/prompts',
                artifactKind: 'prompt-template',
                nativeForm: 'pi-prompt-template',
                installationId: 'ins_fedcba9876543210fedcba9876543210',
              ),
              targetFiles: {'reviewer.md': utf8.encode('Review.')},
            ),
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          fs
              .file('/work/project/.agent-resource/conversions/$id.json')
              .readAsStringSync(),
          '{partial',
        );
        expect(fs.file('$stage/initial-intent.json').existsSync(), isTrue);
        io.interruptEvidenceUpgrade = false;
        if (corruptFallback) {
          fs.file('$stage/initial-intent.json').writeAsStringSync('{bad');
        }
        final resumed = ConversionCoordinator(
          io: io,
          state: LifecycleStateService(io: io),
          evidence: ConversionEvidenceService(fileSystem: fs),
        ).resume(options: options, transactionId: id);
        if (corruptFallback) {
          await expectLater(resumed, throwsA(isA<MambaException>()));
          expect(fs.file('$stage/target/reviewer.md').existsSync(), isTrue);
        } else {
          expect((await resumed).phase, ConversionEvidencePhase.rolledBack);
          expect(fs.file('$stage/initial-intent.json').existsSync(), isFalse);
          expect(fs.file('$stage/target/reviewer.md').existsSync(), isFalse);
        }
        expect(fs.file(source).readAsStringSync(), 'original');
        expect(fs.file(target).existsSync(), isFalse);
      }
    });

    test('non-file commit marker blocks rollback', () async {
      const id = 'cvx_0123456789abcdef0123456789abcdef';
      const sourcePath = '/work/project/.claude/agents/reviewer.md';
      fs.file(sourcePath)
        ..createSync(recursive: true)
        ..writeAsStringSync('original');
      seedLedger(
        location: sourcePath,
        nativeRoot: '/work/project/.claude/agents',
      );
      io.failingOperation = 'write';
      io.failingPath = 'commit.json';
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: id,
            options: options,
            source: sourceParticipant(
              location: sourcePath,
              nativeRoot: '/work/project/.claude/agents',
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
            ),
            target: targetParticipant(
              location: '/work/project/.pi/prompts/reviewer.md',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'prompt-template',
              nativeForm: 'pi-prompt-template',
              installationId: 'ins_fedcba9876543210fedcba9876543210',
            ),
            targetFiles: {'reviewer.md': utf8.encode('Review.')},
          ),
        ),
        throwsA(isA<MambaException>()),
      );
      io.failingOperation = null;
      fs
          .directory(
            '/work/project/.agent-resource/conversions/$id/commit.json',
          )
          .createSync(recursive: true);
      await expectLater(
        coordinator.resume(options: options, transactionId: id),
        throwsA(isA<MambaException>()),
      );
      expect(
        fs.file('/work/project/.pi/prompts/reviewer.md').readAsStringSync(),
        'Review.',
      );
      expect(fs.file(sourcePath).readAsStringSync(), 'original');
    });

    test('every durable boundary is exercised', () async {
      const boundaries = <_Boundary>[
        _Boundary(
          'createDirectory',
          'conversions/cvx_0123456789abcdef0123456789abcdef/',
          false,
        ),
        _Boundary('copy', null, false),
        _Boundary('write', '/target/', false),
        _Boundary(
          'write',
          'conversions/cvx_0123456789abcdef0123456789abcdef.json',
          true,
        ),
        _Boundary('write', 'commit.json', true, afterCommit: true),
        _Boundary('write', 'installations.json', true, afterCommit: true),
        _Boundary('delete', '/target', true, afterCommit: true),
      ];
      for (final boundary in boundaries) {
        fs.directory('/work/project').createSync(recursive: true);
        fs.directory('/home/user').createSync(recursive: true);
        fs = MemoryFileSystem();
        fs.directory('/work/project').createSync(recursive: true);
        fs.directory('/home/user').createSync(recursive: true);
        io = _FaultyIO(fs);
        state = LifecycleStateService(io: io);
        coordinator = ConversionCoordinator(
          io: io,
          state: state,
          evidence: ConversionEvidenceService(fileSystem: fs),
        );
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .createSync(recursive: true);
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .writeAsStringSync('Original agent instructions');
        seedLedger(
          location: '/work/project/.claude/agents/reviewer.md',
          nativeRoot: '/work/project/.claude/agents',
        );
        io.failingOperation = boundary.operation;
        io.failingPath = boundary.path;
        final request = ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/reviewer.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            installationId: 'ins_fedcba9876543210fedcba9876543210',
          ),
          targetFiles: <String, List<int>>{
            'reviewer.md': utf8.encode('Review.'),
          },
        );
        if (boundary.expectRecovery) {
          await expectLater(
            coordinator.execute(request),
            throwsA(isA<MambaException>()),
          );
          expect(
            fs.file('/work/project/.pi/prompts/reviewer.md').existsSync(),
            boundary.afterCommit,
            reason:
                'the published target follows the commit decision: '
                '${boundary.operation} ${boundary.path}',
          );
        } else {
          final outcome = await coordinator.execute(request);
          expect(
            outcome.phase,
            ConversionEvidencePhase.rolledBack,
            reason: 'a failure before the commit rolls back',
          );
          expect(outcome.succeeded, isFalse);
          expect(
            fs.file('/work/project/.pi/prompts/reviewer.md').existsSync(),
            isFalse,
          );
          expect(
            fs
                .file('/work/project/.claude/agents/reviewer.md')
                .readAsStringSync(),
            'Original agent instructions',
          );
        }
      }
    });

    test('a cross scope conversion reconciles both roots', () async {
      fs
          .file('/work/project/.claude/skills/demo/SKILL.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/skills/demo/SKILL.md')
          .writeAsStringSync('Skill instructions');
      final projectState = '/work/project/.agent-resource';
      fs.directory(projectState).createSync(recursive: true);
      fs
          .file('$projectState/installations.json')
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'installations': <Object?>[
                InstallationRecord(
                  installationId: sourceInstallationId,
                  kind: ArtifactKind.skillCopy,
                  scope: LifecycleScope.project,
                  nativeDestination: 'claude',
                  nativeForm: 'claude-skill',
                  location: '/work/project/.claude/skills/demo',
                  nativeRoot: '/work/project/.claude/skills',
                  name: 'demo',
                  nativeProfile: 'claude',
                  validatedProfiles: const <String>['claude'],
                  knownConsumers: const <String>['claude'],
                  baseline: const ArtifactBaseline(<BaselineEntry>[]),
                  lifecycle: 'live',
                  origin: const <String, Object?>{'status': 'unknown'},
                  backupIds: const <String>[],
                  transactionId: null,
                ).toJson(),
              ],
            }),
          );
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options.copyWith(scope: LifecycleScope.user),
          source:
              sourceParticipant(
                location: '/work/project/.claude/skills/demo',
                nativeRoot: '/work/project/.claude/skills',
                artifactKind: 'skill-copy',
                nativeForm: 'claude-skill',
              ).copyWith(
                ownershipBefore: ConversionOwnership(
                  managed: true,
                  installationId: sourceInstallationId,
                  nativeForm: 'claude-skill',
                  nativeProfile: 'claude',
                  location: '/work/project/.claude/skills/demo',
                  nativeRoot: '/work/project/.claude/skills',
                  scope: 'project',
                ),
              ),
          target:
              targetParticipant(
                location: '/home/user/.claude/skills/demo',
                nativeRoot: '/home/user/.claude/skills',
                artifactKind: 'skill-copy',
                nativeForm: 'claude-skill',
                installationId: 'ins_fedcba9876543210fedcba9876543210',
              ).copyWith(
                ownershipAfter: ConversionOwnership(
                  managed: true,
                  installationId: 'ins_fedcba9876543210fedcba9876543210',
                  nativeForm: 'claude-skill',
                  nativeProfile: 'claude',
                  location: '/home/user/.claude/skills/demo',
                  nativeRoot: '/home/user/.claude/skills',
                  scope: 'user',
                ),
              ),
          targetFiles: <String, List<int>>{
            'SKILL.md': utf8.encode('---\nname: demo\n---\nDemo.'),
          },
        ),
      );
      expect(outcome.succeeded, isTrue);
      final projectLedger = jsonDecode(
        fs.file('$projectState/installations.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final projectRecords = projectLedger['installations']! as List<Object?>;
      expect(projectRecords.length, 1);
      expect(
        (projectRecords.single! as Map<String, Object?>)['lifecycle'],
        'removed',
      );
      final userLedger = jsonDecode(
        fs.file('/work/state/installations.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final userRecords = userLedger['installations']! as List<Object?>;
      expect(userRecords.length, 1);
      expect(
        (userRecords.single! as Map<String, Object?>)['lifecycle'],
        'live',
      );
    });

    test(
      'a file to file conversion publishes, commits and reconciles',
      () async {
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .createSync(recursive: true);
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .writeAsStringSync('Original agent instructions');
        seedLedger(
          location: '/work/project/.claude/agents/reviewer.md',
          nativeRoot: '/work/project/.claude/agents',
        );
        final outcome = await coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source:
                sourceParticipant(
                  location: '/work/project/.claude/agents/reviewer.md',
                  nativeRoot: '/work/project/.claude/agents',
                  artifactKind: 'agent-file',
                  nativeForm: 'claude-agent-file',
                ).copyWith(
                  membershipBefore: const ConversionMembership(
                    kind: 'pack',
                    state: 'active',
                    memberId: 'mem_reviewer',
                    source: 'pack_demo',
                  ),
                ),
            target: targetParticipant(
              location: '/work/project/.pi/prompts/reviewer.md',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'prompt-template',
              nativeForm: 'pi-prompt-template',
              installationId: 'ins_fedcba9876543210fedcba9876543210',
            ),
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode(
                '---\ndescription: Review\n---\nReview.',
              ),
            },
          ),
        );
        expect(outcome.succeeded, isTrue);
        expect(outcome.phase, ConversionEvidencePhase.completed);
        expect(outcome.committed, isTrue);
        expect(outcome.reconciled, isTrue);
        expect(
          fs.file('/work/project/.pi/prompts/reviewer.md').readAsStringSync(),
          contains('description: Review'),
        );
        expect(
          fs.file('/work/project/.claude/agents/reviewer.md').existsSync(),
          isFalse,
        );
        final ledger = jsonDecode(
          fs
              .file('/work/project/.agent-resource/installations.json')
              .readAsStringSync(),
        ) as Map<String, Object?>;
        final records = ledger['installations']! as List<Object?>;
        expect(records.length, 2);
        final live = records.cast<Map<String, Object?>>().where(
          (record) => record['lifecycle'] == 'live',
        );
        expect(live.length, 1);
        expect(
          live.single['location'],
          '/work/project/.pi/prompts/reviewer.md',
        );
        final liveOrigin = live.single['origin']! as Map<String, Object?>;
        expect(
          (liveOrigin['conversionMembership']!
              as Map<String, Object?>)['state'],
          'detached',
        );
        final removed = records.cast<Map<String, Object?>>().singleWhere(
          (record) => record['lifecycle'] == 'removed',
        );
        final removedOrigin = removed['origin']! as Map<String, Object?>;
        expect(
          (removedOrigin['conversionMembership']!
              as Map<String, Object?>)['state'],
          'retired',
        );
        expect(
          fs.file(outcome.recoveryPayloadPath!).readAsStringSync(),
          'Original agent instructions',
        );
      },
    );

    test('a directory to file conversion publishes the template', () async {
      fs
          .file('/work/project/.claude/skills/demo/SKILL.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/skills/demo/SKILL.md')
          .writeAsStringSync('Skill instructions');
      seedLedger(
        location: '/work/project/.claude/skills/demo',
        nativeRoot: '/work/project/.claude/skills',
        kind: ArtifactKind.skillCopy,
        nativeForm: 'claude-skill',
      );
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/skills/demo',
            nativeRoot: '/work/project/.claude/skills',
            artifactKind: 'skill-copy',
            nativeForm: 'claude-skill',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/demo.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            installationId: 'ins_fedcba9876543210fedcba9876543210',
          ),
          targetFiles: <String, List<int>>{
            'demo.md': utf8.encode('---\ndescription: Demo\n---\nDemo.'),
          },
        ),
      );
      expect(outcome.succeeded, isTrue);
      expect(fs.file('/work/project/.pi/prompts/demo.md').existsSync(), isTrue);
      expect(
        fs.directory('/work/project/.claude/skills/demo').existsSync(),
        isFalse,
      );
    });

    test('an in place conversion keeps the installation identity', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          targetFiles: <String, List<int>>{
            'reviewer.md': utf8.encode('Converted agent instructions'),
          },
        ),
      );
      expect(outcome.succeeded, isTrue);
      expect(
        fs.file('/work/project/.claude/agents/reviewer.md').readAsStringSync(),
        'Converted agent instructions',
      );
      final ledger = jsonDecode(
        fs
            .file('/work/project/.agent-resource/installations.json')
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final records = ledger['installations']! as List<Object?>;
      expect(records.length, 1);
      final record = records.single! as Map<String, Object?>;
      expect(record['installationId'], sourceInstallationId);
      expect(record['lifecycle'], 'live');
    });

    test('a changed source is refused before any live effect', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      final source = sourceParticipant(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
        artifactKind: 'agent-file',
        nativeForm: 'claude-agent-file',
      );
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Changed instructions');
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: source,
            target: targetParticipant(
              location: '/work/project/.pi/prompts/reviewer.md',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'prompt-template',
              nativeForm: 'pi-prompt-template',
              installationId: 'ins_fedcba9876543210fedcba9876543210',
            ),
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Review.'),
            },
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('changed since the reviewed plan'),
          ),
        ),
      );
      expect(
        fs.file('/work/project/.pi/prompts/reviewer.md').existsSync(),
        isFalse,
      );
    });

    test('a failure before the commit rolls the transition back', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      io.failingOperation = 'write';
      io.failingPath = '/work/project/.pi/prompts/reviewer.md';
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/reviewer.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            installationId: 'ins_fedcba9876543210fedcba9876543210',
          ),
          targetFiles: <String, List<int>>{
            'reviewer.md': utf8.encode('Review.'),
          },
        ),
      );
      expect(outcome.succeeded, isFalse);
      expect(outcome.phase, ConversionEvidencePhase.rolledBack);
      expect(
        fs.file('/work/project/.pi/prompts/reviewer.md').existsSync(),
        isFalse,
      );
      expect(
        fs.file('/work/project/.claude/agents/reviewer.md').readAsStringSync(),
        'Original agent instructions',
      );
    });

    test(
      'a reconstructed service finishes a committed transition forward',
      () async {
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .createSync(recursive: true);
        fs
            .file('/work/project/.claude/agents/reviewer.md')
            .writeAsStringSync('Original agent instructions');
        seedLedger(
          location: '/work/project/.claude/agents/reviewer.md',
          nativeRoot: '/work/project/.claude/agents',
        );
        io.failingOperation = 'write';
        io.failingPath = 'installations.json';
        await expectLater(
          coordinator.execute(
            ConversionTransitionRequest(
              transactionId: 'cvx_0123456789abcdef0123456789abcdef',
              options: options,
              source: sourceParticipant(
                location: '/work/project/.claude/agents/reviewer.md',
                nativeRoot: '/work/project/.claude/agents',
                artifactKind: 'agent-file',
                nativeForm: 'claude-agent-file',
              ),
              target: targetParticipant(
                location: '/work/project/.pi/prompts/reviewer.md',
                nativeRoot: '/work/project/.pi/prompts',
                artifactKind: 'prompt-template',
                nativeForm: 'pi-prompt-template',
                installationId: 'ins_fedcba9876543210fedcba9876543210',
              ),
              targetFiles: <String, List<int>>{
                'reviewer.md': utf8.encode('Review.'),
              },
            ),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'exit code',
              6,
            ),
          ),
        );
        io.failingOperation = null;
        io.failingPath = null;
        final reconstructed = ConversionCoordinator(
          io: io,
          state: LifecycleStateService(io: io),
          evidence: ConversionEvidenceService(fileSystem: fs),
        );
        final outcome = await reconstructed.resume(
          options: options,
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
        );
        expect(outcome.succeeded, isTrue);
        expect(outcome.committed, isTrue);
        expect(outcome.phase, ConversionEvidencePhase.completed);
      },
    );

    test('recovery refuses a changed source ledger record', () async {
      const id = 'cvx_0123456789abcdef0123456789abcdef';
      const source = '/work/project/.claude/agents/reviewer.md';
      const root = '/work/project/.claude/agents';
      fs.file(source)
        ..createSync(recursive: true)
        ..writeAsStringSync('original');
      seedLedger(location: source, nativeRoot: root);
      io.failingOperation = 'write';
      io.failingPath = 'installations.json';
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: id,
            options: options,
            source: sourceParticipant(
              location: source,
              nativeRoot: root,
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
            ),
            target: targetParticipant(
              location: '/work/project/.pi/prompts/reviewer.md',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'prompt-template',
              nativeForm: 'pi-prompt-template',
              installationId: 'ins_fedcba9876543210fedcba9876543210',
            ),
            targetFiles: {'reviewer.md': utf8.encode('Review.')},
          ),
        ),
        throwsA(isA<MambaException>()),
      );
      io.failingOperation = null;
      final ledger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final document =
          jsonDecode(ledger.readAsStringSync()) as Map<String, dynamic>;
      (document['installations'] as List<dynamic>).single['location'] =
          '/work/project/elsewhere.md';
      final changed = jsonEncode(document);
      ledger.writeAsStringSync(changed);
      await expectLater(
        coordinator.resume(options: options, transactionId: id),
        throwsA(isA<MambaException>()),
      );
      expect(ledger.readAsStringSync(), changed);
    });

    test(
      'recovery refuses changed source metadata without overwriting it',
      () async {
        const id = 'cvx_0123456789abcdef0123456789abcdef';
        const source = '/work/project/.claude/agents/reviewer.md';
        const root = '/work/project/.claude/agents';
        fs.file(source)
          ..createSync(recursive: true)
          ..writeAsStringSync('original');
        seedLedger(location: source, nativeRoot: root);
        io.failingOperation = 'write';
        io.failingPath = 'installations.json';
        await expectLater(
          coordinator.execute(
            ConversionTransitionRequest(
              transactionId: id,
              options: options,
              source: sourceParticipant(
                location: source,
                nativeRoot: root,
                artifactKind: 'agent-file',
                nativeForm: 'claude-agent-file',
              ),
              target: targetParticipant(
                location: '/work/project/.pi/prompts/reviewer.md',
                nativeRoot: '/work/project/.pi/prompts',
                artifactKind: 'prompt-template',
                nativeForm: 'pi-prompt-template',
                installationId: 'ins_fedcba9876543210fedcba9876543210',
              ),
              targetFiles: {'reviewer.md': utf8.encode('Review.')},
            ),
          ),
          throwsA(isA<MambaException>()),
        );
        io.failingOperation = null;
        final ledger = fs.file(
          '/work/project/.agent-resource/installations.json',
        );
        final document =
            jsonDecode(ledger.readAsStringSync()) as Map<String, dynamic>;
        (document['installations'] as List<dynamic>).single['origin'] =
            <String, Object?>{'status': 'changed after commit'};
        final changed = jsonEncode(document);
        ledger.writeAsStringSync(changed);
        await expectLater(
          coordinator.resume(options: options, transactionId: id),
          throwsA(isA<MambaException>()),
        );
        expect(ledger.readAsStringSync(), changed);
      },
    );

    test('completed evidence and ledgers remain readable', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      final outcome = await coordinator.execute(
        ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: '/work/project/.claude/agents/reviewer.md',
            nativeRoot: '/work/project/.claude/agents',
            artifactKind: 'agent-file',
            nativeForm: 'claude-agent-file',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/reviewer.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            installationId: 'ins_fedcba9876543210fedcba9876543210',
          ),
          targetFiles: <String, List<int>>{
            'reviewer.md': utf8.encode('Review.'),
          },
        ),
      );
      final evidence = await ConversionEvidenceService(
        fileSystem: fs,
      ).readPersisted('/work/project/.agent-resource', outcome.transactionId);
      expect(evidence!.phase, ConversionEvidencePhase.completed);
      expect(evidence.source.payload!.digest, evidence.source.baseline!.digest);
      expect(evidence.target.publication!.verified, isTrue);
      expect(
        state.records(LifecycleContext.resolve(options, fileSystem: fs)),
        hasLength(2),
      );
    });

    test('an occupied target is refused before staging', () async {
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .createSync(recursive: true);
      fs
          .file('/work/project/.claude/agents/reviewer.md')
          .writeAsStringSync('Original agent instructions');
      fs.file('/work/project/.pi/prompts/reviewer.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing target');
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
              nativeRoot: '/work/project/.claude/agents',
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
            ),
            target: targetParticipant(
              location: '/work/project/.pi/prompts/reviewer.md',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'prompt-template',
              nativeForm: 'pi-prompt-template',
            ),
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Review.'),
            },
          ),
        ),
        throwsA(isA<MambaException>()),
      );
      expect(
        fs.file('/work/project/.pi/prompts/reviewer.md').readAsStringSync(),
        'Existing target',
      );
      expect(
        fs.directory('/work/project/.agent-resource/conversions').existsSync(),
        isFalse,
      );
    });

    test('unsafe proposed target paths are refused before staging', () async {
      fs.file('/work/project/.claude/skills/demo/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Skill instructions');
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/skills/demo',
              nativeRoot: '/work/project/.claude/skills',
              artifactKind: 'skill-copy',
              nativeForm: 'claude-skill',
            ),
            target: targetParticipant(
              location: '/work/project/.codex/skills/demo',
              nativeRoot: '/work/project/.codex/skills',
              artifactKind: 'skill-copy',
              nativeForm: 'codex-skill',
              installationId: 'ins_fedcba9876543210fedcba9876543210',
            ),
            targetFiles: <String, List<int>>{
              '../escape': utf8.encode('escape'),
            },
          ),
        ),
        throwsA(isA<MambaException>()),
      );
      expect(
        fs.file('/work/project/.codex/skills/escape').existsSync(),
        isFalse,
      );
    });

    test(
      'an in-place quarantine failure rolls back without live change',
      () async {
        fs.file('/work/project/.claude/agents/reviewer.md')
          ..createSync(recursive: true)
          ..writeAsStringSync('Original agent instructions');
        seedLedger(
          location: '/work/project/.claude/agents/reviewer.md',
          nativeRoot: '/work/project/.claude/agents',
        );
        io.failingOperation = 'rename';
        io.failingPath = '/work/project/.claude/agents/reviewer.md';
        final outcome = await coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
              nativeRoot: '/work/project/.claude/agents',
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
            ),
            target: targetParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
              nativeRoot: '/work/project/.claude/agents',
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
            ),
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Converted instructions'),
            },
          ),
        );
        expect(outcome.phase, ConversionEvidencePhase.rolledBack);
        expect(
          fs
              .file('/work/project/.claude/agents/reviewer.md')
              .readAsStringSync(),
          'Original agent instructions',
        );
      },
    );

    test('source ownership must match the reviewed ledger record', () async {
      fs.file('/work/project/.claude/agents/reviewer.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/other.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
              nativeRoot: '/work/project/.claude/agents',
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
            ),
            target: targetParticipant(
              location: '/work/project/.pi/prompts/reviewer.md',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'prompt-template',
              nativeForm: 'pi-prompt-template',
            ),
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Review.'),
            },
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('does not match the installation ledger'),
          ),
        ),
      );
    });

    test('cross-scope target ownership is refused', () async {
      fs.file('/work/project/.claude/agents/reviewer.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Original agent instructions');
      seedLedger(
        location: '/work/project/.claude/agents/reviewer.md',
        nativeRoot: '/work/project/.claude/agents',
      );
      fs.directory('/work/state').createSync(recursive: true);
      fs
          .file('/work/state/installations.json')
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'installations': <Object?>[
                InstallationRecord(
                  installationId: 'ins_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                  kind: ArtifactKind.promptTemplate,
                  scope: LifecycleScope.user,
                  nativeDestination: 'pi',
                  nativeForm: 'pi-prompt-template',
                  location: '/work/project/.pi/prompts/reviewer.md',
                  nativeRoot: '/work/project/.pi/prompts',
                  name: 'reviewer.md',
                  nativeProfile: 'pi',
                  validatedProfiles: const <String>['pi'],
                  knownConsumers: const <String>['pi'],
                  baseline: const ArtifactBaseline(<BaselineEntry>[]),
                  lifecycle: 'live',
                  origin: const <String, Object?>{'status': 'unknown'},
                  backupIds: const <String>[],
                  transactionId: null,
                ).toJson(),
              ],
            }),
          );
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/agents/reviewer.md',
              nativeRoot: '/work/project/.claude/agents',
              artifactKind: 'agent-file',
              nativeForm: 'claude-agent-file',
            ),
            target: targetParticipant(
              location: '/work/project/.pi/prompts/reviewer.md',
              nativeRoot: '/work/project/.pi/prompts',
              artifactKind: 'prompt-template',
              nativeForm: 'pi-prompt-template',
            ),
            targetFiles: <String, List<int>>{
              'reviewer.md': utf8.encode('Review.'),
            },
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('Another scope already owns'),
          ),
        ),
      );
    });

    test('unsupported linked target publication is refused', () async {
      fs.file('/work/project/.claude/skills/demo/SKILL.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Skill instructions');
      await expectLater(
        coordinator.execute(
          ConversionTransitionRequest(
            transactionId: 'cvx_0123456789abcdef0123456789abcdef',
            options: options,
            source: sourceParticipant(
              location: '/work/project/.claude/skills/demo',
              nativeRoot: '/work/project/.claude/skills',
              artifactKind: 'skill-copy',
              nativeForm: 'claude-skill',
            ),
            target: targetParticipant(
              location: '/work/project/.codex/skills/demo',
              nativeRoot: '/work/project/.codex/skills',
              artifactKind: 'skill-link',
              nativeForm: 'codex-skill-link',
            ),
            targetFiles: <String, List<int>>{'SKILL.md': utf8.encode('Demo.')},
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('not supported'),
          ),
        ),
      );
    });
  });

  group('pending transaction guards', () {
    test(
      'a pending conflict is reported as a conflict, not as missing authority',
      () async {
        final request = seedRequest();
        io.after = (operation, path) {
          if (operation == 'write' &&
              path.endsWith('/conversions/${request.transactionId}.json')) {
            throw StateError('Interrupted after intent');
          }
        };
        await expectLater(coordinator.execute(request), throwsStateError);
        io.after = null;
        final ledger = fs.file(
          '/work/project/.agent-resource/installations.json',
        );
        final before = ledger.readAsStringSync();
        await expectLater(
          LifecycleStateService(io: LifecycleIO(fs: fs)).updateOrigin(
            context: LifecycleContext.resolve(
              options.copyWith(approved: true),
              fileSystem: fs,
            ),
            installationId: sourceInstallationId,
            expectedOrigin: const {'status': 'unknown'},
            origin: const {'status': 'known'},
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 6)
                .having(
                  (error) => error.message,
                  'diagnostic',
                  allOf(
                    contains('Pending coordinated transaction'),
                    isNot(contains('authority is unavailable')),
                  ),
                ),
          ),
        );
        expect(ledger.readAsStringSync(), before);
      },
    );

    test('an unreadable coordinator is reported as unavailable authority', () async {
      final request = seedRequest();
      io.after = (operation, path) {
        if (operation == 'write' &&
            path.endsWith('/conversions/${request.transactionId}.json')) {
          throw StateError('Interrupted after intent');
        }
      };
      await expectLater(coordinator.execute(request), throwsStateError);
      io.after = null;
      final authority = fs.file(
        '/work/project/.agent-resource/conversions/${request.transactionId}.json',
      );
      final document = jsonDecode(authority.readAsStringSync()) as Map;
      document['schemaVersion'] = 999;
      authority.writeAsStringSync(jsonEncode(document));
      final ledger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final before = ledger.readAsStringSync();
      await expectLater(
        LifecycleStateService(io: LifecycleIO(fs: fs)).updateOrigin(
          context: LifecycleContext.resolve(
            options.copyWith(approved: true),
            fileSystem: fs,
          ),
          installationId: sourceInstallationId,
          expectedOrigin: const {'status': 'unknown'},
          origin: const {'status': 'known'},
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains('Coordinated mutation authority is unavailable'),
              ),
        ),
      );
      expect(ledger.readAsStringSync(), before);
    });

    test(
      'the registered skill remove command refuses a pending participant',
      () async {
        const skillPath = '/work/project/.claude/skills/reserved';
        fs.file('$skillPath/SKILL.md')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '---\nname: reserved\ndescription: Work.\n---\nWork.\n',
          );
        seedLedger(
          location: skillPath,
          nativeRoot: '/work/project/.claude/skills',
          kind: ArtifactKind.skillCopy,
          nativeForm: 'skill-copy',
        );
        final ledger = fs.file(
          '/work/project/.agent-resource/installations.json',
        );
        final document = jsonDecode(ledger.readAsStringSync()) as Map;
        final record = (document['installations'] as List).single as Map;
        record['baseline'] = state
            .baselineFor(skillPath, ArtifactKind.skillCopy)
            .toJson();
        ledger.writeAsStringSync(jsonEncode(document));
        final request = ConversionTransitionRequest(
          transactionId: 'cvx_0123456789abcdef0123456789abcdef',
          options: options,
          source: sourceParticipant(
            location: skillPath,
            nativeRoot: '/work/project/.claude/skills',
            artifactKind: 'skill-copy',
            nativeForm: 'skill-copy',
          ),
          target: targetParticipant(
            location: '/work/project/.pi/prompts/reserved.md',
            nativeRoot: '/work/project/.pi/prompts',
            artifactKind: 'prompt-template',
            nativeForm: 'pi-prompt-template',
            installationId: 'ins_fedcba9876543210fedcba9876543210',
          ),
          targetFiles: <String, List<int>>{
            'reserved.md': utf8.encode('---\ndescription: Work\n---\nWork.'),
          },
        );
        io.after = (operation, path) {
          if (operation == 'write' &&
              path.endsWith('/conversions/${request.transactionId}.json')) {
            throw StateError('Interrupted after intent');
          }
        };
        await expectLater(coordinator.execute(request), throwsStateError);
        io.after = null;
        final result = await createExecutor(fileSystem: fs).fake().execute([
          'skill',
          'remove',
          sourceInstallationId,
          '--scope',
          'project',
          '--cwd',
          '/work/project/',
          '--project-root',
          '/work/project/',
          '--home',
          '/home/user/',
          '--state-dir',
          '/work/state/',
          '--yes',
          '--format',
          'json',
        ]);
        expect(
          result,
          isA<MambaFailureResult>()
              .having((value) => value.exitCode, 'status', 6)
              .having(
                (value) => value.message,
                'diagnostic',
                contains('Pending coordinated transaction'),
              )
              .having((value) => value.output, 'output', isNull),
        );
        expect(fs.directory(skillPath).existsSync(), isTrue);
        expect(
          fs.file('/work/project/.pi/prompts/reserved.md').existsSync(),
          isFalse,
        );
      },
    );
    test('a participant reference in another project names the blocking transaction', () async {
      final original = seedRequest();
      final userSource = '/home/user/.claude/agents/reviewer.md';
      fs.file(userSource)
        ..createSync(recursive: true)
        ..writeAsStringSync('original');
      final projectLedger = fs.file(
        '/work/project/.agent-resource/installations.json',
      );
      final document = jsonDecode(projectLedger.readAsStringSync()) as Map;
      final record = (document['installations'] as List).single as Map;
      record['scope'] = 'user';
      record['location'] = userSource;
      record['nativeRoot'] = '/home/user/.claude/agents';
      fs.file('/work/state/installations.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(document));
      projectLedger.deleteSync();
      final request = ConversionTransitionRequest(
        transactionId: original.transactionId,
        options: options,
        source: ConversionParticipant(
          role: ConversionParticipantRole.source,
          intent: ConversionParticipantIntent.retired,
          artifactKind: 'agent-file',
          nativeForm: 'claude-agent-file',
          nativeProfile: 'claude',
          location: userSource,
          nativeRoot: '/home/user/.claude/agents',
          scope: 'user',
          ownershipBefore: ConversionOwnership(
            managed: true,
            installationId: sourceInstallationId,
            nativeForm: 'claude-agent-file',
            nativeProfile: 'claude',
            location: userSource,
            nativeRoot: '/home/user/.claude/agents',
            scope: 'user',
          ),
          baseline: ConversionBaseline(
            entries: conversionManifestEntries(io, userSource),
          ),
        ),
        target: original.target,
        targetFiles: original.targetFiles,
      );
      io.after = (operation, path) {
        if (operation == 'write' &&
            path.endsWith('/conversions/${request.transactionId}.json')) {
          throw StateError('Interrupted after the coordinator intent');
        }
      };
      await expectLater(coordinator.execute(request), throwsStateError);
      io.after = null;
      fs.directory('/work/other').createSync();
      await expectLater(
        LifecycleStateService(io: LifecycleIO(fs: fs)).updateOrigin(
          context: LifecycleContext.resolve(
            LifecycleOptions(
              processWorkingDirectory: '/work/other',
              environment: const <String, String>{},
              scope: LifecycleScope.user,
              projectRoot: '/work/other',
              cwd: '/work/other',
              home: '/home/user',
              stateDir: '/work/state',
              approved: true,
            ),
            fileSystem: fs,
          ),
          installationId: sourceInstallationId,
          expectedOrigin: const {'status': 'unknown'},
          origin: const {'status': 'known'},
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 6)
              .having(
                (error) => error.message,
                'diagnostic',
                contains(
                  'Pending coordinated transaction ${request.transactionId}',
                ),
              ),
        ),
      );
      expect(
        fs.file('/work/state/installations.json').readAsStringSync(),
        jsonEncode(document),
      );
    });
  });
}
