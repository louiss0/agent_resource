import 'package:mamba/mamba.dart';

import 'conversion.dart';
import 'src/services/conversion_coordinator_service.dart';

final class PromptCommand extends GroupCommand {
  PromptCommand(ConversionCoordinator coordinator)
    : super([ConversionCommand(coordinator)]);

  @override
  String get name => 'prompt';

  @override
  String get shortDescription =>
      'Inspect and recover native Prompt transactions.';
}
