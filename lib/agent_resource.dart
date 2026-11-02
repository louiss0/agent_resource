import 'package:mamba/mamba.dart';

import 'agent.dart';
import 'agents.dart';
import 'config.dart';
import 'skill.dart';
import 'pack.dart';
import 'skills.dart';
import 'src/services/agent_installation_service.dart';
import 'src/services/pack_lifecycle_service.dart';
import 'src/services/skill_installation_service.dart';

const applicationVersion = String.fromEnvironment(
  'AGENT_RESOURCE_VERSION',
  defaultValue: '0.1.0',
);

/// Creates a fresh executor for the Agent Resource command-line application.
///
/// Keeping composition here lets the production executable and application
/// tests exercise the same metadata and command registration.
Executor createExecutor({
  SkillInstallationService? skillInstallation,
  AgentInstallationService? agentInstallation,
  PackLifecycleService? packLifecycle,
  void Function(String)? deprecationWarning,
}) => Executor(
  'agent_resource',
  'Manage resources consumed by AI coding harnesses.',
  applicationVersion,
  [
    SkillCommand(installation: skillInstallation),
    AgentCommand(installation: agentInstallation),
    PackCommand(service: packLifecycle),
    SkillsCommand(service: packLifecycle, warning: deprecationWarning),
    AgentsCommand(service: packLifecycle, warning: deprecationWarning),
    ConfigCommand(service: packLifecycle),
  ],
);
