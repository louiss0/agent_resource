import 'package:interact2/interact2.dart' as interact;

T runPrompt<T>(T Function() action, {void Function()? reset}) {
  try {
    return action();
  } catch (_) {
    try {
      (reset ?? interact.reset)();
    } catch (_) {
      // Preserve the prompt failure even if terminal restoration fails.
    }
    rethrow;
  }
}
