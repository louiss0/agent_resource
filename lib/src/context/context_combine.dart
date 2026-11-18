import 'package:mamba/mamba.dart';

/// Deterministic byte combination for create, append, and replace.
final class ContextCombine {
  const ContextCombine();

  /// Combines [existingContent] with the template's [content].
  String call({
    required String? existingContent,
    required String content,
    required bool replace,
  }) => combineContextContent(
    existingContent: existingContent,
    templateContent: content,
    replace: replace,
  );
}

/// Combines stored template text with the observed target text.
///
/// Appends use exactly one blank-line separator and normalize leading and
/// trailing newlines. An empty template can never be appended to a populated
/// context file.
String combineContextContent({
  required String? existingContent,
  required String templateContent,
  required bool replace,
}) {
  String ensureTrailingNewline(String text) =>
      text.isEmpty ? '' : (text.endsWith('\n') ? text : '$text\n');

  if (existingContent == null || replace || existingContent.isEmpty) {
    return ensureTrailingNewline(templateContent);
  }
  if (templateContent.isEmpty) {
    throw MambaException(
      'EMPTY_TEMPLATE_APPEND_REFUSED: Cannot append an empty context '
      'template to a non-empty context file; pass --replace or populate '
      'the template first.',
      exitCode: 4,
    );
  }
  final trimmedExisting = existingContent.replaceFirst(RegExp(r'[\r\n]+$'), '');
  final trimmedTemplate = templateContent.replaceFirst(RegExp(r'^[\r\n]+'), '');
  return ensureTrailingNewline('$trimmedExisting\n\n$trimmedTemplate');
}
