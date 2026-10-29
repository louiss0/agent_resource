import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
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
    this.omittedLinkPaths = const [],
    this._temporaryDirectory,
  });

  final String selectedRoot;
  final String? selectedFile;
  final AcquisitionProvenance provenance;

  /// Source-root-relative Git symlinks omitted from the materialized tree.
  final List<String> omittedLinkPaths;
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
    final clock = Stopwatch()..start();
    final locator = request.locator;
    if (locator.trim().isEmpty) {
      throw MambaException('The installation source must not be blank.');
    }
    final shorthand = RegExp(
      r'^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$',
    ).hasMatch(locator);
    final localExists =
        FileSystemEntity.typeSync(
          p.join(request.cwd, locator),
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound;
    if (_isLocal(locator) && (!shorthand || localExists)) {
      if (request.ref != null) {
        throw MambaException('--ref applies only to Git sources.');
      }
      return _local(request);
    }
    final uri = Uri.tryParse(
      shorthand ? 'https://github.com/$locator' : locator,
    );
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host.toLowerCase() == 'github.com') {
      final segments = uri.pathSegments
          .where((part) => part.isNotEmpty)
          .toList();
      if (segments.length > 2 &&
          (segments[2] == 'tree' || segments[2] == 'blob')) {
        throw MambaException(
          'Use the GitHub repository root with --ref and --subpath instead of a tree or blob page.',
          exitCode: 3,
        );
      }
      if (segments.length == 2 &&
          !uri.path.contains('//') &&
          !uri.hasQuery &&
          !uri.hasFragment) {
        return _git(request, uri, clock);
      }
    }
    if (uri != null && _isGit(uri)) return _git(request, uri, clock);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return _http(request, uri, clock);
    }
    throw MambaException(
      'The source scheme is unsupported or its acquisition provider is not '
      'available. Use an explicit local path or supported Git/HTTPS source.',
      exitCode: 3,
    );
  }

  Future<AcquisitionWorkspace> _git(
    AcquisitionRequest request,
    Uri uri,
    Stopwatch clock,
  ) async {
    _remaining(clock, request.deadline);
    final temporary = await Directory.systemTemp.createTemp(
      'agent-resource-git-',
    );
    try {
      final repository = p.join(temporary.path, 'repository');
      final checkout = p.join(temporary.path, 'source');
      final archive = p.join(temporary.path, 'source.tar');
      final environment = <String, String>{
        ...Platform.environment,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
        'GIT_TERMINAL_PROMPT': '0',
        'GIT_ASKPASS': '',
        'SSH_ASKPASS': '',
      };
      final config = <String>[
        '-c',
        'core.hooksPath=${p.join(temporary.path, 'empty-hooks')}',
        '-c',
        'core.symlinks=false',
        '-c',
        'core.autocrlf=false',
        '-c',
        'protocol.ext.allow=never',
        '-c',
        'protocol.file.allow=never',
        '-c',
        'submodule.recurse=false',
      ];
      Future<String> git(List<String> arguments) => _runGit(
        <String>[...config, ...arguments],
        repository,
        environment,
        clock,
        request.deadline,
      );
      await Directory(p.join(temporary.path, 'empty-hooks')).create();
      await Directory(repository).create();
      await Directory(checkout).create();
      await git(<String>['init', '--quiet', repository]);
      await git(<String>['remote', 'add', 'origin', _gitUri(uri).toString()]);
      await git(<String>[
        'fetch',
        '--depth=1',
        '--no-tags',
        'origin',
        request.ref ?? 'HEAD',
      ]);
      final commit = (await git(<String>['rev-parse', 'FETCH_HEAD'])).trim();
      await _runGitArchive(
        <String>[...config, 'archive', '--format=tar', commit],
        repository,
        environment,
        archive,
        clock,
        request.deadline,
      );
      final omittedLinkPaths = <String>[];
      _extractArchive(
        archive,
        checkout,
        clock,
        request.deadline,
        omittedLinkPaths: omittedLinkPaths,
      );
      await File(archive).delete();
      await Directory(repository).delete(recursive: true);
      await _validateMaterializedTree(checkout, clock, request.deadline);
      final selected = _selectRemoteRoot(checkout, request.subpath);
      return AcquisitionWorkspace(
        selectedRoot: selected,
        selectedFile: null,
        omittedLinkPaths: List.unmodifiable(omittedLinkPaths),
        provenance: AcquisitionProvenance(
          kind: AcquisitionLocatorKind.git,
          requestedLocator: sanitizeLocator(request.locator),
          resolvedLocator: sanitizeLocator(_gitUri(uri).toString()),
          subpath: request.subpath,
          temporary: true,
          directFile: false,
          durableLocalDirectory: false,
          requestedRef: request.ref,
          resolvedCommit: commit,
        ),
        temporaryDirectory: temporary,
      );
    } on Exception {
      await _deleteFailedAcquisition(temporary);
      rethrow;
    }
  }

  Future<AcquisitionWorkspace> _http(
    AcquisitionRequest request,
    Uri uri,
    Stopwatch clock,
  ) async {
    if (request.ref != null) {
      throw MambaException('--ref applies only to Git sources.');
    }
    if (uri.scheme == 'http' && uri.userInfo.isNotEmpty) {
      throw MambaException(
        'Plaintext HTTP sources must not contain credentials.',
        exitCode: 4,
      );
    }
    final temporary = await Directory.systemTemp.createTemp(
      'agent-resource-download-',
    );
    try {
      final name = uri.pathSegments.isEmpty || uri.pathSegments.last.isEmpty
          ? 'download'
          : uri.pathSegments.last;
      final downloaded = p.join(temporary.path, name);
      final result = await _download(uri, downloaded, clock, request.deadline);
      if (_isArchivePath(result.resolved.path)) {
        final extracted = p.join(temporary.path, 'extracted');
        await Directory(extracted).create();
        _extractArchive(
          downloaded,
          extracted,
          clock,
          request.deadline,
          formatPath: result.resolved.path,
        );
        await File(downloaded).delete();
        final selected = _selectRemoteRoot(extracted, request.subpath);
        return AcquisitionWorkspace(
          selectedRoot: selected,
          selectedFile: null,
          provenance: AcquisitionProvenance(
            kind: AcquisitionLocatorKind.archive,
            requestedLocator: sanitizeLocator(request.locator),
            resolvedLocator: sanitizeLocator(result.resolved.toString()),
            subpath: request.subpath,
            temporary: true,
            directFile: false,
            durableLocalDirectory: false,
            downloadDigest: result.digest,
          ),
          temporaryDirectory: temporary,
        );
      }
      if (request.subpath != null) {
        throw MambaException(
          '--subpath requires a directory, repository, or archive source.',
        );
      }
      return AcquisitionWorkspace(
        selectedRoot: temporary.path,
        selectedFile: downloaded,
        provenance: AcquisitionProvenance(
          kind: AcquisitionLocatorKind.http,
          requestedLocator: sanitizeLocator(request.locator),
          resolvedLocator: sanitizeLocator(result.resolved.toString()),
          subpath: null,
          temporary: true,
          directFile: true,
          durableLocalDirectory: false,
          downloadDigest: result.digest,
        ),
        temporaryDirectory: temporary,
      );
    } on Exception {
      await _deleteFailedAcquisition(temporary);
      rethrow;
    }
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
      if (File(root).lengthSync() > _downloadLimit) {
        throw MambaException(
          'The direct file exceeded the 64 MiB input limit.',
          exitCode: 3,
        );
      }
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

const _downloadLimit = 64 * 1024 * 1024;
const _fileLimit = 64 * 1024 * 1024;
const _treeContentLimit = 256 * 1024 * 1024;
const _treeEntryLimit = 20000;
const _treeDepthLimit = 32;

final class _BoundedOutputFileStream extends OutputFileStream {
  _BoundedOutputFileStream(String path, this.maximumLength)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));

  final int maximumLength;

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _reserve(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  void _reserve(int count) {
    if (length + count > maximumLength) {
      throw MambaException(
        'The expanded archive exceeded its bounded processing size.',
        exitCode: 3,
      );
    }
  }
}

