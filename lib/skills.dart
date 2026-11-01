import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'source.dart';
import 'src/services/pack_lifecycle_service.dart';

final class SkillsCommand extends GroupCommand {
  new({PackLifecycleService? service, void Function(String)? warning})
    : this._(service ?? PackLifecycleService(), warning);

  SkillsCommand._(PackLifecycleService service, void Function(String)? warning)
    : super([
        ...packLifecycleCommands(
          PackResourceType.skill,
          service,
          warning: warning,
        ),
        PackSourceCommand(PackResourceType.skill, service, warning: warning),
      ]);

  @override
  String get name => 'skills';

  @override
  String get shortDescription => 'Deprecated: use pack --type skill.';
}
