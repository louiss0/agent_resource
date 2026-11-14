import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

/// The guard that establishes the protected storage of a draft.
///
/// The guard mutates the storage: it restricts the permissions of a
/// directory. It is only used by the operations that write.
typedef InstructionDraftPrivacyGuard = void Function(String path);

/// The verifier that confirms the protected storage of a draft.
///
/// The verifier is read-only: it inspects the existing permissions and it
/// never restricts, creates or replaces anything. A read-only operation uses
/// it instead of the guard.
typedef InstructionDraftPrivacyVerifier = void Function(String path);

/// One access control entry of one Windows path.
final class WindowsAccessGrant {
  const WindowsAccessGrant({required this.principal, required this.rights});

  /// The principal the entry grants the rights to.
  final String principal;

  /// The rights the entry carries.
  final String rights;
}

/// Confirms that one directory is private, without changing it.
///
/// The confirmation reads the existing permissions of the directory. It never
/// restricts, creates or replaces anything, so a read-only operation can use
/// it without touching the storage.
///
/// A directory that cannot be inspected is not confirmed: an unverifiable
/// privacy is not privacy.
void verifyPrivateDirectory(fslib.FileSystem fileSystem, String path) {
  if (fileSystem is! local.LocalFileSystem) {
    throw MambaException(
      'The privacy of the private draft storage could not be verified on this '
      'filesystem: $path',
      exitCode: 4,
    );
  }
  final type = fileSystem.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.directory) {
    throw MambaException(
      'The private draft storage is not a directory: $path',
      exitCode: 4,
    );
  }
  if (Platform.isWindows) {
    _verifyWindowsPrivacy(path);
    return;
  }
  _verifyUnixPrivacy(path);
}

/// Confirms the Windows access control list of one directory.
///
/// The confirmation reads the access control list and it never restricts,
/// creates or replaces anything. Only the account that runs the
/// application, the system account and the administrators group may hold a
/// grant: every other principal refuses the storage.
void _verifyWindowsPrivacy(String path) {
  final account = _currentWindowsAccount();
  if (account == null) {
    throw MambaException(
      'Cannot verify the Windows owner for private draft storage.',
      exitCode: 4,
    );
  }
  final inspection = Process.runSync('icacls', [path]);
  if (inspection.exitCode != 0) {
    throw MambaException(
      'Windows private draft storage privacy could not be verified: $path',
      exitCode: 4,
    );
  }
  final List<WindowsAccessGrant> grants;
  try {
    grants = parseWindowsAccessGrants('${inspection.stdout}', path: path);
  } on FormatException catch (error) {
    throw MambaException(
      'The Windows access control list of the private draft storage is not '
      'readable: ${error.message}',
      exitCode: 4,
    );
  }
  if (!windowsAccessIsPrivate(grants, account)) {
    throw MambaException(
      'Windows private draft storage privacy could not be verified: $path',
      exitCode: 4,
    );
  }
}

/// Parses the access control entries of one icacls inspection.
///
/// The inspection names the path it belongs to. Every entry names a
/// principal and its rights. An entry that cannot be parsed is refused: an
/// unreadable access control list is not a private one.
List<WindowsAccessGrant> parseWindowsAccessGrants(
  String output, {
  String? path,
}) {
  final grants = <WindowsAccessGrant>[];
  for (final raw in output.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.toLowerCase().startsWith('successfully processed')) continue;
    var remainder = line;
    final expected = path?.trim() ?? '';
    if (expected.isNotEmpty) {
      final index = line.toLowerCase().indexOf(expected.toLowerCase());
      if (index >= 0) {
        remainder = line.substring(index + expected.length);
      }
    }
    remainder = remainder.trim().replaceFirst(RegExp(r'^[\\/:\s]+'), '');
    final match = RegExp(r'^([^:]+):((?:\([A-Za-z]+\))+)$')
        .firstMatch(remainder);
    if (match == null) {
      throw FormatException('The access control entry is not parsable: $line');
    }
    final principal = match.group(1)!.trim();
    final rights = match.group(2)!.trim();
    if (principal.isEmpty || rights.isEmpty) {
      throw FormatException('The access control entry is not parsable: $line');
    }
    grants.add(WindowsAccessGrant(principal: principal, rights: rights));
  }
  return List<WindowsAccessGrant>.unmodifiable(grants);
}

/// Whether the granted principals are the ones private storage may carry.
///
/// Only the account that runs the application, the system account and the
/// administrators group may hold a grant. The account is matched in full:
/// a short user name is a different principal and refuses the storage.
/// Every other principal, however narrow its name, refuses the storage.
bool windowsAccessIsPrivate(List<WindowsAccessGrant> grants, String account) {
  if (grants.isEmpty) return false;
  final allowed = <String>{
    account.trim().toLowerCase(),
    'nt authority\\system',
    'builtin\\administrators',
  };
  for (final grant in grants) {
    if (!allowed.contains(grant.principal.trim().toLowerCase())) return false;
  }
  return true;
}

String? _cachedWindowsAccount;

/// The account that runs the application.
///
/// The account of a process is an immutable identity, so the inspection
/// runs once instead of once per inspected directory.
String? _currentWindowsAccount() {
  final cached = _cachedWindowsAccount;
  if (cached != null) return cached;
  final inspection = Process.runSync('whoami', const []);
  if (inspection.exitCode != 0) return null;
  final account = '${inspection.stdout}'.trim();
  if (account.isEmpty) return null;
  _cachedWindowsAccount = account;
  return account;
}

/// Confirms the Unix permissions of one directory.
///
/// The confirmation reads the permission bits and the owner of the
/// directory. It never restricts, creates or replaces anything.
void _verifyUnixPrivacy(String path) {
  final FileStat stat;
  try {
    stat = FileStat.statSync(path);
  } on FileSystemException {
    throw MambaException(
      'The private draft storage could not be inspected: $path',
      exitCode: 4,
    );
  }
  if (stat.mode & 0x3F != 0) {
    throw MambaException(
      'The private draft storage is not private: $path',
      exitCode: 4,
    );
  }
  final current = _currentAccountIds();
  final owner = _ownerIds(path);
  if (current == null || owner == null || current.$1 != owner.$1) {
    throw MambaException(
      'The private draft storage is not owned by the current account: $path',
      exitCode: 4,
    );
  }
}

int? _cachedUid;
int? _cachedGid;

/// The identifiers of the account that runs the application.
(int, int)? _currentAccountIds() {
  final uid = _cachedUid;
  final gid = _cachedGid;
  if (uid != null && gid != null) return (uid, gid);
  final user = Process.runSync('id', ['-u']);
  final group = Process.runSync('id', ['-g']);
  if (user.exitCode != 0 || group.exitCode != 0) return null;
  final parsedUid = int.tryParse('${user.stdout}'.trim());
  final parsedGid = int.tryParse('${group.stdout}'.trim());
  if (parsedUid == null || parsedGid == null) return null;
  _cachedUid = parsedUid;
  _cachedGid = parsedGid;
  return (parsedUid, parsedGid);
}

/// The identifiers of the account that owns one path.
(int, int)? _ownerIds(String path) {
  for (final arguments in <List<String>>[
    ['-c', '%u %g', path],
    ['-f', '%u %g', path],
  ]) {
    final inspection = Process.runSync('stat', arguments);
    if (inspection.exitCode != 0) continue;
    final parts = '${inspection.stdout}'.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) continue;
    final uid = int.tryParse(parts[0]);
    final gid = int.tryParse(parts[1]);
    if (uid == null || gid == null) continue;
    return (uid, gid);
  }
  return null;
}
