import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'agent.dart';
import 'authoring.dart';
import 'config.dart';
import 'skill.dart';
import 'pack.dart';
import 'prompt.dart';
import 'mcp.dart';
import 'src/services/conversion_coordinator_service.dart';
import 'src/services/conversion_restore_service.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/agent_authoring_service.dart';
import 'src/services/agent_conversion_service.dart';
import 'src/services/agent_graph_service.dart';
import 'src/services/agent_installation_service.dart';
import 'src/services/agent_lifecycle_service.dart';
import 'src/services/authoring_recovery_service.dart';
import 'src/services/guided_authoring_service.dart';
import 'src/services/instruction_draft_service.dart';
import 'src/services/mcp_conversion_service.dart';
import 'src/services/mcp_inspection_service.dart';
import 'src/services/mcp_mutation_service.dart';
import 'src/services/mcp_recovery_service.dart';
import 'src/services/mcp_validation_service.dart';
import 'src/services/pack_lifecycle_service.dart';
import 'src/services/parent_config_service.dart';
import 'src/services/prompt_read_service.dart';
import 'src/services/skill_installation_service.dart';
import 'src/services/skill_lifecycle_service.dart';

import 'context.dart';
import 'src/services/context_template_service.dart';
import 'components/installation_approval.dart';

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
  ConversionRestoreService? conversionRestore,
  AuthoringRecoveryService? authoringRecovery,
  InstructionDraftService? instructionDrafts,
  GuidedAuthoringService? guided,
  PromptReadService? promptRead,
  PackLifecycleService? packLifecycle,
  McpInspectionService? mcpInspection,
  McpValidationService? mcpValidation,
  McpMutationService? mcpMutation,
  McpRecoveryService? mcpRecovery,
  McpConversionService? mcpConversion,
  ContextTemplateService? contextTemplates,
  InstallationApprovalComponent? contextDeleteApproval,
}) {
  final guidedService =
      guided ?? GuidedAuthoringService(fileSystem: fileSystem);
  return Executor(
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
        restore:
            conversionRestore ??
            ConversionRestoreService(
              io: LifecycleIO(fs: fileSystem),
              state: LifecycleStateService(io: LifecycleIO(fs: fileSystem)),
            ),
        read: promptRead,
        guided: guidedService,
        fileSystem: fileSystem,
      ),
      AuthoringCommand(
        authoringRecovery ??
            AuthoringRecoveryService(
              fileSystem: fileSystem,
              state: LifecycleStateService(io: LifecycleIO(fs: fileSystem)),
            ),
        drafts: instructionDrafts,
        fileSystem: fileSystem,
      ),
      SkillCommand(
        installation: skillInstallation,
        lifecycle: skillLifecycle,
        guided: guidedService,
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
        guided: guidedService,
      ),
      PackCommand(service: packLifecycle, fileSystem: fileSystem),
      ConfigCommand(service: packLifecycle, fileSystem: fileSystem),
      McpCommand(
        inspection: mcpInspection,
        validation:
            mcpValidation ?? McpValidationService(fileSystem: fileSystem),
        mutation: mcpMutation,
        recovery: mcpRecovery,
        conversion: mcpConversion,
        fileSystem: fileSystem,
      ),
      ContextCommand(
        contextTemplates: contextTemplates,
        fileSystem: fileSystem,
        deleteApproval: contextDeleteApproval,
      ),
    ],
  );
}
