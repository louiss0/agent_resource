import 'package:mamba/mamba.dart';

import 'agent.dart';
import 'agents.dart';
import 'config.dart';
import 'skill.dart';
import 'skills.dart';
import 'src/services/agent_installation_service.dart';
import 'src/services/pack_lifecycle_service.dart';
import 'src/services/skill_installation_service.dart';

/// Creates a fresh executor for the Agent Resource command-line application.
///
/// Keeping composition here lets the production executable and application
/// tests exercise the same metadata and command registration.
Executor createExecutor({
  SkillInstallationService? skillInstallation,
  AgentInstallationService? agentInstallation,
  PackLifecycleService? packLifecycle,
}) => Executor(
  'agent_resource',
  'Manage resources consumed by AI coding harnesses.',
  '0.0.0',
  [
    SkillCommand(installation: skillInstallation),
    AgentCommand(installation: agentInstallation),
    SkillsCommand(service: packLifecycle),
    AgentsCommand(service: packLifecycle),
    ConfigCommand(service: packLifecycle),
  ],
);
