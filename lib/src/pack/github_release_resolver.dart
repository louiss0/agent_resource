import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pack_configuration.dart';
import 'release_policy.dart';

/// The small HTTP surface used by [GithubReleaseResolver].
///
/// Tests can provide a deterministic client without opening sockets. Response
/// headers must contain lower-case field names.
interface class GithubHttpClient {
  const GithubHttpClient();

  Future<GithubHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        return GithubHttpResponse(
          statusCode: response.statusCode,
          headers: _responseHeaders(response.headers),
          body: '',
        );
      }
      final body = await utf8.decodeStream(response);
      return GithubHttpResponse(
        statusCode: response.statusCode,
        headers: _responseHeaders(response.headers),
        body: body,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, String> _responseHeaders(HttpHeaders headers) {
    final result = <String, String>{};
    headers.forEach((name, values) {
      result[name.toLowerCase()] = values.join(',');
    });
    return result;
  }
}

final class const GithubHttpResponse({
  required final int statusCode,
  required final Map<String, String> headers,
  required final String body,
});

final class GithubReleaseResolverException implements Exception {
  const GithubReleaseResolverException(this.message);

  final String message;

  @override
  String toString() => 'GithubReleaseResolverException: $message';
}

final class const GithubRepositoryIdentity({
  required final String host,
  required final String repository,
  required final int id,
});

/// The immutable provider metadata for a selected release.
final class const GithubReleaseEvidence({
  required final GithubRepositoryIdentity repository,
  required final int id,
  required final String literalTag,
  required final bool isDraft,
  required final bool isPrerelease,
  final String? targetCommitish,
  final String? commit,
});

sealed class GithubReleaseAcquisition {
  const GithubReleaseAcquisition();
}

/// Acquire the selected source through Git, retaining the tag separately from
/// any commit evidence supplied by the release response.
final class GithubArchiveAcquisition extends GithubReleaseAcquisition {
  const GithubArchiveAcquisition({
    required this.repositoryUri,
    required this.gitRef,
    this.commit,
  });

  final Uri repositoryUri;
  final String gitRef;
  final String? commit;
}

/// Acquire one named release asset by URL. [digest] is provider-reported asset
/// evidence; it is not the digest of a source archive or extracted content.
final class GithubAttachmentAcquisition extends GithubReleaseAcquisition {
  const GithubAttachmentAcquisition({
    required this.id,
    required this.name,
    required this.downloadUri,
    required this.size,
    this.digest,
  });

  final int id;
  final String name;
  final Uri downloadUri;
  final int size;
  final String? digest;
}

final class const GithubReleaseResolution({
  required final GithubReleaseEvidence release,
  required final GithubReleaseAcquisition acquisition,
});

final class const GithubReleaseInventory({
  required final GithubRepositoryIdentity repository,
  required final List<GithubReleaseEvidence> releases,
});

/// The previously consumed identity and byte evidence for an attachment.
final class const GithubAttachmentEvidence({
  required final int releaseId,
  required final int attachmentId,
  required final String attachmentName,
  required final String digest,
});

/// Resolves release metadata only; it never downloads or executes pack content.
interface class GithubReleaseResolver {
  const GithubReleaseResolver({
    GithubHttpClient httpClient = const GithubHttpClient(),
    String? accessToken,
  }) : this._(httpClient, accessToken);

  const GithubReleaseResolver._(this._httpClient, this._accessToken);

  final GithubHttpClient _httpClient;
  final String? _accessToken;

  Future<GithubReleaseResolution> resolve({
    required GitHubPackSource source,
    required ReleaseTrack track,
    required ReleasePolicy policy,
    ReleaseCandidate? current,
    String? exactTag,
  }) async {
    final apiRoot = source.host.toLowerCase() == 'github.com'
        ? Uri.https('api.github.com')
        : Uri.https(source.host, '/api/v3');
    final repository = await _repository(apiRoot, source);
    final releases = await _allReleases(apiRoot, source);
    final candidates = [
      for (final release in releases)
        ReleaseCandidate(
          literalTag: release.literalTag,
          isDraft: release.isDraft,
          isPrerelease: release.isPrerelease,
          id: release.id.toString(),
        ),
    ];
    final selected = policy.select(
      candidates: candidates,
      current: current,
      exactTag: exactTag,
    );
    final selectedId = selected.id;
    if (selectedId == null) {
      throw const GithubReleaseResolverException(
        'Release selection lost provider identity.',
      );
    }
    final release = releases.singleWhere(
      (candidate) => candidate.id.toString() == selectedId,
    );
    final evidence = GithubReleaseEvidence(
      repository: repository,
      id: release.id,
      literalTag: release.literalTag,
      isDraft: release.isDraft,
      isPrerelease: release.isPrerelease,
      targetCommitish: release.targetCommitish,
      commit: release.commit,
    );
    final repositoryUri = Uri.https(source.host, '/${source.repository}');
    final acquisition = switch (track.artifact) {
      ReleaseArtifact.archive => GithubArchiveAcquisition(
        repositoryUri: repositoryUri,
        gitRef: release.literalTag,
        commit: release.commit,
      ),
      ReleaseArtifact.attachment => _attachment(release, track.attachment!),
    };
    return GithubReleaseResolution(release: evidence, acquisition: acquisition);
  }

