import 'package:mamba/mamba.dart';

import 'agent.dart';
import 'agents.dart';
import 'config.dart';
import 'skill.dart';
import 'pack.dart';
import 'skills.dart';
import 'src/services/agent_authoring_service.dart';
import 'src/services/agent_conversion_service.dart';
import 'src/services/agent_graph_service.dart';
import 'src/services/agent_installation_service.dart';
import 'src/services/agent_lifecycle_service.dart';
import 'src/services/pack_lifecycle_service.dart';
import 'src/services/parent_config_service.dart';
import 'src/services/skill_installation_service.dart';
import 'src/services/skill_lifecycle_service.dart';

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
  SkillLifecycleService? skillLifecycle,
  AgentInstallationService? agentInstallation,
  AgentLifecycleService? agentLifecycle,
  AgentGraphService? agentGraph,
  ParentConfigService? parentConfig,
  AgentAuthoringService? agentAuthoring,
  AgentConversionService? agentConversion,
  PackLifecycleService? packLifecycle,
  void Function(String)? deprecationWarning,
}) => Executor(
  'agent_resource',
  'Manage resources consumed by AI coding harnesses.',
  applicationVersion,
  [
    SkillCommand(installation: skillInstallation, lifecycle: skillLifecycle),
    AgentCommand(
      installation: agentInstallation,
      lifecycle: agentLifecycle,
      graph: agentGraph,
      parentConfig: parentConfig,
      authoring: agentAuthoring,
      conversion: agentConversion,
    ),
    PackCommand(service: packLifecycle),
    SkillsCommand(service: packLifecycle, warning: deprecationWarning),
    AgentsCommand(service: packLifecycle, warning: deprecationWarning),
    ConfigCommand(service: packLifecycle),
  ],
);
