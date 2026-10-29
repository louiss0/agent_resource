import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:mamba/mamba.dart';

/// Native operations for the one supported linked-artifact form: a true
/// directory symlink. Windows reparse inspection never treats junctions or
/// unknown reparse tags as equivalent authority.
interface class NativeLinkService {
  const new();

  String inspectKind(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.link) {
      throw MambaException(
        'The managed entry is not a directory link: $path',
        exitCode: 4,
      );
    }
    if (!Platform.isWindows) return 'posix-directory-symlink';
    return _windowsDirectoryKind(path);
  }

  String readTarget(String path) {
    inspectKind(path);
    try {
      return Link(path).targetSync();
    } on FileSystemException catch (error) {
      throw MambaException(
        'Could not read the directory-link target representation: ${error.message}',
        exitCode: 4,
      );
    }
  }

  void createDirectoryLink(String path, String target) {
    if (target.isEmpty) {
      throw MambaException('A link target must not be blank.', exitCode: 4);
    }
    if (Platform.isWindows) {
      _createWindowsDirectoryLink(path, target);
    } else {
      try {
        Link(path).createSync(target);
      } on FileSystemException catch (error) {
        throw MambaException(
          'Could not create the directory symlink: ${error.message}',
          exitCode: 4,
        );
      }
    }
    inspectKind(path);
    final observed = readTarget(path);
    if (observed != target) {
      throw MambaException(
        'The created directory-link representation did not round-trip.',
        exitCode: 4,
      );
    }
  }
}

String _windowsDirectoryKind(String path) {
  final attributes = _win32.getFileAttributes(path);
  final broken = attributes == 0xFFFFFFFF;
  if (!broken && attributes & 0x10 == 0) {
    throw MambaException(
      'The Windows linked entry is not a directory: $path',
      exitCode: 4,
    );
  }
  final handle = _win32.createFile(path);
  if (handle == -1) {
    throw MambaException(
      'Could not open the Windows reparse entry for verification: $path',
      exitCode: 4,
    );
  }
  final buffer = calloc<Uint8>(16384);
  final returned = calloc<Uint32>();
  final information = calloc<Uint8>(52);
  try {
    if (_win32.getFileInformation(handle, information) == 0) {
      throw MambaException(
        'Could not inspect the Windows directory-link attributes: $path',
        exitCode: 4,
      );
    }
    if (information.cast<Uint32>().value & 0x10 == 0) {
      throw MambaException(
        'The Windows linked entry is not a directory: $path',
        exitCode: 4,
      );
    }
    final ok = _win32.deviceIoControl(
      handle,
      0x000900A8, // FSCTL_GET_REPARSE_POINT
      buffer,
      16384,
      returned,
    );
    if (ok == 0) {
      throw MambaException(
        'Could not inspect the Windows reparse subtype: $path',
        exitCode: 4,
      );
    }
    final tag = buffer.cast<Uint32>().value;
    final dataLength = buffer.cast<Uint16>()[2];
    if (dataLength > 16384 - 8) {
      throw MambaException('Invalid Windows reparse data length.', exitCode: 4);
    }
    if (tag == 0xA0000003) {
      throw MambaException(
        'Windows junctions are reported but are not managed directory symlinks.',
        exitCode: 4,
      );
    }
    if (tag != 0xA000000C) {
      throw MambaException(
        'Unsupported Windows reparse form; a true directory symlink is required.',
        exitCode: 4,
      );
    }
    // A dangling directory symlink can make GetFileAttributesW fail while the
    // reparse tag remains a symlink. The owned entry is still observable and
    // removable; target resolution is a separate observation.
    return 'windows-directory-symlink';
  } finally {
    calloc.free(information);
    calloc.free(returned);
    calloc.free(buffer);
    _win32.closeHandle(handle);
  }
}

void _createWindowsDirectoryLink(String path, String target) {
  final ok = _win32.createSymbolicLink(path, target, 0x1 | 0x2);
  if (ok == 0) {
    final error = _win32.lastError;
    throw MambaException(
      'Could not create a true Windows directory symlink (error $error). '
      'Enable Developer Mode or grant SeCreateSymbolicLinkPrivilege; '
      'no junction or copy fallback is permitted.',
      exitCode: 4,
    );
  }
}

final _win32 = _Win32Bindings();

final class _Win32Bindings {
  _Win32Bindings() : _library = DynamicLibrary.open('kernel32.dll');

  final DynamicLibrary _library;

  late final int Function(String) getFileAttributes = _library
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetFileAttributesW')
      .let((native) {
        return (String path) {
          final pathPtr = path.toNativeUtf16();
          try {
            return native(pathPtr);
          } finally {
            calloc.free(pathPtr);
          }
        };
      });

  late final int Function(String) createFile = (() {
    final native = _library
        .lookupFunction<
          IntPtr Function(
            Pointer<Utf16>,
            Uint32,
            Uint32,
            Pointer<Void>,
            Uint32,
            Uint32,
            IntPtr,
          ),
          int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
        >('CreateFileW');
    return (String path) {
      final pathPtr = path.toNativeUtf16();
      try {
        return native(pathPtr, 0, 7, nullptr, 3, 0x02200000, 0);
      } finally {
        calloc.free(pathPtr);
      }
    };
  })();

  late final int Function(int, int, Pointer<Uint8>, int, Pointer<Uint32>)
  deviceIoControl = (() {
    final native = _library
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Uint32,
            Pointer<Void>,
            Uint32,
            Pointer<Uint8>,
            Uint32,
            Pointer<Uint32>,
            Pointer<Void>,
          ),
          int Function(
            int,
            int,
            Pointer<Void>,
            int,
            Pointer<Uint8>,
            int,
            Pointer<Uint32>,
            Pointer<Void>,
          )
        >('DeviceIoControl');
    return (
      int handle,
      int code,
      Pointer<Uint8> output,
      int outputSize,
      Pointer<Uint32> returned,
    ) {
      return native(
        handle,
        code,
        nullptr,
        0,
        output,
        outputSize,
        returned,
        nullptr,
      );
    };
  })();

  late final int Function(String, String, int) createSymbolicLink = _library
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('CreateSymbolicLinkW')
      .let((native) {
        return (String path, String target, int flags) {
          final pathPtr = path.toNativeUtf16();
          final targetPtr = target.toNativeUtf16();
          try {
            return native(pathPtr, targetPtr, flags);
          } finally {
            calloc.free(targetPtr);
            calloc.free(pathPtr);
          }
        };
      });

  late final int Function(int, Pointer<Uint8>) getFileInformation = (() {
    final native = _library
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>),
          int Function(int, Pointer<Uint8>)
        >('GetFileInformationByHandle');
    return native;
  })();

  late final int Function(int) closeHandle = _library
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

  int get lastError => _library
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError')();
}

extension<T> on T {
  R let<R>(R Function(T) body) => body(this);
}
