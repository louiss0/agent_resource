import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../authoring/authoring_inputs.dart';
import '../authoring/instruction_draft.dart';
import '../authoring/instruction_draft_document.dart';
import '../authoring/instruction_draft_privacy.dart';
import '../skill_files.dart';
import 'authoring_plan_service.dart';
import 'lifecycle_state_service.dart';

export '../authoring/instruction_draft_privacy.dart'
    show
        InstructionDraftPrivacyGuard,
        InstructionDraftPrivacyVerifier,
        WindowsAccessGrant,
        parseWindowsAccessGrants,
        windowsAccessIsPrivate,
        verifyPrivateDirectory;

/// The directory that holds the retained instruction drafts of one state
/// root.
///
/// The directory is application-owned private storage. It never holds a
/// publication record and it never adopts a resource.
const String instructionDraftDirectoryName = 'instruction-drafts';

/// The largest instruction body that a draft retains.
const int maxInstructionDraftBodyBytes = 1024 * 1024;

/// The factory of one opaque draft identity.
typedef InstructionDraftIdFactory = String Function();

/// Creates, retains, resumes and removes protected instruction drafts.
///
/// The service owns the drafts and the instructions in them. It never
/// publishes anything, it never records an approval and it never removes the
/// original input the operator supplied.
///
/// A draft is retained until it is explicitly discarded or until a verified
/// publication removes it. There is no automatic expiry: a cancelled or
/// failed authoring run keeps its draft and reports its location.
///
/// The read-only operations never change the storage. They confirm the
/// privacy of the existing directories with a read-only check, so a listing,
/// an inspection and a resume leave the filesystem exactly as they found it.
interface class InstructionDraftService {
  factory InstructionDraftService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    LifecycleStateService? state,
    AuthoringPlanService? plans,
    Future<String> Function()? standardInput,
    InstructionDraftPrivacyGuard? privacy,
    InstructionDraftPrivacyVerifier? verifier,
    InstructionDraftIdFactory? newId,
  }) {
    final io = LifecycleIO(fs: fileSystem);
    final resolved = state ?? LifecycleStateService(io: io);
    return InstructionDraftService._(
      fileSystem,
      resolved,
      plans ?? AuthoringPlanService(fileSystem: fileSystem, state: resolved),
      standardInput,
      privacy ?? resolved.protectDirectory,
      verifier ?? ((path) => verifyPrivateDirectory(fileSystem, path)),
      newId ?? newInstructionDraftId,
    );
  }

  InstructionDraftService._(
    this._fileSystem,
    this._state,
    this._plans,
    this._standardInput,
    this._privacy,
    this._verifier,
    this._newId,
  );

  final fslib.FileSystem _fileSystem;
  final LifecycleStateService _state;
  final AuthoringPlanService? _plans;
  final Future<String> Function()? _standardInput;
  final InstructionDraftPrivacyGuard _privacy;
  final InstructionDraftPrivacyVerifier _verifier;
  final InstructionDraftIdFactory _newId;

  LifecycleIO get _io => _state.io;

  /// The directory that holds the retained drafts of one state root.
  String draftsDirectory(LifecycleContext context) =>
      _fileSystem.path.join(context.stateRoot(), instructionDraftDirectoryName);

  /// Prepares one protected instruction draft.
  ///
  /// The body input is exclusive: a body file, explicitly selected standard
  /// input or literal text. The exact multiline bytes are preserved. The
  /// protected storage is established and confirmed before the sensitive body
  /// is written.
  ///
  /// A privacy failure leaves no instruction bytes behind. A failure while
  /// the instructions are written retains the ownership document of the
  /// draft as unresolved evidence: the evidence is never removed by a
  /// failure.
  ///
  /// A draft preparation is a distinct authoring interaction: it is refused
  /// in dry-run mode, where a read-only plan is the correct operation.
  Future<InstructionDraft> prepare(
    LifecycleOptions options,
    AuthoringInputs inputs,
  ) async {
    if (options.dryRun) {
      throw MambaException(
        'A draft preparation writes protected storage; it is not available in '
        'dry-run mode.',
        exitCode: 4,
      );
    }
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    if (inputs.scope != context.scope) {
      throw MambaException(
        'The selected scope does not agree with the resolved lifecycle scope.',
        exitCode: 4,
      );
    }
    if (inputs.operation == AuthoringOperation.clone ||
        inputs.operation == AuthoringOperation.convert) {
      throw MambaException(
        'A clone or a conversion preserves the instructions of its source; it '
        'has no instruction input to draft.',
        exitCode: 4,
      );
    }
    final selection = inputs.body;
    if (selection == null) {
      throw MambaException(
        'A draft requires an explicit body input: a body file, standard input '
        'or literal text.',
        exitCode: 4,
      );
    }
    final body = await _resolveBody(selection, context);
    final bytes = utf8.encode(body.text);
    if (bytes.length > maxInstructionDraftBodyBytes) {
      throw MambaException(
        'The instruction body exceeds the 1 MiB limit.',
        exitCode: 3,
      );
    }
    final draftId = _newId();
    _requireDraftId(draftId);
    final document = InstructionDraftDocument(
      draftId: draftId,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      intent: InstructionDraftIntent.from(inputs, context: context),
      bodyOrigin: body.origin,
      bodySha256: _digestBytes(bytes),
      bodyByteLength: bytes.length,
      bodySourcePath: body.sourcePath,
    );
    // The ownership document is encoded and bounded before any sensitive
    // write. An oversized intent is refused while the storage is still
    // untouched.
    final encoded = utf8.encode(document.encode());
    if (encoded.length > maxInstructionDraftDocumentBytes) {
      throw MambaException(
        'The instruction draft metadata exceeds its byte limit.',
        exitCode: 3,
      );
    }
    final root = draftsDirectory(context);
    _requireUnlinkedAncestors(context.stateRoot());
    _protectDirectory(root);
    final directory = _fileSystem.path.join(root, draftId);
    _requireUnlinkedAncestors(directory);
    // A draft identity selects one empty draft directory. An occupied
    // directory is never overwritten: the preparation fails closed before
    // any write.
    if (_io.type(directory, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw MambaException(
        'The instruction draft $draftId already exists; the preparation is '
        'refused.',
        exitCode: 4,
      );
    }
    _protectDirectory(directory);
    // The protected storage is established and confirmed before the
    // sensitive body is written, and the ownership document is persisted
    // first. A metadata failure therefore cannot leave an instruction
    // without its owner document.
    _state.writeProtectedDocument(
      _fileSystem.path.join(directory, instructionDraftMetadataFileName),
      encoded,
    );
    _io.write(
      _fileSystem.path.join(directory, instructionDraftBodyFileName),
      bytes,
    );
    return InstructionDraft(
      draftId: draftId,
      intent: document.intent,
      bodyOrigin: document.bodyOrigin,
      bodySha256: document.bodySha256,
      bodyByteLength: document.bodyByteLength,
      bodySourcePath: document.bodySourcePath,
      path: directory,
      metadataSha256: document.digest,
      createdAt: document.createdAt,
    );
  }

  /// Lists the retained drafts of the selected scope.
  ///
  /// The listing is metadata only: it never reports the instruction body. An
  /// entry that cannot be resolved stays visible with its reason instead of
  /// disappearing from the inventory. The listing never changes the storage.
  Future<List<InstructionDraftSummary>> list(LifecycleOptions options) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final root = draftsDirectory(context);
    final type = _io.type(root, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const <InstructionDraftSummary>[];
    }
    if (type != FileSystemEntityType.directory) {
      throw MambaException(
        'The private draft storage is not a directory: $root',
        exitCode: 4,
      );
    }
    _requireUnlinkedAncestors(root);
    _verifier(root);
    final summaries = <InstructionDraftSummary>[];
    for (final entry in _io.list(root)) {
      final name = _fileSystem.path.basename(entry.path);
      if (!isInstructionDraftId(name)) {
        summaries.add(
          InstructionDraftSummary.unresolved(
            name,
            'The entry is not an instruction draft.',
          ),
        );
        continue;
      }
      summaries.add(await _summaryOf(context, name));
    }
    summaries.sort((left, right) => left.draftId.compareTo(right.draftId));
    return List<InstructionDraftSummary>.unmodifiable(summaries);
  }

  /// Finds one retained draft.
  ///
  /// A missing draft is null. A malformed identity is refused: the identity
  /// selects one owned draft and never an arbitrary path.
  Future<InstructionDraftSummary?> find(
    LifecycleOptions options,
    String draftId,
  ) async {
    _requireDraftId(draftId);
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final directory = _fileSystem.path.join(draftsDirectory(context), draftId);
    _requireUnlinkedAncestors(directory);
    if (_io.type(directory, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    return _summaryOf(context, draftId);
  }

  /// Reads the metadata of one retained draft.
  ///
  /// The inspection never reports the instruction body and it never changes
  /// the storage.
  Future<InstructionDraft> inspect(
    LifecycleOptions options,
    String draftId,
  ) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final draft = await _load(context, draftId);
    _confirmContainerPrivacy(draft);
    return draft;
  }

  /// Reads the instructions of one retained draft.
  ///
  /// The effective body is the editable working copy when it exists and the
  /// prepared snapshot otherwise. The privacy of the existing container is
  /// confirmed before the body is read, because an editor that replaces the
  /// draft writes its temporary copy beside it.
  Future<InstructionDraftBody> read(
    LifecycleOptions options,
    String draftId,
  ) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final draft = await _load(context, draftId);
    _confirmContainerPrivacy(draft);
    return _readBody(draft);
  }

  /// Creates the editable working copy of one retained draft.
  ///
  /// The working copy is the file an editor may replace. No editor is
  /// launched here: the operation only prepares the protected file. It is an
  /// explicit mutation and it is refused in dry-run mode.
  Future<String> prepareWorkingCopy(
    LifecycleOptions options,
    String draftId,
  ) async {
    if (options.dryRun) {
      throw MambaException(
        'A working copy writes protected storage; it is not available in '
        'dry-run mode.',
        exitCode: 4,
      );
    }
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final draft = await _load(context, draftId);
    _confirmContainerPrivacy(draft);
    final bodyPath = _fileSystem.path.join(
      draft.path,
      instructionDraftBodyFileName,
    );
    final workingPath = _fileSystem.path.join(
      draft.path,
      instructionDraftWorkingFileName,
    );
    if (_io.type(workingPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw MambaException(
        'The instruction draft already has a working copy: $workingPath',
        exitCode: 4,
      );
    }
    _readBytes(bodyPath, draft.bodySha256);
    _io.copyFile(bodyPath, workingPath);
    return workingPath;
  }

  /// Resumes one retained draft with fresh context and a fresh plan.
  ///
  /// The resume rebuilds the authoring inputs from the retained intent and
  /// the current instructions, and it asks the plan service for a new plan
  /// from the current observations. It never replays an old plan identity and
  /// it never carries an approval. It never changes the storage.
  Future<InstructionDraftResume> resume(
    LifecycleOptions options,
    String draftId, {
    LifecycleOptions? planOptions,
    AuthoringPlanService? plans,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final draft = await _load(context, draftId);
    _confirmContainerPrivacy(draft);
    final body = await _readBody(draft);
    final inputs = draft.intent.toInputs(bodyText: body.text);
    final service = plans ?? _plans;
    if (service == null) {
      throw MambaException(
        'No authoring plan service is available to resume the instruction '
        'draft.',
        exitCode: 6,
      );
    }
    final plan = await service.plan(inputs, planOptions ?? options);
    return InstructionDraftResume(
      draft: draft,
      body: body,
      inputs: inputs,
      plan: plan,
    );
  }

  /// Discards one retained draft.
  ///
  /// The removal is narrow: it touches the owned draft directory and nothing
  /// else. The original input of the operator is never a removal target.
  ///
  /// The removal requires the explicit consent of the operator. The
  /// post-publication cleanup is the separate operation that carries no
  /// consent of its own.
  Future<InstructionDraftCleanup> discard(
    LifecycleOptions options,
    String draftId,
  ) async {
    if (options.dryRun) {
      throw MambaException(
        'A draft discard removes protected storage; it is not available in '
        'dry-run mode.',
        exitCode: 4,
      );
    }
    if (!options.approved) {
      throw MambaException(
        'A draft discard requires the explicit consent of the operator.',
        exitCode: 4,
      );
    }
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    return _removeOwned(context, draftId);
  }

  /// Removes one retained draft after a verified publication.
  ///
  /// The cleanup reports its own failure instead of throwing, so a cleanup
  /// problem never hides the evidence of a published output. A frontend
  /// calls it only after the publication succeeded.
  Future<InstructionDraftCleanup> cleanupOwned(
    LifecycleOptions options,
    String draftId,
  ) async {
    if (options.dryRun) {
      return InstructionDraftCleanup(
        draftId: draftId,
        cleaned: false,
        reason: 'Dry-run mode does not remove the retained instruction draft.',
      );
    }
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    try {
      return await _removeOwned(context, draftId);
    } on Exception catch (error) {
      return InstructionDraftCleanup(
        draftId: draftId,
        cleaned: false,
        reason: '$error',
      );
    }
  }

  /// The summary of one retained draft.
  ///
  /// A draft that cannot be resolved stays visible with its reason. The
  /// reason never carries instruction bytes or the raw source: an
  /// operational failure is reported without its content.
  Future<InstructionDraftSummary> _summaryOf(
    LifecycleContext context,
    String draftId,
  ) async {
    try {
      final draft = await _load(context, draftId);
      final bodyPath = _fileSystem.path.join(
        draft.path,
        instructionDraftBodyFileName,
      );
      if (_io.type(bodyPath, followLinks: false) != FileSystemEntityType.file) {
        return InstructionDraftSummary.unresolved(
          draftId,
          'The prepared instructions of the instruction draft are missing.',
        );
      }
      return InstructionDraftSummary(
        draftId: draft.draftId,
        operation: draft.intent.operation.name,
        kind: draft.intent.kind.name,
        profile: draft.intent.profile.name,
        scope: draft.intent.scope.name,
        bodyOrigin: draft.bodyOrigin,
        bodyByteLength: draft.bodyByteLength,
        bodySha256: draft.bodySha256,
        resolved: true,
        hasWorkingCopy: draft.hasWorkingCopy,
      );
    } on MambaException catch (error) {
      return InstructionDraftSummary.unresolved(draftId, error.message);
    } on Exception {
      return InstructionDraftSummary.unresolved(
        draftId,
        'The instruction draft could not be read.',
      );
    }
  }

  /// The retained metadata of one draft.
  Future<InstructionDraft> _load(
    LifecycleContext context,
    String draftId,
  ) async {
    _requireDraftId(draftId);
    final document = await _readDocument(context, draftId);
    final directory = _fileSystem.path.join(draftsDirectory(context), draftId);
    final workingPath = _fileSystem.path.join(
      directory,
      instructionDraftWorkingFileName,
    );
    return InstructionDraft(
      draftId: document.draftId,
      intent: document.intent,
      bodyOrigin: document.bodyOrigin,
      bodySha256: document.bodySha256,
      bodyByteLength: document.bodyByteLength,
      bodySourcePath: document.bodySourcePath,
      path: directory,
      metadataSha256: document.digest,
      createdAt: document.createdAt,
      hasWorkingCopy:
          _io.type(workingPath, followLinks: false) ==
          FileSystemEntityType.file,
    );
  }

  /// The bound metadata document of one draft.
  ///
  /// The document is the ownership proof of a draft. A missing, substituted
  /// or corrupt document fails closed: it is never evidence of an owned
  /// draft.
  Future<InstructionDraftDocument> _readDocument(
    LifecycleContext context,
    String draftId,
  ) async {
    final directory = _fileSystem.path.join(draftsDirectory(context), draftId);
    _requireUnlinkedAncestors(directory);
    final directoryType = _io.type(directory, followLinks: false);
    if (directoryType == FileSystemEntityType.notFound) {
      throw MambaException(
        'No instruction draft exists for $draftId.',
        exitCode: 4,
      );
    }
    if (directoryType != FileSystemEntityType.directory) {
      throw MambaException(
        'The instruction draft path is not a directory; a substituted draft is '
        'refused: $directory',
        exitCode: 6,
      );
    }
    // The privacy of the container is confirmed before the metadata is
    // loaded. An existing directory is never recreated or repaired here: an
    // unconfirmed container is refused.
    _verifier(directory);
    final path = _fileSystem.path.join(
      directory,
      instructionDraftMetadataFileName,
    );
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException(
        'The instruction draft $draftId has no metadata document.',
        exitCode: 6,
      );
    }
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The instruction draft metadata is not a regular file: $path',
        exitCode: 6,
      );
    }
    final bytes = _io.read(path, maxInstructionDraftDocumentBytes);
    if (bytes.length > maxInstructionDraftDocumentBytes) {
      throw MambaException(
        'The instruction draft metadata exceeds its byte limit.',
        exitCode: 3,
      );
    }
    final String encoded;
    try {
      encoded = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw MambaException(
        'The instruction draft metadata is not valid UTF-8.',
        exitCode: 6,
      );
    }
    try {
      final document = InstructionDraftDocument.decode(encoded);
      if (document.draftId != draftId) {
        throw MambaException(
          'The instruction draft metadata does not bind to $draftId.',
          exitCode: 6,
        );
      }
      return document;
    } on FormatException catch (error) {
      throw MambaException(
        'The instruction draft metadata is not usable: ${error.message}',
        exitCode: 6,
      );
    }
  }

  /// The effective instructions of one draft.
  ///
  /// The immutable snapshot is verified first: a changed snapshot refuses the
  /// read even when an editable working copy exists. A working copy that is
  /// not a regular file refuses the read as well; it never falls back to the
  /// snapshot silently.
  Future<InstructionDraftBody> _readBody(InstructionDraft draft) async {
    final bodyPath = _fileSystem.path.join(
      draft.path,
      instructionDraftBodyFileName,
    );
    final snapshot = _readBytes(bodyPath, draft.bodySha256);
    final workingPath = _fileSystem.path.join(
      draft.path,
      instructionDraftWorkingFileName,
    );
    final workingType = _io.type(workingPath, followLinks: false);
    if (workingType == FileSystemEntityType.link) {
      throw MambaException(
        'The instruction draft working copy is a link; a substituted draft is '
        'refused.',
        exitCode: 6,
      );
    }
    if (workingType != FileSystemEntityType.notFound &&
        workingType != FileSystemEntityType.file) {
      throw MambaException(
        'The instruction draft working copy is not a regular file; a '
        'substituted draft is refused.',
        exitCode: 6,
      );
    }
    if (workingType == FileSystemEntityType.file) {
      final bytes = _readBytes(workingPath, null);
      final digest = _digestBytes(bytes);
      return InstructionDraftBody(
        text: _decode(bytes, workingPath),
        sha256: digest,
        byteLength: bytes.length,
        origin: draft.bodyOrigin,
        edited: digest != draft.bodySha256,
        sourcePath: draft.bodySourcePath,
      );
    }
    return InstructionDraftBody(
      text: _decode(snapshot, bodyPath),
      sha256: draft.bodySha256,
      byteLength: snapshot.length,
      origin: draft.bodyOrigin,
      edited: false,
      sourcePath: draft.bodySourcePath,
    );
  }

  /// Reads one draft file and verifies the expected content.
  List<int> _readBytes(String path, String? expectedDigest) {
    final type = _io.type(path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The instruction draft file is missing or is not a regular file: $path',
        exitCode: 6,
      );
    }
    final bytes = _io.read(path, maxInstructionDraftBodyBytes);
    if (bytes.length > maxInstructionDraftBodyBytes) {
      throw MambaException(
        'The instruction draft file exceeds its byte limit: $path',
        exitCode: 3,
      );
    }
    final digest = _digestBytes(bytes);
    if (expectedDigest != null && digest != expectedDigest) {
      throw MambaException(
        'The instruction draft content changed; a substituted draft is '
        'refused: $path',
        exitCode: 6,
      );
    }
    return bytes;
  }

  /// Resolves the instruction body of the selected input.
  Future<_ResolvedBody> _resolveBody(
    AuthoringBodySelection selection,
    LifecycleContext context,
  ) async {
    switch (selection.kind) {
      case BodyInputKind.file:
        final path = context.resolvePath(selection.filePath!);
        final type = skillEntityType(path, followLinks: false, fs: _fileSystem);
        if (type != FileSystemEntityType.file) {
          throw MambaException(
            'The body file must be a regular non-link file: $path',
            exitCode: 4,
          );
        }
        final bytes = _io.read(path, maxInstructionDraftBodyBytes);
        if (bytes.length > maxInstructionDraftBodyBytes) {
          throw MambaException(
            'The instruction body exceeds the 1 MiB limit: $path',
            exitCode: 3,
          );
        }
        return _ResolvedBody(
          text: _decode(bytes, path),
          origin: InstructionDraftBodyOrigin.file,
          sourcePath: path,
        );
      case BodyInputKind.standardInput:
        final reader = _standardInput;
        if (reader == null) {
          throw MambaException(
            'Standard input was not supplied; select a body file or literal '
            'text.',
            exitCode: 4,
          );
        }
        final text = await reader();
        return _ResolvedBody(
          text: text,
          origin: InstructionDraftBodyOrigin.standardInput,
          sourcePath: null,
        );
      case BodyInputKind.literal:
        return _ResolvedBody(
          text: selection.text!,
          origin: InstructionDraftBodyOrigin.literal,
          sourcePath: null,
        );
    }
  }

  /// Removes the owned directory of one draft.
  ///
  /// Only the files the service itself wrote are removed, and only after the
  /// bound metadata document proved the ownership of the draft.
  Future<InstructionDraftCleanup> _removeOwned(
    LifecycleContext context,
    String draftId,
  ) async {
    _requireDraftId(draftId);
    final root = draftsDirectory(context);
    final directory = _fileSystem.path.join(root, draftId);
    if (!_fileSystem.path.isWithin(root, directory)) {
      throw MambaException(
        'The instruction draft path escapes its storage.',
        exitCode: 4,
      );
    }
    // The deletion authority rests on the confirmed privacy of the
    // container, on the bound metadata document and on the immutable
    // prepared snapshot. Nothing is removed before all three hold.
    _verifier(directory);
    final document = await _readDocument(context, draftId);
    // The prepared snapshot is immutable: a changed snapshot refuses the
    // removal instead of destroying an unreviewed state. An edited working
    // copy is allowed.
    final bodyPath = _fileSystem.path.join(
      directory,
      instructionDraftBodyFileName,
    );
    _readBytes(bodyPath, document.bodySha256);
    final names = <String>[];
    for (final entry in _io.list(directory)) {
      final name = _fileSystem.path.basename(entry.path);
      if (name != instructionDraftMetadataFileName &&
          name != instructionDraftBodyFileName &&
          name != instructionDraftWorkingFileName) {
        throw MambaException(
          'The instruction draft holds an unexpected entry; the removal is '
          'refused: $name',
          exitCode: 6,
        );
      }
      if (_io.type(entry.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw MambaException(
          'The instruction draft entry is not a regular file; the removal is '
          'refused: $name',
          exitCode: 6,
        );
      }
      names.add(name);
    }
    for (final name in names) {
      _io.delete(_fileSystem.path.join(directory, name));
    }
    _io.deleteEmptyDirectory(directory);
    return InstructionDraftCleanup(draftId: draftId, cleaned: true);
  }

  /// Establishes one private directory and confirms it.
  ///
  /// The guard restricts the permissions of the directory and the verifier
  /// confirms the result. Both run before any sensitive write.
  void _protectDirectory(String path) {
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _io.createDirectory(path);
    } else if (type != FileSystemEntityType.directory) {
      throw MambaException(
        'The private draft storage is not a directory: $path',
        exitCode: 4,
      );
    }
    _privacy(path);
    if (_io.type(path, followLinks: false) != FileSystemEntityType.directory) {
      throw MambaException(
        'The private draft storage is not a directory: $path',
        exitCode: 4,
      );
    }
    _verifier(path);
  }

  /// Confirms the privacy of the directory that holds the instructions.
  ///
  /// The confirmation is read-only: it never restricts, creates or replaces
  /// anything.
  void _confirmContainerPrivacy(InstructionDraft draft) {
    _verifier(draft.path);
    if (_io.type(draft.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw MambaException(
        'The private draft storage is not a directory: ${draft.path}',
        exitCode: 6,
      );
    }
  }

  /// Refuses a path whose ancestors contain a link.
  ///
  /// The check walks from the filesystem root down to the path, so a linked
  /// ancestor cannot redirect the private storage into another location. It
  /// runs before any create, read or removal.
  void _requireUnlinkedAncestors(String path) {
    final normalized = _fileSystem.path.normalize(path);
    var current = normalized;
    while (true) {
      if (_io.type(current, followLinks: false) == FileSystemEntityType.link) {
        throw MambaException(
          'The private draft storage path contains a link: $current',
          exitCode: 4,
        );
      }
      final parent = _fileSystem.path.dirname(current);
      if (parent.isEmpty || _fileSystem.path.equals(parent, current)) break;
      current = parent;
    }
  }

  /// Refuses an identity that is not an opaque draft identity.
  void _requireDraftId(String draftId) {
    if (!isInstructionDraftId(draftId)) {
      throw MambaException(
        'Invalid instruction draft identifier.',
        exitCode: 4,
      );
    }
  }

  String _decode(List<int> bytes, String path) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw MambaException(
        'The instruction content is not valid UTF-8: $path',
        exitCode: 2,
      );
    }
  }

  String _digestBytes(List<int> bytes) => sha256.convert(bytes).toString();
}

/// The resolved instruction body of one request.
final class _ResolvedBody {
  const _ResolvedBody({
    required this.text,
    required this.origin,
    required this.sourcePath,
  });

  final String text;
  final InstructionDraftBodyOrigin origin;
  final String? sourcePath;
}
