import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/installation/resource_catalog.dart';
import 'package:archive/archive.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AcquisitionService', () {
    late Directory sandbox;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('acquisition-local-');
    });

    tearDown(() async {
      if (sandbox.existsSync()) await sandbox.delete(recursive: true);
    });

    AcquisitionRequest request(
      String locator, {
      String? subpath,
      String? ref,
      AcquisitionSourceKind? sourceKind,
      Duration deadline = acquisitionDeadline,
    }) => AcquisitionRequest(
      locator: locator,
      cwd: sandbox.path,
      resourceType: CatalogResourceType.skill,
      subpath: subpath,
      ref: ref,
      sourceKind: sourceKind,
      deadline: deadline,
    );

    test(
      'selects a local collection root without scanning or cleanup',
      () async {
        final collection = Directory(p.join(sandbox.path, 'collection'))
          ..createSync();
        File(p.join(collection.path, sourceConfigFileName))
            .writeAsStringSync('schema_version = 1\n');
        final nested = Directory(p.join(collection.path, 'nested'))
          ..createSync();
        File(p.join(nested.path, 'sentinel.txt'))
            .writeAsStringSync('unchanged');

        final workspace = await AcquisitionService().acquire(
          request('collection', sourceKind: AcquisitionSourceKind.collection),
        );
        await workspace.close();

        expect(workspace.selectedRoot, collection.path);
        expect(workspace.provenance.kind, AcquisitionLocatorKind.local);
        expect(workspace.provenance.requestedLocator, 'collection');
        expect(workspace.provenance.durableLocalDirectory, isTrue);
        expect(workspace.provenance.temporary, isFalse);
        expect(nested.existsSync(), isTrue);
        expect(
          File(p.join(nested.path, 'sentinel.txt')).readAsStringSync(),
          'unchanged',
        );
      },
    );

    test('applies an explicit subpath and refuses traversal', () async {
      Directory(p.join(sandbox.path, 'repo', 'skills', 'review'))
          .createSync(recursive: true);
      final workspace = await AcquisitionService().acquire(
        request('repo', subpath: 'skills/review'),
      );
      expect(
        workspace.selectedRoot,
        p.join(sandbox.path, 'repo', 'skills', 'review'),
      );
      await workspace.close();

      for (final subpath in [
        '../outside',
        '/absolute',
        r'..\outside',
        'missing',
      ]) {
        expect(
          () => AcquisitionService().acquire(request('repo', subpath: subpath)),
          throwsA(isA<MambaException>()),
        );
      }
    });

    test('retains direct-file boundaries and refuses a subpath', () async {
      final marker = File(p.join(sandbox.path, 'SKILL.md'))
        ..writeAsStringSync('---\nname: review\ndescription: Reviews.\n---\n');
      final workspace = await AcquisitionService().acquire(
        request(marker.path, sourceKind: AcquisitionSourceKind.resource),
      );
      expect(workspace.selectedFile, isNot(marker.path));
      expect(workspace.selectedRoot, isNot(sandbox.path));
      expect(workspace.provenance.directFile, isTrue);
      expect(workspace.provenance.durableLocalDirectory, isFalse);
      final staged = workspace.selectedFile!;
      await workspace.close();
      expect(marker.existsSync(), isTrue);
      expect(File(staged).existsSync(), isFalse);

      expect(
        () => AcquisitionService().acquire(
          request(marker.path, subpath: 'sibling'),
        ),
        throwsA(isA<MambaException>()),
      );
    });

    test(
      'materializes an immutable Git revision without running source helpers',
      () async {
        final fixture = await _GitFixture.create(sandbox);
        final marker = p.join(sandbox.path, 'source-hook-ran');
        File(p.join(fixture.repository.path, '.git', 'hooks', 'post-checkout'))
            .writeAsStringSync('#!/bin/sh\ntouch "$marker"\n');
        File(p.join(fixture.repository.path, '.gitattributes'))
            .writeAsStringSync('*.txt filter=source\n');
        File(p.join(fixture.repository.path, 'review.txt'))
            .writeAsStringSync('selected revision\n');
        fixture
          ..run(<String>['add', '.'])
          ..run(<String>['commit', '-m', 'selected']);
        final commit = fixture.run(<String>['rev-parse', 'HEAD']).trim();
        File(p.join(fixture.repository.path, 'review.txt'))
            .writeAsStringSync('wrong revision\n');
        fixture
          ..run(<String>['add', '.'])
          ..run(<String>['commit', '-m', 'later']);
        fixture.run(<String>['config', 'core.hooksPath', 'hooks']);
        fixture.run(<String>[
          'config',
          'filter.source.clean',
          'touch "$marker"',
        ]);
        fixture.run(<String>[
          'config',
          'filter.source.smudge',
          'touch "$marker"',
        ]);
        fixture.run(<String>['config', 'filter.source.required', 'true']);
        fixture.publish();
        await fixture.serve();
        addTearDown(fixture.dispose);

        final workspace = await AcquisitionService().acquire(
          request(fixture.locator, ref: commit),
        );
        addTearDown(workspace.close);

        expect(
          File(p.join(workspace.selectedRoot, 'review.txt')).readAsStringSync(),
          'selected revision\n',
        );
        expect(workspace.provenance.kind, AcquisitionLocatorKind.git);
        expect(workspace.provenance.requestedRef, commit);
        expect(workspace.provenance.resolvedCommit, commit);
        expect(workspace.provenance.temporary, isTrue);
        expect(File(marker).existsSync(), isFalse);
        expect(
          Directory(p.join(workspace.selectedRoot, '.git')).existsSync(),
          isFalse,
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'downloads one bounded direct file with sanitized digest provenance',
      () async {
        final bytes = utf8.encode('name: review\n');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) {
          request.response
            ..statusCode = HttpStatus.ok
            ..add(bytes)
            ..close();
        });
        final uri = Uri.parse(
          'http://127.0.0.1:${server.port}/catalog.toml?token=redacted#private',
        );

        final workspace = await AcquisitionService().acquire(
          request(uri.toString(), sourceKind: AcquisitionSourceKind.collection),
        );
        addTearDown(workspace.close);

        expect(workspace.selectedFile, isNotNull);
        expect(await File(workspace.selectedFile!).readAsBytes(), bytes);
        expect(workspace.provenance.kind, AcquisitionLocatorKind.http);
        expect(workspace.provenance.directFile, isTrue);
        expect(
          workspace.provenance.downloadDigest,
          sha256.convert(bytes).toString(),
        );
        expect(
          workspace.provenance.requestedLocator,
          isNot(contains('redacted')),
        );
        expect(
          workspace.provenance.requestedLocator,
          isNot(contains('private')),
        );
        expect(
          () => workspace.resolveOffering(_offering('entry', 'skills/review')),
          throwsA(isA<MambaException>()),
        );
      },
    );

    test(
      'extracts a bounded archive and applies its selected subpath',
      () async {
        final archive = Archive()
          ..add(ArchiveFile.directory('package/skills'))
          ..add(
            ArchiveFile.stream(
              'package/skills/review.txt',
              InputMemoryStream(utf8.encode('reviewed')),
            ),
          );
        final bytes = ZipEncoder().encode(archive);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) {
          request.response
            ..add(bytes)
            ..close();
        });

        final workspace = await AcquisitionService().acquire(
          request(
            'http://127.0.0.1:${server.port}/source.zip',
            subpath: 'package/skills',
          ),
        );
        final root = workspace.selectedRoot;
        expect(File(p.join(root, 'review.txt')).readAsStringSync(), 'reviewed');
        expect(workspace.provenance.kind, AcquisitionLocatorKind.archive);
        expect(
          workspace.provenance.downloadDigest,
          sha256.convert(bytes).toString(),
        );
        expect(workspace.provenance.directFile, isFalse);
        await workspace.close();
        expect(Directory(root).existsSync(), isFalse);
      },
    );

    test('uses the resolved archive format after a redirect', () async {
      final bytes = ZipEncoder().encode(
        Archive()..add(ArchiveFile.string('package/review.txt', 'redirected')),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        if (request.uri.path == '/download') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/source.zip')
            ..close();
          return;
        }
        request.response
          ..add(bytes)
          ..close();
      });

      final workspace = await AcquisitionService().acquire(
        request('http://127.0.0.1:${server.port}/download'),
      );
      addTearDown(workspace.close);
      expect(
        File(p.join(workspace.selectedRoot, 'package', 'review.txt'))
            .readAsStringSync(),
        'redirected',
      );
    });

    test('extracts tar.gz and rejects linked archive entries', () async {
      final linked = Archive()
        ..add(
          ArchiveFile.string('package/link', '../outside')
            ..symbolicLink = '../outside'
            ..mode = 0xa1ff,
        );
      final linkedBytes = ZipEncoder().encode(linked);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..add(linkedBytes)
          ..close();
      });
      await expectLater(
        AcquisitionService().acquire(
          request('http://127.0.0.1:${server.port}/linked.zip'),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('link'),
          ),
        ),
      );

      final tar = TarEncoder().encode(
        Archive()
          ..add(ArchiveFile.string('package/review.txt', 'tar contents')),
      );
      final bytes = GZipEncoder().encode(tar);
      final tarServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => tarServer.close(force: true));
      tarServer.listen((request) {
        request.response
          ..add(bytes)
          ..close();
      });
      final workspace = await AcquisitionService().acquire(
        request('http://127.0.0.1:${tarServer.port}/source.tar.gz'),
      );
      addTearDown(workspace.close);
      expect(
        File(p.join(workspace.selectedRoot, 'package', 'review.txt'))
            .readAsStringSync(),
        'tar contents',
      );
    });

    test('rejects duplicate archive members instead of overwriting', () async {
      final archive = Archive()
        ..add(ArchiveFile.string('package/review.txt', 'first'))
        ..add(ArchiveFile.string('package/other.txt', 'second'));
      archive.modifyAtIndex(
        1,
        ArchiveFile.string('package/review.txt', 'second'),
      );
      final bytes = ZipEncoder().encode(archive);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..add(bytes)
          ..close();
      });

      await expectLater(
        AcquisitionService().acquire(
          request('http://127.0.0.1:${server.port}/duplicate.zip'),
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 4)
              .having(
                (error) => error.message,
                'message',
                contains('conflicting'),
              ),
        ),
      );
    });

    test(
      'rejects archive traversal before writing outside the workspace',
      () async {
        final bytes = ZipEncoder().encode(
          Archive()..add(
            ArchiveFile.stream(
              '../outside.txt',
              InputMemoryStream(utf8.encode('unsafe')),
            ),
          ),
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) {
          request.response
            ..add(bytes)
            ..close();
        });

        await expectLater(
          AcquisitionService().acquire(
            request('http://127.0.0.1:${server.port}/source.zip'),
          ),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 4)
                .having(
                  (error) => error.message,
                  'message',
                  contains('archive'),
                ),
          ),
        );
        expect(File(p.join(sandbox.path, 'outside.txt')).existsSync(), isFalse);
      },
    );

    test(
      'bounds redirects and rejects credentials on plaintext HTTP',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var requests = 0;
        server.listen((request) {
          requests++;
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/next')
            ..close();
        });
        final base = 'http://127.0.0.1:${server.port}';

        await expectLater(
          AcquisitionService().acquire(request('$base/start')),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 3)
                .having(
                  (error) => error.message,
                  'message',
                  contains('redirect'),
                ),
          ),
        );
        expect(requests, 6);
        final credentialUri = Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.port,
          path: '/start',
          userInfo: 'test-user:test-credential',
        );
        await expectLater(
          AcquisitionService().acquire(request(credentialUri.toString())),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('credentials'),
                isNot(contains('test-credential')),
              ),
            ),
          ),
        );
      },
    );

    test('applies the deadline across a trickling HTTP response', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        try {
          for (var index = 0; index < 20; index++) {
            request.response.write('chunk');
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          await request.response.close();
        } on HttpException {
          // The overall acquisition deadline deliberately closes the stream.
        }
      });
      final clock = Stopwatch()..start();
      await expectLater(
        AcquisitionService().acquire(
          request(
            'http://127.0.0.1:${server.port}/trickle.txt',
            deadline: const Duration(milliseconds: 100),
          ),
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('deadline'),
          ),
        ),
      );
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test(
      'enforces direct-file input limits and acquisition deadlines',
      () async {
        final oversized = File(p.join(sandbox.path, 'large.bin'));
        oversized.openSync(mode: FileMode.writeOnly)
          ..setPositionSync(64 * 1024 * 1024)
          ..writeByteSync(0)
          ..closeSync();
        await expectLater(
          AcquisitionService().acquire(request(oversized.path)),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('64 MiB'),
            ),
          ),
        );

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          try {
            request.response.write('first');
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 200));
            request.response.write('last');
            await request.response.close();
          } on HttpException {
            // The acquisition deadline deliberately closes the connection.
          }
        });
        await expectLater(
          AcquisitionService().acquire(
            request(
              'http://127.0.0.1:${server.port}/slow.txt',
              deadline: const Duration(milliseconds: 50),
            ),
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              contains('deadline'),
            ),
          ),
        );
      },
    );

    test('rejects refs for local sources before any writes', () {
      expect(
        () => AcquisitionService().acquire(request('.', ref: 'main')),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 1)
              .having((error) => error.message, 'message', contains('--ref')),
        ),
      );
      expect(
        Directory(p.join(sandbox.path, '.agent-resource')).existsSync(),
        isFalse,
      );
    });
  });
}

