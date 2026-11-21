import 'package:agent_resource/src/agent_inspection.dart';
import 'package:agent_resource/src/context/context_types.dart';
import 'package:agent_resource/src/harness/harness_catalog.dart';
import 'package:agent_resource/src/installation/installation_plan.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/services/parent_config_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:test/test.dart';

void main() {
  test('all harness-named enums translate through one shared helper', () {
    expect(HarnessId.of(AgentHarness.antigravity), HarnessId.antigravity);
    expect(HarnessId.of(ContextHarness.codex), HarnessId.codex);
    expect(HarnessId.of(McpHarness.pi), HarnessId.pi);
    expect(HarnessId.of(InstallationTarget.claude), HarnessId.claude);
    expect(HarnessId.of(SkillHarness.antigravity), HarnessId.antigravity);
    expect(HarnessId.of(ParentHarness.codex), HarnessId.codex);
    expect(HarnessId.of(HarnessId.claude), HarnessId.claude);
    expect(
      () => HarnessId.fromWire('unknown'),
      throwsA(isA<FormatException>()),
    );
  });
}