  /// Reads verified provider and complete release inventory without choosing
  /// a first-install release. Used by offline configuration resolution.
  Future<GithubReleaseInventory> inspect({
    required GitHubPackSource source,
  }) async {
    final apiRoot = source.host.toLowerCase() == 'github.com'
        ? Uri.https('api.github.com')
        : Uri.https(source.host, '/api/v3');
    final repository = await _repository(apiRoot, source);
    final releases = await _allReleases(apiRoot, source);
    return GithubReleaseInventory(
      repository: repository,
      releases: [
        for (final release in releases)
          GithubReleaseEvidence(
            repository: repository,
            id: release.id,
            literalTag: release.literalTag,
            isDraft: release.isDraft,
            isPrerelease: release.isPrerelease,
            targetCommitish: release.targetCommitish,
            commit: release.commit,
          ),
      ],
    );
  }

  /// Enforces the special review for changed source content at the same release asset.
  ///
  /// Equality of all evidence returns normally. A change requires both a live
  /// interactive invocation and acceptance of this exact [candidate]. [yes]
  /// always rejects a change, including when [interactive] and [accepted] are
  /// also true. Missing or different identity evidence is not byte equality.
  static void requireAcceptedAttachmentChange({
    required GithubAttachmentEvidence previous,
    required GithubReleaseResolution candidate,
    required bool interactive,
    required bool accepted,
    bool yes = false,
  }) {
    final acquisition = candidate.acquisition;
    if (acquisition is! GithubAttachmentAcquisition) {
      throw const GithubReleaseResolverException(
        'Attachment review requires an attachment candidate.',
      );
    }
    if (previous.releaseId != candidate.release.id ||
        previous.attachmentName != acquisition.name) {
      throw const GithubReleaseResolverException(
        'Attachment review does not match the selected release and asset.',
      );
    }
    final digest = acquisition.digest;
    if (digest != null && digest == previous.digest) return;
    if (yes || !interactive || !accepted) {
      throw const GithubReleaseResolverException(
        'Changed or unverified attachment bytes require live interactive '
        'acceptance of the exact candidate; unattended approval cannot accept '
        'this change.',
      );
    }
  }

  Future<GithubRepositoryIdentity> _repository(
    Uri apiRoot,
    GitHubPackSource source,
  ) async {
    final value = await _getJson(apiRoot.resolve('repos/${source.repository}'));
    final map = _object(value, 'repository');
    return GithubRepositoryIdentity(
      host: source.host,
      repository: source.repository,
      id: _integer(map['id'], 'repository.id'),
    );
  }

  Future<List<_GithubRelease>> _allReleases(
    Uri apiRoot,
    GitHubPackSource source,
  ) async {
    final result = <_GithubRelease>[];
    final visited = <Uri>{};
    Uri? next = apiRoot
        .resolve('repos/${source.repository}/releases')
        .replace(queryParameters: const {'per_page': '100', 'page': '1'});
    while (next != null) {
      final uri = next;
      if (!visited.add(uri)) {
        throw const GithubReleaseResolverException(
          'GitHub release pagination contains a cycle; results are incomplete.',
        );
      }
      if (uri.scheme != 'https' || uri.origin != apiRoot.origin) {
        throw const GithubReleaseResolverException(
          'GitHub release pagination left the provider origin.',
        );
      }
      final response = await _get(uri);
      _requireSuccess(response);
      final decoded = _decode(response.body);
      if (decoded is! List) {
        throw const GithubReleaseResolverException(
          'GitHub returned an invalid release page.',
        );
      }
      result.addAll([
        for (final value in decoded) _parseRelease(_object(value, 'release')),
      ]);
      next = _nextPage(response.headers['link'], uri);
    }
    return List.unmodifiable(result);
  }

  Future<Object?> _getJson(Uri uri) async {
    final response = await _get(uri);
    _requireSuccess(response);
    return _decode(response.body);
  }

