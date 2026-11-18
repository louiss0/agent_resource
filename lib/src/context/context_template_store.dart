import 'dart:convert';
import 'dart:io' show FileSystemEntityType;

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'context_types.dart';
import '../services/instruction_draft_service.dart';
import '../services/lifecycle_state_service.dart';

/// The private user-state directory that holds plain UTF-8 Markdown templates.
const contextTemplatesDirectoryName = 'context-templates';

/// Reads named context templates from the user state root without following
/// links or trusting template names as paths.
final class ContextTemplateStore {
  const ContextTemplateStore({this.fileSystem = const local.LocalFileSystem()});

  final fslib.FileSystem fileSystem;

  /// The resolved template directory for [options].
  String templateDirectory(LifecycleOptions options) {
    final context = LifecycleContext.resolve(options, fileSystem: fileSystem);
    return fileSystem.path.join(
      context.stateRoot(LifecycleScope.user),
      contextTemplatesDirectoryName,
    );
  }

  /// Returns the stored templates in lexicographical name order.
  List<ContextTemplateMetadata> list(LifecycleOptions options) {
    final directory = templateDirectory(options);
    final type = fileSystem.typeSync(directory, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return <ContextTemplateMetadata>[];
    }
    _requireRegularDirectory(directory, type);

    final templates = <ContextTemplateMetadata>[];
    for (final entity
        in fileSystem.directory(directory).listSync(followLinks: false)) {
      final entryType = fileSystem.typeSync(entity.path, followLinks: false);
      _requireRegularEntry(entity.path, entryType);
      final basename = fileSystem.path.basename(entity.path);
      if (!basename.endsWith('.md')) continue;
      final name = basename.substring(0, basename.length - 3);
      if (!isValidContextTemplateName(name)) {
        throw _refusal(
          'INVALID_TEMPLATE_NAME',
          'Stored template file "$basename" has a non-portable name.',
        );
      }
      final path = fileSystem.path.join(directory, '$name.md');
      final bytes = _readBounded(path);
      templates.add(_metadata(name, path, bytes));
    }
    templates.sort((left, right) => left.name.compareTo(right.name));
    return templates;
  }

  /// Returns one template's metadata and complete UTF-8 Markdown body.
  ContextTemplateRead inspect(LifecycleOptions options, String name) {
    if (!isValidContextTemplateName(name)) {
      throw _refusal(
        'INVALID_TEMPLATE_NAME',
        'Context template name "$name" is not portable.',
      );
    }
    final directory = templateDirectory(options);
    final directoryType = fileSystem.typeSync(directory, followLinks: false);
    if (directoryType == FileSystemEntityType.notFound) {
      throw _refusal(
        'TEMPLATE_NOT_FOUND',
        'No context template "$name" exists.',
      );
    }
    _requireRegularDirectory(directory, directoryType);

    final path = fileSystem.path.join(directory, '$name.md');
    final type = fileSystem.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw _refusal(
        'TEMPLATE_NOT_FOUND',
        'No context template "$name" exists.',
      );
    }
    _requireRegularEntry(path, type);

    final bytes = _readBounded(path);
    return ContextTemplateRead(
      metadata: _metadata(name, path, bytes),
      content: _decode(bytes, path),
    );
  }

  void _requireRegularDirectory(String path, FileSystemEntityType type) {
    if (type == FileSystemEntityType.link) {
      throw _refusal(
        'SYMLINK_REFUSED',
        'Context template directory is a link: $path',
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw _refusal(
        'NON_REGULAR_TEMPLATE_REFUSED',
        'Context template directory is not a regular directory: $path',
      );
    }
  }

  void _requireRegularEntry(String path, FileSystemEntityType type) {
    if (type == FileSystemEntityType.link) {
      throw _refusal(
        'SYMLINK_REFUSED',
        'Context template entry is a link: $path',
      );
    }
    if (type != FileSystemEntityType.file) {
      throw _refusal(
        'NON_REGULAR_TEMPLATE_REFUSED',
        'Context template entry is not a regular file: $path',
      );
    }
  }

  List<int> _readBounded(String path) {
    final bytes = LifecycleIO(fs: fileSystem)
        .read(path, maxInstructionDraftBodyBytes);
    if (bytes.length > maxInstructionDraftBodyBytes) {
      throw _refusal(
        'TEMPLATE_TOO_LARGE',
        'Context template exceeds the 1 MiB body limit: $path',
      );
    }
    return bytes;
  }

  String _decode(List<int> bytes, String path) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw _refusal(
        'INVALID_TEMPLATE_UTF8',
        'Context template is not UTF-8: $path',
      );
    }
  }

  ContextTemplateMetadata _metadata(
    String name,
    String path,
    List<int> bytes,
  ) => ContextTemplateMetadata(
    name: name,
    path: path,
    byteLength: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );

  MambaException _refusal(String code, String message) =>
      MambaException('$code: $message', exitCode: 4);
}
