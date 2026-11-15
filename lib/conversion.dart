import 'package:mamba/mamba.dart';

import 'conversion_action.dart';
import 'src/services/conversion_coordinator_service.dart';
import 'src/services/conversion_restore_service.dart';

final class ConversionCommand extends GroupCommand {
  ConversionCommand(
    ConversionCoordinator coordinator, {
    ConversionRestoreService? restore,
  }) : super([
         for (final action in ConversionAction.values)
           ConversionActionCommand(coordinator, action, restore: restore),
       ]);

  @override
  String get name => 'conversion';

  @override
  String get shortDescription =>
      'List, inspect, recover, or clean conversion evidence.';
}
