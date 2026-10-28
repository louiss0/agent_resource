import 'package:mamba/mamba.dart';

final class InstallationApprovalComponent {
  const InstallationApprovalComponent({
    this.label = 'Apply this reviewed installation plan? (Ctrl+C to cancel)',
  });

  final String label;

  Future<bool> render() =>
      Confirm(prompt: label, defaultValue: false).interact();
}