bool _isArchivePath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz');
}

void _extractArchive(
  String source,
  String destination,
  Stopwatch clock,
  Duration deadline, {
  String? formatPath,
  List<String>? omittedLinkPaths,
}) {
  InputFileStream? input;
  try {
    final lower = (formatPath ?? source).toLowerCase();
    final encodedNames = <String>{};
    var encodedEntries = 0;
    void validateEncodedEntry(ArchiveFile entry) {
      encodedEntries++;
      if (encodedEntries > _treeEntryLimit) {
        throw MambaException(
          'The archive exceeded the 20,000-entry materialization limit.',
          exitCode: 3,
        );
      }
      final name = entry.name.endsWith('/')
          ? entry.name.substring(0, entry.name.length - 1)
          : entry.name;
      final key = Platform.isWindows ? name.toLowerCase() : name;
      if (!encodedNames.add(key)) {
        throw MambaException(
          'The archive contains conflicting entries.',
          exitCode: 4,
        );
      }
    }

    final Archive archive;
    if (lower.endsWith('.zip')) {
      input = InputFileStream(source);
      archive = ZipDecoder().decodeStream(
        input,
        callback: validateEncodedEntry,
      );
    } else {
      var tarSource = source;
      if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
        tarSource = '$source.tar';
        final compressed = InputFileStream(source);
        final output = _BoundedOutputFileStream(
          tarSource,
          _treeContentLimit + 128 * 1024 * 1024,
        );
        try {
          GZipDecoder().decodeStream(compressed, output, verify: true);
        } finally {
          compressed.close();
          output.closeSync();
        }
      }
      input = InputFileStream(tarSource);
      archive = TarDecoder().decodeStream(
        input,
        callback: validateEncodedEntry,
      );
    }
    var entries = 0;
    var total = 0;
    final materialized = <String, String>{};
    for (final entry in archive) {
      _remaining(clock, deadline);
      entries++;
      if (entries > _treeEntryLimit) {
        throw MambaException(
          'The archive exceeded the 20,000-entry materialization limit.',
          exitCode: 3,
        );
      }
      final name = entry.name;
      final directoryName = entry.isDirectory && name.endsWith('/')
          ? name.substring(0, name.length - 1)
          : name;
      final parts = _validateArchiveName(directoryName);
      if (parts.length > _treeDepthLimit) {
        throw MambaException(
          'The archive exceeded the 32-level materialization depth limit.',
          exitCode: 3,
        );
      }
      final fileType = entry.mode & 0xf000;
      if (entry.isSymbolicLink && omittedLinkPaths != null) {
        omittedLinkPaths.add(directoryName);
        continue;
      }
      if (entry.isSymbolicLink ||
          (fileType != 0 &&
              fileType != 0x8000 &&
              !(entry.isDirectory && fileType == 0x4000))) {
        throw MambaException(
          'The archive contains an unsupported link or special entry.',
          exitCode: 4,
        );
      }
      final target = p.joinAll(<String>[destination, ...parts]);
      if (!p.isWithin(destination, target)) {
        throw MambaException(
          'The archive entry escapes its root.',
          exitCode: 4,
        );
      }
      String keyFor(List<String> segments) {
        final value = segments.join('/');
        return Platform.isWindows ? value.toLowerCase() : value;
      }

      final key = keyFor(parts);
      final duplicate = materialized.containsKey(key);
      final fileParent = <String>[];
      var blockedByFile = false;
      for (final part in parts.take(parts.length - 1)) {
        fileParent.add(part);
        if (materialized[keyFor(fileParent)] == 'file') {
          blockedByFile = true;
        }
      }
      if (duplicate || blockedByFile) {
        throw MambaException(
          'The archive contains conflicting entries.',
          exitCode: 4,
        );
      }
      materialized[key] = entry.isDirectory ? 'directory' : 'file';
      if (entry.isDirectory) {
        Directory(target).createSync(recursive: true);
        continue;
      }
      if (!entry.isFile) {
        throw MambaException(
          'The archive contains an unsupported special entry.',
          exitCode: 4,
        );
      }
      if (entry.size < 0 || entry.size > _fileLimit) {
        throw MambaException(
          'An archive file exceeded the 64 MiB ordinary-file limit.',
          exitCode: 3,
        );
      }
      total += entry.size;
      if (total > _treeContentLimit) {
        throw MambaException(
          'The archive exceeded the 256 MiB materialized-content limit.',
          exitCode: 3,
        );
      }
      File(target).parent.createSync(recursive: true);
      final output = File(target).openSync(mode: FileMode.writeOnly);
      final content = entry.getContent();
      var written = 0;
      try {
        if (content != null) {
          while (!content.isEOS) {
            _remaining(clock, deadline);
            final chunk = content.readBytes(65536).toUint8List();
            written += chunk.length;
            if (written > _fileLimit || written > entry.size) {
              throw MambaException(
                'An archive file exceeded its declared bounded size.',
                exitCode: 3,
              );
            }
            output.writeFromSync(chunk);
          }
        }
        output.flushSync();
      } finally {
        output.closeSync();
      }
      if (written != entry.size) {
        throw MambaException(
          'The archive file content was truncated.',
          exitCode: 3,
        );
      }
    }
  } on ArchiveException {
    throw MambaException(
      'The archive could not be decoded safely.',
      exitCode: 3,
    );
  } on FileSystemException {
    throw MambaException(
      'The archive contains conflicting or unwritable entries.',
      exitCode: 4,
    );
  } finally {
    input?.close();
  }
}

