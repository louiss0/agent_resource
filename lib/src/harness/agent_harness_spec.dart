import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import 'harness_facet.dart';
import 'harness_id.dart';
import 'harness_user_roots.dart';

/// The kind of native location a bounded Agent inventory must inspect.
enum AgentDiscoveryKind { directory, codexConfig }

/// The native file layout of one Agent definition occurrence.
enum AgentLayout { legacy, flat, nested }

/// The native parser and field contract used by a harness.
enum AgentSchemaKind { claude, codex, pi, antigravity }

/// The diagnostic class of one frontmatter finding.
enum AgentFieldCategory { specification, product, advisory }

/// One bounded, explicitly selected native Agent discovery location.
final class AgentDiscoveryRoot {
  const AgentDiscoveryRoot({
    required this.path,
    required this.anchor,
    required this.scope,
    this.destination = 'native',
    this.kind = AgentDiscoveryKind.directory,
    this.piDistinction = false,
    this.maxDepth = 16,
  });

  final String path;
  final String anchor;
  final String scope;
  final String destination;
  final AgentDiscoveryKind kind;
  final bool piDistinction;
  final int maxDepth;
}

/// Read-only process, project, and user-root inputs for discovery.
final class AgentDiscoveryContext {
  const AgentDiscoveryContext({
    required this.path,
    required this.projectRoot,
    required this.home,
    required this.ancestors,
    required this.readRoots,
    required this.userRoots,
  });

  final p.Context path;
  final String projectRoot;
  final String home;
  final List<String> ancestors;
  final List<String> readRoots;
  final HarnessUserRoots userRoots;
}

/// Read-only process, project, user-root, and ancestry inputs for lifecycle.
final class AgentLifecycleContext {
  const AgentLifecycleContext({
    required this.path,
    required this.projectRoot,
    required this.cwd,
    required this.home,
    required this.scope,
    required this.ancestors,
    required this.readRoots,
    required this.userRoots,
  });

  final p.Context path;
  final String projectRoot;
  final String cwd;
  final String home;
  final String scope;
  final List<String> ancestors;
  final List<String> readRoots;
  final HarnessUserRoots userRoots;
}

/// One typed declaration extracted from a native Agent definition.
final class AgentFieldDeclaration {
  const AgentFieldDeclaration({
    required this.kind,
    required this.name,
    this.label = 'explicit',
    this.detail,
  });

  factory AgentFieldDeclaration.fromJson(Map<String, Object?> json) =>
      AgentFieldDeclaration(
        kind: json['kind']! as String,
        name: json['name']! as String,
        label: json['label']! as String,
        detail: json['detail'] as String?,
      );

  final String kind;
  final String name;
  final String label;
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'name': name,
    'label': label,
    'detail': ?detail,
  };
}

/// The declarations and resolution policy extracted for one Agent graph.
final class AgentGraphExtraction {
  const AgentGraphExtraction({
    required this.references,
    required this.capabilities,
    required this.relationships,
    required this.skillRoots,
    required this.runtimeDependentKinds,
  });

  final List<AgentFieldDeclaration> references;
  final List<AgentFieldDeclaration> capabilities;
  final Map<String, String> relationships;
  final List<String> skillRoots;
  final Set<String> runtimeDependentKinds;
}

/// The narrow inspection sink used by facet-owned schema validation.
abstract interface class AgentFieldValidation {
  void reportError(
    String code,
    AgentFieldCategory category,
    String? field,
    String message,
  );

  void reportWarning(
    String code,
    AgentFieldCategory category,
    String? field,
    String message,
  );

  void declareName(String name);

  void declareDescription(String description);

  void addReference(AgentFieldDeclaration declaration);

  void addCapability(AgentFieldDeclaration declaration);

  void addParentRequirement(String aspect, String label, String detail);

  String typeName(Object? value);
}

/// The Agent definition capability declared by one harness.
///
/// The facet owns discovery roots, file layouts, the documented frontmatter
/// contract, dependency extraction, native-name comparison, and installation
/// authority. Domain engines supply only their bounded filesystem/path seam.
abstract class AgentHarnessSpec implements HarnessFacetSpec {
  const AgentHarnessSpec();

  static const _antigravityKnownFields = <String>{
    'name',
    'description',
    'tools',
    'mainAgent',
  };

