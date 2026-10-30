import 'dart:convert';

import 'package:agent_resource/src/pack/github_release_resolver.dart';
import 'package:agent_resource/src/pack/pack_configuration.dart'
    hide ReleaseBump;
import 'package:agent_resource/src/pack/release_policy.dart';
import 'package:test/test.dart';

void main() {
  const source = GitHubPackSource(host: 'github.com', repository: 'owner/pack');
  const attachmentTrack = ReleaseTrack(
    artifact: ReleaseArtifact.attachment,
    attachment: 'pack.zip',
  );
  const archiveTrack = ReleaseTrack(artifact: ReleaseArtifact.archive);
  const policy = ReleasePolicy(bump: ReleaseBump.major);

  Map<String, Object?> release(
    int id,
    String tag, {
    bool draft = false,
    bool prerelease = false,
    String target = 'main',
    List<Map<String, Object?>> assets = const [],
  }) => {
    'id': id,
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'target_commitish': target,
    'assets': assets,
  };

  Map<String, Object?> asset(int id, String name, {String? digest}) => {
    'id': id,
    'name': name,
    'browser_download_url': 'https://downloads.example/$name',
    'size': 123,
    'digest': ?digest,
  };

  group('GithubReleaseResolver', () {
    test(
      'paginates completely and retains separate attachment evidence',
      () async {
        final http = FakeGithubHttpClient([
          jsonResponse({'id': 42}),
          jsonResponse(
            [release(10, 'v1.0.0')],
            headers: {
              'link': '<https://api.github.com/repos/owner/pack/releases?per_page=100&page=2>; rel="next", <https://api.github.com/repos/owner/pack/releases?per_page=100&page=2>; rel="last"',
            },
          ),
          jsonResponse([
            release(
              11,
              'v1.1.0',
              target: 'a' * 40,
              assets: [asset(99, 'pack.zip', digest: 'sha256:abc')],
            ),
          ]),
        ]);

        final result = await GithubReleaseResolver(httpClient: http).resolve(
          source: source,
          track: attachmentTrack,
          policy: policy,
          exactTag: 'v1.1.0',
        );

        expect(http.requests, hasLength(3));
        expect(http.requests[1].queryParameters['page'], '1');
        expect(http.requests[2].queryParameters['page'], '2');
        expect(result.release.repository.id, 42);
        expect(result.release.repository.repository, 'owner/pack');
        expect(result.release.id, 11);
        expect(result.release.literalTag, 'v1.1.0');
        expect(result.release.isDraft, isFalse);
        expect(result.release.isPrerelease, isFalse);
        expect(result.release.targetCommitish, 'a' * 40);
        expect(result.release.commit, 'a' * 40);
        final acquisition = result.acquisition as GithubAttachmentAcquisition;
        expect(acquisition.id, 99);
        expect(acquisition.name, 'pack.zip');
        expect(
          acquisition.downloadUri,
          Uri.parse('https://downloads.example/pack.zip'),
        );
        expect(acquisition.digest, 'sha256:abc');
        expect(acquisition.size, 123);
      },
    );

    test(
      'returns Git acquisition with literal tag and available commit',
      () async {
        final http = FakeGithubHttpClient([
          jsonResponse({'id': 42}),
          jsonResponse([release(10, 'release-october', target: 'b' * 40)]),
        ]);

        final result = await GithubReleaseResolver(httpClient: http).resolve(
          source: source,
          track: archiveTrack,
          policy: policy,
          exactTag: 'release-october',
        );

        final acquisition = result.acquisition as GithubArchiveAcquisition;
        expect(
          acquisition.repositoryUri,
          Uri.parse('https://github.com/owner/pack'),
        );
        expect(acquisition.gitRef, 'release-october');
        expect(acquisition.commit, 'b' * 40);
      },
    );

    test('uses ReleasePolicy range, prerelease, and tie behavior', () async {
      Future<GithubReleaseResolution> resolve({
        required bool includePrerelease,
      }) {
        final http = FakeGithubHttpClient([
          jsonResponse({'id': 42}),
          jsonResponse([
            release(10, 'v1.0.1'),
            release(11, 'v1.1.0'),
            release(12, 'v1.0.2-rc.1', prerelease: true),
          ]),
        ]);
        return GithubReleaseResolver(httpClient: http).resolve(
          source: source,
          track: archiveTrack,
          policy: ReleasePolicy(
            bump: ReleaseBump.patch,
            includePrerelease: includePrerelease,
          ),
          current: ReleaseCandidate(literalTag: 'v1.0.0'),
        );
      }

      expect((await resolve(includePrerelease: false)).release.id, 10);
      expect((await resolve(includePrerelease: true)).release.id, 12);

      final tied = FakeGithubHttpClient([
        jsonResponse({'id': 42}),
        jsonResponse([release(10, 'v1.0.1+one'), release(11, 'v1.0.1+two')]),
      ]);
      expect(
        () => GithubReleaseResolver(httpClient: tied).resolve(
          source: source,
          track: archiveTrack,
          policy: const ReleasePolicy(bump: ReleaseBump.patch),
          current: ReleaseCandidate(literalTag: 'v1.0.0'),
        ),
        throwsA(isA<ReleaseSelectionException>()),
      );
    });

    test(
      'fails instead of accepting an incomplete cross-origin page chain',
      () async {
        final http = FakeGithubHttpClient([
          jsonResponse({'id': 42}),
          jsonResponse(
            [release(10, 'v1.0.0')],
            headers: {'link': '<https://elsewhere.example/page2>; rel="next"'},
          ),
        ]);

        expect(
          () => GithubReleaseResolver(httpClient: http).resolve(
            source: source,
            track: archiveTrack,
            policy: policy,
            exactTag: 'v1.0.0',
          ),
          throwsA(
            isA<GithubReleaseResolverException>().having(
              (error) => error.message,
              'message',
              contains('provider origin'),
            ),
          ),
        );
        expect(http.requests, hasLength(1));
      },
    );

    test('rejects an ambiguous named attachment', () async {
      final http = FakeGithubHttpClient([
        jsonResponse({'id': 42}),
        jsonResponse([
          release(
            10,
            'v1.0.0',
            assets: [asset(1, 'pack.zip'), asset(2, 'pack.zip')],
          ),
        ]),
      ]);

      expect(
        () => GithubReleaseResolver(httpClient: http).resolve(
          source: source,
          track: attachmentTrack,
          policy: policy,
          exactTag: 'v1.0.0',
        ),
        throwsA(
          isA<GithubReleaseResolverException>().having(
            (error) => error.message,
            'message',
            contains('ambiguous'),
          ),
        ),
      );
    });

    test(
      'uses API headers without retaining them in resolution evidence',
      () async {
        final http = FakeGithubHttpClient([
          jsonResponse({'id': 42}),
          jsonResponse([release(10, 'v1.0.0')]),
        ]);

        final result =
            await GithubReleaseResolver(
              httpClient: http,
              accessToken: 'secret-token',
            ).resolve(
              source: source,
              track: archiveTrack,
              policy: policy,
              exactTag: 'v1.0.0',
            );

        expect(http.sentHeaders[1]['authorization'], 'Bearer secret-token');
        expect(http.sentHeaders[1]['accept'], 'application/vnd.github+json');
        expect(http.sentHeaders[1]['x-github-api-version'], '2022-11-28');
        expect(result.toString(), isNot(contains('secret-token')));
      },
    );
  });

  group('changed attachment review', () {
    final downloadUri = Uri.parse('https://downloads.example/pack.zip');
    const previous = GithubAttachmentEvidence(
      releaseId: 10,
      attachmentId: 99,
      attachmentName: 'pack.zip',
      digest: 'sha256:old',
    );
    final candidate = GithubReleaseResolution(
      release: GithubReleaseEvidence(
        repository: GithubRepositoryIdentity(
          host: 'github.com',
          repository: 'owner/pack',
          id: 42,
        ),
        id: 10,
        literalTag: 'v1.0.0',
        isDraft: false,
        isPrerelease: false,
      ),
      acquisition: GithubAttachmentAcquisition(
        id: 99,
        name: 'pack.zip',
        downloadUri: downloadUri,
        size: 123,
        digest: 'sha256:new',
      ),
    );

    test('accepts only a live interactive exact-candidate review', () {
      expect(
        () => GithubReleaseResolver.requireAcceptedAttachmentChange(
          previous: previous,
          candidate: candidate,
          interactive: true,
          accepted: true,
        ),
        returnsNormally,
      );
      for (final invocation in [
        (interactive: false, accepted: true, yes: false),
        (interactive: true, accepted: false, yes: false),
        (interactive: true, accepted: true, yes: true),
        (interactive: false, accepted: false, yes: true),
      ]) {
        expect(
          () => GithubReleaseResolver.requireAcceptedAttachmentChange(
            previous: previous,
            candidate: candidate,
            interactive: invocation.interactive,
            accepted: invocation.accepted,
            yes: invocation.yes,
          ),
          throwsA(isA<GithubReleaseResolverException>()),
        );
      }
    });

    test('missing current evidence is not equality and yes cannot bypass', () {
      final unverified = GithubReleaseResolution(
        release: candidate.release,
        acquisition: GithubAttachmentAcquisition(
          id: 99,
          name: 'pack.zip',
          downloadUri: downloadUri,
          size: 123,
        ),
      );
      expect(
        () => GithubReleaseResolver.requireAcceptedAttachmentChange(
          previous: previous,
          candidate: unverified,
          interactive: true,
          accepted: true,
          yes: true,
        ),
        throwsA(isA<GithubReleaseResolverException>()),
      );
    });

    test('equal evidence needs no review and reupload needs live review', () {
      final same = GithubReleaseResolution(
        release: candidate.release,
        acquisition: GithubAttachmentAcquisition(
          id: 99,
          name: 'pack.zip',
          downloadUri: downloadUri,
          size: 123,
          digest: 'sha256:old',
        ),
      );
      expect(
        () => GithubReleaseResolver.requireAcceptedAttachmentChange(
          previous: previous,
          candidate: same,
          interactive: false,
          accepted: false,
          yes: true,
        ),
        returnsNormally,
      );
      final other = GithubReleaseResolution(
        release: candidate.release,
        acquisition: GithubAttachmentAcquisition(
          id: 100,
          name: 'pack.zip',
          downloadUri: downloadUri,
          size: 123,
          digest: 'sha256:new',
        ),
      );
      expect(
        () => GithubReleaseResolver.requireAcceptedAttachmentChange(
          previous: previous,
          candidate: other,
          interactive: true,
          accepted: true,
        ),
        returnsNormally,
      );
      expect(
        () => GithubReleaseResolver.requireAcceptedAttachmentChange(
          previous: previous,
          candidate: other,
          interactive: true,
          accepted: true,
          yes: true,
        ),
        throwsA(isA<GithubReleaseResolverException>()),
      );
      final differentName = GithubReleaseResolution(
        release: candidate.release,
        acquisition: GithubAttachmentAcquisition(
          id: 100,
          name: 'other.zip',
          downloadUri: downloadUri,
          size: 123,
          digest: 'sha256:new',
        ),
      );
      expect(
        () => GithubReleaseResolver.requireAcceptedAttachmentChange(
          previous: previous,
          candidate: differentName,
          interactive: true,
          accepted: true,
        ),
        throwsA(isA<GithubReleaseResolverException>()),
      );
    });
  });
}

final class FakeGithubHttpClient implements GithubHttpClient {
  FakeGithubHttpClient(List<GithubHttpResponse> responses)
    : _responses = List.of(responses);

  final List<GithubHttpResponse> _responses;
  final requests = <Uri>[];
  final sentHeaders = <Map<String, String>>[];

  @override
  Future<GithubHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    requests.add(uri);
    sentHeaders.add({
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    });
    if (_responses.isEmpty) throw StateError('Unexpected request: $uri');
    return _responses.removeAt(0);
  }
}

GithubHttpResponse jsonResponse(
  Object? body, {
  Map<String, String> headers = const {},
}) => GithubHttpResponse(
  statusCode: 200,
  headers: headers,
  body: jsonEncode(body),
);
