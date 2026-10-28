import 'dart:io';

import 'package:agent_resource/src/installation/resource_catalog.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
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
    }) => AcquisitionRequest(
      locator: locator,
      cwd: sandbox.path,
      resourceType: CatalogResourceType.skill,
      subpath: subpath,
      ref: ref,
      sourceKind: sourceKind,
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
