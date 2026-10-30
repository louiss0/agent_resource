import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'source.dart';
import 'src/services/pack_lifecycle_service.dart';

final class AgentsCommand extends GroupCommand {
  new({PackLifecycleService? service})
    : this._(service ?? PackLifecycleService());

  AgentsCommand._(PackLifecycleService service)
    : super([
        ...packLifecycleCommands(PackResourceType.agent, service),
        PackSourceCommand(PackResourceType.agent, service),
      ]);

  @override
  String get name => 'agents';

  @override
  String get shortDescription =>
      'Manage source-aware native Agent collections.';
}
