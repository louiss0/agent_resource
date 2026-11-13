import 'package:mamba/mamba.dart';

import 'prompt_native_view.dart';

/// Completed native validation with blocking views, not an operational error.
final class PromptValidationFailure(final PromptNativeViews report)
    extends MambaException {
  this
    : super(
        'The source is not a valid Prompt for the selected views.',
        exitCode: 2,
      );
}
