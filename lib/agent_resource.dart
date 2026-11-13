import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'agent.dart';
import 'agents.dart';
import 'authoring.dart';
import 'config.dart';
import 'skill.dart';
import 'pack.dart';
import 'skills.dart';
import 'prompt.dart';
import 'src/services/conversion_coordinator_service.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/agent_authoring_service.dart';
import 'src/services/agent_conversion_service.dart';
import 'src/services/agent_graph_service.dart';
import 'src/services/agent_installation_service.dart';
import 'src/services/agent_lifecycle_service.dart';
import 'src/services/authoring_recovery_service.dart';
import 'src/services/pack_lifecycle_service.dart';
import 'src/services/parent_config_service.dart';
import 'src/services/prompt_read_service.dart';
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
  fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  SkillInstallationService? skillInstallation,
  SkillLifecycleService? skillLifecycle,
  AgentInstallationService? agentInstallation,
  AgentLifecycleService? agentLifecycle,
  AgentGraphService? agentGraph,
  ParentConfigService? parentConfig,
  AgentAuthoringService? agentAuthoring,
  AgentConversionService? agentConversion,
  ConversionCoordinator? conversionRecovery,
  AuthoringRecoveryService? authoringRecovery,
  PromptReadService? promptRead,
  PackLifecycleService? packLifecycle,
  void Function(String)? deprecationWarning,
}) => Executor(
  'agent_resource',
  'Manage resources consumed by AI coding harnesses.',
  applicationVersion,
  [
    PromptCommand(
      conversionRecovery ??
          ConversionCoordinator(
            io: LifecycleIO(fs: fileSystem),
            state: LifecycleStateService(io: LifecycleIO(fs: fileSystem)),
          ),
      read: promptRead,
      fileSystem: fileSystem,
    ),
    AuthoringCommand(
      authoringRecovery ??
          AuthoringRecoveryService(
            fileSystem: fileSystem,
            state: LifecycleStateService(io: LifecycleIO(fs: fileSystem)),
          ),
    ),
    SkillCommand(
      installation: skillInstallation,
      lifecycle: skillLifecycle,
      fileSystem: fileSystem,
    ),
    AgentCommand(
      fileSystem: fileSystem,
      installation: agentInstallation,
      lifecycle: agentLifecycle,
      graph: agentGraph,
      parentConfig: parentConfig,
      authoring: agentAuthoring,
      conversion: agentConversion,
    ),
    PackCommand(service: packLifecycle, fileSystem: fileSystem),
    SkillsCommand(
      service: packLifecycle,
      warning: deprecationWarning,
      fileSystem: fileSystem,
    ),
    AgentsCommand(
      service: packLifecycle,
      warning: deprecationWarning,
      fileSystem: fileSystem,
    ),
    ConfigCommand(service: packLifecycle, fileSystem: fileSystem),
  ],
);
