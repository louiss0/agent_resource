import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/services/bound_role_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/parent_config_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _FailRegistrationApply implements ParentConfigService {
  final ParentConfigService _delegate = ParentConfigService();

  @override
  Future<ParentResult> plan({
    required ParentRequest request,
    required LifecycleOptions options,
  }) => _delegate.plan(request: request, options: options);

  @override
  String restorePlanId(LifecycleOptions options, String backupId) =>
      _delegate.restorePlanId(options, backupId);

  @override
  Future<ParentResult> restore({
    required LifecycleOptions options,
    required String backupId,
    required String planId,
    required bool clientsStopped,
  }) => _delegate.restore(
    options: options,
    backupId: backupId,
    planId: planId,
    clientsStopped: clientsStopped,
  );

  @override
  Future<ParentResult> apply({
    required ParentRequest request,
    required LifecycleOptions options,
  }) => throw MambaException('Injected registration failure.');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('BoundRoleService', () {
    test(
      'create plans by default and publishes definition plus registration',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('bound-create-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
          final config = File(p.join(project.path, '.codex', 'config.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# keep\n');
          final source = File(p.join(sandbox.path, 'reviewer.toml'))
            ..writeAsStringSync(
              'name = "reviewer"\ndescription = "Reviews changes."\n'
              'developer_instructions = "Review."\n',
            );
          final service = BoundRoleService();
          LifecycleOptions options({
            bool approved = false,
            bool dryRun = false,
          }) => LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            codexHome: codex.path,
            approved: approved,
            dryRun: dryRun,
          );
          final request = BoundRoleRequest(
            operation: BoundOperation.create,
            configFile: p.join(project.path, '.codex', 'config.toml'),
            roleKey: 'reviewer',
            ownership: BoundOwnership.both,
            source: source.path,
            output: p.join(project.path, '.codex', 'agents', 'reviewer.toml'),
            clientsStopped: true,
          );
          final planned = await service.run(request, options(dryRun: true));
          expect(planned.outcome, 'planned');
          expect(
            File(p.join(project.path, '.codex', 'agents', 'reviewer.toml'))
                .existsSync(),
            isFalse,
          );
          expect(config.readAsStringSync(), '# keep\n');
          final planId = planned.data['planId']! as String;
          final applied = await service.run(
            BoundRoleRequest(
              operation: BoundOperation.create,
              configFile: request.configFile,
              roleKey: request.roleKey,
              ownership: request.ownership,
              source: request.source,
              output: request.output,
              planId: planId,
              clientsStopped: true,
            ),
            options(approved: true),
          );
          expect(applied.outcome, 'created');
          final installed = File(
            p.join(project.path, '.codex', 'agents', 'reviewer.toml'),
          );
          expect(installed.existsSync(), isTrue);
          final text = config.readAsStringSync();
          expect(text, contains('# keep'));
          expect(text, contains('[agents.reviewer]'));
          expect(text, contains('config_file ='));
          expect(text, contains('reviewer.toml'));
          expect(text, contains('description = "Reviews changes."'));
          expect(applied.data['registrationCommitted'], isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test('request parsing rejects operation/source ambiguity', () async {
      final sandbox = await Directory.systemTemp.createTemp('bound-request-');
      try {
        final request = File(p.join(sandbox.path, 'request.json'))
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': 'create',
              'source': <String, Object?>{
                'kind': 'codex-role',
                'configFile': '.codex/config.toml',
                'roleKey': 'reviewer',
              },
              'ownership': 'both',
              'definition': <String, Object?>{'source': 'reviewer.toml'},
              'unexpected': true,
            }),
          );
        expect(
          () => parseBoundRoleRequest(request.path, sandbox.path),
          throwsA(isA<MambaException>()),
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });
    test('registration failure removes a newly created definition', () async {
      final sandbox = await Directory.systemTemp.createTemp('bound-recovery-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
        final config = File(p.join(project.path, '.codex', 'config.toml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('# preserve\n');
        final source = File(p.join(sandbox.path, 'reviewer.toml'))
          ..writeAsStringSync(
            'name = "reviewer"\ndescription = "Reviews."\n'
            'developer_instructions = "Review."\n',
          );
        final service = BoundRoleService(parent: _FailRegistrationApply());
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          codexHome: codex.path,
          approved: true,
        );
        final request = BoundRoleRequest(
          operation: BoundOperation.create,
          configFile: config.path,
          roleKey: 'reviewer',
          ownership: BoundOwnership.both,
          source: source.path,
          clientsStopped: true,
        );
        final planned = await service.run(request, options);
        final apply = BoundRoleRequest(
          operation: request.operation,
          configFile: request.configFile,
          roleKey: request.roleKey,
          ownership: request.ownership,
          source: request.source,
          planId: planned.data['planId']! as String,
          clientsStopped: true,
        );
        await expectLater(
          service.run(apply, options),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'status',
              5,
            ),
          ),
        );
        expect(
          File(p.join(project.path, '.codex', 'agents', 'reviewer.toml'))
              .existsSync(),
          isFalse,
        );
        expect(config.readAsStringSync(), '# preserve\n');
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'definition-only creation needs no stopped-client acknowledgement',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'bound-definition-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
          final config = File(p.join(project.path, '.codex', 'config.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# unchanged\n');
          final source = File(p.join(sandbox.path, 'reviewer.toml'))
            ..writeAsStringSync(
              'name = "reviewer"\ndescription = "Reviews."\n'
              'developer_instructions = "Review."\n',
            );
          final service = BoundRoleService();
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            codexHome: codex.path,
            approved: true,
          );
          final planned = await service.run(
            BoundRoleRequest(
              operation: BoundOperation.create,
              configFile: config.path,
              roleKey: 'reviewer',
              ownership: BoundOwnership.definition,
              source: source.path,
            ),
            options,
          );
          final created = await service.run(
            BoundRoleRequest(
              operation: BoundOperation.create,
              configFile: config.path,
              roleKey: 'reviewer',
              ownership: BoundOwnership.definition,
              source: source.path,
              planId: planned.data['planId']! as String,
            ),
            options,
          );
          expect(created.outcome, 'created');
          expect(config.readAsStringSync(), '# unchanged\n');
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test('referenced definitions adopt inside the approved boundary', () async {
      final sandbox = await Directory.systemTemp.createTemp('bound-adopt-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
        final definition =
            File(p.join(project.path, '.codex', 'roles', 'reviewer.toml'))
              ..createSync(recursive: true)
              ..writeAsStringSync(
                'name = "reviewer"\ndescription = "Reviews."\n'
                'developer_instructions = "Review."\n',
              );
        final original = definition.readAsBytesSync();
        final config = File(p.join(project.path, '.codex', 'config.toml'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '[agents.reviewer]\n'
            'description = "Reviews."\n'
            'config_file = "roles/reviewer.toml"\n',
          );
        final service = BoundRoleService();
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          codexHome: codex.path,
          approved: true,
        );
        final planned = await service.run(
          BoundRoleRequest(
            operation: BoundOperation.adopt,
            configFile: config.path,
            roleKey: 'reviewer',
            ownership: BoundOwnership.both,
            clientsStopped: true,
          ),
          options,
        );
        final adopted = await service.run(
          BoundRoleRequest(
            operation: BoundOperation.adopt,
            configFile: config.path,
            roleKey: 'reviewer',
            ownership: BoundOwnership.both,
            planId: planned.data['planId']! as String,
            clientsStopped: true,
          ),
          options,
        );
        expect(adopted.outcome, 'adopted');
        expect(definition.readAsBytesSync(), original);
        final records = service.agent.state.records(
          LifecycleContext.resolve(options),
        );
        expect(records.single.nativeDestination, 'codex-bound');
        expect(records.single.location, definition.path);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test('builtin name conflicts stop before publication', () async {
      final sandbox = await Directory.systemTemp.createTemp('bound-builtin-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
        final config = File(p.join(project.path, '.codex', 'config.toml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('# unchanged\n');
        final source = File(p.join(sandbox.path, 'default.toml'))
          ..writeAsStringSync(
            'name = "default"\ndescription = "Built in."\n'
            'developer_instructions = "Default."\n',
          );
        final service = BoundRoleService();
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          codexHome: codex.path,
        );
        await expectLater(
          service.run(
            BoundRoleRequest(
              operation: BoundOperation.create,
              configFile: config.path,
              roleKey: 'default',
              ownership: BoundOwnership.both,
              source: source.path,
              clientsStopped: true,
            ),
            options,
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 4)
                .having(
                  (error) => error.message,
                  'message',
                  contains('builtin'),
                ),
          ),
        );
        expect(config.readAsStringSync(), '# unchanged\n');
        expect(
          File(p.join(project.path, '.codex', 'agents', 'default.toml'))
              .existsSync(),
          isFalse,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test('source bytes are bound to the reviewed plan', () async {
      final sandbox = await Directory.systemTemp.createTemp('bound-drift-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
        final config = File(p.join(project.path, '.codex', 'config.toml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('# unchanged\n');
        final source = File(p.join(sandbox.path, 'reviewer.toml'))
          ..writeAsStringSync(
            'name = "reviewer"\ndescription = "Reviews."\n'
            'developer_instructions = "Original."\n',
          );
        final service = BoundRoleService();
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          scope: LifecycleScope.project,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          codexHome: codex.path,
          approved: true,
        );
        final request = BoundRoleRequest(
          operation: BoundOperation.create,
          configFile: config.path,
          roleKey: 'reviewer',
          ownership: BoundOwnership.both,
          source: source.path,
          clientsStopped: true,
        );
        final planned = await service.run(request, options);
        source.writeAsStringSync(
          'name = "reviewer"\ndescription = "Reviews."\n'
          'developer_instructions = "Changed after review."\n',
        );
        await expectLater(
          service.run(
            BoundRoleRequest(
              operation: request.operation,
              configFile: request.configFile,
              roleKey: request.roleKey,
              ownership: request.ownership,
              source: request.source,
              planId: planned.data['planId']! as String,
              clientsStopped: true,
            ),
            options,
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 4)
                .having(
                  (error) => error.message,
                  'message',
                  contains('plan ID'),
                ),
          ),
        );
        expect(config.readAsStringSync(), '# unchanged\n');
        expect(
          File(p.join(project.path, '.codex', 'agents', 'reviewer.toml'))
              .existsSync(),
          isFalse,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'user-scope registration uses the actual Codex-home location',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('bound-user-');
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
          final config = File(p.join(codex.path, 'config.toml'))
            ..writeAsStringSync('# user\n');
          final source = File(p.join(sandbox.path, 'reviewer.toml'))
            ..writeAsStringSync(
              'name = "reviewer"\ndescription = "Reviews."\n'
              'developer_instructions = "Review."\n',
            );
          final service = BoundRoleService();
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            scope: LifecycleScope.user,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            codexHome: codex.path,
            stateDir: p.join(sandbox.path, 'state'),
            approved: true,
          );
          final request = BoundRoleRequest(
            operation: BoundOperation.create,
            configFile: config.path,
            roleKey: 'reviewer',
            ownership: BoundOwnership.both,
            source: source.path,
            clientsStopped: true,
          );
          final planned = await service.run(request, options);
          final created = await service.run(
            BoundRoleRequest(
              operation: request.operation,
              configFile: request.configFile,
              roleKey: request.roleKey,
              ownership: request.ownership,
              source: request.source,
              planId: planned.data['planId']! as String,
              clientsStopped: true,
            ),
            options,
          );
          expect(created.outcome, 'created');
          final installed = File(p.join(codex.path, 'agents', 'reviewer.toml'));
          expect(installed.existsSync(), isTrue);
          final separator = Platform.isWindows ? r'\\' : '/';
          expect(
            config.readAsStringSync(),
            contains('config_file = "agents${separator}reviewer.toml"'),
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'relative definition sources digest against the selected cwd',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'bound-relative-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final codex = Directory(p.join(sandbox.path, 'codex'))..createSync();
          final config = File(p.join(project.path, '.codex', 'config.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync('# relative\n');
          final source = File(p.join(project.path, 'reviewer.toml'))
            ..writeAsStringSync(
              'name = "reviewer"\ndescription = "Reviews."\n'
              'developer_instructions = "Review."\n',
            );
          final service = BoundRoleService();
          final options = LifecycleOptions(
            processWorkingDirectory: sandbox.path,
            scope: LifecycleScope.project,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
            codexHome: codex.path,
          );
          final request = BoundRoleRequest(
            operation: BoundOperation.create,
            configFile: config.path,
            roleKey: 'reviewer',
            ownership: BoundOwnership.definition,
            source: 'reviewer.toml',
          );
          final planned = await service.run(request, options);
          expect(planned.outcome, 'planned');
          expect(source.existsSync(), isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