  Future<GithubHttpResponse> _get(Uri uri) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const GithubReleaseResolverException(
        'GitHub API requests require an HTTPS URL without credentials.',
      );
    }
    return _httpClient.get(
      uri,
      headers: {
        HttpHeaders.acceptHeader: 'application/vnd.github+json',
        HttpHeaders.userAgentHeader: 'agent-resource',
        'X-GitHub-Api-Version': '2022-11-28',
        if (_accessToken case final token?)
          HttpHeaders.authorizationHeader: 'Bearer $token',
      },
    );
  }

  static GithubAttachmentAcquisition _attachment(
    _GithubRelease release,
    String name,
  ) {
    final matches = release.assets
        .where((asset) => asset.name == name)
        .toList(growable: false);
    if (matches.isEmpty) {
      throw GithubReleaseResolverException(
        'Release ${release.literalTag} has no attachment named $name.',
      );
    }
    if (matches.length != 1) {
      throw GithubReleaseResolverException(
        'Release ${release.literalTag} has ambiguous attachment name $name.',
      );
    }
    final asset = matches.single;
    final uri = Uri.tryParse(asset.downloadUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        _hasSensitiveQuery(uri)) {
      throw const GithubReleaseResolverException(
        'GitHub returned an unsafe attachment download URL.',
      );
    }
    return GithubAttachmentAcquisition(
      id: asset.id,
      name: asset.name,
      downloadUri: uri,
      size: asset.size,
      digest: asset.digest,
    );
  }

  static _GithubRelease _parseRelease(Map<String, Object?> map) {
    final target = _optionalString(map['target_commitish'], 'target_commitish');
    return _GithubRelease(
      id: _integer(map['id'], 'release.id'),
      literalTag: _string(map['tag_name'], 'release.tag_name'),
      isDraft: _boolean(map['draft'], 'release.draft'),
      isPrerelease: _boolean(map['prerelease'], 'release.prerelease'),
      targetCommitish: target,
      commit:
          target != null &&
              RegExp(r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$').hasMatch(target)
          ? target
          : null,
      assets: [
        for (final value in _list(map['assets'], 'release.assets'))
          _parseAsset(_object(value, 'release asset')),
      ],
    );
  }

  static _GithubAsset _parseAsset(Map<String, Object?> map) => _GithubAsset(
    id: _integer(map['id'], 'asset.id'),
    name: _string(map['name'], 'asset.name'),
    downloadUrl: _string(map['browser_download_url'], 'asset.download_url'),
    size: _integer(map['size'], 'asset.size'),
    digest: _optionalString(map['digest'], 'asset.digest'),
  );

  static Uri? _nextPage(String? link, Uri current) {
    if (link == null || link.trim().isEmpty) return null;
    for (final part in link.split(',')) {
      final match = RegExp(r'^\s*<([^>]+)>\s*;\s*(.*)$').firstMatch(part);
      if (match == null) continue;
      final relations = RegExp(r'rel\s*=\s*"?([^";\s]+)"?')
          .firstMatch(match.group(2)!);
      if (relations?.group(1)?.split(RegExp(r'\s+')).contains('next') == true) {
        final reference = match.group(1)!;
        final uri = current.resolve(reference);
        if (uri.userInfo.isNotEmpty) {
          throw const GithubReleaseResolverException(
            'GitHub release pagination contains credentials.',
          );
        }
        return uri;
      }
    }
    return null;
  }

  static void _requireSuccess(GithubHttpResponse response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GithubReleaseResolverException(
        'GitHub API returned HTTP ${response.statusCode}.',
      );
    }
  }

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const GithubReleaseResolverException(
        'GitHub returned malformed JSON.',
      );
    }
  }

  static Map<String, Object?> _object(Object? value, String label) {
    if (value is! Map) {
      throw GithubReleaseResolverException('Invalid GitHub $label object.');
    }
    return {
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value as Object?,
    };
  }

  static List<Object?> _list(Object? value, String label) {
    if (value is! List) {
      throw GithubReleaseResolverException('GitHub $label must be an array.');
    }
    return value.cast<Object?>();
  }

  static String _string(Object? value, String label) {
    if (value is! String || value.isEmpty) {
      throw GithubReleaseResolverException('GitHub $label must be a string.');
    }
    return value;
  }

  static String? _optionalString(Object? value, String label) {
    if (value == null) return null;
    return _string(value, label);
  }

  static int _integer(Object? value, String label) {
    if (value is! int || value < 0) {
      throw GithubReleaseResolverException(
        'GitHub $label must be a nonnegative integer.',
      );
    }
    return value;
  }

  static bool _boolean(Object? value, String label) {
    if (value is! bool) {
      throw GithubReleaseResolverException('GitHub $label must be a boolean.');
    }
    return value;
  }

  static bool _hasSensitiveQuery(Uri uri) {
    const sensitive = {
      'access_token',
      'auth',
      'authorization',
      'key',
      'password',
      'signature',
      'token',
      'x-amz-credential',
      'x-amz-signature',
    };
    return uri.queryParameters.keys.any(
      (key) => sensitive.contains(key.toLowerCase()),
    );
  }
}

final class _GithubRelease {
  const _GithubRelease({
    required this.id,
    required this.literalTag,
    required this.isDraft,
    required this.isPrerelease,
    required this.targetCommitish,
    required this.commit,
    required this.assets,
  });

  final int id;
  final String literalTag;
  final bool isDraft;
  final bool isPrerelease;
  final String? targetCommitish;
  final String? commit;
  final List<_GithubAsset> assets;
}

final class _GithubAsset {
  const _GithubAsset({
    required this.id,
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.digest,
  });

  final int id;
  final String name;
  final String downloadUrl;
  final int size;
  final String? digest;
}
