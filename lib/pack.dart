import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'source.dart';
import 'src/services/pack_lifecycle_service.dart';

final class PackCommand extends GroupCommand {
  new({PackLifecycleService? service})
    : this._(service ?? PackLifecycleService());

  PackCommand._(PackLifecycleService service)
    : super([
        ...packLifecycleCommands(
          PackResourceType.skill,
          service,
          canonical: true,
        ),
        PackSourceCommand(PackResourceType.skill, service, canonical: true),
      ]);

  @override
  String get name => 'pack';

  @override
  String get shortDescription =>
      'Manage configured packs of skills and agents.';
}
