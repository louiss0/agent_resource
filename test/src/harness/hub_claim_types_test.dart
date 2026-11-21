import 'package:agent_resource/src/harness/harness_catalog.dart';
import 'package:agent_resource/src/harness/hub_claim_types.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:test/test.dart';

void main() {
  test('Agent and MCP canonical claims share one wire shape', () async {
    final catalog = HarnessCatalog.instance;
    final agent = catalog
        .agentSpecById(HarnessId.claude)
        .importNativeAgent(
          const AgentImportRequest(
            fields: <String, Object?>{
              'name': 'reviewer',
              'model': 'claude-sonnet',
            },
            sourceForm: 'claude-agent-file',
            sourceProfile: 'claude-agent-native-v1',
          ),
        );
    final mcp = catalog
        .mcpSpec(McpHarness.claude)
        .importNative(
          const McpImportRequest(
            fields: <String, Object?>{'command': 'npx'},
            scope: McpScope.project,
            transport: McpTransport.stdio,
            omitFields: <String>{},
          ),
        );
    expect(agent.claims.first, isA<HubClaimWire>());
    expect(mcp.claims.single, isA<HubClaimWire>());
    for (final claims in <HubClaimsWire>[agent, mcp]) {
      final json = claims.toJsonBase();
      expect(
        json.keys,
        containsAll(<String>['sourceHarness', 'sourceProfile', 'claims']),
      );
      final claim =
          (json['claims']! as List<Object?>).first! as Map<String, Object?>;
      expect(
        claim.keys,
        containsAll(<String>[
          'canonicalPath',
          'sourcePath',
          'kind',
          'provenance',
        ]),
      );
      final provenance = claim['provenance']! as Map<String, Object?>;
      expect(
        provenance.keys,
        containsAll(<String>['sourceHarness', 'sourceProfile', 'sourcePath']),
      );
    }
  });
}
