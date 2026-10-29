import 'package:interact2/interact2.dart';

SpinnerState _startSpinner(Spinner spinner) => spinner.interact();

/// interact2 progress with completion on success and cleanup on failure.
final class AcquisitionProgressComponent {
  const AcquisitionProgressComponent({
    this.label = 'Acquiring source',
    this.start = _startSpinner,
  });

  final String label;
  final SpinnerState Function(Spinner) start;

  Future<T> render<T>(Future<T> Function() work) async {
    final progress = spinner();
    final T result;
    try {
      result = await work();
    } catch (_) {
      try {
        progress.failed();
      } catch (_) {
        // A cleanup failure must not replace the acquisition failure.
      }
      rethrow;
    }
    progress.done();
    return result;
  }

  SpinnerState spinner() =>
      start(Spinner(icon: '✓', failedIcon: '✗', rightPrompt: (_) => label));
}
