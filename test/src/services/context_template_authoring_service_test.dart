import 'package:agent_resource/src/context/context_authoring_plan.dart';
import 'package:agent_resource/src/services/context_template_authoring_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('ContextTemplateAuthoringService', () {
    late MemoryFileSystem fs;
    late ContextTemplateAuthoringService service;
    late LifecycleOptions options;

    final planIdPattern = RegExp(r'^pln_[a-f0-9]{64}$');

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      for (final directory in [
        '/sandbox/project',
        '/sandbox/home',
        '/sandbox/state',
      ]) {
        fs.directory(directory).createSync(recursive: true);
      }
      service = ContextTemplateAuthoringService(
        fileSystem: fs,
        terminal: () => false,
      );
      options = LifecycleOptions(
        processWorkingDirectory: '/sandbox/project',
        environment: const <String, String>{},
        scope: LifecycleScope.user,
        cwd: '/sandbox/project',
        home: '/sandbox/home',
        stateDir: '/sandbox/state',
      );
    });

    ContextAuthoringRequest request({
      required bool create,
      String name = 'alpha',
      String? bodyText,
      bool empty = false,
      String? planId,
      bool apply = false,
    }) => ContextAuthoringRequest(
      command: create ? 'context create' : 'context edit',
      create: create,
      positionalName: name,
      optionName: null,
      interactive: false,
      unattended: true,
      empty: empty,
      bodyFile: null,
      bodyStdin: false,
      bodyText: bodyText,
      standardInput: null,
      editorChoice: null,
      planId: planId,
      apply: apply,
      yes: true,
      dryRun: false,
      showInstructions: false,
      options: options,
    );

    test('binds create plan identity to operation, name and body', () async {
      final first = await service.run(request(create: true, bodyText: 'one'));
      final repeated = await service.run(
        request(create: true, bodyText: 'one'),
      );
      final changed = await service.run(request(create: true, bodyText: 'two'));
      final renamed = await service.run(
        request(create: true, bodyText: 'one', name: 'beta'),
      );

      final firstId = first.data['planId'] as String;
      expect(firstId, matches(planIdPattern));
      expect(repeated.data['planId'], equals(firstId));
      expect(changed.data['planId'], isNot(firstId));
      expect(renamed.data['planId'], isNot(firstId));
      expect(
        first.data['sha256'],
        equals(
          '7692c3ad3540bb803c020b3aee66cd8887123234ea0c6e7143c0add73ff431ed',
        ),
      );
      expect(ContextAuthoringPlan.isPlanId(firstId), isTrue);
      expect(ContextAuthoringPlan.isPlanId('authoring-plan-$firstId'), isFalse);
    });

    test('binds edit plan identity to the observed template bytes', () async {
      final template = fs.file('/sandbox/state/context-templates/alpha.md')
        ..parent.createSync(recursive: true);
      template.writeAsStringSync('before\n');

      final first = await service.run(
        request(create: false, bodyText: 'after\n'),
      );
      expect(first.data['planId'], matches(planIdPattern));
      expect(first.data['existingSha256'], isA<String>());

      template.writeAsStringSync('raced\n');
      final raced = await service.run(
        request(create: false, bodyText: 'after\n'),
      );
      expect(raced.data['planId'], isNot(first.data['planId']));
    });
  });
}
