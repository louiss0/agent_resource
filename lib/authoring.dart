import 'package:mamba/mamba.dart';

import 'authoring_action.dart';
import 'src/services/authoring_recovery_service.dart';

final class AuthoringCommand extends GroupCommand {
  AuthoringCommand(AuthoringRecoveryService recovery)
    : super([
        for (final action in AuthoringAction.values)
          AuthoringActionCommand(recovery, action),
      ]);

  @override
  String get name => 'authoring';

  @override
  String get shortDescription =>
      'List, inspect, recover, or clean authoring transactions.';
}
