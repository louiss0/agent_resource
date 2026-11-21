import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/services/authoring_plan_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late AuthoringPlanService service;
  late LifecycleOptions options;

  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/work/project').createSync(recursive: true);
    fs.directory('/home/user').createSync(recursive: true);
    options = LifecycleOptions(
      processWorkingDirectory: '/work/project',
      environment: const <String, String>{},
      scope: LifecycleScope.project,
      cwd: '/work/project',
      projectRoot: '/work/project',
      home: '/home/user',
      stateDir: '/work/state',
    );
    service = AuthoringPlanService(fileSystem: fs);
  });

  void skill(
    String directory, {
    String frontmatter = '',
    String body = 'Instructions',
  }) {
    fs.file('$directory/SKILL.md').createSync(recursive: true);
    fs
        .file('$directory/SKILL.md')
        .writeAsStringSync(
          '---\nname: demo\ndescription: Test\n$frontmatter\n---\n$body',
        );
  }

  AuthoringInputs createInputs({
    AuthoringKind kind = AuthoringKind.skill,
    AuthoringProfile profile = AuthoringProfile.claude,
    String body = 'Instructions',
    Map<String, Object?> fields = const <String, Object?>{
      'name': 'demo',
      'description': 'Demo resource',
    },
    bool manage = false,
    String? output,
  }) => parseAuthoringInputs(
    operation: AuthoringOperation.create,
    kind: kind,
    profile: profile,
    bodyText: body,
    fields: fields,
    manage: manage,
    output: output,
  );

  List<String> codes(AuthoringPlan plan) => plan.diagnostics
      .map((diagnostic) => diagnostic['code']! as String)
      .toList();

  test('a new skill plan is author-only and writes nothing', () async {
    final plan = await service.plan(createInputs(), options);
    expect(plan.ready, isTrue);
    expect(plan.ownership, AuthoringOwnership.authorOnly);
    expect(plan.output, '/work/project/.claude/skills/demo/SKILL.md');
    expect(plan.candidate, contains('name: "demo"'));
    expect(plan.candidate, contains('description: "Demo resource"'));
    expect(plan.data['writes'], isFalse);
    expect(fs.directory('/work/project/.claude').existsSync(), isFalse);
  });

  test('a skill-backed prompt declares the manual only control', () async {
    final plan = await service.plan(
      createInputs(kind: AuthoringKind.prompt),
      options,
    );
    expect(plan.ready, isTrue);
    expect(plan.candidate, contains('disable-model-invocation: true'));
    expect(plan.output, '/work/project/.claude/skills/demo/SKILL.md');
  });

  test('a codex prompt declares the sidecar policy', () async {
    final plan = await service.plan(
      createInputs(kind: AuthoringKind.prompt, profile: AuthoringProfile.codex),
      options,
    );
    expect(plan.ready, isTrue);
    expect(plan.sidecar, contains('allow_implicit_invocation: false'));
    expect(
      plan.data['target'],
      containsPair(
        'sidecar',
        '/work/project/.codex/skills/demo/agents/openai.yaml',
      ),
    );
  });

  test('a global prompt declares both manual only controls', () async {
    final plan = await service.plan(
      createInputs(
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.global,
      ),
      options,
    );
    expect(plan.ready, isTrue);
    expect(plan.candidate, contains('disable-model-invocation: true'));
    expect(plan.sidecar, contains('allow_implicit_invocation: false'));
    expect(plan.output, '/work/project/.agents/skills/demo/SKILL.md');
  });

  test('a pi prompt is a native template without the skill fields', () async {
    final plan = await service.plan(
      createInputs(
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        fields: const <String, Object?>{
          'name': 'review',
          'description': 'Review staged changes',
        },
      ),
      options,
    );
    expect(plan.ready, isTrue);
    expect(plan.output, '/work/project/.pi/prompts/review.md');
    expect(plan.candidate, isNot(contains('name:')));
    expect(plan.candidate, contains('description: "Review staged changes"'));
  });

  test('managed publication is refused for prompts', () async {
    final plan = await service.plan(
      createInputs(kind: AuthoringKind.prompt, manage: true),
      options,
    );
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('MANAGEMENT_UNSUPPORTED'));
    expect(plan.ownership, AuthoringOwnership.authorOnly);
  });

  test('managed publication requires the eligible native location', () async {
    final supported = await service.plan(createInputs(manage: true), options);
    expect(supported.ready, isTrue);
    expect(supported.ownership, AuthoringOwnership.managedRequested);

    final outside = await service.plan(
      createInputs(manage: true, output: '/work/project/source/demo.md'),
      options,
    );
    expect(outside.ready, isFalse);
    expect(codes(outside), contains('MANAGEMENT_TARGET_UNSUPPORTED'));
  });

  test('an occupied target is never taken over', () async {
    skill('/work/project/.claude/skills/demo');
    final plan = await service.plan(createInputs(), options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('TARGET_OCCUPIED'));
  });

  test('an unmanaged edit keeps the source unmanaged and in place', () async {
    skill('/work/project/source/demo');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.edit,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
      fields: const <String, Object?>{'description': 'Updated description'},
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isTrue);
    expect(plan.ownership, AuthoringOwnership.authorOnly);
    expect(plan.output, '/work/project/source/demo/SKILL.md');
    expect(plan.candidate, contains('description: "Updated description"'));
    expect(plan.candidate, contains('name: "demo"'));
  });

  test('a clone preserves the source body and fields', () async {
    skill(
      '/work/project/source/demo',
      body: 'Original body',
      frontmatter: 'license: MIT',
    );
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.clone,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isTrue);
    expect(plan.candidate, contains('Original body'));
    expect(plan.candidate, contains('license: "MIT"'));
    expect(plan.output, '/work/project/.claude/skills/demo/SKILL.md');
  });

  test('compose appends, replaces or retains the base body', () async {
    skill('/work/project/source/demo', body: 'Base body');
    AuthoringInputs compose(CompositionMode mode, String? body) =>
        parseAuthoringInputs(
          operation: AuthoringOperation.compose,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          sourcePath: '/work/project/source/demo',
          composition: mode,
          bodyText: body,
        );
    final appended = await service.plan(
      compose(CompositionMode.append, 'New body'),
      options,
    );
    expect(appended.candidate, contains('Base body\nNew body'));
    final replaced = await service.plan(
      compose(CompositionMode.replace, 'New body'),
      options,
    );
    expect(replaced.candidate, contains('New body'));
    expect(replaced.candidate, isNot(contains('Base body')));
    final retained = await service.plan(
      compose(CompositionMode.retain, null),
      options,
    );
    expect(retained.candidate, contains('Base body'));
  });

  test('a skill to prompt conversion reclassifies in place', () async {
    skill('/work/project/source/demo');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.convert,
      kind: AuthoringKind.prompt,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
      conversion: ConversionDirection.skillToPrompt,
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isTrue);
    expect(plan.data['conversionTargetForm'], 'skillBacked');
    expect(plan.output, '/work/project/source/demo/SKILL.md');
    expect(plan.candidate, contains('disable-model-invocation: true'));
  });

  test('a skill to prompt conversion refuses bundled resources', () async {
    skill('/work/project/source/demo');
    fs
        .file('/work/project/source/demo/reference.md')
        .createSync(recursive: true);
    fs
        .file('/work/project/source/demo/reference.md')
        .writeAsStringSync('extra');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.convert,
      kind: AuthoringKind.prompt,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
      conversion: ConversionDirection.skillToPrompt,
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('CONVERSION_SOURCE_SHAPE'));
  });

  test('a skill to prompt conversion refuses blocked resource paths', () async {
    skill(
      '/work/project/source/demo',
      body: 'Read references/guide.md for details.',
    );
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.convert,
      kind: AuthoringKind.prompt,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
      conversion: ConversionDirection.skillToPrompt,
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('CONVERSION_RESOURCE_REFERENCE'));
  });

  test(
    'a prompt to agent conversion refuses active template arguments',
    () async {
      skill(
        '/work/project/source/demo',
        frontmatter: 'disable-model-invocation: true',
        body: 'Review \$1 carefully.',
      );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.agent,
        profile: AuthoringProfile.claude,
        sourcePath: '/work/project/source/demo',
        conversion: ConversionDirection.promptToAgent,
        fields: const <String, Object?>{'name': 'reviewer'},
      );
      final plan = await service.plan(inputs, options);
      expect(plan.ready, isFalse);
      expect(codes(plan), contains('ACTIVE_TEMPLATE_REFUSED'));
    },
  );

  test('a prompt to agent conversion discloses the role change', () async {
    skill(
      '/work/project/source/demo',
      frontmatter: 'disable-model-invocation: true',
      body: 'Review the staged changes.',
    );
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.convert,
      kind: AuthoringKind.agent,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
      conversion: ConversionDirection.promptToAgent,
      fields: const <String, Object?>{'name': 'reviewer'},
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isTrue);
    expect(
      plan.data['roleDelegation'],
      containsPair('instructionsBecomeRole', true),
    );
    expect(
      plan.data['roleDelegation'],
      containsPair('manualInvocationBecomesDelegation', true),
    );
    expect(plan.output, '/work/project/.claude/agents/reviewer.md');
  });

  test('a body file preserves multiline bytes', () async {
    fs.file('/work/project/body.md').createSync(recursive: true);
    fs
        .file('/work/project/body.md')
        .writeAsStringSync('First line\n\n  indented\n');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.create,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      bodyFile: '/work/project/body.md',
      fields: const <String, Object?>{'name': 'demo'},
    );
    final plan = await service.plan(inputs, options);
    expect(plan.candidate, endsWith('First line\n\n  indented\n'));
  });

  test('an unattended plan never waits for standard input', () async {
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.create,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      bodyStandardInput: true,
      fields: const <String, Object?>{'name': 'demo'},
    );
    expect(
      () => service.plan(inputs, options),
      throwsA(
        isA<MambaException>().having(
          (error) => error.message,
          'message',
          contains('Standard input was not supplied'),
        ),
      ),
    );
  });

  test('the plan identity is stable and changes with the proposal', () async {
    final first = await service.plan(createInputs(), options);
    final second = await service.plan(createInputs(), options);
    expect(second.planId, first.planId);
    final changed = await service.plan(
      createInputs(
        fields: const <String, Object?>{
          'name': 'demo',
          'description': 'Another description',
        },
      ),
      options,
    );
    expect(changed.planId, isNot(first.planId));
  });

  test('a missing required field blocks the plan', () async {
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.create,
      kind: AuthoringKind.agent,
      profile: AuthoringProfile.pi,
      bodyText: 'Instructions',
      fields: const <String, Object?>{'name': 'reviewer'},
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('FIELD_REQUIRED'));
  });

  test(
    'a native agent proposal is validated by the native inspector',
    () async {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.agent,
        profile: AuthoringProfile.claude,
        bodyText: 'Instructions',
        fields: const <String, Object?>{
          'name': 'reviewer',
          'description': 'Reviews changes',
        },
      );
      final plan = await service.plan(inputs, options);
      expect(plan.output, '/work/project/.claude/agents/reviewer.md');
      expect(plan.candidate, contains('name: "reviewer"'));
      expect(plan.data['candidate'], containsPair('byteLength', isA<int>()));
      expect(fs.directory('/work/project/.claude').existsSync(), isFalse);
    },
  );

  test('a supplied list replaces the whole native field', () async {
    skill(
      '/work/project/source/demo',
      frontmatter: 'allowed-tools: Read, Write',
    );
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.edit,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
      fields: const <String, Object?>{
        'allowed-tools': <String>['Read'],
      },
    );
    final plan = await service.plan(inputs, options);
    expect(plan.candidate, contains('allowed-tools: "Read"'));
    expect(plan.candidate, isNot(contains('Write')));
    expect(
      plan.data['fieldIntents'],
      containsPair('allowed-tools', 'supplied'),
    );
  });

  test('an explicit clear removes the native field', () async {
    skill(
      '/work/project/source/demo',
      frontmatter: 'allowed-tools: Read, Write',
    );
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.edit,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
      fields: const <String, Object?>{'allowed-tools': ClearedFieldValue()},
    );
    final plan = await service.plan(inputs, options);
    expect(plan.candidate, isNot(contains('allowed-tools')));
    expect(plan.data['fieldIntents'], containsPair('allowed-tools', 'cleared'));
  });

  test('an unresolved reference change requires a deliberate choice', () async {
    skill('/work/project/.claude/skills/alpha');
    skill('/work/project/.claude/skills/beta');
    fs.file('/work/project/source/agent.md').createSync(recursive: true);
    fs
        .file('/work/project/source/agent.md')
        .writeAsStringSync(
          '---\nname: reviewer\ndescription: Reviews changes\nskills:\n  - alpha\n---\nInstructions',
        );
    AuthoringInputs conversion(Set<String> decisions) => parseAuthoringInputs(
      operation: AuthoringOperation.convert,
      kind: AuthoringKind.agent,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/agent.md',
      conversion: ConversionDirection.agentToAgent,
      fields: const <String, Object?>{
        'skills': <String>['beta'],
      },
      decisions: decisions,
    );
    final unresolved = await service.plan(
      conversion(const <String>{}),
      options,
    );
    expect(unresolved.ready, isFalse);
    expect(codes(unresolved), contains('REFERENCE_DECISION_REQUIRED'));
    final resolved = await service.plan(
      conversion(const <String>{
        'reference:skill:alpha:remove',
        'reference:skill:beta:add',
      }),
      options,
    );
    expect(resolved.ready, isTrue);
    expect(resolved.candidate, contains('skills: ["beta"]'));
  });

  test(
    'a source declaration the profile cannot represent blocks the plan',
    () async {
      skill('/work/project/source/demo', frontmatter: 'disallowed-tools: Bash');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.codex,
        sourcePath: '/work/project/source/demo',
      );
      final plan = await service.plan(inputs, options);
      expect(plan.ready, isFalse);
      expect(codes(plan), contains('SOURCE_FIELD_UNSUPPORTED'));
    },
  );

  test(
    'a validated source declaration without a named input is preserved',
    () async {
      skill('/work/project/source/demo', frontmatter: 'user-invocable: true');
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        sourcePath: '/work/project/source/demo',
      );
      final plan = await service.plan(inputs, options);
      expect(plan.ready, isTrue);
      expect(plan.candidate, contains('user-invocable: true'));
    },
  );

  test(
    'a pi template source converts to an agent with an explicit name',
    () async {
      fs.file('/work/project/source/review.md').createSync(recursive: true);
      fs
          .file('/work/project/source/review.md')
          .writeAsStringSync(
            '---\ndescription: Review staged changes\nargument-hint: "[focus]"\n---\nReview the staged changes.',
          );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.agent,
        profile: AuthoringProfile.claude,
        sourcePath: '/work/project/source/review.md',
        conversion: ConversionDirection.promptToAgent,
        fields: const <String, Object?>{
          'name': 'reviewer',
          'description': 'Reviews staged changes',
        },
      );
      final plan = await service.plan(inputs, options);
      expect(plan.ready, isTrue);
      expect(plan.output, '/work/project/.claude/agents/reviewer.md');
    },
  );

  test('a pi template with active arguments is refused', () async {
    fs.file('/work/project/source/review.md').createSync(recursive: true);
    fs
        .file('/work/project/source/review.md')
        .writeAsStringSync(
          '---\ndescription: Review staged changes\n---\nReview \${1:-correctness}.',
        );
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.convert,
      kind: AuthoringKind.agent,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/review.md',
      conversion: ConversionDirection.promptToAgent,
      fields: const <String, Object?>{
        'name': 'reviewer',
        'description': 'Reviews staged changes',
      },
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('ACTIVE_TEMPLATE_REFUSED'));
  });

  test('a clone never takes over the source it copies', () async {
    skill('/work/project/.claude/skills/demo');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.clone,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/.claude/skills/demo',
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('TARGET_OCCUPIED'));
  });

  test('a missing name reports the required field without a target', () async {
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.create,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      bodyText: 'Instructions',
      fields: const <String, Object?>{'description': 'Demo resource'},
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('FIELD_REQUIRED'));
    expect(plan.output, isNull);
  });

  test('a pi conversion records that the source must be removed', () async {
    skill('/work/project/source/demo');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.convert,
      kind: AuthoringKind.prompt,
      profile: AuthoringProfile.pi,
      sourcePath: '/work/project/source/demo',
      conversion: ConversionDirection.skillToPrompt,
      fields: const <String, Object?>{
        'name': 'demo',
        'description': 'Demo resource',
      },
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isTrue);
    expect(plan.data['sourceRemovalRequired'], isTrue);
    expect(plan.data['conversionTargetForm'], 'template');
    expect(plan.output, '/work/project/.pi/prompts/demo.md');
  });

  test('a scope that disagrees with the lifecycle scope is refused', () async {
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.create,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      scope: LifecycleScope.user,
      bodyText: 'Instructions',
      fields: const <String, Object?>{'name': 'demo'},
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('SCOPE_MISMATCH'));
  });

  test('a skill to prompt edit dispatches the conversion', () async {
    skill('/work/project/source/demo');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.edit,
      kind: AuthoringKind.prompt,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isTrue);
    expect(plan.output, '/work/project/source/demo/SKILL.md');
    expect(plan.candidate, contains('disable-model-invocation: true'));
  });

  test('a prompt to skill edit is refused', () async {
    skill(
      '/work/project/source/demo',
      frontmatter: 'disable-model-invocation: true',
    );
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.edit,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('PROMPT_TO_SKILL_UNSUPPORTED'));
  });

  test('an unresolved native graph blocks an agent proposal', () async {
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.create,
      kind: AuthoringKind.agent,
      profile: AuthoringProfile.claude,
      bodyText: 'Instructions',
      fields: const <String, Object?>{
        'name': 'reviewer',
        'description': 'Reviews changes',
        'skills': <String>['missing-skill'],
      },
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('GRAPH_NOT_READY'));
  });

  test('the source profile is explicit for an agent source', () async {
    skill('/work/project/.claude/skills/alpha');
    fs.file('/work/project/source/agent.md').createSync(recursive: true);
    fs
        .file('/work/project/source/agent.md')
        .writeAsStringSync(
          '---\nname: reviewer\ndescription: Reviews changes\nskills:\n  - alpha\n---\nInstructions',
        );
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.convert,
      kind: AuthoringKind.agent,
      profile: AuthoringProfile.codex,
      sourcePath: '/work/project/source/agent.md',
      sourceProfile: AuthoringProfile.claude,
      conversion: ConversionDirection.agentToAgent,
    );
    final plan = await service.plan(inputs, options);
    expect(plan.data['source'], containsPair('profile', 'claude'));
  });

  test(
    'a codex prompt keeps the validated source sidecar declarations',
    () async {
      skill('/work/project/source/demo');
      fs
          .file('/work/project/source/demo/agents/openai.yaml')
          .createSync(recursive: true);
      fs
          .file('/work/project/source/demo/agents/openai.yaml')
          .writeAsStringSync(
            'interface:\n  display_name: Demo\npolicy:\n  allow_implicit_invocation: false\n',
          );
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.edit,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.codex,
        sourcePath: '/work/project/source/demo',
      );
      final plan = await service.plan(inputs, options);
      expect(plan.sidecar, contains('display_name'));
      expect(plan.sidecar, contains('allow_implicit_invocation: false'));
    },
  );

  test('a name that disagrees with the target directory is refused', () async {
    skill('/work/project/source/demo');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.edit,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
      fields: const <String, Object?>{'name': 'other'},
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('NAME_MISMATCH'));
  });

  test('empty instructions are refused', () async {
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.create,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      bodyText: '   ',
      fields: const <String, Object?>{'name': 'demo'},
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
    expect(codes(plan), contains('INSTRUCTIONS_REQUIRED'));
  });

  test('a source that the target profile cannot read is refused', () async {
    skill('/work/project/source/demo', frontmatter: 'hooks: {}');
    final inputs = parseAuthoringInputs(
      operation: AuthoringOperation.edit,
      kind: AuthoringKind.skill,
      profile: AuthoringProfile.claude,
      sourcePath: '/work/project/source/demo',
    );
    final plan = await service.plan(inputs, options);
    expect(plan.ready, isFalse);
  });

  test('planning creates no draft, staging or journal entry', () async {
    await service.plan(createInputs(), options);
    expect(fs.directory('/work/state').existsSync(), isFalse);
    expect(fs.directory('/work/project/.agent-resource').existsSync(), isFalse);
    expect(
      fs.directory('/work/project/.agent-resource-authoring').existsSync(),
      isFalse,
    );
  });
}
