import 'dart:async';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../installation/resource_catalog.dart';

const acquisitionDeadline = Duration(seconds: 120);

enum AcquisitionSourceKind { collection, resource }

enum AcquisitionLocatorKind { local, git, http, archive }

final class AcquisitionRequest {
  const AcquisitionRequest({
    required this.locator,
    required this.cwd,
    required this.resourceType,
    this.sourceKind,
    this.ref,
    this.subpath,
    this.deadline = acquisitionDeadline,
  });

  final String locator;
  final String cwd;
  final CatalogResourceType resourceType;
  final AcquisitionSourceKind? sourceKind;
  final String? ref;
  final String? subpath;
  final Duration deadline;
}

final class AcquisitionProvenance {
  const AcquisitionProvenance({
    required this.kind,
    required this.requestedLocator,
    required this.resolvedLocator,
    required this.subpath,
    required this.temporary,
    required this.directFile,
    required this.durableLocalDirectory,
    this.requestedRef,
    this.resolvedCommit,
    this.downloadDigest,
    this.configDigest,
  });

  final AcquisitionLocatorKind kind;
  final String requestedLocator;
  final String resolvedLocator;
  final String? subpath;
  final bool temporary;
  final bool directFile;
  final bool durableLocalDirectory;
  final String? requestedRef;
  final String? resolvedCommit;
  final String? downloadDigest;
  final String? configDigest;

  AcquisitionProvenance withConfigDigest(String digest) =>
      AcquisitionProvenance(
        kind: kind,
        requestedLocator: requestedLocator,
        resolvedLocator: resolvedLocator,
        subpath: subpath,
        temporary: temporary,
        directFile: directFile,
        durableLocalDirectory: durableLocalDirectory,
        requestedRef: requestedRef,
        resolvedCommit: resolvedCommit,
        downloadDigest: downloadDigest,
        configDigest: digest,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'requestedLocator': requestedLocator,
    'resolvedLocator': resolvedLocator,
    if (subpath != null) 'subpath': subpath,
    'temporary': temporary,
    if (directFile) 'packageBoundary': 'single-file',
    if (requestedRef != null) 'requestedRef': requestedRef,
    if (resolvedCommit != null) 'resolvedCommit': resolvedCommit,
    if (downloadDigest != null) 'downloadDigest': downloadDigest,
    if (configDigest != null) 'configDigest': configDigest,
  };
}

/// A scoped, inert local view of an acquired source. Remote implementations
/// own their temporary directory here; local sources are never deleted.
final class AcquisitionWorkspace {
  AcquisitionWorkspace({
    required this.selectedRoot,
    required this.selectedFile,
    required this.provenance,
    this._temporaryDirectory,
  });

  final String selectedRoot;
  final String? selectedFile;
  final AcquisitionProvenance provenance;
  final Directory? _temporaryDirectory;
  var _closed = false;

  String resolveOffering(CatalogOffering offering) {
    if (selectedFile != null) {
      throw MambaException(
        'A direct downloaded configuration cannot authorize crawling its host '
        'for catalog entries; select a repository or archive.',
        exitCode: 1,
      );
    }
    final segments = offering.path == '.'
        ? const <String>[]
        : offering.path.split('/');
    final resolved = p.normalize(p.joinAll([selectedRoot, ...segments]));
    if (!p.equals(resolved, selectedRoot) &&
        !p.isWithin(selectedRoot, resolved)) {
      throw MambaException(
        'A catalog entry escapes its source root.',
        exitCode: 4,
      );
    }
    if (FileSystemEntity.typeSync(resolved, followLinks: false) ==
        FileSystemEntityType.link) {
      throw MambaException(
        'A catalog entry must not be a linked source alias: ${offering.id}',
        exitCode: 4,
      );
    }
    return resolved;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final temporary = _temporaryDirectory;
    if (temporary == null) return;
    try {
      if (temporary.existsSync()) await temporary.delete(recursive: true);
    } on FileSystemException catch (error) {
      throw MambaException(
        'Required acquisition cleanup is pending for ${temporary.path}: '
        '${error.message}',
        exitCode: 6,
      );
    }
  }
}

