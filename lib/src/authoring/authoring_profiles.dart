import 'package:mamba/mamba.dart';

import '../agent_inspection.dart';
import 'native_field_matrix.dart';

/// The Agent harness that one authoring profile targets.
///
/// The mapping is shared by the plan and the publication: an authoring
/// operation and its publication must agree on the native profile of the
/// target.
AgentHarness agentHarnessForProfile(AuthoringProfile profile) =>
    switch (profile) {
      AuthoringProfile.claude => AgentHarness.claude,
      AuthoringProfile.codex => AgentHarness.codex,
      AuthoringProfile.pi => AgentHarness.pi,
      AuthoringProfile.global => throw MambaException(
        'A global profile does not target an Agent definition.',
        exitCode: 4,
      ),
      AuthoringProfile.antigravity => AgentHarness.antigravity,
    };
