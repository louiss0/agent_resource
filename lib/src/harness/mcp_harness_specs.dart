import 'package:path/path.dart' as p;

import '../mcp/mcp_conversion_account.dart';
import '../mcp/mcp_native_location.dart';
import '../mcp/mcp_types.dart';
import '../mcp/mcp_validation_contract.dart';
import 'harness_facet.dart';
import 'harness_id.dart';
import 'mcp_harness_spec.dart';

typedef _LocationBuilder = List<McpNativeLocation> Function(
  _ConfiguredMcpHarnessSpec spec,
  McpHarnessRoots roots,
);

/// The four concrete MCP facets registered by the composed catalog.
final Map<HarnessId, McpHarnessSpec> mcpHarnessSpecs =
    <HarnessId, McpHarnessSpec>{
      HarnessId.claude: _ConfiguredMcpHarnessSpec(
        harness: HarnessId.claude,
        mcpHarness: McpHarness.claude,
        supportedScopes: const <McpScope>{
          McpScope.project,
          McpScope.user,
          McpScope.local,
        },
        inspectOnlyScopes: const <McpScope>{McpScope.user, McpScope.local},
        inspectOnlyDiagnostic:
            'Claude user/local MCP registrations live in the shared '
            '~/.claude.json home file, whose third-party edit/concurrency '
            'protocol is not documented. This surface is inspect-only: all '
            'mutations are refused and no managed policy or trust file is '
            'written.',
        projectSegments: const <String>['.mcp.json'],
        nativeFormat: McpNativeFormat.json,
        nativeSection: McpNativeSection.mcpServers,
        validation: mcpValidationContract(
          profile: 'mcp-claude-native-static-v1',
          sources: <String>{mcpClaudeBaseline, mcpParentConfigurationBaseline},
          commonFields: mcpClaudeCommonFields,
          stdioFields: mcpClaudeStdioFields,
          httpFields: mcpClaudeHttpFields,
          stdioTypes: mcpClaudeStdioTypes,
          httpTypes: mcpClaudeHttpTypes,
          requiresHttpType: true,
          fieldSchema: mcpClaudeFieldSchema,
        ),
        runtimeControlFields: const <String>{},
        toolProfile: null,
        httpEndpointKey: 'url',
        headerKey: 'headers',
        locationsBuilder: _claudeLocations,
      ),
      HarnessId.codex: _ConfiguredMcpHarnessSpec(
        harness: HarnessId.codex,
        mcpHarness: McpHarness.codex,
        supportedScopes: const <McpScope>{McpScope.project, McpScope.user},
        inspectOnlyScopes: const <McpScope>{},
        inspectOnlyDiagnostic: null,
        projectSegments: const <String>['.codex', 'config.toml'],
        nativeFormat: McpNativeFormat.toml,
        nativeSection: McpNativeSection.codexMcpServers,
        validation: mcpValidationContract(
          profile: 'mcp-codex-native-static-v1',
          sources: <String>{mcpCodexBaseline, mcpParentConfigurationBaseline},
          commonFields: mcpCodexCommonFields,
          stdioFields: mcpCodexStdioFields,
          httpFields: mcpCodexHttpFields,
          stdioTypes: mcpCodexStdioTypes,
          httpTypes: mcpCodexHttpTypes,
          requiresHttpType: false,
          fieldSchema: mcpCodexFieldSchema,
        ),
        runtimeControlFields: mcpCodexRuntimeControls,
        toolProfile: 'codex-tool-controls-v1',
        httpEndpointKey: 'url',
        headerKey: 'http_headers',
        locationsBuilder: _codexLocations,
      ),
      HarnessId.pi: _ConfiguredMcpHarnessSpec(
        harness: HarnessId.pi,
        mcpHarness: McpHarness.pi,
        supportedScopes: const <McpScope>{McpScope.project, McpScope.user},
        inspectOnlyScopes: const <McpScope>{},
        inspectOnlyDiagnostic: null,
        projectSegments: const <String>['.pi', 'mcp.json'],
        nativeFormat: McpNativeFormat.json,
        nativeSection: McpNativeSection.mcpServers,
        validation: mcpValidationContract(
          profile: 'mcp-pi-native-static-v1',
          sources: <String>{mcpPiBaseline, mcpParentConfigurationBaseline},
          commonFields: mcpPiCommonFields,
          stdioFields: mcpPiStdioFields,
          httpFields: mcpPiHttpFields,
          stdioTypes: mcpPiStdioTypes,
          httpTypes: mcpPiHttpTypes,
          requiresHttpType: false,
          fieldSchema: mcpPiFieldSchema,
        ),
        runtimeControlFields: mcpPiRuntimeControls,
        toolProfile: null,
        httpEndpointKey: 'url',
        headerKey: 'headers',
        locationsBuilder: _piLocations,
      ),
      HarnessId.antigravity: _ConfiguredMcpHarnessSpec(
        harness: HarnessId.antigravity,
        mcpHarness: McpHarness.antigravity,
        supportedScopes: const <McpScope>{McpScope.project, McpScope.user},
        inspectOnlyScopes: const <McpScope>{},
        inspectOnlyDiagnostic: null,
        projectSegments: const <String>['.agents', 'mcp_config.json'],
        nativeFormat: McpNativeFormat.json,
        nativeSection: McpNativeSection.mcpServers,
        validation: mcpValidationContract(
          profile: 'mcp-antigravity-native-static-v1',
          sources: <String>{
            mcpAntigravityBaseline,
            mcpParentConfigurationBaseline,
          },
          commonFields: mcpAntigravityCommonFields,
          stdioFields: mcpAntigravityStdioFields,
          httpFields: mcpAntigravityHttpFields,
          stdioTypes: mcpAntigravityStdioTypes,
          httpTypes: mcpAntigravityHttpTypes,
          stdioTransportKeys: mcpAntigravityStdioTransportKeys,
          httpTransportKeys: mcpAntigravityHttpTransportKeys,
          requiresHttpType: false,
          fieldSchema: mcpAntigravityFieldSchema,
        ),
        runtimeControlFields: mcpAntigravityRuntimeControls,
        toolProfile: 'antigravity-tool-settings-v1',
        httpEndpointKey: 'serverUrl',
        headerKey: 'headers',
        locationsBuilder: _antigravityLocations,
      ),
    };