  static const _antigravityEvidence = <String, Object?>{
    'kind': 'official-document-contract',
    'contract': 'antigravity-custom-subagents',
    'baseline': '2.12',
  };

  AgentSchemaKind get schemaKind => switch (harness) {
    HarnessId.claude => AgentSchemaKind.claude,
    HarnessId.codex => AgentSchemaKind.codex,
    HarnessId.pi => AgentSchemaKind.pi,
    HarnessId.antigravity => AgentSchemaKind.antigravity,
  };

  String get nativeForm => '${harness.wireName}-agent-file';

  String get profile => '${harness.wireName}-agent-native-v1';

  Map<String, Object?> get evidence => switch (harness) {
    HarnessId.claude => const <String, Object?>{
      'kind': 'official-document-snapshot',
      'contract': 'claude-agent-native-v1',
    },
    HarnessId.codex => const <String, Object?>{
      'kind': 'official-document-snapshot',
      'contract': 'codex-agent-native-v1',
    },
    HarnessId.pi => const <String, Object?>{
      'kind': 'pinned-package-sources',
      'contract': 'pi-agent-common-v1',
    },
    HarnessId.antigravity => _antigravityEvidence,
  };

  String get definitionExtension =>
      harness == HarnessId.codex ? '.toml' : '.md';

  bool get runtimeTrimmedInstructions => harness == HarnessId.pi;

  bool get nestedLayouts => harness == HarnessId.antigravity;

  bool get caseInsensitiveNames => harness == HarnessId.pi;

  Set<String> get builtinNames => switch (harness) {
    HarnessId.claude => const <String>{'Explore', 'Plan', 'general-purpose'},
    HarnessId.codex => const <String>{'default', 'worker', 'explorer'},
    HarnessId.pi || HarnessId.antigravity => const <String>{},
  };

  String normalizeName(String name) =>
      caseInsensitiveNames ? name.toLowerCase() : name;

  Set<String> get documentedFrontmatterFields =>
      harness == HarnessId.antigravity
      ? _antigravityKnownFields
      : const <String>{};

  String? associationField(String kind) => switch ((kind, harness)) {
    ('skill', HarnessId.claude || HarnessId.codex) => 'skills',
    ('mcp-server', HarnessId.claude) => 'mcpServers',
    ('mcp-server', HarnessId.codex) => 'mcp_servers',
    ('hook', HarnessId.claude) => 'hooks',
    ('tool', HarnessId.antigravity) => 'tools',
    _ => null,
  };

  List<AgentDiscoveryRoot> discoveryRoots(
    AgentDiscoveryContext context, {
    required String scope,
  }) => switch (scope) {
    'project' => _projectRoots(context),
    'user' => _userRoots(context),
    _ => throw ArgumentError.value(scope, 'scope', 'Unsupported Agent scope.'),
  };

  List<AgentDiscoveryRoot> _projectRoots(AgentDiscoveryContext context) {
    final path = context.path;
    switch (harness) {
      case HarnessId.claude:
        return List<AgentDiscoveryRoot>.unmodifiable(<AgentDiscoveryRoot>[
          for (final ancestor in context.ancestors)
            AgentDiscoveryRoot(
              path: path.join(ancestor, '.claude', 'agents'),
              anchor: ancestor,
              scope: 'project',
            ),
          for (final root in context.readRoots)
            AgentDiscoveryRoot(
              path: path.join(root, '.claude', 'agents'),
              anchor: root,
              scope: 'project',
            ),
        ]);
      case HarnessId.codex:
        return List<AgentDiscoveryRoot>.unmodifiable(<AgentDiscoveryRoot>[
          for (final ancestor in context.ancestors) ...<AgentDiscoveryRoot>[
            AgentDiscoveryRoot(
              path: path.join(ancestor, '.codex', 'agents'),
              anchor: ancestor,
              scope: 'project',
            ),
            AgentDiscoveryRoot(
              path: path.join(ancestor, '.codex', 'config.toml'),
              anchor: ancestor,
              scope: 'project',
              kind: AgentDiscoveryKind.codexConfig,
            ),
          ],
        ]);
      case HarnessId.pi:
        return List<AgentDiscoveryRoot>.unmodifiable(<AgentDiscoveryRoot>[
          AgentDiscoveryRoot(
            path: path.join(context.projectRoot, '.pi', 'agents'),
            anchor: context.projectRoot,
            scope: 'project',
            piDistinction: true,
          ),
          AgentDiscoveryRoot(
            path: path.join(context.projectRoot, '.agents', 'agents'),
            anchor: context.projectRoot,
            scope: 'project',
            destination: 'shared',
            piDistinction: true,
          ),
        ]);
      case HarnessId.antigravity:
        return List<AgentDiscoveryRoot>.unmodifiable(<AgentDiscoveryRoot>[
          AgentDiscoveryRoot(
            path: path.join(context.projectRoot, '.agents', 'agents'),
            anchor: context.projectRoot,
            scope: 'project',
            maxDepth: 1,
          ),
        ]);
    }
  }