/// Resolves explicit source locators into bounded local workspaces. It never
/// executes source content, installs tools, or scans for resource candidates.
interface class AcquisitionService {
  const AcquisitionService();

  Future<AcquisitionWorkspace> acquire(AcquisitionRequest request) async {
    final locator = request.locator;
    if (locator.trim().isEmpty) {
      throw MambaException('The installation source must not be blank.');
    }
    if (_isLocal(locator)) {
      if (request.ref != null) {
        throw MambaException('--ref applies only to Git sources.');
      }
      return _local(request);
    }
    throw MambaException(
      'The source scheme is unsupported or its acquisition provider is not '
      'available. Use an explicit local path or supported Git/HTTPS source.',
      exitCode: 3,
    );
  }

  AcquisitionWorkspace _local(AcquisitionRequest request) {
    final selected = p.normalize(
      p.isAbsolute(request.locator)
          ? request.locator
          : p.join(request.cwd, request.locator),
    );
    var root = selected;
    if (request.subpath != null) {
      _validateSubpath(request.subpath!);
      root = p.normalize(p.joinAll([selected, ...request.subpath!.split('/')]));
      if (!p.equals(root, selected) && !p.isWithin(selected, root)) {
        throw MambaException(
          '--subpath escapes the selected source.',
          exitCode: 4,
        );
      }
    }
    final type = FileSystemEntity.typeSync(root, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException(
        'The selected source does not exist: $root',
        exitCode: 3,
      );
    }
    if (type == FileSystemEntityType.link) {
      throw MambaException(
        'The selected source root must not be a link: $root',
        exitCode: 4,
      );
    }
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.file) {
      throw MambaException(
        'The selected source is not a regular file or directory: $root',
        exitCode: 2,
      );
    }
    if (type == FileSystemEntityType.file && request.subpath != null) {
      throw MambaException(
        '--subpath requires a directory, repository, or archive source.',
      );
    }
    final directFile = type == FileSystemEntityType.file;
    if (directFile) {
      final temporary = Directory.systemTemp.createTempSync(
        'agent-resource-direct-file-',
      );
      try {
        final stagedFile = p.join(temporary.path, p.basename(root));
        File(root).copySync(stagedFile);
        return AcquisitionWorkspace(
          selectedRoot: temporary.path,
          selectedFile: stagedFile,
          provenance: AcquisitionProvenance(
            kind: AcquisitionLocatorKind.local,
            requestedLocator: sanitizeLocator(request.locator),
            resolvedLocator: p.normalize(selected),
            subpath: request.subpath,
            temporary: true,
            directFile: true,
            durableLocalDirectory: false,
          ),
          temporaryDirectory: temporary,
        );
      } on Exception {
        if (temporary.existsSync()) temporary.deleteSync(recursive: true);
        rethrow;
      }
    }
    return AcquisitionWorkspace(
      selectedRoot: root,
      selectedFile: null,
      provenance: AcquisitionProvenance(
        kind: AcquisitionLocatorKind.local,
        requestedLocator: sanitizeLocator(request.locator),
        resolvedLocator: p.normalize(selected),
        subpath: request.subpath,
        temporary: false,
        directFile: false,
        durableLocalDirectory: true,
      ),
    );
  }
}

bool _isLocal(String locator) {
  if (p.isAbsolute(locator) ||
      locator.startsWith('.') ||
      locator.contains(r'\')) {
    return true;
  }
  final uri = Uri.tryParse(locator);
  return uri == null || !uri.hasScheme;
}

void _validateSubpath(String subpath) {
  if (subpath.isEmpty ||
      subpath == '.' ||
      subpath.endsWith('/') ||
      subpath.contains(r'\') ||
      subpath.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(subpath) ||
      subpath
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw MambaException(
      '--subpath must be a nonempty forward-slash source-relative path.',
    );
  }
}

String sanitizeLocator(String locator) {
  final uri = Uri.tryParse(locator);
  if (uri == null || !uri.hasScheme || _isLocal(locator)) return locator;
  return uri.replace(userInfo: '', query: null, fragment: null).toString();
}
