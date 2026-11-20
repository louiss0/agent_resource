import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/mcp_conversion_service.dart';
import 'package:agent_resource/src/services/mcp_mutation_service.dart';
import 'package:agent_resource/src/services/mcp_validation_service.dart';
import 'package:test/test.dart';

void main() {
  test('MCP requests bundle native root overrides without losing flags', () {
    final roots = LifecycleRootOverrides(
      cwd: '/project',
      projectRoot: '/project',
      home: '/home',
      claudeConfigDir: '/claude',
      codexHome: '/codex',
      piAgentDir: '/pi',
      geminiDir: '/gemini',
      stateDir: '/state',
    );
    final conversion = McpConversionRequest(
      environment: const <String, String>{},
      harness: McpHarness.claude,
      scope: McpScope.project,
      name: 'demo',
      targetHarness: McpHarness.antigravity,
      roots: roots,
    );
    final mutation = McpMutationRequest(
      operation: McpMutationOperation.register,
      environment: const <String, String>{},
      harness: McpHarness.claude,
      scope: McpScope.project,
      name: 'demo',
      roots: roots,
    );
    final validation = McpValidationSelectionRequest(
      environment: const <String, String>{},
      harness: McpHarness.claude,
      scope: McpScope.project,
      name: 'demo',
      roots: roots,
    );
    for (final request in <Object>[conversion, mutation, validation]) {
      final bundled = switch (request) {
        McpConversionRequest() => request.roots,
        McpMutationRequest() => request.roots,
        McpValidationSelectionRequest() => request.roots,
        _ => throw StateError('Unexpected request type'),
      };
      expect(bundled.cwd, '/project');
      expect(bundled.geminiDir, '/gemini');
      expect(bundled.stateDir, '/state');
    }
    expect(conversion.cwd, isNull);
    expect(mutation.cwd, isNull);
    expect(validation.cwd, isNull);
  });

  test('the individual flags still build the same bundle', () {
    final request = McpConversionRequest(
      environment: const <String, String>{},
      harness: McpHarness.claude,
      scope: McpScope.project,
      name: 'demo',
      targetHarness: McpHarness.antigravity,
      cwd: '/legacy-project',
      geminiDir: '/legacy-gemini',
    );
    expect(request.roots.cwd, '/legacy-project');
    expect(request.roots.geminiDir, '/legacy-gemini');
    expect(request.roots.codexHome, isNull);
  });
}
