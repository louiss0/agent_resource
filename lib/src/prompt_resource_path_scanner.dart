/// One blocked resource path segment found in an instruction body.
final class BlockedResourcePath {
  const BlockedResourcePath({required this.matchStart, required this.segment});

  /// The offset of the whole match, including any boundary character.
  final int matchStart;

  /// The blocked path segment, such as `references`.
  final String segment;
}

/// A lexical scan for path-shaped resource references in instruction bodies.
///
/// The scan recognizes whole `references`, `scripts` or `assets` path segments
/// followed by a separator. It is not path resolution and not intent
/// analysis: it never touches the filesystem and never follows a link.
final class PromptResourcePathScanner {
  /// The whole-segment pattern used for the scan.
  static final RegExp pattern = RegExp(
    r'(^|(?<=[/\\\s(<\[\x60\x27\x22=:,;]))(references|scripts|assets)[/\\]',
    multiLine: true,
  );

  /// The blocked path segments in [body], in source order.
  static List<BlockedResourcePath> scan(String body) {
    final matches = <BlockedResourcePath>[];
    for (final match in pattern.allMatches(body)) {
      final segment = match.group(2);
      if (segment == null) continue;
      matches.add(
        BlockedResourcePath(matchStart: match.start, segment: segment),
      );
    }
    return List<BlockedResourcePath>.unmodifiable(matches);
  }
}