List<String> _validateArchiveName(String name) {
  final parts = name.split('/');
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains(r'\') ||
      name.contains(String.fromCharCode(0)) ||
      RegExp(r'^[A-Za-z]:').hasMatch(name) ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw MambaException(
      'The archive contains an absolute, escaping, or invalid entry path.',
      exitCode: 4,
    );
  }
  return parts;
}

final class _DownloadResult {
  const _DownloadResult(this.resolved, this.digest);
  final Uri resolved;
  final String digest;
}

final class _DigestCollector implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<_DownloadResult> _download(
  Uri initial,
  String destination,
  Stopwatch clock,
  Duration deadline,
) async {
  // HTTP content encoding is transport compression; the decoded resource bytes
  // are what must be validated and installed. The decompressed stream is still
  // counted against the bounded download limit below.
  final client = HttpClient()..autoUncompress = true;
  var expired = false;
  final deadlineTimer = Timer(_remaining(clock, deadline), () {
    expired = true;
    client.close(force: true);
  });
  var uri = initial;
  var authorization = initial.scheme == 'https' && initial.userInfo.isNotEmpty
      ? 'Basic ${base64Encode(utf8.encode(initial.userInfo))}'
      : null;
  try {
    for (var redirects = 0; ; redirects++) {
      final request = await client
          .getUrl(uri.replace(userInfo: ''))
          .timeout(_remaining(clock, deadline));
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      if (authorization != null) {
        request.headers.set(HttpHeaders.authorizationHeader, authorization);
      }
      final response = await request.close().timeout(
        _remaining(clock, deadline),
      );
      if (_isRedirect(response.statusCode)) {
        if (redirects >= 5) {
          await response.drain<void>();
          throw MambaException(
            'The download exceeded the five-redirect limit.',
            exitCode: 3,
          );
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) {
          await response.drain<void>();
          throw MambaException(
            'The download redirect was invalid.',
            exitCode: 3,
          );
        }
        final next = uri.resolve(location);
        if ((next.scheme != 'http' && next.scheme != 'https') ||
            (uri.scheme == 'https' && next.scheme != 'https') ||
            (uri.scheme == 'http' && next.scheme != 'http')) {
          await response.drain<void>();
          throw MambaException(
            'The download redirect violated its transport boundary.',
            exitCode: 3,
          );
        }
        if (next.userInfo.isNotEmpty) {
          await response.drain<void>();
          throw MambaException(
            'The download redirect must not introduce credentials.',
            exitCode: 4,
          );
        }
        if (next.host != uri.host || next.port != uri.port) {
          authorization = null;
        }
        uri = next;
        await response.drain<void>();
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw MambaException(
          'The source download returned HTTP ${response.statusCode}.',
          exitCode: 3,
        );
      }
      if (response.contentLength > _downloadLimit) {
        await response.drain<void>();
        throw MambaException(
          'The download exceeded the 64 MiB input limit.',
          exitCode: 3,
        );
      }
      final collector = _DigestCollector();
      final hashing = sha256.startChunkedConversion(collector);
      final file = File(destination);
      final output = file.openWrite();
      var size = 0;
      try {
        await for (final chunk in response.timeout(
          _remaining(clock, deadline),
        )) {
          size += chunk.length;
          if (size > _downloadLimit) {
            throw MambaException(
              'The download exceeded the 64 MiB input limit.',
              exitCode: 3,
            );
          }
          hashing.add(chunk);
          output.add(chunk);
          await output.flush().timeout(_remaining(clock, deadline));
        }
        hashing.close();
        await output.close().timeout(_remaining(clock, deadline));
      } on TimeoutException {
        await output.close();
        throw MambaException('The acquisition deadline elapsed.', exitCode: 3);
      } on Exception {
        await output.close();
        rethrow;
      }
      return _DownloadResult(uri, collector.value!.toString());
    }
  } on TimeoutException {
    throw MambaException('The acquisition deadline elapsed.', exitCode: 3);
  } on HttpException {
    if (expired) {
      throw MambaException('The acquisition deadline elapsed.', exitCode: 3);
    }
    throw MambaException('The source download failed.', exitCode: 3);
  } on SocketException {
    if (expired) {
      throw MambaException('The acquisition deadline elapsed.', exitCode: 3);
    }
    throw MambaException('The source download failed.', exitCode: 3);
  } on Exception {
    if (expired) {
      throw MambaException('The acquisition deadline elapsed.', exitCode: 3);
    }
    rethrow;
  } finally {
    deadlineTimer.cancel();
    client.close(force: true);
  }
}