CatalogOffering _offering(String id, String path) =>
    SkillOffering(id: id, path: path, label: null);

final class _GitFixture {
  _GitFixture(this.sandbox, this.repository);

  final Directory sandbox;
  final Directory repository;
  late final Directory bare;
  late final int port;
  Process? daemon;

  static Future<_GitFixture> create(Directory sandbox) async {
    final repository = Directory(p.join(sandbox.path, 'work'))..createSync();
    final fixture = _GitFixture(sandbox, repository);
    fixture.run(<String>['init', '-q']);
    fixture.run(<String>['config', 'user.name', 'Acquisition Test']);
    fixture.run(<String>[
      'config',
      'user.email',
      'acquisition@example.invalid',
    ]);
    return fixture;
  }

  String get locator => 'git://127.0.0.1:$port/repo.git';

  String run(List<String> arguments) {
    final result = Process.runSync(
      'git',
      arguments,
      workingDirectory: repository.path,
      runInShell: false,
    );
    if (result.exitCode != 0) {
      fail(
        'Git fixture command failed: ${arguments.join(' ')}\n${result.stderr}',
      );
    }
    return result.stdout as String;
  }

  void publish() {
    bare = Directory(p.join(sandbox.path, 'repo.git'));
    final result = Process.runSync('git', <String>[
      'clone',
      '--bare',
      repository.path,
      bare.path,
    ], runInShell: false);
    if (result.exitCode != 0) fail('Could not publish Git fixture.');
  }

  Future<void> serve() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = socket.port;
    await socket.close();
    daemon = await Process.start('git', <String>[
      'daemon',
      '--reuseaddr',
      '--listen=127.0.0.1',
      '--port=$port',
      '--export-all',
      '--base-path=${sandbox.path}',
    ], runInShell: false);
    for (var attempt = 0; attempt < 50; attempt++) {
      try {
        final probe = await Socket.connect(InternetAddress.loopbackIPv4, port);
        await probe.close();
        return;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    fail('Git daemon did not start.');
  }

  Future<void> dispose() async {
    daemon?.kill();
    await daemon?.exitCode;
  }
}
