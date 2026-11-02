import 'package:agent_resource/src/installation/installation_request.dart';
import 'package:agent_resource/src/installation/resource_catalog.dart';
import 'package:agent_resource/src/services/acquisition_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

import '../../support/installation_test_support.dart';

void main() {
  late fslib.FileSystem fs;
  late fslib.Directory root;
  setUp(() {
    fs = MemoryFileSystem(style: FileSystemStyle.posix);
    root = fs.directory('/sandbox')..createSync();
  });

  Future<InstallationCandidateSet?> resolve({
    List<String> omitted = const [],
    String? subpath,
    AcquisitionSourceKind? kind,
  }) {
    return resolveInstallationCandidates(
      workspace: AcquisitionWorkspace(
        selectedRoot: root.path,
        selectedFile: null,
        omittedLinkPaths: omitted,
        provenance: AcquisitionProvenance(
          kind: AcquisitionLocatorKind.git,
          requestedLocator: 'owner/repo',
          resolvedLocator: 'https://github.com/owner/repo',
          subpath: subpath,
          temporary: true,
          directFile: false,
          durableLocalDirectory: false,
        ),
        fileSystem: fs,
      ),
      request: InstallationWorkflowRequest(
        source: 'owner/repo',
        options: LifecycleOptions(processWorkingDirectory: root.path),
        sourceKind: kind,
        resourceIds: const [],
        allResources: kind != AcquisitionSourceKind.resource,
        targets: const [],
        method: null,
        profile: null,
        ref: null,
        subpath: subpath,
        scopeExplicit: true,
      ),
      interaction: ScriptedInstallationInteraction(interactive: false),
      resourceType: CatalogResourceType.skill,
      interactive: false,
      fileSystem: fs,
    );
  }

  void marker(String relative) {
    final directory = fs.directory(fs.path.join(root.path, relative))
      ..createSync(recursive: true);
    fs
        .file(fs.path.join(directory.path, 'SKILL.md'))
        .writeAsStringSync(
          '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
        );
  }

  test(
    'unrelated omitted Git symlink does not block discovered Skill',
    () async {
      marker('skills/review');
      final result = await resolve(omitted: ['AGENTS.md']);
      expect(result!.candidates.single.id, 'skills/review');
    },
  );

  for (final subpath in [null, 'packages/catalog']) {
    test('selected package symlink is refused with subpath $subpath', () async {
      marker('skills/review');
      final link = [?subpath, 'skills/review/reference.md'].join('/');
      await expectLater(
        resolve(omitted: [link], subpath: subpath),
        throwsA(
          isA<MambaException>()
              .having((e) => e.exitCode, 'status', 4)
              .having(
                (e) => e.message,
                'message',
                contains('unsupported Git symlink'),
              ),
        ),
      );
    });
  }

  test(
    'exact root Skill cannot silently lose an omitted Git symlink',
    () async {
      marker('.');
      await expectLater(
        resolve(
          omitted: ['reference.md'],
          kind: AcquisitionSourceKind.resource,
        ),
        throwsA(
          isA<MambaException>()
              .having((e) => e.exitCode, 'status', 4)
              .having(
                (e) => e.message,
                'message',
                contains('unsupported Git symlink'),
              ),
        ),
      );
    },
  );

  test('empty tree explains expected Skill marker', () async {
    await expectLater(
      resolve(),
      throwsA(
        isA<MambaException>()
            .having((e) => e.exitCode, 'status', 2)
            .having((e) => e.message, 'message', contains('No Skills found')),
      ),
    );
  });
}