bool _isRedirect(int status) =>
    status == HttpStatus.movedPermanently ||
    status == HttpStatus.found ||
    status == HttpStatus.seeOther ||
    status == HttpStatus.temporaryRedirect ||
    status == HttpStatus.permanentRedirect;

bool _isGit(Uri uri) =>
    uri.scheme == 'git' ||
    uri.scheme == 'ssh' ||
    uri.scheme == 'git+https' ||
    (uri.scheme == 'https' && uri.path.endsWith('.git'));

Uri _gitUri(Uri uri) =>
    uri.scheme == 'git+https' ? uri.replace(scheme: 'https') : uri;

Future<void> _runGitArchive(
  List<String> arguments,
  String workingDirectory,
  Map<String, String> environment,
  String destination,
  Stopwatch clock,
  Duration deadline,
) async {
  Process process;
  try {
    process = await Process.start(
      'git',
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    ).timeout(_remaining(clock, deadline));
  } on ProcessException {
    throw MambaException(
      'Git is required for this source but could not be started.',
      exitCode: 3,
    );
  }
  final errors = StringBuffer();
  final stderrDone = _collectProcessOutput(process.stderr, errors);
  final output = File(destination).openWrite();
  var length = 0;
  try {
    await for (final chunk in process.stdout.timeout(
      _remaining(clock, deadline),
    )) {
      length += chunk.length;
      if (length > _treeContentLimit + 128 * 1024 * 1024) {
        throw MambaException(
          'The materialized Git archive exceeded its processing budget.',
          exitCode: 3,
        );
      }
      output.add(chunk);
      await output.flush().timeout(_remaining(clock, deadline));
    }
    await output.close().timeout(_remaining(clock, deadline));
    final exitCode = await process.exitCode.timeout(
      _remaining(clock, deadline),
    );
    await stderrDone;
    if (exitCode != 0) {
      throw MambaException(
        'Git could not materialize the requested source or revision.',
        exitCode: 3,
      );
    }
  } on TimeoutException {
    process.kill();
    await output.close();
    await process.exitCode;
    await stderrDone;
    throw MambaException('The acquisition deadline elapsed.', exitCode: 3);
  } on Exception {
    process.kill();
    await output.close();
    await process.exitCode;
    await stderrDone;
    rethrow;
  }
}

