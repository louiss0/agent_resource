import 'package:mamba/mamba.dart';

import 'conversion_action.dart';
import 'src/services/conversion_coordinator_service.dart';

final class ConversionCommand extends GroupCommand {
  ConversionCommand(ConversionCoordinator coordinator)
    : super([
        for (final action in ConversionAction.values)
          ConversionActionCommand(coordinator, action),
      ]);

  @override
  String get name => 'conversion';

  @override
  String get shortDescription =>
      'List, inspect, recover, or clean conversion evidence.';
}
