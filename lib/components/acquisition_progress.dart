import 'package:mamba/mamba.dart';

/// Clix spinner with guaranteed stop/cleanup on success and failure.
final class AcquisitionProgressComponent {
  const AcquisitionProgressComponent({this.label = 'Acquiring source'});

  final String label;

  Future<T> render<T>(Future<T> Function() work) =>
      spinner().whileRunning(work);

  Spinner spinner({SpinnerType type = SpinnerType.dots}) =>
      Spinner(label, type: type);
}