Future<String> _runGit(
  List<String> arguments,
  String workingDirectory,
  Map<String, String> environment,
  Stopwatch clock,
  Duration deadline,
) async {
  Process process;
  try {
    process = await Process.start(
      'git',
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    ).timeout(_remaining(clock, deadline));
  } on ProcessException {
    throw MambaException(
      'Git is required for this source but could not be started.',
      exitCode: 3,
    );
  }
  final output = StringBuffer();
  final errors = StringBuffer();
  final stdoutDone = _collectProcessOutput(process.stdout, output);
  final stderrDone = _collectProcessOutput(process.stderr, errors);
  try {
    final exitCode = await process.exitCode.timeout(
      _remaining(clock, deadline),
    );
    await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
    if (exitCode != 0) {
      throw MambaException(
        'Git could not materialize the requested source or revision.',
        exitCode: 3,
      );
    }
    return output.toString();
  } on TimeoutException {
    process.kill();
    await process.exitCode;
    await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
    throw MambaException('The acquisition deadline elapsed.', exitCode: 3);
  } on MambaException {
    process.kill();
    await process.exitCode;
    await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
    rethrow;
  }
}

Future<void> _collectProcessOutput(
  Stream<List<int>> stream,
  StringBuffer output,
) async {
  var length = 0;
  await for (final chunk in stream.transform(utf8.decoder)) {
    length += chunk.length;
    if (length <= 65536) output.write(chunk);
  }
}

