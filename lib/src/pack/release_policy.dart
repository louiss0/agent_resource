/// The SemVer range used when advancing an installed release.
enum ReleaseBump { patch, minor, major }

/// A GitHub release candidate with provider evidence kept separate from its tag.
final class const ReleaseCandidate({
  required final String literalTag,
  final bool isDraft = false,
  final bool isPrerelease = false,
  final String? id,
  final String? digest,
}) {
  SemanticVersion? get semanticVersion => SemanticVersion.tryParse(literalTag);
}

/// A parsed SemVer 2.0 version. Build metadata is retained but not ordered.
final class SemanticVersion implements Comparable<SemanticVersion> {
  const SemanticVersion._(
    this.major,
    this.minor,
    this.patch,
    this.prerelease,
    this.build,
  );

  factory SemanticVersion.parse(String literal) {
    final match = _pattern.firstMatch(literal);
    if (match == null) {
      throw FormatException('Not a strict SemVer 2.0 version', literal);
    }

    return SemanticVersion._(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      List.unmodifiable(match.group(4)?.split('.') ?? const <String>[]),
      List.unmodifiable(match.group(5)?.split('.') ?? const <String>[]),
    );
  }

  static SemanticVersion? tryParse(String literal) {
    try {
      return SemanticVersion.parse(literal);
    } on FormatException {
      return null;
    }
  }

  static final _pattern = RegExp(
    r'^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    r'(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );

  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;
  final List<String> build;

  bool get isPrerelease => prerelease.isNotEmpty;

  @override
  int compareTo(SemanticVersion other) {
    final core = major.compareTo(other.major);
    if (core != 0) return core;
    final minorResult = minor.compareTo(other.minor);
    if (minorResult != 0) return minorResult;
    final patchResult = patch.compareTo(other.patch);
    if (patchResult != 0) return patchResult;

    if (prerelease.isEmpty) return other.prerelease.isEmpty ? 0 : 1;
    if (other.prerelease.isEmpty) return -1;

    for (var index = 0; index < prerelease.length; index++) {
      if (index == other.prerelease.length) return 1;
      final result = _comparePrerelease(
        prerelease[index],
        other.prerelease[index],
      );
      if (result != 0) return result;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  static int _comparePrerelease(String first, String second) {
    final firstNumeric = _numericIdentifier.hasMatch(first);
    final secondNumeric = _numericIdentifier.hasMatch(second);
    if (firstNumeric && secondNumeric) {
      return int.parse(first).compareTo(int.parse(second));
    }
    if (firstNumeric) return -1;
    if (secondNumeric) return 1;
    return first.compareTo(second);
  }

  static final _numericIdentifier = RegExp(r'^[0-9]+$');
}

/// Why a release could not be selected without a more explicit invocation.
final class ReleaseSelectionException implements Exception {
  const ReleaseSelectionException(this.message);

  final String message;

  @override
  String toString() => 'ReleaseSelectionException: $message';
}

/// Deterministic release eligibility for one installed resource snapshot.
final class const ReleasePolicy({
  required final ReleaseBump bump,
  final bool includePrerelease = false,
}) {
  /// Selects [exactTag] literally, or the unique highest eligible version.
  ///
  /// Automatic selection requires a SemVer [current] release. Exact selection
  /// supports first installs and non-SemVer tags, and may explicitly select a
  /// draft or prerelease. It never permits a SemVer downgrade or no-op update.
  ReleaseCandidate select({
    required Iterable<ReleaseCandidate> candidates,
    ReleaseCandidate? current,
    String? exactTag,
  }) {
    final available = candidates.toList(growable: false);
    if (exactTag != null) {
      return _selectExact(available, current, exactTag);
    }

    if (current == null) {
      throw const ReleaseSelectionException(
        'First release installation requires an exact literal tag.',
      );
    }
    final currentVersion = current.semanticVersion;
    if (currentVersion == null) {
      throw const ReleaseSelectionException(
        'A non-SemVer current release requires an exact literal tag.',
      );
    }

    final eligible =
        <({ReleaseCandidate candidate, SemanticVersion version})>[];
    for (final candidate in available) {
      if (candidate.isDraft) continue;
      final version = candidate.semanticVersion;
      if (version == null) continue;
      if (!includePrerelease &&
          (candidate.isPrerelease || version.isPrerelease)) {
        continue;
      }
      if (!_isInRange(version, currentVersion)) continue;
      if (version.compareTo(currentVersion) <= 0) continue;
      eligible.add((candidate: candidate, version: version));
    }

    if (eligible.isEmpty) {
      throw const ReleaseSelectionException('No eligible higher release.');
    }

    var highest = eligible.first;
    final tied = <ReleaseCandidate>[highest.candidate];
    for (final entry in eligible.skip(1)) {
      final comparison = entry.version.compareTo(highest.version);
      if (comparison > 0) {
        highest = entry;
        tied
          ..clear()
          ..add(entry.candidate);
      } else if (comparison == 0) {
        tied.add(entry.candidate);
      }
    }
    if (tied.length != 1) {
      throw const ReleaseSelectionException(
        'Equal-precedence releases require an exact literal tag.',
      );
    }
    return highest.candidate;
  }

  ReleaseCandidate _selectExact(
    List<ReleaseCandidate> candidates,
    ReleaseCandidate? current,
    String exactTag,
  ) {
    final matches = candidates
        .where((candidate) => candidate.literalTag == exactTag)
        .toList(growable: false);
    if (matches.isEmpty) {
      throw ReleaseSelectionException(
        'Exact release tag was not found: $exactTag',
      );
    }
    if (matches.length != 1) {
      throw ReleaseSelectionException(
        'Exact release tag is ambiguous: $exactTag',
      );
    }

    final selected = matches.single;
    final currentVersion = current?.semanticVersion;
    final selectedVersion = selected.semanticVersion;
    if (currentVersion != null &&
        selectedVersion != null &&
        selectedVersion.compareTo(currentVersion) <= 0) {
      throw const ReleaseSelectionException(
        'Exact selection must be strictly higher than the current release.',
      );
    }
    return selected;
  }

  bool _isInRange(SemanticVersion candidate, SemanticVersion current) =>
      switch (bump) {
        ReleaseBump.patch =>
          candidate.major == current.major && candidate.minor == current.minor,
        ReleaseBump.minor => candidate.major == current.major,
        ReleaseBump.major => true,
      };
}
