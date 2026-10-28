import 'package:mamba/mamba.dart';

import 'agent.dart';
import 'skill.dart';
import 'src/services/agent_installation_service.dart';
import 'src/services/skill_installation_service.dart';

/// Creates a fresh executor for the Agent Resource command-line application.
///
/// Keeping composition here lets the production executable and application
/// tests exercise the same metadata and command registration.
Executor createExecutor({
  SkillInstallationService? skillInstallation,
  AgentInstallationService? agentInstallation,
}) => Executor(
  'agent_resource',
  'Manage resources consumed by AI coding harnesses.',
  '0.0.0',
  [
    SkillCommand(installation: skillInstallation),
    AgentCommand(installation: agentInstallation),
  ],
);