Duration _remaining(Stopwatch clock, Duration deadline) {
  final remaining = deadline - clock.elapsed;
  if (remaining <= Duration.zero) {
    throw MambaException('The acquisition deadline elapsed.', exitCode: 3);
  }
  return remaining;
}

Future<void> _validateMaterializedTree(
  String root,
  Stopwatch clock,
  Duration deadline,
) async {
  var entries = 0;
  var total = 0;
  final pending = <({Directory directory, int depth})>[
    (directory: Directory(root), depth: 0),
  ];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    await for (final entity in current.directory.list(followLinks: false)) {
      _remaining(clock, deadline);
      entries++;
      if (entries > _treeEntryLimit) {
        throw MambaException(
          'The source exceeded the 20,000-entry materialization limit.',
          exitCode: 3,
        );
      }
      final depth = current.depth + 1;
      if (depth > _treeDepthLimit) {
        throw MambaException(
          'The source exceeded the 32-level materialization depth limit.',
          exitCode: 3,
        );
      }
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw MambaException(
          'The acquired source contains an unsupported linked entry.',
          exitCode: 4,
        );
      }
      if (type == FileSystemEntityType.file) {
        final size = File(entity.path).lengthSync();
        if (size > _fileLimit) {
          throw MambaException(
            'A source file exceeded the 64 MiB ordinary-file limit.',
            exitCode: 3,
          );
        }
        total += size;
        if (total > _treeContentLimit) {
          throw MambaException(
            'The source exceeded the 256 MiB materialized-content limit.',
            exitCode: 3,
          );
        }
      } else if (type == FileSystemEntityType.directory) {
        pending.add((directory: Directory(entity.path), depth: depth));
      } else {
        throw MambaException(
          'The acquired source contains an unsupported special entry.',
          exitCode: 4,
        );
      }
    }
  }
}

String _selectRemoteRoot(String checkout, String? subpath) {
  if (subpath == null) return checkout;
  _validateSubpath(subpath);
  final selected = p.normalize(p.joinAll([checkout, ...subpath.split('/')]));
  if (!p.equals(selected, checkout) && !p.isWithin(checkout, selected)) {
    throw MambaException('--subpath escapes the selected source.', exitCode: 4);
  }
  if (FileSystemEntity.typeSync(selected, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw MambaException(
      '--subpath must select a directory in the acquired source.',
      exitCode: 3,
    );
  }
  return selected;
}

Future<void> _deleteFailedAcquisition(Directory temporary) async {
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
  return uri.replace(userInfo: '', query: '', fragment: '').toString();
}