  List<AgentDiscoveryRoot> _userRoots(AgentDiscoveryContext context) {
    final path = context.path;
    switch (harness) {
      case HarnessId.claude:
        return _oneRoot(
          path.join(context.userRoots.claudeConfigRoot(), 'agents'),
          context.home,
        );
      case HarnessId.codex:
        return List<AgentDiscoveryRoot>.unmodifiable(<AgentDiscoveryRoot>[
          AgentDiscoveryRoot(
            path: path.join(context.userRoots.codexRoot(), 'agents'),
            anchor: context.home,
            scope: 'user',
          ),
          AgentDiscoveryRoot(
            path: path.join(context.userRoots.codexRoot(), 'config.toml'),
            anchor: context.home,
            scope: 'user',
            kind: AgentDiscoveryKind.codexConfig,
          ),
        ]);
      case HarnessId.pi:
        return List<AgentDiscoveryRoot>.unmodifiable(<AgentDiscoveryRoot>[
          AgentDiscoveryRoot(
            path: path.join(context.userRoots.piAgentRoot(), 'agents'),
            anchor: context.home,
            scope: 'user',
            piDistinction: true,
          ),
        ]);
      case HarnessId.antigravity:
        return List<AgentDiscoveryRoot>.unmodifiable(<AgentDiscoveryRoot>[
          AgentDiscoveryRoot(
            path: path.join(context.userRoots.geminiConfigRoot(), 'agents'),
            anchor: context.home,
            scope: 'user',
            maxDepth: 1,
          ),
        ]);
    }
  }

  List<AgentDiscoveryRoot> _oneRoot(String path, String anchor) =>
      List<AgentDiscoveryRoot>.unmodifiable(<AgentDiscoveryRoot>[
        AgentDiscoveryRoot(path: path, anchor: anchor, scope: 'user'),
      ]);

  bool acceptsDirectory(String relativePath, int depth, p.Context path) {
    if (!nestedLayouts) return true;
    return depth == 0 && path.split(relativePath).length == 1;
  }

  AgentLayout? candidateLayout(
    String relativePath,
    int fileDepth,
    p.Context path,
  ) {
    if (!nestedLayouts) return AgentLayout.legacy;
    final parts = path.split(relativePath);
    if (fileDepth == 0 &&
        parts.length == 1 &&
        path.extension(relativePath) == definitionExtension) {
      return AgentLayout.flat;
    }
    if (fileDepth == 1 &&
        parts.length == 2 &&
        path.basename(relativePath) == 'agent.md') {
      return AgentLayout.nested;
    }
    return null;
  }

  String? targetName(String relativePath, p.Context path) {
    final parts = path.split(relativePath);
    if (parts.length == 1 &&
        path.extension(relativePath) == definitionExtension) {
      return path.basenameWithoutExtension(relativePath);
    }
    if (parts.length == 2 && path.basename(relativePath) == 'agent.md') {
      return path.basename(path.dirname(relativePath));
    }
    return null;
  }

  /// Names that must be unique for the same harness target. Antigravity
  /// compares both its declared frontmatter name and its layout target name.
  Set<String> comparisonNames(Map<String, Object?> occurrence, p.Context path) {
    final names = <String>{};
    final identity = occurrence['identity'];
    if (identity is Map<Object?, Object?>) {
      final name = identity['name'];
      if (name is Map<Object?, Object?>) {
        final resolved = name['resolved'];
        if (resolved is String && resolved.isNotEmpty) {
          names.add(normalizeName(resolved));
        }
      }
    }
    if (nestedLayouts) {
      final declaredTarget = occurrence['targetName'];
      if (declaredTarget is String && declaredTarget.isNotEmpty) {
        names.add(normalizeName(declaredTarget));
      }
      final root = occurrence['root'];
      final location = occurrence['path'];
      if (root is String &&
          location is String &&
          path.isWithin(root, location)) {
        final observed = targetName(path.relative(location, from: root), path);
        if (observed != null && observed.isNotEmpty) {
          names.add(normalizeName(observed));
        }
      }
    }
    return Set<String>.unmodifiable(names);
  }

