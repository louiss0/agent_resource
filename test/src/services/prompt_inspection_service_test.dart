import 'dart:io' show FileSystemException;

import 'package:agent_resource/src/services/prompt_inspection_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late PromptInspectionService service;
  setUp(() {
    fs = MemoryFileSystem();
    fs.directory('/work/demo').createSync(recursive: true);
    service = PromptInspectionService(fs: fs);
  });
  void skill(String front, [String body = 'Instructions']) {
    fs
        .file('/work/demo/SKILL.md')
        .writeAsStringSync(
          '---\nname: demo\ndescription: Test\n$front\n---\n$body',
        );
  }

  void sidecar(String contents) {
    fs.file('/work/demo/agents/openai.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  Future<PromptInspection> inspect({
    PromptConsumer? consumer,
    PromptPlacement placement = PromptPlacement.unknown,
  }) => service.inspect(
    '/work/demo',
    form: PromptForm.skill,
    consumer: consumer,
    placement: placement,
  );

  test(
    'independent views and selection; global compatibility is not placement',
    () async {
      skill('disable-model-invocation: true');
      final result = await inspect(placement: PromptPlacement.user);
      expect(result.selectedView, isNull);
      expect(
        result.views[PromptConsumer.claude]!.classification,
        PromptClassification.prompt,
      );
      expect(
        result.views[PromptConsumer.codex]!.classification,
        PromptClassification.nonPrompt,
      );
      expect(
        result.views[PromptConsumer.pi]!.classification,
        PromptClassification.prompt,
      );
      expect(result.globalCompatibility, PromptCompatibility.incompatible);
      expect(result.placement, PromptPlacement.user);
      sidecar('policy:\n  allow_implicit_invocation: false\n');
      final all = await inspect(consumer: PromptConsumer.codex);
      expect(all.selectedView, all.views[PromptConsumer.codex]);
      expect(all.globalCompatibility, PromptCompatibility.compatible);
      expect(all.placement, PromptPlacement.unknown);
      expect(() => all.views.clear(), throwsUnsupportedError);
      expect(
        () => (all.sidecarFields['policy'] as Map).clear(),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'mixed controls do not impose Prompt layout on ordinary Skills',
    () async {
      skill('disable-model-invocation: true', 'See references/guide.md');
      fs.directory('/work/demo/references').createSync();
      final result = await inspect(consumer: PromptConsumer.codex);
      expect(
        result.selectedView!.classification,
        PromptClassification.nonPrompt,
      );
      expect(result.selectedView!.valid, isTrue);
      expect(result.selectedView!.diagnostics, isEmpty);
      expect(result.views[PromptConsumer.claude]!.valid, isFalse);
      expect(
        result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
        containsAll(['EXTRA_ENTRY', 'RESOURCE_REFERENCE']),
      );
    },
  );
  test(
    'malformed controls are unknown but known true survives unrelated errors',
    () async {
      skill('disable-model-invocation: nope');
      sidecar('policy:\n  allow_implicit_invocation: false');
      var result = await inspect();
      expect(
        result.views[PromptConsumer.claude]!.classification,
        PromptClassification.malformed,
      );
      expect(
        result.views[PromptConsumer.codex]!.classification,
        PromptClassification.prompt,
      );
      skill('disable-model-invocation: true');
      sidecar('policy: [broken');
      result = await inspect();
      expect(
        result.views[PromptConsumer.claude]!.classification,
        PromptClassification.prompt,
      );
      expect(result.views[PromptConsumer.claude]!.valid, isFalse);
      expect(
        result.views[PromptConsumer.codex]!.classification,
        PromptClassification.malformed,
      );
      sidecar('policy: {}');
      result = await inspect();
      expect(
        result.views[PromptConsumer.codex]!.classification,
        PromptClassification.nonPrompt,
      );
    },
  );
  test('native checks apply to ordinary skills too', () async {
    fs
        .file('/work/demo/SKILL.md')
        .writeAsStringSync('---\nname: WRONG\ndescription: ""\n---\nHello');
    final result = await inspect();
    expect(
      result.views[PromptConsumer.codex]!.classification,
      PromptClassification.nonPrompt,
    );
    expect(result.views[PromptConsumer.codex]!.valid, isFalse);
  });
  test('Pi skill appends arguments; template expands them', () async {
    skill('disable-model-invocation: true', r'$1 $ARGUMENTS !`echo x`');
    final result = await inspect();
    expect(result.views[PromptConsumer.pi]!.valid, isTrue);
    expect(result.views[PromptConsumer.pi]!.argumentsAppended, isTrue);
    expect(result.views[PromptConsumer.pi]!.argumentExpressions, isEmpty);
    expect(result.views[PromptConsumer.claude]!.argumentExpressions, [
      r'$1',
      r'$ARGUMENTS',
    ]);
    expect(result.views[PromptConsumer.claude]!.dynamicShell, isTrue);
    expect(result.views[PromptConsumer.codex]!.dynamicShell, isFalse);
    fs.file('/work/t.md').writeAsStringSync(r'$1 $@ ${1:-default}');
    final template = await service.inspect(
      '/work/t.md',
      form: PromptForm.template,
      consumer: PromptConsumer.pi,
    );
    expect(template.selectedView!.valid, isTrue);
    expect(
      template.selectedView!.argumentExpressions,
      containsAll([r'$1', r'$@', r'${1:-default}']),
    );
    expect(template.selectedView!.argumentsAppended, isFalse);
  });
  test('YAML budgets and links remain bounded', () async {
    skill('disable-model-invocation: true\nmetadata: &a [*a]');
    var result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
      contains('YAML_ALIAS'),
    );
    fs.link('/linked').createSync('/work');
    await expectLater(
      service.inspect('/linked/demo', form: PromptForm.skill),
      throwsA(isA<MambaException>()),
    );
    skill('disable-model-invocation: true');
    for (var i = 0; i < 1024; i++) {
      fs.file('/work/demo/extra$i').createSync();
    }
    await expectLater(inspect(), throwsA(isA<MambaException>()));
  });
  test('source byte limit and body scanner positions', () async {
    skill(
      'disable-model-invocation: true',
      'See [x](references/a) and `scripts\\run`\nhttps://x/assets/a',
    );
    final result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.diagnostics
          .where((d) => d.code == 'RESOURCE_REFERENCE')
          .map((d) => (d.line, d.column)),
      [(6, 9), (6, 28), (7, 11)],
    );
    fs.file('/work/t.md').writeAsBytesSync(List.filled(1048577, 65));
    final large = await service.inspect(
      '/work/t.md',
      form: PromptForm.template,
      consumer: PromptConsumer.pi,
    );
    expect(
      large.selectedView!.diagnostics.map((d) => d.code),
      contains('FILE_SIZE_LIMIT'),
    );
  });
  test('angle paths and whole segments, scalar YAML and immutable metadata', () async {
    skill(
      'disable-model-invocation: true\nmetadata:\n  note: "${'[' * 40} *word"',
      '[details](<references/checklist.md>) my.scripts/run ?assets/file ./scripts/run x/references/file',
    );
    final result = await inspect();
    final view = result.views[PromptConsumer.claude]!;
    expect(
      view.diagnostics
          .where((d) => d.code == 'RESOURCE_REFERENCE')
          .map((d) => (d.line, d.column)),
      [(8, 12), (8, 68), (8, 82)],
    );
    expect(view.diagnostics.map((d) => d.code), isNot(contains('YAML_BUDGET')));
    expect(
      () => (result.fields['metadata'] as Map)['note'] = 'changed',
      throwsUnsupportedError,
    );
  });
  test('block scalars are not interpreted as YAML syntax', () async {
    fs
        .file('/work/demo/SKILL.md')
        .writeAsStringSync(
          '---\nname: demo\ndescription: |\n  ${'[' * 40} *word\ndisable-model-invocation: true\n---\nhello',
        );
    final result = await inspect();
    expect(result.views[PromptConsumer.claude]!.valid, isTrue);
  });
  test('depth and node preflight budgets reject oversized YAML', () async {
    skill("disable-model-invocation: true\nmetadata: ${'[' * 40}a${']' * 40}");
    var result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
      contains('YAML_BUDGET'),
    );
    skill(
      'disable-model-invocation: true\nmetadata: [${List.filled(4100, 'a').join(',')}]',
    );
    result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
      contains('YAML_BUDGET'),
    );
  });
  test('UTF8 and frontmatter size failures remain diagnostics', () async {
    fs.file('/work/demo/SKILL.md').writeAsBytesSync([255]);
    var result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.classification,
      PromptClassification.malformed,
    );
    expect(
      result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
      contains('UTF8_INVALID'),
    );
    skill('disable-model-invocation: true\n# ${'a' * 65536}');
    result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
      contains('YAML_SIZE_LIMIT'),
    );
  });
  test('exact byte boundary is accepted and overflow rejected', () async {
    final file = fs.file('/work/limit.md');
    file.writeAsBytesSync(List.filled(1048576, 65));
    var result = await service.inspect(
      file.path,
      form: PromptForm.template,
      consumer: PromptConsumer.pi,
    );
    expect(result.selectedView!.valid, isTrue);
    file.writeAsBytesSync(List.filled(1048577, 65));
    result = await service.inspect(
      file.path,
      form: PromptForm.template,
      consumer: PromptConsumer.pi,
    );
    expect(
      result.selectedView!.diagnostics.map((d) => d.code),
      contains('FILE_SIZE_LIMIT'),
    );
  });
  test('missing marker and source absence confirmation are bounded', () async {
    for (var i = 0; i < 1025; i++) {
      fs.file('/work/demo/extra$i').createSync();
    }
    for (final source in ['/work/demo', '/work/demo/missing']) {
      await expectLater(
        service.inspect(source, form: PromptForm.skill),
        throwsA(
          isA<MambaException>().having(
            (e) => e.message,
            'message',
            contains('1024-entry'),
          ),
        ),
      );
    }
  });
  test('marker and sidecar links never read their targets', () async {
    fs.file('/work/outside').writeAsStringSync('secret');
    fs.link('/work/demo/SKILL.md').createSync('/work/outside');
    var result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.classification,
      PromptClassification.malformed,
    );
    expect(result.fields, isEmpty);
    fs.link('/work/demo/SKILL.md').deleteSync();
    skill('disable-model-invocation: true');
    fs.directory('/work/demo/agents').createSync();
    fs.link('/work/demo/agents/openai.yaml').createSync('/work/outside');
    result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.classification,
      PromptClassification.prompt,
    );
    expect(result.views[PromptConsumer.claude]!.valid, isFalse);
    expect(
      result.views[PromptConsumer.codex]!.classification,
      PromptClassification.malformed,
    );
    expect(result.sidecarFields, isEmpty);
  });
  test('CRLF locations and Unicode-prefixed nonsegments', () async {
    fs
        .file('/work/demo/SKILL.md')
        .writeAsStringSync(
          '---\r\nname: demo\r\ndescription: Test\r\ndisable-model-invocation: true\r\n---\r\néassets/file pscripts/run\r\n./assets/file\r\n',
        );
    final result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.diagnostics
          .where((d) => d.code == 'RESOURCE_REFERENCE')
          .map((d) => (d.line, d.column)),
      [(7, 3)],
    );
  });
  test('Claude tool and context shapes are checked', () async {
    for (final value in ['Read, Write', '[Read, Write]']) {
      skill(
        'disable-model-invocation: true\ndisallowed-tools: $value\ncontext: fork',
      );
      expect((await inspect()).views[PromptConsumer.claude]!.valid, isTrue);
    }
    skill(
      'disable-model-invocation: true\ndisallowed-tools: [Read, 3]\ncontext: other\nuser-invocable: false\nhooks: false',
    );
    final result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
      containsAll([
        'FIELD_TYPE',
        'FIELD_VALUE',
        'UNSUPPORTED_FIELD',
        'USER_INVOCATION_DISABLED',
      ]),
    );
  });
  test('source contents are unchanged by inspection', () async {
    skill('disable-model-invocation: true');
    sidecar('policy:\n  allow_implicit_invocation: false');
    final before = {
      for (final entry
          in fs.directory('/').listSync(recursive: true, followLinks: false))
        entry.path: entry.statSync().size,
    };
    final marker = fs.file('/work/demo/SKILL.md').readAsBytesSync();
    final side = fs.file('/work/demo/agents/openai.yaml').readAsBytesSync();
    await inspect();
    expect({
      for (final entry
          in fs.directory('/').listSync(recursive: true, followLinks: false))
        entry.path: entry.statSync().size,
    }, before);
    expect(fs.file('/work/demo/SKILL.md').readAsBytesSync(), marker);
    expect(fs.file('/work/demo/agents/openai.yaml').readAsBytesSync(), side);
  });
  test('uncertain sidecar and agents link never default to ordinary', () async {
    skill('');
    sidecar('interface: wrong');
    var result = await inspect();
    expect(
      result.views[PromptConsumer.codex]!.classification,
      PromptClassification.malformed,
    );
    sidecar('interface: wrong\npolicy:\n  allow_implicit_invocation: false');
    result = await inspect();
    expect(
      result.views[PromptConsumer.codex]!.classification,
      PromptClassification.prompt,
    );
    expect(result.views[PromptConsumer.codex]!.valid, isFalse);
    fs.directory('/work/demo/agents').deleteSync(recursive: true);
    fs.link('/work/demo/agents').createSync('/work');
    result = await inspect();
    expect(
      result.views[PromptConsumer.codex]!.classification,
      PromptClassification.malformed,
    );
  });
  test('template requires selected consumer as explicit context', () async {
    fs.file('/work/t.md').writeAsStringSync('Hello');
    final noTarget = await service.inspect(
      '/work/t.md',
      form: PromptForm.template,
    );
    expect(noTarget.selectedView, isNull);
    expect(
      noTarget.views[PromptConsumer.pi]!.classification,
      PromptClassification.unclassified,
    );
    expect(noTarget.views[PromptConsumer.pi]!.valid, isFalse);
    final selected = await service.inspect(
      '/work/t.md',
      form: PromptForm.template,
      consumer: PromptConsumer.pi,
    );
    expect(selected.selectedView!.valid, isTrue);
  });
  test(
    'common marker constraints and profile-specific tools are checked',
    () async {
      skill('compatibility: ""\nallowed-tools: [Read]');
      var result = await inspect();
      expect(result.views[PromptConsumer.codex]!.valid, isFalse);
      expect(
        result.views[PromptConsumer.codex]!.diagnostics.map((d) => d.code),
        containsAll(['COMPATIBILITY_LENGTH', 'FIELD_TYPE']),
      );
      expect(
        result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
        isNot(contains('FIELD_TYPE')),
      );
      skill('compatibility: ${'a' * 501}');
      result = await inspect();
      expect(
        result.views[PromptConsumer.pi]!.diagnostics.map((d) => d.code),
        contains('COMPATIBILITY_LENGTH'),
      );
    },
  );
  test(
    'sidecar extra entries and invalid policy are diagnosed per view',
    () async {
      skill('disable-model-invocation: true');
      sidecar('policy:\n  allow_implicit_invocation: nope');
      fs.file('/work/demo/agents/other').createSync();
      final result = await inspect();
      expect(
        result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
        containsAll(['SIDECAR_TYPE', 'EXTRA_ENTRY']),
      );
      expect(
        result.views[PromptConsumer.codex]!.classification,
        PromptClassification.malformed,
      );
    },
  );
  test('valid control with unrelated invalid fields stays prompt', () async {
    skill(
      'disable-model-invocation: true\nunknown: value\nmetadata: 42\narguments: {x: 1}',
    );
    final result = await inspect();
    expect(
      result.views[PromptConsumer.claude]!.classification,
      PromptClassification.prompt,
    );
    expect(
      result.views[PromptConsumer.claude]!.diagnostics.map((d) => d.code),
      containsAll(['UNKNOWN_FIELD', 'FIELD_TYPE']),
    );
  });
  test(
    'Claude named expressions and agent paths are observed without execution',
    () async {
      skill(
        'disable-model-invocation: true\narguments: [task]\nallowed-tools: [Read, Write]',
        r'Read agents/openai.yaml $task $1 $@ ${1:-default}',
      );
      final result = await inspect();
      expect(result.views[PromptConsumer.claude]!.valid, isTrue);
      expect(result.views[PromptConsumer.claude]!.argumentExpressions, [
        r'$1',
        r'$task',
      ]);
      expect(result.views[PromptConsumer.codex]!.argumentExpressions, isEmpty);
    },
  );
  test(
    'invalid dependency identity cannot qualify as a validated sidecar',
    () async {
      skill('disable-model-invocation: true');
      final invalidTools = [
        '{}',
        '{description: Missing identity}',
        '{type: mcp}',
        '{value: github}',
        '{type: "", value: github}',
        '{type: mcp, value: "   "}',
        '{type: "${'a' * 65}", value: github}',
        '{type: mcp, value: "${'a' * 1025}"}',
      ];
      for (final tool in invalidTools) {
        for (final policy in [
          '',
          'policy:\n  allow_implicit_invocation: false\n',
        ]) {
          sidecar('${policy}dependencies:\n  tools:\n    - $tool\n');
          final result = await inspect();
          final codex = result.views[PromptConsumer.codex]!;
          expect(
            codex.classification,
            policy.isEmpty
                ? PromptClassification.malformed
                : PromptClassification.prompt,
            reason: tool,
          );
          for (final consumer in PromptConsumer.inspectable) {
            final view = result.views[consumer]!;
            expect(view.valid, isFalse, reason: '$consumer: $tool');
            expect(
              view.diagnostics.map((d) => d.code),
              contains('SIDECAR_FIELD'),
              reason: '$consumer: $tool',
            );
          }
          expect(
            result.globalCompatibility,
            isNot(PromptCompatibility.compatible),
          );
        }
      }
      sidecar(
        'policy:\n  allow_implicit_invocation: false\ndependencies:\n  tools:\n    - type: mcp\n      value: github\n',
      );
      final valid = await inspect();
      expect(valid.globalCompatibility, PromptCompatibility.compatible);
    },
  );
  test('missing source is an operational error', () async {
    await expectLater(
      service.inspect('/work/missing', form: PromptForm.skill),
      throwsA(isA<MambaException>()),
    );
  });
  test(
    'unsupported template context cannot imply a Pi source profile',
    () async {
      fs.file('/work/t.md').writeAsStringSync('Hello');
      for (final consumer in [PromptConsumer.claude, PromptConsumer.codex]) {
        final result = await service.inspect(
          '/work/t.md',
          form: PromptForm.template,
          consumer: consumer,
        );
        expect(
          result.selectedView!.classification,
          PromptClassification.unclassified,
        );
        expect(result.selectedView!.valid, isFalse);
        expect(
          result.views[PromptConsumer.pi]!.classification,
          PromptClassification.unclassified,
        );
        expect(result.views[PromptConsumer.pi]!.valid, isFalse);
      }
    },
  );
  test(
    'agents references are exempt and global requires both controls',
    () async {
      skill('disable-model-invocation: true', 'Read agents/openai.yaml');
      final result = await inspect();
      expect(result.views[PromptConsumer.claude]!.valid, isTrue);
      expect(result.globalCompatibility, PromptCompatibility.incompatible);
    },
  );
  test(
    'sidecar open failure is operational and inspection does not mutate',
    () async {
      var active = false;
      final operations = <FileSystemOp>[];
      final guarded = MemoryFileSystem(
        opHandle: (context, op) {
          if (!active) return;
          operations.add(op);
          if (context == '/work/demo/agents/openai.yaml' &&
              op == FileSystemOp.open) {
            throw FileSystemException('injected read failure', context);
          }
        },
      );
      guarded.directory('/work/demo/agents').createSync(recursive: true);
      guarded
          .file('/work/demo/SKILL.md')
          .writeAsStringSync(
            '---\nname: demo\ndescription: Test\ndisable-model-invocation: true\n---\nbody',
          );
      guarded
          .file('/work/demo/agents/openai.yaml')
          .writeAsStringSync('policy: {}');
      active = true;
      await expectLater(
        PromptInspectionService(fs: guarded)
            .inspect('/work/demo', form: PromptForm.skill),
        throwsA(isA<MambaException>()),
      );
      expect(operations, contains(FileSystemOp.open));
      expect(
        operations.where(
          (op) =>
              op == FileSystemOp.create ||
              op == FileSystemOp.delete ||
              op == FileSystemOp.write ||
              op == FileSystemOp.copy,
        ),
        isEmpty,
      );
    },
  );
}
