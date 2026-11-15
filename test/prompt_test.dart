import 'dart:convert';
import 'dart:io' show FileSystemEntityType;

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/conversion/conversion_evidence.dart';
import 'package:agent_resource/src/services/conversion_coordinator_service.dart';
import 'package:agent_resource/src/services/agent_lifecycle_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:file/file.dart' show File;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

class _InterruptIO extends LifecycleIO {
  _InterruptIO(MemoryFileSystem fs) : super(fs: fs);
  void Function(String, String)? after;
  void Function(String)? beforeDelete;

  @override
  void write(String path, List<int> bytes) {
    super.write(path, bytes);
    after?.call('write', path);
  }

  @override
  void delete(String path) {
    beforeDelete?.call(path);
    super.delete(path);
    after?.call('delete', path);
  }

  @override
  void rename(String source, String destination) {
    super.rename(source, destination);
    after?.call('rename', destination);
  }
}

void main() {
  const id = 'cvx_0123456789abcdef0123456789abcdef';
  const installationId = 'ins_0123456789abcdef0123456789abcdef';
  late MemoryFileSystem fs;
  late _InterruptIO io;
  late LifecycleOptions options;
  late ConversionTransitionRequest request;

  ConversionCoordinator coordinator({bool interrupted = false}) {
    final selectedIO = interrupted ? io : LifecycleIO(fs: fs);
    return ConversionCoordinator(
      io: selectedIO,
      state: LifecycleStateService(io: selectedIO),
    );
  }

  void seed({
    bool inPlace = false,
    bool directory = false,
    bool userTarget = false,
    bool managed = true,
    bool directoryTarget = false,
  }) {
    fs = MemoryFileSystem();
    fs.directory('/project').createSync();
    fs.directory('/home').createSync();
    fs.currentDirectory = '/project';
    io = _InterruptIO(fs);
    options = LifecycleOptions(
      processWorkingDirectory: '/project',
      environment: const {},
      projectRoot: '/project',
      home: '/home',
      stateDir: '/state',
      scope: userTarget ? LifecycleScope.user : LifecycleScope.project,
    );
    final source = directory
        ? '/project/skills/source'
        : '/project/agents/source.md';
    fs.file(directory ? '$source/SKILL.md' : source)
      ..createSync(recursive: true)
      ..writeAsStringSync('original body');
    if (directory) {
      fs.file('$source/references/notes.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('owned member');
    }
    final kind = directory ? ArtifactKind.skillCopy : ArtifactKind.agentFile;
    final form = directory ? 'skill-directory' : 'claude-agent-file';
    if (managed) {
      final record = InstallationRecord(
        installationId: installationId,
        kind: kind,
        scope: LifecycleScope.project,
        nativeDestination: 'claude',
        nativeForm: form,
        location: source,
        nativeRoot: fs.path.dirname(source),
        name: fs.path.basename(source),
        nativeProfile: 'claude',
        validatedProfiles: const ['claude'],
        knownConsumers: const ['claude'],
        baseline: coordinator().state.baselineFor(source, kind),
        lifecycle: 'live',
        origin: const {'status': 'unknown'},
        backupIds: const [],
        transactionId: null,
      );
      fs.file('/project/.agent-resource/installations.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'schemaVersion': 1,
            'installations': [record.toJson()],
          }),
        );
    }
    final target = inPlace
        ? source
        : '${userTarget ? '/home' : '/project'}/prompts/${directoryTarget ? 'target' : 'target.md'}';
    final targetKind = inPlace
        ? kind.wireName
        : (directoryTarget ? 'skill-copy' : 'prompt-template');
    final targetForm = inPlace
        ? form
        : (directoryTarget ? 'skill-directory' : 'pi-prompt-template');
    request = ConversionTransitionRequest(
      transactionId: id,
      options: options,
      source: ConversionParticipant(
        role: ConversionParticipantRole.source,
        intent: ConversionParticipantIntent.retired,
        artifactKind: kind.wireName,
        nativeForm: form,
        nativeProfile: 'claude',
        location: source,
        nativeRoot: fs.path.dirname(source),
        scope: 'project',
        ownershipBefore: ConversionOwnership(
          managed: managed,
          installationId: managed ? installationId : null,
          receiptId: managed ? null : 'source-receipt',
          nativeForm: form,
          nativeProfile: 'claude',
          location: source,
          nativeRoot: fs.path.dirname(source),
          scope: 'project',
        ),
        baseline: ConversionBaseline(
          entries: conversionManifestEntries(io, source),
        ),
      ),
      target: ConversionParticipant(
        role: ConversionParticipantRole.target,
        intent: ConversionParticipantIntent.created,
        artifactKind: targetKind,
        nativeForm: targetForm,
        nativeProfile: 'claude',
        location: target,
        nativeRoot: fs.path.dirname(target),
        scope: options.scope.name,
        ownershipAfter: ConversionOwnership(
          managed: managed,
          installationId: managed ? installationId : null,
          receiptId: managed ? null : 'target-receipt',
          nativeForm: targetForm,
          nativeProfile: 'claude',
          location: target,
          nativeRoot: fs.path.dirname(target),
          scope: options.scope.name,
        ),
      ),
      targetFiles: {
        directoryTarget ? 'SKILL.md' : fs.path.basename(target): utf8.encode(
          'converted body',
        ),
      },
    );
  }

  Future<MambaExecutionResult> invoke(
    String action, {
    List<String> extra = const [],
    bool selectedId = true,
  }) => createExecutor(fileSystem: fs, conversionRecovery: coordinator())
      .fake()
      .execute([
        'prompt',
        'conversion',
        action,
        if (action != 'list' && selectedId) id,
        '--format',
        'json',
        '--home',
        '/home/',
        '--project-root',
        '/project/',
        '--state-dir',
        '/state/',
        '--scope',
        options.scope.name,
        ...extra,
      ]);

  Map<String, dynamic> success(MambaExecutionResult result, String outcome) {
    if (result is MambaFailureResult) fail(result.message);
    expect(
      result,
      isA<MambaSuccessResult>().having(
        (value) => value.exitCode,
        'exit code',
        0,
      ),
    );
    final envelope = jsonDecode(
      (result as MambaSuccessResult).output!,
    ) as Map<String, dynamic>;
    expect(envelope['outcome'], outcome);
    return envelope['data'] as Map<String, dynamic>;
  }

  void failure(
    MambaExecutionResult result,
    String message,
    String action, {
    int code = 6,
  }) {
    expect(
      result,
      isA<MambaFailureResult>()
          .having((value) => value.exitCode, 'exit code', code)
          .having((value) => value.message, 'message', contains(message))
          .having((value) => value.output, 'output', isNull)
          .having(
            (value) => value.error.phase,
            'phase',
            MambaExecutionPhase.run,
          )
          .having((value) => value.error.commandPath, 'path', [
            'agent_resource',
            'prompt',
            'conversion',
            action,
          ]),
    );
  }

  Map<String, String> snapshot() => {
    for (final root in ['/project', '/state', '/home'])
      if (fs.directory(root).existsSync())
        for (final file
            in fs.directory(root).listSync(recursive: true).whereType<File>())
          file.path: base64Encode(file.readAsBytesSync()),
  };

  Future<void> interrupt(String operation, String suffix) async {
    io.after = (op, path) {
      if (op == operation && path.endsWith(suffix)) {
        throw StateError('Process interrupted');
      }
    };
    await expectLater(
      coordinator(interrupted: true).execute(request),
      throwsStateError,
    );
    io.after = null;
  }

  group('agent_resource', () {
    group('prompt', () {
      group('conversion', () {
        group('recover', () {
          for (final duplicate in [
            '/state/conversions/$id.json',
            '/project/.agent-resource/conversion-participants/$id.json',
          ]) {
            test(
              'refuses unvalidated same-ID authority at $duplicate',
              () async {
                seed();
                await interrupt('write', '/commit.json');
                final plan = success(await invoke('recover'), 'planned');
                fs.file(duplicate)
                  ..createSync(recursive: true)
                  ..writeAsStringSync('corrupt duplicate');
                final before = snapshot();
                failure(
                  await invoke('recover'),
                  'duplicate conversion authority',
                  'recover',
                );
                failure(
                  await invoke(
                    'recover',
                    extra: [
                      '--apply',
                      '--yes',
                      '--plan-id',
                      plan['planId'] as String,
                    ],
                  ),
                  'duplicate conversion authority',
                  'recover',
                );
                expect(snapshot(), before);
              },
            );
          }
          for (final deleted in [
            'target.md',
            '$id/target',
            '$id/source-payload',
          ]) {
            test(
              'rollback remains inspectable after recovery is interrupted deleting $deleted',
              () async {
                seed();
                await interrupt('write', '/project/prompts/target.md');
                final plan = success(await invoke('recover'), 'planned');
                io.after = (operation, path) {
                  if (operation == 'delete' && path.endsWith(deleted)) {
                    throw StateError('Interrupted rollback');
                  }
                };
                await expectLater(
                  coordinator(interrupted: true).recoverReviewed(
                    options.copyWith(approved: true),
                    id,
                    planId: plan['planId'] as String,
                  ),
                  throwsStateError,
                );
                io.after = null;
                final inspected = success(await invoke('inspect'), 'reviewed');
                if (inspected['terminal'] == true) {
                  expect(inspected['phase'], 'rolledBack');
                } else {
                  final fresh = success(await invoke('recover'), 'planned');
                  success(
                    await invoke(
                      'recover',
                      extra: [
                        '--apply',
                        '--yes',
                        '--plan-id',
                        fresh['planId'] as String,
                      ],
                    ),
                    'recovered',
                  );
                }
                expect(
                  fs.file(request.source.location).readAsStringSync(),
                  'original body',
                );
                expect(fs.file(request.target.location).existsSync(), isFalse);
              },
            );
          }
          for (final authority in ['missing', 'corrupt', 'changed']) {
            test(
              'process reconstruction refuses $authority participant authority',
              () async {
                seed();
                io.after = (operation, path) {
                  if (path.endsWith('/project/prompts/target.md') &&
                      (operation == 'write' || operation == 'delete')) {
                    throw StateError('Interrupted publication rollback');
                  }
                };
                await expectLater(
                  coordinator(interrupted: true).execute(request),
                  throwsStateError,
                );
                io.after = null;
                final marker = fs.file(
                  '/state/conversion-participants/$id.json',
                );
                switch (authority) {
                  case 'missing':
                    marker.deleteSync();
                  case 'corrupt':
                    marker.writeAsStringSync('{corrupt');
                  case 'changed':
                    final evidence = ConversionEvidence.decode(
                      marker.readAsStringSync(),
                    );
                    marker.writeAsStringSync(
                      evidence
                          .withPhase(ConversionEvidencePhase.published)
                          .encode(),
                    );
                }
                final before = snapshot();
                await expectLater(
                  coordinator().resume(options: options, transactionId: id),
                  throwsA(
                    isA<MambaException>().having(
                      (error) => error.exitCode,
                      'status',
                      6,
                    ),
                  ),
                );
                expect(snapshot(), before);
                expect(
                  fs
                      .directory('/project/.agent-resource/conversions/$id')
                      .existsSync(),
                  isTrue,
                );
              },
            );
          }
          for (final unsafe in [
            'payload path',
            'staging path',
            'publication path',
            'unknown private entry',
            'missing payload',
          ]) {
            test('process reconstruction refuses $unsafe', () async {
              seed();
              io.after = (operation, path) {
                if (path.endsWith('/project/prompts/target.md') &&
                    (operation == 'write' || operation == 'delete')) {
                  throw StateError('Interrupted publication rollback');
                }
              };
              await expectLater(
                coordinator(interrupted: true).execute(request),
                throwsStateError,
              );
              io.after = null;
              final evidenceFile = fs.file(
                '/project/.agent-resource/conversions/$id.json',
              );
              final evidence = ConversionEvidence.decode(
                evidenceFile.readAsStringSync(),
              );
              switch (unsafe) {
                case 'payload path':
                  final payload = evidence.source.payload!;
                  fs.file('/project/substituted/source.md')
                    ..createSync(recursive: true)
                    ..writeAsStringSync('original body');
                  evidenceFile.writeAsStringSync(
                    evidence
                        .copyWith(
                          source: evidence.source.copyWith(
                            payload: ConversionPayloadReference(
                              path: '/project/substituted/source.md',
                              digest: payload.digest,
                              length: payload.length,
                            ),
                          ),
                        )
                        .encode(),
                  );
                case 'staging path':
                  final staging = evidence.target.staging!;
                  evidenceFile.writeAsStringSync(
                    evidence
                        .copyWith(
                          target: evidence.target.copyWith(
                            staging: ConversionPublicationEvidence(
                              path: '/project/substituted/target.md',
                              digest: staging.digest,
                              verified: staging.verified,
                            ),
                          ),
                        )
                        .encode(),
                  );
                case 'publication path':
                  final publication =
                      evidence.target.publication ?? evidence.target.staging!;
                  evidenceFile.writeAsStringSync(
                    evidence
                        .copyWith(
                          target: evidence.target.copyWith(
                            publication: ConversionPublicationEvidence(
                              path: '/project/substituted/published.md',
                              digest: publication.digest,
                              verified: publication.verified,
                            ),
                          ),
                        )
                        .encode(),
                  );
                case 'unknown private entry':
                  fs
                      .file(
                        '/project/.agent-resource/conversions/$id/unexpected.txt',
                      )
                      .writeAsStringSync('not authorized');
                case 'missing payload':
                  fs.file(evidence.source.payload!.path).deleteSync();
              }
              final before = snapshot();
              await expectLater(
                coordinator().resume(options: options, transactionId: id),
                throwsA(
                  isA<MambaException>().having(
                    (error) => error.exitCode,
                    'status',
                    6,
                  ),
                ),
              );
              expect(snapshot(), before);
            });
          }
          test('process reconstruction refuses another pending transaction on the same participants', () async {
            seed();
            io.after = (operation, path) {
              if (path.endsWith('/project/prompts/target.md') &&
                  (operation == 'write' || operation == 'delete')) {
                throw StateError('Interrupted publication rollback');
              }
            };
            await expectLater(
              coordinator(interrupted: true).execute(request),
              throwsStateError,
            );
            io.after = null;
            final evidence = ConversionEvidence.decode(
              fs
                  .file('/project/.agent-resource/conversions/$id.json')
                  .readAsStringSync(),
            );
            const conflictId = 'cvx_ffffffffffffffffffffffffffffffff';
            final conflict = ConversionEvidence(
              transactionId: conflictId,
              operation: evidence.operation,
              phase: evidence.phase,
              createdScope: evidence.createdScope,
              source: evidence.source,
              target: evidence.target,
              approvals: evidence.approvals,
              observations: evidence.observations,
            );
            fs
                .file('/project/.agent-resource/conversions/$conflictId.json')
                .writeAsStringSync(conflict.encode());
            fs
                .file('/state/conversion-participants/$conflictId.json')
                .writeAsStringSync(conflict.initialIntent.encode());
            final before = snapshot();
            await expectLater(
              coordinator().resume(options: options, transactionId: id),
              throwsA(
                isA<MambaException>().having(
                  (error) => error.exitCode,
                  'status',
                  6,
                ),
              ),
            );
            expect(snapshot(), before);
          });
          for (final changed in [
            'source',
            'target',
            'payload',
            'participant',
          ]) {
            test(
              'refuses changed $changed without altering evidence or native content',
              () async {
                seed();
                await interrupt('write', '/commit.json');
                final path = switch (changed) {
                  'source' => request.source.location,
                  'target' => request.target.location,
                  'payload' =>
                    '/project/.agent-resource/conversions/$id/source-payload/source.md',
                  _ => '/state/conversion-participants/$id.json',
                };
                fs.file(path).writeAsStringSync('later edit');
                final before = snapshot();
                final result = await invoke('recover');
                expect(
                  result,
                  isA<MambaFailureResult>().having(
                    (value) => value.message,
                    'diagnostic',
                    isNotEmpty,
                  ),
                );
                expect(snapshot(), before);
                expect(fs.file(path).readAsStringSync(), 'later edit');
              },
            );
          }
          test(
            'rejects stale approval when ledger observations change',
            () async {
              seed();
              await interrupt('write', '/commit.json');
              final plan = success(await invoke('recover'), 'planned');
              final ledger = fs.file(
                '/project/.agent-resource/installations.json',
              );
              final content =
                  jsonDecode(ledger.readAsStringSync()) as Map<String, dynamic>;
              content['reviewNote'] = 'changed after review';
              ledger.writeAsStringSync(jsonEncode(content));
              failure(
                await invoke(
                  'recover',
                  extra: [
                    '--apply',
                    '--yes',
                    '--plan-id',
                    plan['planId'] as String,
                  ],
                ),
                'exact fresh --plan-id',
                'recover',
                code: 4,
              );
              expect(
                fs.file(request.source.location).readAsStringSync(),
                'original body',
              );
              expect(
                jsonDecode(ledger.readAsStringSync())['reviewNote'],
                'changed after review',
              );
            },
          );
          test(
            'refuses a missing participant and a missing committed decision',
            () async {
              seed();
              await interrupt('write', '/commit.json');
              final marker = fs.file('/state/conversion-participants/$id.json');
              final markerBytes = marker.readAsBytesSync();
              marker.deleteSync();
              failure(
                await invoke('recover'),
                'participant authority is missing',
                'recover',
              );
              marker.writeAsBytesSync(markerBytes);
              // A committed phase contradicts the now missing decision.
              final evidenceFile = fs.file(
                '/project/.agent-resource/conversions/$id.json',
              );
              final evidence = ConversionEvidence.decode(
                evidenceFile.readAsStringSync(),
              );
              evidenceFile.writeAsStringSync(
                evidence.withPhase(ConversionEvidencePhase.committed).encode(),
              );
              fs
                  .file('/project/.agent-resource/conversions/$id/commit.json')
                  .deleteSync();
              failure(
                await invoke('recover'),
                'committed conversion decision is missing',
                'recover',
              );
            },
          );
          for (final managed in [false, true]) {
            test(
              'same-form edit recovery preserves ${managed ? 'managed identity' : 'untracked receipt ownership'}',
              () async {
                seed(inPlace: true, managed: managed);
                await interrupt('write', '/commit.json');
                final plan = success(await invoke('recover'), 'planned');
                success(
                  await invoke(
                    'recover',
                    extra: [
                      '--apply',
                      '--yes',
                      '--plan-id',
                      plan['planId'] as String,
                    ],
                  ),
                  'recovered',
                );
                expect(
                  fs.file(request.target.location).readAsStringSync(),
                  'converted body',
                );
                final records = coordinator().state.records(
                  LifecycleContext.resolve(options, fileSystem: fs),
                );
                if (managed) {
                  expect(records.single.installationId, installationId);
                  expect(records.single.lifecycle, 'live');
                } else {
                  expect(records, isEmpty);
                  expect(
                    fs
                        .file('/project/.agent-resource/installations.json')
                        .existsSync(),
                    isFalse,
                  );
                }
              },
            );
          }
          for (final shape in [
            'file',
            'directory',
            'in-place',
            'directory-target',
          ]) {
            for (final crossScope in [false, true]) {
              if (shape == 'in-place' && crossScope) continue;
              for (final boundary in [
                'intent',
                'publication',
                'commit',
                'ledger',
                'removal',
                'cleanup',
              ]) {
                test(
                  '$shape ${crossScope ? 'cross' : 'same'} scope restarts after $boundary',
                  () async {
                    seed(
                      inPlace: shape == 'in-place',
                      directory: shape == 'directory',
                      directoryTarget: shape == 'directory-target',
                      userTarget: crossScope,
                    );
                    final draft =
                        fs.file(
                            '/project/.agent-resource-authoring/unrelated/draft.md',
                          )
                          ..createSync(recursive: true)
                          ..writeAsStringSync('unrelated authoring draft');
                    final stateRoot = crossScope
                        ? '/state'
                        : '/project/.agent-resource';
                    final operation =
                        boundary == 'removal' || boundary == 'cleanup'
                        ? 'delete'
                        : boundary == 'ledger'
                        ? 'rename'
                        : 'write';
                    final suffix = switch (boundary) {
                      'intent' => '/conversions/$id.json',
                      'publication' => request.target.location,
                      'commit' => '/commit.json',
                      'ledger' => '$stateRoot/installations.json',
                      'removal' =>
                        shape == 'in-place'
                            ? '/quarantine'
                            : request.source.location,
                      _ => '$id/target',
                    };
                    // Directory publication writes its member rather than the directory entry.
                    await interrupt(
                      operation,
                      boundary == 'publication' && shape == 'directory-target'
                          ? '${request.target.location}/SKILL.md'
                          : suffix,
                    );
                    final before = snapshot();
                    final plan = success(await invoke('recover'), 'planned');
                    expect(
                      snapshot(),
                      before,
                      reason: 'Planning must not write or remove any file.',
                    );
                    final rollback =
                        boundary == 'intent' || boundary == 'publication';
                    expect(plan['action'], rollback ? 'rollback' : 'complete');
                    failure(
                      await invoke(
                        'recover',
                        extra: [
                          '--apply',
                          '--plan-id',
                          plan['planId'] as String,
                        ],
                      ),
                      'explicit approval',
                      'recover',
                      code: 4,
                    );
                    final result = success(
                      await invoke(
                        'recover',
                        extra: [
                          '--apply',
                          '--yes',
                          '--plan-id',
                          plan['planId'] as String,
                        ],
                      ),
                      'recovered',
                    );
                    expect(
                      result['phase'],
                      rollback ? 'rolledBack' : 'completed',
                    );
                    expect(result['originalOperationSucceeded'], !rollback);
                    final sourceFile = shape == 'directory'
                        ? '${request.source.location}/SKILL.md'
                        : request.source.location;
                    final targetFile = shape == 'directory-target'
                        ? '${request.target.location}/SKILL.md'
                        : request.target.location;
                    if (rollback) {
                      expect(
                        fs.file(sourceFile).readAsStringSync(),
                        'original body',
                      );
                      if (shape != 'in-place') {
                        expect(
                          fs.typeSync(request.target.location),
                          FileSystemEntityType.notFound,
                        );
                      }
                    } else {
                      expect(
                        fs.file(targetFile).readAsStringSync(),
                        'converted body',
                      );
                      if (shape != 'in-place') {
                        expect(
                          fs.typeSync(request.source.location),
                          FileSystemEntityType.notFound,
                        );
                      }
                      final retained = shape == 'directory'
                          ? '$stateRoot/conversions/$id/source-payload/SKILL.md'
                          : '$stateRoot/conversions/$id/source-payload/source.md';
                      expect(
                        fs.file(retained).readAsStringSync(),
                        'original body',
                      );
                    }
                    final projectContext = LifecycleContext.resolve(
                      options.copyWith(scope: LifecycleScope.project),
                      fileSystem: fs,
                    );
                    final sourceRecord = coordinator().state.recordById(
                      projectContext,
                      installationId,
                    );
                    expect(
                      sourceRecord.lifecycle,
                      rollback || shape == 'in-place' ? 'live' : 'removed',
                    );
                    if (!rollback && shape != 'in-place') {
                      final records = coordinator().state.records(
                        LifecycleContext.resolve(options, fileSystem: fs),
                      );
                      final targetRecord = records.singleWhere(
                        (record) => record.lifecycle == 'live',
                      );
                      expect(
                        targetRecord.installationId,
                        isNot(installationId),
                      );
                      expect(
                        targetRecord.origin['convertedFromInstallationId'],
                        installationId,
                      );
                    }
                    failure(
                      await invoke(
                        'recover',
                        extra: [
                          '--apply',
                          '--yes',
                          '--plan-id',
                          plan['planId'] as String,
                        ],
                      ),
                      'already terminal',
                      'recover',
                      code: 4,
                    );
                    expect(
                      draft.readAsStringSync(),
                      'unrelated authoring draft',
                    );
                  },
                );
              }
            }
          }
        });
        group('inspect', () {
          test('returns a stable read-only plan and never exposes instruction bytes', () async {
            seed();
            await interrupt('write', '/commit.json');
            final before = snapshot();
            final first = success(await invoke('inspect'), 'reviewed');
            final second = success(await invoke('inspect'), 'reviewed');
            expect(first['planId'], second['planId']);
            expect(first['action'], 'complete');
            expect(jsonEncode(first), isNot(contains('original body')));
            expect(jsonEncode(first), isNot(contains('converted body')));
            expect(snapshot(), before);
          });
          test('rejects substituted payload paths even with a recomputed document digest', () async {
            seed();
            await interrupt('write', '/project/prompts/target.md');
            final document = fs.file(
              '/project/.agent-resource/conversions/$id.json',
            );
            final evidence = ConversionEvidence.decode(
              document.readAsStringSync(),
            );
            fs.file('/project/input.md').writeAsStringSync('original body');
            final source = ConversionParticipant.fromJson({
              ...evidence.source.toJson(),
              'payload': {
                ...evidence.source.payload!.toJson(),
                'path': '/project/input.md',
              },
            });
            document.writeAsStringSync(
              evidence.copyWith(source: source).encode(),
            );
            failure(
              await invoke('inspect'),
              'paths were substituted',
              'inspect',
            );
            expect(
              fs.file('/project/input.md').readAsStringSync(),
              'original body',
            );
          });
        });
        group('cleanup', () {
          for (final directory in [false, true]) {
            for (final rollback in [false, true]) {
              test(
                'resumes partial ${directory ? 'directory' : 'file'} cleanup after ${rollback ? 'rollback' : 'completion'}',
                () async {
                  seed(directory: directory);
                  final payloadRoot =
                      '/project/.agent-resource/conversions/$id/source-payload';
                  io.beforeDelete = (path) {
                    if (path == payloadRoot) {
                      fs
                          .file(
                            '$payloadRoot/${directory ? 'SKILL.md' : 'source.md'}',
                          )
                          .deleteSync();
                      throw StateError('Interrupted inside recursive deletion');
                    }
                  };
                  if (rollback) {
                    await interrupt('write', '/project/prompts/target.md');
                    final plan = success(await invoke('recover'), 'planned');
                    await expectLater(
                      coordinator(interrupted: true).recoverReviewed(
                        options.copyWith(approved: true),
                        id,
                        planId: plan['planId'] as String,
                      ),
                      throwsStateError,
                    );
                  } else {
                    await coordinator().execute(request);
                    final plan = success(await invoke('cleanup'), 'planned');
                    await expectLater(
                      coordinator(interrupted: true).cleanupReviewed(
                        options.copyWith(approved: true),
                        id,
                        planId: plan['planId'] as String,
                      ),
                      throwsStateError,
                    );
                  }
                  io.beforeDelete = null;
                  final before = snapshot();
                  expect(
                    success(
                      await invoke('inspect'),
                      'reviewed',
                    )['cleanupStatus'],
                    'pending',
                  );
                  final fresh = success(await invoke('cleanup'), 'planned');
                  expect(snapshot(), before);
                  if (directory) {
                    final survivor = fs.file(
                      '$payloadRoot/references/notes.txt',
                    );
                    survivor.writeAsStringSync('changed survivor');
                    failure(
                      await invoke('cleanup'),
                      'payload is missing or changed',
                      'cleanup',
                    );
                    expect(survivor.readAsStringSync(), 'changed survivor');
                    survivor.writeAsStringSync('owned member');
                    final extra = fs.file('$payloadRoot/unknown.txt')
                      ..writeAsStringSync('not authorized');
                    failure(
                      await invoke('cleanup'),
                      'payload is missing or changed',
                      'cleanup',
                    );
                    expect(extra.existsSync(), isTrue);
                    extra.deleteSync();
                  }
                  success(
                    await invoke(
                      'cleanup',
                      extra: [
                        '--apply',
                        '--yes',
                        '--plan-id',
                        fresh['planId'] as String,
                      ],
                    ),
                    'cleaned',
                  );
                  expect(fs.directory(payloadRoot).existsSync(), isFalse);
                  expect(
                    success(
                      await invoke('inspect'),
                      'reviewed',
                    )['cleanupStatus'],
                    'cleaned',
                  );
                  final live = rollback
                      ? (directory
                            ? '${request.source.location}/SKILL.md'
                            : request.source.location)
                      : request.target.location;
                  expect(
                    fs.file(live).readAsStringSync(),
                    rollback ? 'original body' : 'converted body',
                  );
                },
              );
            }
          }
          test(
            'resumes an interrupted cleanup only after another fresh review',
            () async {
              seed();
              await coordinator().execute(request);
              final plan = success(await invoke('cleanup'), 'planned');
              io.after = (operation, path) {
                if (operation == 'write' && path.endsWith('/cleanup.json')) {
                  throw StateError('Interrupted cleanup');
                }
              };
              await expectLater(
                coordinator(interrupted: true).cleanupReviewed(
                  options.copyWith(approved: true),
                  id,
                  planId: plan['planId'] as String,
                ),
                throwsStateError,
              );
              io.after = null;
              expect(
                success(await invoke('inspect'), 'reviewed')['cleanupStatus'],
                'pending',
              );
              failure(
                await invoke(
                  'cleanup',
                  extra: [
                    '--apply',
                    '--yes',
                    '--plan-id',
                    plan['planId'] as String,
                  ],
                ),
                'exact fresh --plan-id',
                'cleanup',
                code: 4,
              );
              final fresh = success(await invoke('cleanup'), 'planned');
              success(
                await invoke(
                  'cleanup',
                  extra: [
                    '--apply',
                    '--yes',
                    '--plan-id',
                    fresh['planId'] as String,
                  ],
                ),
                'cleaned',
              );
            },
          );
          test('retains unfinished evidence and user input files', () async {
            seed();
            await interrupt('write', '/commit.json');
            fs
                .file('/project/instructions.txt')
                .writeAsStringSync('user input');
            final before = snapshot();
            failure(
              await invoke('cleanup'),
              'Unfinished conversion evidence',
              'cleanup',
            );
            expect(snapshot(), before);
          });
          test('requires fresh approval, cleans only intact terminal payloads, and refuses replay', () async {
            seed(directory: true);
            await coordinator().execute(request);
            fs
                .file('/project/instructions.txt')
                .writeAsStringSync('user input');
            final draft =
                fs.file('/project/.agent-resource-authoring/unrelated/draft.md')
                  ..createSync(recursive: true)
                  ..writeAsStringSync('unrelated authoring draft');
            final before = snapshot();
            final plan = success(await invoke('cleanup'), 'planned');
            expect(snapshot(), before);
            expect(plan['forfeitsPayloadRestore'], isTrue);
            failure(
              await invoke(
                'cleanup',
                extra: ['--apply', '--yes', '--plan-id', 'stale'],
              ),
              'exact fresh --plan-id',
              'cleanup',
              code: 4,
            );
            success(
              await invoke(
                'cleanup',
                extra: [
                  '--apply',
                  '--yes',
                  '--plan-id',
                  plan['planId'] as String,
                ],
              ),
              'cleaned',
            );
            expect(
              fs
                  .directory(
                    '/project/.agent-resource/conversions/$id/source-payload',
                  )
                  .existsSync(),
              isFalse,
            );
            expect(
              fs
                  .file('/project/.agent-resource/conversions/$id.json')
                  .existsSync(),
              isTrue,
            );
            expect(
              fs.file(request.target.location).readAsStringSync(),
              'converted body',
            );
            expect(
              fs.file('/project/instructions.txt').readAsStringSync(),
              'user input',
            );
            expect(draft.readAsStringSync(), 'unrelated authoring draft');
            expect(
              success(await invoke('inspect'), 'reviewed')['cleanupStatus'],
              'cleaned',
            );
            failure(
              await invoke('cleanup'),
              'already cleaned',
              'cleanup',
              code: 4,
            );
          });
          test('refuses corrupt payloads and unknown private files instead of deleting them', () async {
            seed();
            await coordinator().execute(request);
            final payload = fs.file(
              '/project/.agent-resource/conversions/$id/source-payload/source.md',
            );
            payload.writeAsStringSync('edited backup');
            failure(
              await invoke('cleanup'),
              'payload is missing or changed',
              'cleanup',
            );
            expect(payload.readAsStringSync(), 'edited backup');
            payload.writeAsStringSync('original body');
            final unknown = fs.file(
              '/project/.agent-resource/conversions/$id/keep.txt',
            )..writeAsStringSync('not ours');
            failure(
              await invoke('cleanup'),
              'Unknown private conversion entry',
              'cleanup',
            );
            expect(unknown.readAsStringSync(), 'not ours');
          });
        });
        group('list', () {
          test('reports orphan participant authority and corrupt coordinators without writes', () async {
            seed();
            await interrupt('write', '/conversion-participants/$id.json');
            final before = snapshot();
            options = options.copyWith(scope: LifecycleScope.user);
            final listed = success(await invoke('list'), 'listed');
            expect(
              (listed['transactions'] as List).single['status'],
              'participant-reference',
            );
            expect(snapshot(), before);
            options = options.copyWith(scope: LifecycleScope.project);
            fs.file('/project/.agent-resource/conversions/$id.json')
              ..createSync(recursive: true)
              ..writeAsStringSync('{corrupt');
            final unresolved = success(await invoke('list'), 'listed');
            expect(
              (unresolved['transactions'] as List).single['status'],
              'unresolved',
            );
            failure(await invoke('recover'), 'not usable', 'recover', code: 3);
          });
          test('reports an empty inventory without creating state', () async {
            final fs = MemoryFileSystem();
            fs.directory('/project').createSync();
            fs.directory('/home').createSync();
            fs.currentDirectory = '/project';
            final result = await createExecutor(fileSystem: fs).fake().execute([
              'prompt',
              'conversion',
              'list',
              '--format',
              'json',
              '--home',
              '/home/',
              '--state-dir',
              '/state/',
              '--project-root',
              '/project/',
            ]);
            if (result is MambaFailureResult) fail(result.message);
            expect(
              result,
              isA<MambaSuccessResult>().having(
                (value) => value.exitCode,
                'exit code',
                0,
              ),
            );
            final output =
                jsonDecode((result as MambaSuccessResult).output!) as Map;
            expect(output['outcome'], 'listed');
            expect((output['data'] as Map)['transactions'], isEmpty);
            expect(
              fs.directory('/project/.agent-resource').existsSync(),
              isFalse,
            );
            expect(fs.directory('/state').existsSync(), isFalse);
          });
        });
        for (final action in [
          'list',
          'inspect',
          'recover',
          'restore',
          'cleanup',
        ]) {
          group(action, () {
            test('registered help is read-only and rejects undeclared direction overrides', () async {
              seed();
              final before = snapshot();
              final help = await invoke(
                action,
                selectedId: false,
                extra: ['--help'],
              );
              expect(
                help,
                isA<MambaSuccessResult>()
                    .having((value) => value.exitCode, 'exit code', 0)
                    .having(
                      (value) => value.output,
                      'help',
                      contains('Offline transaction evidence'),
                    ),
              );
              final rejected = await invoke(
                action,
                extra: ['--action', 'rollback'],
              );
              expect(
                rejected,
                isA<MambaFailureResult>()
                    .having((value) => value.exitCode, 'exit code', 1)
                    .having(
                      (value) => value.message,
                      'message',
                      contains('--action'),
                    )
                    .having((value) => value.output, 'output', isNull)
                    .having(
                      (value) => value.error.phase,
                      'phase',
                      MambaExecutionPhase.parse,
                    )
                    .having((value) => value.error.commandPath, 'path', [
                      'agent_resource',
                      'prompt',
                      'conversion',
                      action,
                    ]),
              );
              expect(snapshot(), before);
            });
          });
        }
      });
    });
    for (final resource in ['agent', 'skill']) {
      group(resource, () {
        group('recover', () {
          test('recovers an untracked edit receipt without adopting it and refuses a direction override', () async {
            seed(
              inPlace: true,
              managed: false,
              directory: resource == 'skill',
              directoryTarget: resource == 'skill',
            );
            await interrupt('write', '/commit.json');
            Future<MambaExecutionResult> recover(List<String> extra) =>
                createExecutor(
                  fileSystem: fs,
                  agentLifecycle: AgentLifecycleService(fileSystem: fs),
                  skillLifecycle: SkillLifecycleService(fileSystem: fs),
                ).fake().execute([
                  resource,
                  'recover',
                  id,
                  '--scope',
                  'project',
                  '--home',
                  '/home/',
                  '--state-dir',
                  '/state/',
                  '--project-root',
                  '/project/',
                  '--format',
                  'json',
                  ...extra,
                ]);
            final plan = success(await recover([]), 'planned');
            final refused = await recover([
              '--action',
              'rollback',
              '--yes',
              '--plan-id',
              plan['planId'] as String,
            ]);
            expect(
              refused,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'status', 4)
                  .having(
                    (value) => value.message,
                    'message',
                    contains('direction is fixed'),
                  ),
            );
            success(
              await recover([
                '--action',
                'complete',
                '--yes',
                '--plan-id',
                plan['planId'] as String,
              ]),
              'recovered',
            );
            final output = resource == 'skill'
                ? '${request.target.location}/SKILL.md'
                : request.target.location;
            expect(fs.file(output).readAsStringSync(), 'converted body');
            expect(
              coordinator().state.records(
                LifecycleContext.resolve(options, fileSystem: fs),
              ),
              isEmpty,
            );
          });
        });
      });
    }
  });
}