  /// Names compared during a lifecycle mutation. A malformed candidate can
  /// still shadow a reviewed native name through its observable basename.
  Set<String> uniquenessNames(Map<String, Object?> occurrence, p.Context path) {
    final names = <String>{...comparisonNames(occurrence, path)};
    final location = occurrence['path'];
    if (location is String) {
      final basename = path.basenameWithoutExtension(location);
      if (basename.isNotEmpty) names.add(normalizeName(basename));
      final root = occurrence['root'];
      if (root is String && path.isWithin(root, location)) {
        final relative = path.relative(location, from: root);
        final observed = targetName(relative, path);
        if (observed != null && observed.isNotEmpty) {
          names.add(normalizeName(observed));
        }
      }
    }
    return Set<String>.unmodifiable(names);
  }

  /// Dispatches decoded native field validation through the facet. Legacy
  /// validators retain their detailed contracts; Antigravity owns its own.
  void validateFields(
    Map<Object?, Object?> fields,
    AgentFieldValidation validation,
    void Function(AgentSchemaKind kind, Map<Object?, Object?> fields) legacy,
  ) {
    if (schemaKind != AgentSchemaKind.antigravity) {
      legacy(schemaKind, fields);
      return;
    }
    _validateAntigravityFields(fields, validation);
  }

