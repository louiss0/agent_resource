import 'mcp_types.dart';

/// The parser used for a native configuration file.
enum McpNativeFormat { json, toml }

/// Which part of a parsed document holds the named server entries.
enum McpNativeSection { mcpServers, claudeLocalProjects, codexMcpServers }

/// One bounded, read-only native configuration location.
final class McpNativeLocation {
  const McpNativeLocation({
    required this.harness,
    required this.scope,
    required this.path,
    required this.format,
    required this.section,
    this.projectKey,
  });

  final McpHarness harness;
  final McpScope scope;
  final String path;
  final McpNativeFormat format;
  final McpNativeSection section;

  /// The `projects` map key for Claude local scope.
  final String? projectKey;
}
