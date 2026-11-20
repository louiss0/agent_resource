import 'package:agent_resource/src/authoring/native_field_matrix.dart';
import 'package:agent_resource/src/harness/harness_catalog.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

LifecycleOptions lifecycleOptions(
  String project,
  String home, {
  Map<String, String> environment = const <String, String>{},
  String? geminiDir,
}) => LifecycleOptions(
  processWorkingDirectory: project,
  cwd: project,
  projectRoot: project,
  home: home,
  environment: environment,
  geminiDir: geminiDir,
);

LifecycleContext resolveContext(MemoryFileSystem fs, LifecycleOptions options) {
  fs.directory(options.cwd!).createSync(recursive: true);
  fs.directory(options.home!).createSync(recursive: true);
  return LifecycleContext.resolve(options, fileSystem: fs);
}

void main() {
  group('HarnessCatalog', () {
    test('registers four harnesses by identity and wire name', () {
      final catalog = HarnessCatalog.instance;

      expect(
        catalog.descriptors.map((descriptor) => descriptor.id),
        <HarnessId>[
          HarnessId.claude,
          HarnessId.codex,
          HarnessId.pi,
          HarnessId.antigravity,
        ],
      );
      expect(catalog.byWireName('antigravity').id, HarnessId.antigravity);
      expect(catalog.byId(HarnessId.pi).wireName, 'pi');
      expect(HarnessId.fromWire('codex'), HarnessId.codex);
      expect(() => catalog.byWireName('Gemini'), throwsFormatException);
    });

    test('reports supported Resource categories without a hooks facet', () {
      final catalog = HarnessCatalog.instance;
      const supported = <HarnessId>[
        HarnessId.claude,
        HarnessId.codex,
        HarnessId.pi,
        HarnessId.antigravity,
      ];
      const promptSupported = <HarnessId>[
        HarnessId.claude,
        HarnessId.codex,
        HarnessId.pi,
      ];

      expect(HarnessFacet.values.map((facet) => facet.wireName), <String>[
        'context',
        'mcp',
        'skill',
        'prompt',
        'agent',
      ]);
      expect(catalog.harnessesSupporting(HarnessFacet.context), supported);
      expect(catalog.harnessesSupporting(HarnessFacet.mcp), supported);
      expect(catalog.harnessesSupporting(HarnessFacet.skill), supported);
      expect(catalog.harnessesSupporting(HarnessFacet.prompt), promptSupported);
      expect(catalog.harnessesSupporting(HarnessFacet.agent), supported);
      expect(
        catalog.supports(HarnessId.antigravity, HarnessFacet.prompt),
        isFalse,
      );
      expect(catalog.facet(HarnessId.antigravity, HarnessFacet.prompt), isNull);
      expect(catalog.byId(HarnessId.antigravity).prompt, isNull);
      expect(
        catalog.facet(HarnessId.antigravity, HarnessFacet.agent)?.harness,
        HarnessId.antigravity,
      );
    });

    test('refuses unsupported facets with the category exit code', () {
      final catalog = HarnessCatalog.instance;
      final refusal = catalog.refusal(
        HarnessId.antigravity,
        HarnessFacet.prompt,
        exitCode: 4,
      )!;
      final invalidInputRefusal = catalog.refusal(
        HarnessId.antigravity,
        HarnessFacet.prompt,
        exitCode: 2,
      )!;

      expect(refusal.harness, HarnessId.antigravity);
      expect(refusal.facet, HarnessFacet.prompt);
      expect(refusal.code, 'UNSUPPORTED_HARNESS_FACET');
      expect(
        refusal.message,
        'UNSUPPORTED_HARNESS_FACET: Harness "antigravity" does not support '
        'the "prompt" Resource category.',
      );
      expect(invalidInputRefusal.message, refusal.message);
      expect(refusal.toException().exitCode, 4);
      expect(invalidInputRefusal.toException().exitCode, 2);
      expect(
        () => catalog.requireFacet(
          HarnessId.antigravity,
          HarnessFacet.prompt,
          refusalExitCode: 2,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'exit code', 2)
              .having(
                (error) => error.message,
                'message',
                contains('UNSUPPORTED_HARNESS_FACET'),
              ),
        ),
      );
      expect(catalog.refusal(HarnessId.claude, HarnessFacet.prompt), isNull);
      expect(
        catalog.requireFacet(HarnessId.pi, HarnessFacet.agent).harness,
        HarnessId.pi,
      );
    });

    test('the Agent facet owns authoring matrices and conversion spokes', () {
      final catalog = HarnessCatalog.instance;
      final ids = HarnessId.values;
      for (final id in ids) {
        final spec = catalog.agentSpecById(id);
        final profile = AuthoringProfile.values.firstWhere(
          (value) => value.name == id.wireName,
        );
        final matrix = spec.nativeAgentFields(profile);
        expect(matrix.kind, AuthoringKind.agent);
        expect(matrix.profile, profile);
        if (id == HarnessId.antigravity) {
          expect(matrix.supportedNames, <String>[
            'description',
            'mainAgent',
            'name',
            'tools',
          ]);
          expect(matrix.specFor('tools')!.listForm, NativeListForm.sequence);
        }
        final native = spec.importNativeAgent(
          AgentImportRequest(
            fields: <String, Object?>{
              'name': 'reviewer',
              'description': 'Reviews.',
              'tools': <Object?>['read'],
            },
            sourceForm: '${id.wireName}-agent-file',
            sourceProfile: spec.profile,
          ),
        );
        expect(native.sourceHarness, id);
        expect(
          native.claims.map((claim) => claim.provenance.sourceHarness).toSet(),
          <HarnessId>{id},
        );
      }
      for (final source in ids) {
        final sourceSpec = catalog.agentSpecById(source);
        for (final target in ids) {
          if (source == target) continue;
          final targetSpec = catalog.agentSpecById(target);
          final result = targetSpec.exportCanonicalAgent(
            AgentExportRequest(
              canonical: sourceSpec.importNativeAgent(
                AgentImportRequest(
                  fields: const <String, Object?>{
                    'name': 'reviewer',
                    'description': 'Reviews.',
                    'tools': <Object?>['read'],
                  },
                  sourceForm: '${source.wireName}-agent-file',
                  sourceProfile: sourceSpec.profile,
                ),
              ),
              definition: const <String, Object?>{},
              decisions: const <String>{},
              sourceProfile: sourceSpec.profile,
            ),
          );
          expect(result.fields, isNotEmpty);
          expect(result.targetProfile, targetSpec.profile);
          expect(
            result.fields.every(
              (field) =>
                  field.containsKey('sourceProfile') &&
                  field.containsKey('outcome'),
            ),
            isTrue,
          );
        }
      }
    });
  });

  group('LifecycleContext', () {
    test('resolves Antigravity roots across platforms without writes', () {
      void expectDefaultRoots(
        FileSystemStyle style,
        String project,
        String home,
        String expectedRoot,
        String expectedConfigRoot,
      ) {
        final fs = MemoryFileSystem(style: style);
        final context = resolveContext(fs, lifecycleOptions(project, home));

        expect(context.geminiRoot(), expectedRoot);
        expect(context.geminiConfigRoot(), expectedConfigRoot);
        expect(fs.directory(expectedRoot).existsSync(), isFalse);
        expect(fs.directory(expectedConfigRoot).existsSync(), isFalse);
      }

      expectDefaultRoots(
        FileSystemStyle.posix,
        '/sandbox/project',
        '/sandbox/home',
        '/sandbox/home/.gemini',
        '/sandbox/home/.gemini/config',
      );
      expectDefaultRoots(
        FileSystemStyle.windows,
        r'C:\sandbox\project',
        r'C:\sandbox\home',
        r'C:\sandbox\home\.gemini',
        r'C:\sandbox\home\.gemini\config',
      );

      final fs = MemoryFileSystem(style: FileSystemStyle.posix);
      final configDirContext = resolveContext(
        fs,
        lifecycleOptions(
          '/sandbox/project',
          '/sandbox/home',
          environment: const <String, String>{
            'GEMINI_CONFIG_DIR': '/sandbox/from-config-env',
            'GEMINI_HOME': '/sandbox/from-home-env',
          },
        ),
      );
      expect(configDirContext.geminiRoot(), '/sandbox/from-config-env');
      expect(
        configDirContext.geminiConfigRoot(),
        '/sandbox/from-config-env/config',
      );

      final geminiHomeContext = resolveContext(
        fs,
        lifecycleOptions(
          '/sandbox/project',
          '/sandbox/home',
          environment: const <String, String>{
            'GEMINI_HOME': '/sandbox/from-home-env',
          },
        ),
      );
      expect(geminiHomeContext.geminiRoot(), '/sandbox/from-home-env');
      expect(
        geminiHomeContext.geminiConfigRoot(),
        '/sandbox/from-home-env/config',
      );

      final explicitOptions = lifecycleOptions(
        '/sandbox/project',
        '/sandbox/home',
        environment: const <String, String>{
          'GEMINI_CONFIG_DIR': '/sandbox/from-config-env',
        },
        geminiDir: '/sandbox/explicit-gemini',
      );
      expect(
        LifecycleContext.resolve(explicitOptions, fileSystem: fs).geminiRoot(),
        '/sandbox/explicit-gemini',
      );
      expect(
        LifecycleContext.resolve(
          explicitOptions.copyWith(scope: LifecycleScope.user),
          fileSystem: fs,
        ).geminiConfigRoot(),
        '/sandbox/explicit-gemini/config',
      );
      expect(
        LifecycleContext.resolve(
          explicitOptions.copyWith(geminiDir: '/sandbox/copied-gemini'),
          fileSystem: fs,
        ).geminiRoot(),
        '/sandbox/copied-gemini',
      );
      expect(fs.directory('/sandbox/home/.gemini').existsSync(), isFalse);
      expect(
        fs.directory('/sandbox/home/.gemini/config').existsSync(),
        isFalse,
      );
    });
  });

  group('HarnessCatalog user roots', () {
    test('resolves each harness root through the lifecycle context', () {
      final catalog = HarnessCatalog.instance;
      final fs = MemoryFileSystem(style: FileSystemStyle.posix);
      final context = resolveContext(
        fs,
        LifecycleOptions(
          processWorkingDirectory: '/sandbox/project',
          cwd: '/sandbox/project',
          projectRoot: '/sandbox/project',
          home: '/sandbox/home',
          claudeConfigDir: '/sandbox/claude',
          codexHome: '/sandbox/codex',
          piAgentDir: '/sandbox/pi',
          geminiDir: '/sandbox/gemini',
        ),
      );

      expect(catalog.userRoot(HarnessId.claude, context), '/sandbox/claude');
      expect(catalog.userRoot(HarnessId.codex, context), '/sandbox/codex');
      expect(catalog.userRoot(HarnessId.pi, context), '/sandbox/pi');
      expect(
        catalog.userRoot(HarnessId.antigravity, context),
        '/sandbox/gemini',
      );
      expect(
        catalog.userConfigRoot(HarnessId.claude, context),
        '/sandbox/claude',
      );
      expect(
        catalog.userConfigRoot(HarnessId.codex, context),
        '/sandbox/codex',
      );
      expect(catalog.userConfigRoot(HarnessId.pi, context), '/sandbox/pi');
      expect(
        catalog.userConfigRoot(HarnessId.antigravity, context),
        '/sandbox/gemini/config',
      );

      final windowsFs = MemoryFileSystem(style: FileSystemStyle.windows);
      final windowsContext = resolveContext(
        windowsFs,
        lifecycleOptions(r'C:\sandbox\project', r'C:\sandbox\home'),
      );
      expect(
        catalog.userRoot(HarnessId.antigravity, windowsContext),
        r'C:\sandbox\home\.gemini',
      );
      expect(
        catalog.userConfigRoot(HarnessId.antigravity, windowsContext),
        r'C:\sandbox\home\.gemini\config',
      );
    });
  });
}
