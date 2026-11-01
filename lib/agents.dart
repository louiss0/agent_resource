import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'source.dart';
import 'src/services/pack_lifecycle_service.dart';

final class AgentsCommand extends GroupCommand {
  new({PackLifecycleService? service, void Function(String)? warning})
    : this._(service ?? PackLifecycleService(), warning);

  AgentsCommand._(PackLifecycleService service, void Function(String)? warning)
    : super([
        ...packLifecycleCommands(
          PackResourceType.agent,
          service,
          warning: warning,
        ),
        PackSourceCommand(PackResourceType.agent, service, warning: warning),
      ]);

  @override
  String get name => 'agents';

  @override
  String get shortDescription => 'Deprecated: use pack --type agent.';
}