final class _ConfiguredMcpHarnessSpec implements McpHarnessSpec {
  _ConfiguredMcpHarnessSpec({
    required this.harness,
    required this.mcpHarness,
    required this.supportedScopes,
    required this.inspectOnlyScopes,
    required this.inspectOnlyDiagnostic,
    required this.projectSegments,
    required this.nativeFormat,
    required this.nativeSection,
    required this.validation,
    required this.runtimeControlFields,
    required this.toolProfile,
    required this.httpEndpointKey,
    required this.headerKey,
    required this._locationsBuilder,
  });

  @override
  final HarnessId harness;

  @override
  HarnessFacet get facet => HarnessFacet.mcp;

  @override
  final McpHarness mcpHarness;

  @override
  final Set<McpScope> supportedScopes;

  @override
  final Set<McpScope> inspectOnlyScopes;

  @override
  final String? inspectOnlyDiagnostic;

  @override
  final List<String> projectSegments;

  @override
  final McpNativeFormat nativeFormat;

  @override
  final McpNativeSection nativeSection;

  @override
  final McpValidationContract validation;

  @override
  String get conversionProfile => 'mcp-${mcpHarness.wireName}-native-v1';

  @override
  final Set<String> runtimeControlFields;

  @override
  final String? toolProfile;

  @override
  Set<String> get stdioTransportKeys => validation.stdioTransportKeys;

  @override
  Set<String> get httpTransportKeys => validation.httpTransportKeys;

  @override
  final String httpEndpointKey;

  @override
  final String headerKey;

  final _LocationBuilder _locationsBuilder;

  @override
  List<McpNativeLocation> locations(McpHarnessRoots roots) =>
      _locationsBuilder(this, roots);

  @override
  McpNativeLocation projectLocation(p.Context path, String root) {
    var current = root;
    for (final segment in projectSegments) {
      current = path.join(current, segment);
    }
    return _location(McpScope.project, current);
  }

  @override
  String sectionKey(McpNativeSection section) => switch (section) {
    McpNativeSection.mcpServers => 'mcpServers',
    McpNativeSection.codexMcpServers => 'mcp_servers',
    McpNativeSection.claudeLocalProjects => 'projects',
  };

  @override
  McpCanonicalRegistration importNative(McpImportRequest request) =>
      mcpImportNative(this, request);

  @override
  McpExportResult exportCanonical(McpExportRequest request) =>
      mcpExportCanonical(this, request);

  McpNativeLocation _location(
    McpScope scope,
    String path, {
    McpNativeSection? section,
    String? projectKey,
  }) => McpNativeLocation(
    harness: mcpHarness,
    scope: scope,
    path: path,
    format: nativeFormat,
    section: section ?? nativeSection,
    projectKey: projectKey,
  );
}

List<McpNativeLocation> _claudeLocations(
  _ConfiguredMcpHarnessSpec spec,
  McpHarnessRoots roots,
) {
  final homeFile = roots.path.join(roots.requireHome(), '.claude.json');
  return <McpNativeLocation>[
    spec.projectLocation(roots.path, roots.projectRoot),
    spec._location(McpScope.user, homeFile),
    spec._location(
      McpScope.local,
      homeFile,
      section: McpNativeSection.claudeLocalProjects,
      projectKey: roots.projectRoot,
    ),
  ];
}

List<McpNativeLocation> _codexLocations(
  _ConfiguredMcpHarnessSpec spec,
  McpHarnessRoots roots,
) => <McpNativeLocation>[
  spec._location(
    McpScope.user,
    roots.path.join(roots.codexRoot(), 'config.toml'),
  ),
  spec.projectLocation(roots.path, roots.projectRoot),
];

List<McpNativeLocation> _piLocations(
  _ConfiguredMcpHarnessSpec spec,
  McpHarnessRoots roots,
) => <McpNativeLocation>[
  spec._location(
    McpScope.user,
    roots.path.join(roots.piAgentRoot(), 'mcp.json'),
  ),
  spec.projectLocation(roots.path, roots.projectRoot),
];

List<McpNativeLocation> _antigravityLocations(
  _ConfiguredMcpHarnessSpec spec,
  McpHarnessRoots roots,
) => <McpNativeLocation>[
  spec.projectLocation(roots.path, roots.projectRoot),
  spec._location(
    McpScope.user,
    roots.path.join(roots.geminiConfigRoot(), 'mcp_config.json'),
  ),
];
