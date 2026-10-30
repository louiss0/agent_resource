import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'source.dart';
import 'src/services/pack_lifecycle_service.dart';

final class SkillsCommand extends GroupCommand {
  new({PackLifecycleService? service})
    : this._(service ?? PackLifecycleService());

  SkillsCommand._(PackLifecycleService service)
    : super([
        ...packLifecycleCommands(PackResourceType.skill, service),
        PackSourceCommand(PackResourceType.skill, service),
      ]);

  @override
  String get name => 'skills';

  @override
  String get shortDescription => 'Manage source-aware Skill packs.';
}