  void _validateAntigravityFields(
    Map<Object?, Object?> fields,
    AgentFieldValidation validation,
  ) {
    void error(String code, String? field, String message) => validation
        .reportError(code, AgentFieldCategory.specification, field, message);

    if (!fields.containsKey('name')) {
      error('NAME_REQUIRED', 'name', 'Frontmatter requires a name string.');
    } else {
      final name = fields['name'];
      if (name is! String) {
        error('NAME_TYPE', 'name', 'name must be a string.');
      } else {
        validation.declareName(name);
        if (name.trim().isEmpty) {
          error('NAME_BLANK', 'name', 'name must not be blank.');
        }
        if (name.runes.length > 256) {
          error(
            'NAME_LENGTH',
            'name',
            'name must contain at most 256 Unicode scalar values.',
          );
        }
        if (name.contains(':') || name.contains('/') || name.contains(r'\')) {
          error(
            'NAME_SEPARATOR',
            'name',
            'name must not contain a colon or path separator.',
          );
        }
        if (name.startsWith('-') || name != name.trim()) {
          error(
            'NAME_FORM',
            'name',
            'name must not start with a hyphen or carry surrounding whitespace.',
          );
        }
      }
    }

    if (!fields.containsKey('description')) {
      error(
        'DESCRIPTION_REQUIRED',
        'description',
        'Frontmatter requires a description string.',
      );
    } else {
      final description = fields['description'];
      if (description is! String) {
        error(
          'DESCRIPTION_TYPE',
          'description',
          'description must be a string.',
        );
      } else {
        validation.declareDescription(description);
        if (description.trim().isEmpty) {
          error(
            'DESCRIPTION_BLANK',
            'description',
            'description must not be blank.',
          );
        }
      }
    }

    if (fields.containsKey('tools')) {
      final tools = fields['tools'];
      if (tools is String) {
        validation.reportError(
          'TOOLS_FORM',
          AgentFieldCategory.specification,
          'tools',
          'tools must be a YAML list of strings, not a scalar.',
        );
      } else if (tools is! List) {
        error('TOOLS_TYPE', 'tools', 'tools must be a YAML list of strings.');
      } else {
        var typed = true;
        for (final entry in tools) {
          if (entry is! String || entry.trim().isEmpty) {
            typed = false;
            continue;
          }
          validation.addCapability(
            AgentFieldDeclaration(
              kind: 'tool-allowlist',
              name: entry,
              detail: 'Declared tool; availability is not certified.',
            ),
          );
        }
        if (!typed) {
          error(
            'TOOLS_ENTRY_TYPE',
            'tools',
            'tools entries must be nonempty strings.',
          );
        }
      }
    }

    if (fields.containsKey('mainAgent')) {
      final mainAgent = fields['mainAgent'];
      if (mainAgent is! bool) {
        error('MAIN_AGENT_TYPE', 'mainAgent', 'mainAgent must be a boolean.');
      } else if (mainAgent) {
        validation.addCapability(
          const AgentFieldDeclaration(
            kind: 'main-agent',
            name: 'mainAgent',
            detail: 'Declared main-agent capability; runtime dispatch is not verified.',
          ),
        );
      }
    }

    final unknown = <String>[
      for (final key in fields.keys)
        if (key is String && !_antigravityKnownFields.contains(key)) key,
    ]..sort();
    for (final key in unknown) {
      validation.reportWarning(
        'UNKNOWN_FIELD',
        AgentFieldCategory.advisory,
        key,
        'Unknown top-level field of type ${validation.typeName(fields[key])}; '
            'the value is not reported.',
      );
    }

    validation.addParentRequirement(
      'discovery-trust',
      'runtime-dependent',
      'Flat and one-level nested Agent roots are documented; project trust '
          'and effective discovery are runtime dependent.',
    );
    validation.addParentRequirement(
      'instruction-context',
      'inherited',
      'The Markdown body supplies system instructions; surrounding harness '
          'context is inherited.',
    );
    if (!fields.containsKey('tools')) {
      validation.addParentRequirement(
        'tool-pool',
        'inherited',
        'Omitting tools inherits the available tool pool; declared lists are '
            'not proof of usable tools.',
      );
    }
  }

  /// Extracts native declarations, graph relationships, and resolution bases.
  AgentGraphExtraction extractGraph({
    required Map<String, Object?> nativeFields,
    required List<Map<String, Object?>> observedReferences,
    required List<Map<String, Object?>> observedCapabilities,
    required String nativeBase,
    required p.Context path,
  }) {
    final references = <AgentFieldDeclaration>[
      for (final reference in observedReferences)
        AgentFieldDeclaration.fromJson(reference),
    ];
    final capabilities = <AgentFieldDeclaration>[
      for (final capability in observedCapabilities)
        AgentFieldDeclaration.fromJson(capability),
    ];
    final runtimeDependentKinds = <String>{
      'model',
      'mcp-server',
      'hook',
      if (harness == HarnessId.antigravity) 'tool',
    };
    final relationships = <String, String>{
      'skill': harness == HarnessId.claude
          ? 'skill-preload'
          : 'skill-exclusion',
      'mcp-server': 'mcp-association',
      'hook': 'hook-association',
      'model': 'model',
      if (harness == HarnessId.antigravity) 'tool': 'tool-capability',
    };
    if (harness == HarnessId.antigravity) {
      final tools = nativeFields['tools'];
      if (tools is List) {
        for (final tool in tools) {
          if (tool is String && tool.trim().isNotEmpty) {
            references.add(
              AgentFieldDeclaration(
                kind: 'tool',
                name: tool,
                detail: 'Declared tool; availability is not certified.',
              ),
            );
          }
        }
      }
    }
    return AgentGraphExtraction(
      references: List<AgentFieldDeclaration>.unmodifiable(references),
      capabilities: List<AgentFieldDeclaration>.unmodifiable(capabilities),
      relationships: Map<String, String>.unmodifiable(relationships),
      skillRoots: graphSkillRoots(nativeBase, path),
      runtimeDependentKinds: Set<String>.unmodifiable(runtimeDependentKinds),
    );
  }

  List<String> graphSkillRoots(String nativeBase, p.Context path) {
    final roots = switch (harness) {
      HarnessId.claude => <String>[
        path.join(nativeBase, '.claude', 'skills'),
        path.join(nativeBase, '.agents', 'skills'),
      ],
      HarnessId.codex => <String>[
        path.join(nativeBase, '.codex', 'skills'),
        path.join(nativeBase, '.agents', 'skills'),
      ],
      HarnessId.pi || HarnessId.antigravity => <String>[
        path.join(nativeBase, '.agents', 'skills'),
      ],
    };
    return List<String>.unmodifiable(roots);
  }

  String defaultInstallRoot(AgentLifecycleContext context, String destination) {
    final path = context.path;
    if (destination == 'shared') {
      if (harness != HarnessId.pi) {
        throw MambaException(
          'Shared Agent destinations are supported only for common-Pi project files.',
          exitCode: 4,
        );
      }
      if (context.scope != 'project') {
        throw MambaException(
          'Pi shared Agent installation is unsupported at user scope.',
          exitCode: 4,
        );
      }
      return path.normalize(
        path.join(context.projectRoot, '.agents', 'agents'),
      );
    }
    return path.normalize(switch (harness) {
      HarnessId.claude =>
        context.scope == 'project'
            ? path.join(context.projectRoot, '.claude', 'agents')
            : path.join(context.userRoots.claudeConfigRoot(), 'agents'),
      HarnessId.codex =>
        context.scope == 'project'
            ? path.join(context.projectRoot, '.codex', 'agents')
            : path.join(context.userRoots.codexRoot(), 'agents'),
      HarnessId.pi =>
        context.scope == 'project'
            ? path.join(context.projectRoot, '.pi', 'agents')
            : path.join(context.userRoots.piAgentRoot(), 'agents'),
      HarnessId.antigravity =>
        context.scope == 'project'
            ? path.join(context.projectRoot, '.agents', 'agents')
            : path.join(context.userRoots.geminiConfigRoot(), 'agents'),
    });
  }

  List<String> authorityRoots(
    AgentLifecycleContext context,
    String destination,
  ) {
    final path = context.path;
    if (destination == 'shared' ||
        context.scope == 'user' ||
        harness == HarnessId.pi) {
      return List<String>.unmodifiable(<String>[
        defaultInstallRoot(context, destination),
      ]);
    }
    final roots = <String>[];
    for (final ancestor in context.ancestors) {
      roots.add(switch (harness) {
        HarnessId.claude => path.join(ancestor, '.claude', 'agents'),
        HarnessId.codex => path.join(ancestor, '.codex', 'agents'),
        HarnessId.pi => path.join(ancestor, '.pi', 'agents'),
        HarnessId.antigravity => path.join(ancestor, '.agents', 'agents'),
      });
    }
    if (roots.isEmpty ||
        !path.equals(roots.last, defaultInstallRoot(context, destination))) {
      roots.add(defaultInstallRoot(context, destination));
    }
    return List<String>.unmodifiable(roots);
  }

  List<String> additionalUniquenessRoots(AgentLifecycleContext context) {
    final path = context.path;
    return List<String>.unmodifiable(<String>[
      if (harness == HarnessId.pi)
        path.join(context.projectRoot, '.agents', 'agents'),
      if (harness == HarnessId.claude)
        for (final root in context.readRoots)
          path.join(root, '.claude', 'agents'),
    ]);
  }

  bool acceptsInstallLocation(
    String root,
    String location,
    String destination,
    p.Context path,
  ) {
    if (harness == HarnessId.pi) {
      if (!path.equals(path.dirname(location), root)) {
        throw MambaException(
          'Common-Pi accepts only immediate native/shared Agent files; '
          'provider-specific deeper files are not common-Pi targets.',
          exitCode: 4,
        );
      }
    }
    if (harness == HarnessId.antigravity) {
      final relative = path.relative(location, from: root);
      final parts = path.split(relative);
      final flat =
          parts.length == 1 && path.extension(relative) == definitionExtension;
      final nested = parts.length == 2 && path.basename(relative) == 'agent.md';
      if (!flat && !nested) {
        throw MambaException(
          'Antigravity Agent definitions use <name>.md or '
          '<name>/agent.md within their native root.',
          exitCode: 4,
        );
      }
    }
    return true;
  }

  /// Chooses the owned destination basename. Nested Antigravity sources are
  /// published in the native flat layout, keyed by the reviewed native name.
  String installationFileName(
    String sourcePath,
    String? nativeName,
    p.Context path,
  ) {
    if (harness != HarnessId.antigravity) return path.basename(sourcePath);
    final basename = path.basename(sourcePath);
    final inferred = basename == 'agent.md'
        ? path.basename(path.dirname(sourcePath))
        : path.basenameWithoutExtension(sourcePath);
    final name = nativeName ?? inferred;
    return '${path.basename(name)}$definitionExtension';
  }
}
