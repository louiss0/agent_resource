import 'dart:convert' show jsonEncode, utf8;
import 'dart:io'
    show
        FileLock,
        FileMode,
        FileSystemEntityType,
        FileSystemException,
        Platform,
        RandomAccessFile;

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart' show MambaException;
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart' show TomlDocument, TomlException;

import '../pack/pack_configuration.dart'
    show
        PackConfiguration,
        PackConfigurationException,
        PackConfigurationScope,
        SkillInstallMethod,
        packConfigurationFileName;
import '../pack/pack_models.dart' show PackProcessStatus;
import '../configuration/effective_configuration.dart';
import 'lifecycle_state_service.dart'
    show LifecycleContext, LifecycleOptions, LifecycleScope;

/// Resolves effective configuration and deliberately saves eligible
/// preferences at the selected user or project configuration path.
interface class ConfigurationWorkflowService {
  new({
    this._fileSystem = const local.LocalFileSystem(),
    Map<String, String>? environment,
    String? operatingSystem,
  }) : _environment = Map<String, String>.unmodifiable(
         environment ?? Platform.environment,
       ),
       _operatingSystem = operatingSystem ?? Platform.operatingSystem;

  final fslib.FileSystem _fileSystem;
  final Map<String, String> _environment;
  final String _operatingSystem;

  ConfigurationWorkflowResult execute(ConfigurationWorkflowRequest request) =>
      switch (request.operation) {
        ConfigurationWorkflowOperation.effective => _effective(request),
        ConfigurationWorkflowOperation.prefer => _prefer(request),
      };

  ConfigurationWorkflowResult _effective(ConfigurationWorkflowRequest request) {
    final paths = _resolvePaths(request);
    final userLayerPath = request.scope == PackConfigurationScope.user
        ? paths.selectedPath
        : paths.userPath;
    final projectLayerPath = request.scope == PackConfigurationScope.project
        ? paths.selectedPath
        : paths.projectPath;
    final userDocument = _readDocument(
      userLayerPath,
      PackConfigurationScope.user,
    );
    final projectDocument = request.scope == PackConfigurationScope.project
        ? _readDocument(projectLayerPath, PackConfigurationScope.project)
        : _ConfigDocument.absent();
    final selectedDocument = request.scope == PackConfigurationScope.project
        ? projectDocument
        : userDocument;
    final selectedLayerPath = request.scope == PackConfigurationScope.project
        ? projectLayerPath
        : userLayerPath;
    final packKey = request.packKey;
    final packOverrides = packKey == null
        ? const <EligiblePreference, _PackOverride>{}
        : _packOverrides(
            packKey,
            selectedDocument,
            selectedLayerPath,
            request.scope,
          );
    final settings = <EffectiveSetting>[
      for (final preference in EligiblePreference.values)
        _setting(
          preference,
          request,
          packOverrides,
          userDocument.map,
          projectDocument.map,
          userLayerPath,
          projectLayerPath,
        ),
    ];
    return ConfigurationWorkflowResult(
      'config.effective',
      'valid',
      request.scope,
      paths.descriptors,
      settings,
      const <EffectiveSetting>[],
      false,
      null,
    );
  }

  ConfigurationWorkflowResult _prefer(ConfigurationWorkflowRequest request) {
    final assignments = _parseAssignments(request.preferences);
    final paths = _resolvePaths(request);
    final targetPath = paths.selectedPath;
    final userLayerPath = request.scope == PackConfigurationScope.user
        ? targetPath
        : paths.userPath;
    final projectLayerPath = request.scope == PackConfigurationScope.project
        ? targetPath
        : paths.projectPath;
    final targetDocument = _readDocument(targetPath, request.scope);
    final userDocument = request.scope == PackConfigurationScope.user
        ? targetDocument
        : _readDocument(userLayerPath, PackConfigurationScope.user);
    final projectDocument = request.scope == PackConfigurationScope.project
        ? targetDocument
        : _ConfigDocument.absent();
    final proposedConfig = _proposeDocument(
      targetDocument,
      assignments,
      targetPath,
      request.scope,
    );
    if (request.apply) {
      _writeDocument(targetPath, proposedConfig);
    }
    final changes = <EffectiveSetting>[
      for (final preference in EligiblePreference.values)
        if (assignments.containsKey(preference))
          EffectiveSetting(
            preference.wireName,
            assignments[preference],
            EffectiveValueOrigin.explicitArgument,
            '--set',
          ),
    ];
    final settings = <EffectiveSetting>[
      for (final preference in EligiblePreference.values)
        _preferSetting(
          preference,
          request,
          assignments,
          userDocument.map,
          projectDocument.map,
          userLayerPath,
          projectLayerPath,
        ),
    ];
    return ConfigurationWorkflowResult(
      'config.prefer',
      request.apply ? 'applied' : 'preview',
      request.scope,
      paths.descriptors,
      settings,
      changes,
      request.apply,
      proposedConfig,
    );
  }

  EffectiveSetting _preferSetting(
    EligiblePreference preference,
    ConfigurationWorkflowRequest request,
    Map<EligiblePreference, Object?> assignments,
    Map<String, Object?> userDocument,
    Map<String, Object?> projectDocument,
    String userLayerPath,
    String projectLayerPath,
  ) {
    if (assignments.containsKey(preference)) {
      return EffectiveSetting(
        preference.wireName,
        assignments[preference],
        EffectiveValueOrigin.explicitArgument,
        '--set',
      );
    }
    return _setting(
      preference,
      request,
      const <EligiblePreference, _PackOverride>{},
      userDocument,
      projectDocument,
      userLayerPath,
      projectLayerPath,
    );
  }

  Map<EligiblePreference, Object?> _parseAssignments(List<String> assignments) {
    final seen = <String>{};
    final result = <EligiblePreference, Object?>{};
    for (final raw in assignments) {
      final separator = raw.indexOf('=');
      if (separator <= 0 || separator == raw.length - 1) {
        throw MambaException(
          'Malformed preference assignment supplied to --set.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      final key = raw.substring(0, separator).trim();
      final value = raw.substring(separator + 1).trim();
      if (key.isEmpty ||
          value.isEmpty ||
          _hasControl(key) ||
          _hasControl(value)) {
        throw MambaException(
          'Malformed preference assignment supplied to --set.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      if (!seen.add(key)) {
        throw MambaException(
          'Preference \'$key\' was supplied more than once.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      if (_isUnsafePreferenceValue(value)) {
        throw MambaException(
          'Unsafe remembered value for preference \'$key\' is refused; '
          'approvals, adoption authority, destructive consent, risk '
          'acknowledgements, and credentials are not persisted. No '
          'configuration was written.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      final preference = _preferenceFor(key);
      result[preference] = _parsePreferenceValue(preference, key, value);
    }
    return result;
  }

  EligiblePreference _preferenceFor(String key) {
    for (final preference in EligiblePreference.values) {
      if (preference.wireName == key) return preference;
    }
    if (_isUnsafePreferenceKey(key)) {
      throw MambaException(
        'Unsafe remembered preference \'$key\' is refused; approvals, '
        'adoption authority, destructive consent, risk acknowledgements, '
        'and credentials are not persisted. No configuration was written.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    final eligible = [
      for (final preference in EligiblePreference.values) preference.wireName,
    ].join(', ');
    throw MambaException(
      'Unsupported preference \'$key\'. Eligible keys: $eligible.',
      exitCode: PackProcessStatus.invalidInput.code,
    );
  }

  Object? _parsePreferenceValue(
    EligiblePreference preference,
    String key,
    String value,
  ) {
    switch (preference) {
      case EligiblePreference.installTargets:
        final targets = [for (final part in value.split(',')) part.trim()];
        final valid = RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$');
        if (targets.isEmpty ||
            targets.any((target) => !valid.hasMatch(target)) ||
            targets.toSet().length != targets.length) {
          throw MambaException(
            'Eligible preference \'$key\' requires unique lowercase '
            'kebab-case targets.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        return targets;
      case EligiblePreference.installSkillMethod:
        if (const {'canonical', 'copy', 'source-link'}.contains(value)) {
          return value;
        }
        throw MambaException(
          'Eligible preference \'$key\' must be canonical, copy, or '
          'source-link.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      case EligiblePreference.retentionSnapshotDays:
        final days = int.tryParse(value);
        if (days != null && days >= 1 && days <= 36500) return days;
        throw MambaException(
          'Eligible preference \'$key\' must be an integer between 1 '
          'and 36500.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
    }
  }

  String _proposeDocument(
    _ConfigDocument document,
    Map<EligiblePreference, Object?> assignments,
    String configPath,
    PackConfigurationScope scope,
  ) {
    final proposed = _focusedEdit(document.source, assignments, configPath);
    try {
      PackConfiguration.parse(proposed, configPath: configPath, scope: scope);
      _verifyPreferenceEdits(document.map, proposed, assignments, configPath);
      return proposed;
    } on MambaException {
      rethrow;
    } on PackConfigurationException catch (error) {
      throw MambaException(
        'Configuration validation failed for $configPath:\n${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on TomlException catch (error) {
      throw MambaException(
        'Configuration validation failed for $configPath: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on FormatException catch (error) {
      throw MambaException(
        'Configuration validation failed for $configPath: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  void _verifyPreferenceEdits(
    Map<String, Object?> original,
    String proposed,
    Map<EligiblePreference, Object?> assignments,
    String configPath,
  ) {
    final normalized = _normalize(TomlDocument.parse(proposed).toMap());
    if (normalized case final Map<String, Object?> map) {
      for (final preference in EligiblePreference.values) {
        final before = _lookup(original, preference.segments);
        final after = _lookup(map, preference.segments);
        final expected = assignments.containsKey(preference)
            ? assignments[preference]
            : before.value;
        if (after.present !=
                (assignments.containsKey(preference) || before.present) ||
            !_samePreferenceValue(after.value, expected)) {
          _refuseUnsafeLayout(configPath);
        }
      }
      return;
    }
    _refuseUnsafeLayout(configPath);
  }

  bool _samePreferenceValue(Object? left, Object? right) {
    if (left is List<dynamic> || right is List<dynamic>) {
      return jsonEncode(left) == jsonEncode(right);
    }
    return left == right;
  }

  Map<EligiblePreference, _PackOverride> _packOverrides(
    String packKey,
    _ConfigDocument document,
    String configPath,
    PackConfigurationScope scope,
  ) {
    if (packKey.trim().isEmpty || _hasControl(packKey)) {
      throw MambaException(
        'Pack key must be a nonblank single-line value.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    if (document.source.isEmpty) {
      throw MambaException(
        'No configured pack matches $packKey in $configPath.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    try {
      final configuration = PackConfiguration.parse(
        document.source,
        configPath: configPath,
        scope: scope,
      );
      final pack = configuration.findPack(packKey);
      if (pack == null) {
        throw MambaException(
          'No configured pack matches $packKey in $configPath.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      final source = '$configPath#packs.${jsonEncode(pack.key)}.install';
      final result = <EligiblePreference, _PackOverride>{};
      if (pack.install.targets.isNotEmpty) {
        result[EligiblePreference.installTargets] = _PackOverride(
          List<String>.unmodifiable(pack.install.targets),
          source,
        );
      }
      final method = _skillMethodWireName(pack.install.skillMethod);
      if (method != null) {
        result[EligiblePreference.installSkillMethod] = _PackOverride(
          method,
          source,
        );
      }
      return result;
    } on MambaException {
      rethrow;
    } on PackConfigurationException catch (error) {
      throw MambaException(
        'Configuration validation failed for $configPath:\n${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on TomlException catch (error) {
      throw MambaException(
        'Configuration validation failed for $configPath: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on FormatException catch (error) {
      throw MambaException(
        'Configuration validation failed for $configPath: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  String? _skillMethodWireName(SkillInstallMethod? method) => switch (method) {
    SkillInstallMethod.canonical => 'canonical',
    SkillInstallMethod.copy => 'copy',
    SkillInstallMethod.sourceLink => 'source-link',
    null => null,
  };

  void _writeDocument(String configPath, String source) {
    final path = _fileSystem.path;
    final absolute = path.normalize(
      path.isAbsolute(configPath)
          ? configPath
          : path.join(_fileSystem.currentDirectory.path, configPath),
    );
    _refuseUnsafeTargetPath(absolute);
    final target = _fileSystem.file(absolute);
    target.parent.createSync(recursive: true);
    fslib.Directory? stagingDirectory;
    RandomAccessFile? lockHandle;
    RandomAccessFile? writeHandle;
    var createdTarget = !target.existsSync();
    if (createdTarget) {
      try {
        target.createSync(exclusive: true);
      } on FileSystemException {
        createdTarget = false;
      }
    }
    var publicationStarted = false;
    List<int> originalBytes = const <int>[];
    String? publicationError;
    String? cleanupError;
    MambaException? safetyError;
    try {
      stagingDirectory = target.parent.createTempSync('agent-resource-prefer-');
      final stagedFile = _fileSystem.file(
        path.join(stagingDirectory.path, 'config.toml'),
      );
      stagedFile.writeAsStringSync(source, flush: true);
      if (stagedFile.readAsStringSync() != source) {
        throw FileSystemException(
          'staged configuration verification failed',
          stagedFile.path,
        );
      }
      lockHandle = target.openSync(mode: FileMode.read);
      lockHandle.lockSync(FileLock.exclusive);
      _refuseUnsafeTargetPath(absolute);
      originalBytes = target.readAsBytesSync();
      final bytes = utf8.encode(source);
      publicationStarted = true;
      writeHandle = target.openSync(mode: FileMode.write);
      writeHandle.setPositionSync(0);
      writeHandle.writeFromSync(bytes);
      writeHandle.flushSync();
      if (target.readAsStringSync() != source) {
        throw FileSystemException('publication verification failed', absolute);
      }
    } on MambaException catch (error) {
      safetyError = error;
    } on FileSystemException catch (error) {
      publicationError = error.message;
    } on FormatException catch (error) {
      publicationError = error.message;
    } on UnimplementedError catch (error) {
      publicationError =
          'exclusive file locking is unsupported: ${error.message}';
    } finally {
      if (publicationError != null && publicationStarted && !createdTarget) {
        try {
          if (writeHandle != null) {
            writeHandle.truncateSync(originalBytes.length);
            writeHandle.setPositionSync(0);
            writeHandle.writeFromSync(originalBytes);
            writeHandle.flushSync();
          } else {
            target.writeAsBytesSync(originalBytes, flush: true);
          }
        } on FileSystemException catch (error) {
          cleanupError = error.message;
        } on UnimplementedError catch (error) {
          cleanupError = error.message;
        }
      }
      if (writeHandle != null) {
        try {
          writeHandle.closeSync();
        } on FileSystemException catch (error) {
          cleanupError ??= error.message;
        }
      }
      if (lockHandle != null) {
        try {
          lockHandle.unlockSync();
        } on FileSystemException catch (error) {
          cleanupError ??= error.message;
        } on UnimplementedError catch (error) {
          cleanupError ??= error.message;
        }
        try {
          lockHandle.closeSync();
        } on FileSystemException catch (error) {
          cleanupError ??= error.message;
        }
      }
      if (createdTarget && (publicationError != null || safetyError != null)) {
        try {
          if (target.existsSync()) target.deleteSync();
        } on FileSystemException catch (error) {
          cleanupError ??= error.message;
        }
      }
      if (stagingDirectory != null) {
        try {
          if (stagingDirectory.existsSync()) {
            stagingDirectory.deleteSync(recursive: true);
          }
        } on FileSystemException catch (error) {
          cleanupError ??= error.message;
        }
      }
    }
    if (safetyError != null) throw safetyError;
    if (publicationError != null) {
      throw MambaException(
        'Could not write configuration $absolute: $publicationError',
        exitCode: PackProcessStatus.failure.code,
      );
    }
    if (cleanupError != null) {
      throw MambaException(
        'Could not clean staged configuration for $absolute: $cleanupError',
        exitCode: PackProcessStatus.failure.code,
      );
    }
  }

  void _refuseUnsafeTargetPath(String configPath) {
    final path = _fileSystem.path;
    final absolute = path.normalize(
      path.isAbsolute(configPath)
          ? configPath
          : path.join(_fileSystem.currentDirectory.path, configPath),
    );
    final targetType = _fileSystem.typeSync(absolute, followLinks: false);
    if (targetType == FileSystemEntityType.link) {
      _refusePublication(absolute, 'configuration target is a symbolic link');
    }
    if (targetType != FileSystemEntityType.file &&
        targetType != FileSystemEntityType.notFound) {
      _refusePublication(
        absolute,
        'configuration target is not a regular file',
      );
    }
    var parent = path.dirname(absolute);
    for (var step = 0; step < 64; step++) {
      final type = _fileSystem.typeSync(parent, followLinks: false);
      if (type == FileSystemEntityType.link) {
        _refusePublication(
          absolute,
          'configuration parent chain contains a symbolic link',
        );
      }
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        _refusePublication(
          absolute,
          'configuration parent chain is not a regular directory',
        );
      }
      final next = path.dirname(parent);
      if (path.equals(next, parent)) return;
      parent = next;
    }
    _refusePublication(
      absolute,
      'configuration parent chain exceeds the 64-step budget',
    );
  }

  EffectiveSetting _setting(
    EligiblePreference preference,
    ConfigurationWorkflowRequest request,
    Map<EligiblePreference, _PackOverride> packOverrides,
    Map<String, Object?> userDocument,
    Map<String, Object?> projectDocument,
    String userLayerPath,
    String projectLayerPath,
  ) {
    final explicitValue = switch (preference) {
      EligiblePreference.installTargets
          when request.explicitTargets.isNotEmpty =>
        request.explicitTargets,
      EligiblePreference.installSkillMethod
          when request.explicitMethod != null =>
        request.explicitMethod,
      EligiblePreference.retentionSnapshotDays
          when request.explicitSnapshotDays != null =>
        request.explicitSnapshotDays,
      _ => null,
    };
    if (explicitValue != null) {
      return EffectiveSetting(
        preference.wireName,
        explicitValue,
        EffectiveValueOrigin.explicitArgument,
        switch (preference) {
          EligiblePreference.installTargets => '--target',
          EligiblePreference.installSkillMethod => '--method',
          EligiblePreference.retentionSnapshotDays => '--snapshot-days',
        },
      );
    }
    final packOverride = packOverrides[preference];
    if (packOverride != null) {
      return EffectiveSetting(
        preference.wireName,
        packOverride.value,
        EffectiveValueOrigin.packConfig,
        packOverride.source,
      );
    }
    if (request.scope == PackConfigurationScope.project) {
      final projectValue = _lookup(projectDocument, preference.segments);
      if (projectValue.present) {
        return EffectiveSetting(
          preference.wireName,
          _normalizedValue(preference, projectValue.value, projectLayerPath),
          EffectiveValueOrigin.projectConfig,
          projectLayerPath,
        );
      }
    }
    final userValue = _lookup(userDocument, preference.segments);
    if (userValue.present) {
      return EffectiveSetting(
        preference.wireName,
        _normalizedValue(preference, userValue.value, userLayerPath),
        EffectiveValueOrigin.userConfig,
        userLayerPath,
      );
    }
    return EffectiveSetting(
      preference.wireName,
      preference.defaultValue,
      EffectiveValueOrigin.builtInDefault,
      null,
    );
  }

  Object? _normalizedValue(
    EligiblePreference preference,
    Object? value,
    String configPath,
  ) {
    final normalized = switch (preference) {
      EligiblePreference.installTargets => switch (value) {
        final List<Object?> list => list.whereType<String>().toList(),
        _ => null,
      },
      EligiblePreference.installSkillMethod => switch (value) {
        final String method => method,
        _ => null,
      },
      EligiblePreference.retentionSnapshotDays => switch (value) {
        final int days => days,
        _ => null,
      },
    };
    if (normalized == null) {
      throw MambaException(
        'Configuration value ${preference.wireName} in $configPath is invalid.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    return normalized;
  }

  ({bool present, Object? value}) _lookup(
    Map<String, Object?> document,
    List<String> segments,
  ) {
    Object? current = document;
    for (final segment in segments) {
      if (current case final Map<String, Object?> map) {
        if (!map.containsKey(segment)) {
          return (present: false, value: null);
        }
        current = map[segment];
      } else {
        return (present: false, value: null);
      }
    }
    return (present: true, value: current);
  }

  _ResolvedPaths _resolvePaths(ConfigurationWorkflowRequest request) {
    final path = _fileSystem.path;
    final context = LifecycleContext.resolve(
      LifecycleOptions(
        processWorkingDirectory: _fileSystem.currentDirectory.path,
        environment: _environment,
        scope: request.scope == PackConfigurationScope.user
            ? LifecycleScope.user
            : LifecycleScope.project,
        cwd: request.cwd,
        projectRoot: request.projectRoot,
        home: request.home,
      ),
      fileSystem: _fileSystem,
    );
    final cwd = context.cwd;
    final projectRoot = context.projectRoot;
    final cwdOverride = request.cwd;
    final projectRootOverride = request.projectRoot;
    final userOverride = request.userConfigPath;
    final userPath = userOverride == null
        ? _discoveredUserPath(context)
        : _resolveAgainst(userOverride, cwd);
    final projectOverride = request.projectConfigPath;
    final projectPath = projectOverride == null
        ? path.join(projectRoot, packConfigurationFileName)
        : _resolveAgainst(projectOverride, cwd);
    final selectedOverride = request.configPath;
    final selectedPath = selectedOverride == null
        ? request.scope == PackConfigurationScope.user
              ? userPath
              : projectPath
        : _resolveAgainst(selectedOverride, cwd);
    final userSource = userOverride == null
        ? request.home == null
              ? _environmentSource
              : '--home'
        : '--user-config';
    final projectSource = projectOverride == null
        ? 'projectRoot'
        : '--project-config';
    final projectRootSource = projectRootOverride == null
        ? path.equals(projectRoot, cwd)
              ? 'cwd'
              : '.git'
        : '--project-root';
    final descriptors = <ConfigurationPathValue>[
      ConfigurationPathValue(
        'userConfig',
        userPath,
        userOverride == null
            ? EffectiveValueOrigin.detection
            : EffectiveValueOrigin.explicitArgument,
        userSource,
      ),
      ConfigurationPathValue(
        'projectConfig',
        projectPath,
        projectOverride == null
            ? EffectiveValueOrigin.detection
            : EffectiveValueOrigin.explicitArgument,
        projectSource,
      ),
      ConfigurationPathValue(
        'selectedConfig',
        selectedPath,
        selectedOverride == null
            ? request.scope == PackConfigurationScope.user
                  ? userOverride == null
                        ? EffectiveValueOrigin.detection
                        : EffectiveValueOrigin.explicitArgument
                  : projectOverride == null
                  ? EffectiveValueOrigin.detection
                  : EffectiveValueOrigin.explicitArgument
            : EffectiveValueOrigin.explicitArgument,
        selectedOverride == null
            ? request.scope == PackConfigurationScope.user
                  ? userSource
                  : projectSource
            : '--config',
      ),
      ConfigurationPathValue(
        'cwd',
        cwd,
        cwdOverride == null
            ? EffectiveValueOrigin.detection
            : EffectiveValueOrigin.explicitArgument,
        cwdOverride == null ? 'process' : '--cwd',
      ),
      ConfigurationPathValue(
        'projectRoot',
        projectRoot,
        projectRootOverride == null
            ? EffectiveValueOrigin.detection
            : EffectiveValueOrigin.explicitArgument,
        projectRootSource,
      ),
    ];
    return _ResolvedPaths(userPath, projectPath, selectedPath, descriptors);
  }

  String _discoveredUserPath(LifecycleContext context) {
    try {
      return PackConfiguration.userConfigPath(
        environment: _environment,
        operatingSystem: _operatingSystem,
        home: context.home,
      );
    } on PackConfigurationException catch (error) {
      throw MambaException(
        'Cannot discover the user configuration: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  String get _environmentSource {
    if (_operatingSystem == 'windows') return 'APPDATA';
    if (_operatingSystem == 'macos') return 'HOME';
    final xdg = _environment['XDG_CONFIG_HOME'];
    if (xdg != null && p.posix.isAbsolute(xdg)) {
      return 'XDG_CONFIG_HOME';
    }
    return 'HOME';
  }

  String _resolveAgainst(String raw, String base) {
    final path = _fileSystem.path;
    return path.normalize(path.isAbsolute(raw) ? raw : path.join(base, raw));
  }

  _ConfigDocument _readDocument(
    String configPath,
    PackConfigurationScope scope,
  ) {
    final file = _fileSystem.file(configPath);
    if (!file.existsSync()) return _ConfigDocument.absent();
    late final String source;
    try {
      source = file.readAsStringSync();
    } on FileSystemException catch (error) {
      throw MambaException(
        'Cannot read configuration $configPath: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on FormatException catch (error) {
      throw MambaException(
        'Configuration $configPath is not UTF-8: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    try {
      final normalized = _normalize(TomlDocument.parse(source).toMap());
      if (normalized case final Map<String, Object?> map) {
        _rejectUnsafeKeys(map, configPath);
        PackConfiguration.parse(source, configPath: configPath, scope: scope);
        return _ConfigDocument(source, map);
      }
      throw MambaException(
        'Configuration $configPath must be a TOML table.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on MambaException {
      rethrow;
    } on PackConfigurationException catch (error) {
      throw MambaException(
        'Configuration validation failed for $configPath:\n${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on TomlException catch (error) {
      throw MambaException(
        'Configuration validation failed for $configPath: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    } on FormatException catch (error) {
      throw MambaException(
        'Configuration validation failed for $configPath: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  void _rejectUnsafeKeys(Map<String, Object?> document, String configPath) {
    void visit(Object? value, String prefix) {
      if (value case final Map<String, Object?> map) {
        for (final entry in map.entries) {
          final keyPath = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
          if (_isUnsafePreferenceKey(entry.key) ||
              _isUnsafePreferenceKey(keyPath)) {
            throw MambaException(
              'Unsafe remembered preference \'$keyPath\' in $configPath is '
              'refused; approvals, adoption authority, destructive consent, '
              'risk acknowledgements, and credentials are not persisted.',
              exitCode: PackProcessStatus.invalidInput.code,
            );
          }
          visit(entry.value, keyPath);
        }
      } else if (value case final List<Object?> list) {
        for (var index = 0; index < list.length; index++) {
          visit(list[index], '$prefix[$index]');
        }
      }
    }

    visit(document, '');
  }

  Object? _normalize(Object? value) => switch (value) {
    final Map<dynamic, dynamic> map => <String, Object?>{
      for (final entry in map.entries)
        entry.key.toString(): _normalize(entry.value),
    },
    final List<dynamic> list => <Object?>[
      for (final item in list) _normalize(item),
    ],
    _ => value,
  };
}

const _unsafePreferenceKeyFragments = <String>{
  'approval',
  'approve',
  'consent',
  'credential',
  'secret',
  'token',
  'password',
  'authority',
  'risk',
  'acknowledg',
  'destructive',
  'adopt',
};

bool _isUnsafePreferenceKey(String key) =>
    _containsUnsafeFragment(key, _unsafePreferenceKeyFragments);

bool _isUnsafePreferenceValue(String value) =>
    _containsUnsafeFragment(value, _unsafePreferenceKeyFragments) ||
    _containsUnsafeFragment(value, const <String>{
      'remember',
      'yes',
      'accepted',
      'always',
    });

bool _containsUnsafeFragment(String value, Set<String> fragments) {
  final normalized = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  return fragments.any(normalized.contains);
}

bool _hasControl(String value) =>
    value.runes.any((rune) => rune < 0x20 || rune == 0x7f);

String _focusedEdit(
  String source,
  Map<EligiblePreference, Object?> assignments,
  String configPath,
) {
  final hasCrlf = source.contains('\r\n');
  final hasLoneLf = source.replaceAll('\r\n', '').contains('\n');
  if (hasCrlf && hasLoneLf) _refuseUnsafeLayout(configPath);
  final normalized = source.replaceAll('\r\n', '\n');
  final lines = normalized.split('\n');
  final trailing = <String>[];
  while (lines.isNotEmpty && lines.last.isEmpty) {
    trailing.add(lines.removeLast());
  }
  _rejectAmbiguousPreferenceLayout(lines, configPath);
  final schemaPattern = RegExp(r'^\s*schema_version\s*=');
  if (!lines.any((line) => schemaPattern.hasMatch(_withoutComment(line)))) {
    lines.insert(0, 'schema_version = 1');
  }
  _editSection(lines, '[cli.install]', <String, Object?>{
    if (assignments.containsKey(EligiblePreference.installTargets))
      'targets': assignments[EligiblePreference.installTargets],
    if (assignments.containsKey(EligiblePreference.installSkillMethod))
      'skill_method': assignments[EligiblePreference.installSkillMethod],
  }, configPath);
  _editSection(lines, '[cli.retention]', <String, Object?>{
    if (assignments.containsKey(EligiblePreference.retentionSnapshotDays))
      'snapshot_days': assignments[EligiblePreference.retentionSnapshotDays],
  }, configPath);
  lines.addAll(trailing);
  final joined = lines.join('\n');
  return hasCrlf ? joined.replaceAll('\n', '\r\n') : joined;
}

void _editSection(
  List<String> lines,
  String header,
  Map<String, Object?> updates,
  String configPath,
) {
  if (updates.isEmpty) return;
  var headerIndex = -1;
  for (var index = 0; index < lines.length; index++) {
    final code = _withoutComment(lines[index]).trim();
    if (code != header) continue;
    if (headerIndex >= 0) _refuseUnsafeLayout(configPath);
    headerIndex = index;
  }
  if (headerIndex < 0) {
    if (lines.isNotEmpty && _withoutComment(lines.last).trim().isNotEmpty) {
      lines.add('');
    }
    lines.add(header);
    for (final entry in updates.entries) {
      lines.add('${entry.key} = ${_tomlValue(entry.value)}');
    }
    return;
  }
  var sectionEnd = lines.length;
  for (var index = headerIndex + 1; index < lines.length; index++) {
    if (_withoutComment(lines[index]).trim().startsWith('[')) {
      sectionEnd = index;
      break;
    }
  }
  for (final entry in updates.entries) {
    final pattern = RegExp(r'^(\s*)' + RegExp.escape(entry.key) + r'\s*=');
    var replaced = false;
    for (var index = headerIndex + 1; index < sectionEnd; index++) {
      final code = _withoutComment(lines[index]);
      final match = pattern.firstMatch(code);
      if (match == null) continue;
      final indentation = match.group(1) ?? '';
      lines[index] =
          '$indentation${entry.key} = ${_tomlValue(entry.value)}'
          '${_commentSuffix(lines[index])}';
      replaced = true;
      break;
    }
    if (replaced) continue;
    var insertAt = sectionEnd;
    while (insertAt > headerIndex + 1 && lines[insertAt - 1].trim().isEmpty) {
      insertAt--;
    }
    lines.insert(insertAt, '${entry.key} = ${_tomlValue(entry.value)}');
    sectionEnd++;
  }
}

void _rejectAmbiguousPreferenceLayout(List<String> lines, String configPath) {
  var section = '';
  var installHeaders = 0;
  var retentionHeaders = 0;
  for (final line in lines) {
    final code = _withoutComment(line).trim();
    if (code.startsWith('[')) {
      section = code;
      if (code == '[cli.install]') installHeaders++;
      if (code == '[cli.retention]') retentionHeaders++;
      if (code.startsWith('[cli') &&
          !const <String>{
            '[cli]',
            '[cli.install]',
            '[cli.retention]',
          }.contains(code)) {
        _refuseUnsafeLayout(configPath);
      }
      continue;
    }
    if (code.isEmpty) continue;
    final inlineCli =
        RegExp(r'^cli\s*=\s*\{').hasMatch(code) ||
        RegExp(r'^cli\.install\s*=\s*\{').hasMatch(code) ||
        RegExp(r'^cli\.retention\s*=\s*\{').hasMatch(code);
    final dottedPreference =
        RegExp(r'^cli\.install\.(?:targets|skill_method)\s*=').hasMatch(code) ||
        RegExp(r'^cli\.retention\.snapshot_days\s*=').hasMatch(code);
    final inlineUnderCli =
        section == '[cli]' &&
        (RegExp(r'^(?:install|retention)\s*=\s*\{').hasMatch(code) ||
            RegExp(r'^install\.(?:targets|skill_method)\s*=').hasMatch(code) ||
            RegExp(r'^retention\.snapshot_days\s*=').hasMatch(code));
    if (inlineCli || dottedPreference || inlineUnderCli) {
      _refuseUnsafeLayout(configPath);
    }
  }
  if (installHeaders > 1 || retentionHeaders > 1) {
    _refuseUnsafeLayout(configPath);
  }
}

String _tomlValue(Object? value) => switch (value) {
  final List<dynamic> list =>
    '[${[for (final item in list) jsonEncode(item)].join(', ')}]',
  final String string => jsonEncode(string),
  final int integer => integer.toString(),
  _ => throw StateError('Unsupported focused preference value.'),
};

String _withoutComment(String line) {
  const singleQuote = 39;
  const doubleQuote = 34;
  const backslash = 92;
  const hash = 35;
  var quote = 0;
  var escaped = false;
  for (var index = 0; index < line.length; index++) {
    final character = line.codeUnitAt(index);
    if (quote == singleQuote) {
      if (character == singleQuote) quote = 0;
    } else if (quote == doubleQuote) {
      if (escaped) {
        escaped = false;
      } else if (character == backslash) {
        escaped = true;
      } else if (character == doubleQuote) {
        quote = 0;
      }
    } else if (character == singleQuote) {
      quote = singleQuote;
    } else if (character == doubleQuote) {
      quote = doubleQuote;
    } else if (character == hash) {
      return line.substring(0, index);
    }
  }
  return line;
}

String _commentSuffix(String line) {
  final code = _withoutComment(line);
  var start = code.length;
  while (start > 0) {
    final character = line.codeUnitAt(start - 1);
    if (character != 32 && character != 9) break;
    start--;
  }
  return line.substring(start);
}

Never _refuseUnsafeLayout(String configPath) => throw MambaException(
  'Cannot safely preserve configuration formatting for $configPath. '
  'Use table-form [cli.install] and [cli.retention] sections; no '
  'configuration was written.',
  exitCode: PackProcessStatus.invalidInput.code,
);

Never _refusePublication(String configPath, String reason) =>
    throw MambaException(
      'Cannot safely publish configuration $configPath: $reason.',
      exitCode: PackProcessStatus.invalidInput.code,
    );

final class _ResolvedPaths(
  final String userPath,
  final String projectPath,
  final String selectedPath,
  final List<ConfigurationPathValue> descriptors,
);

final class const _ConfigDocument(
  final String source,
  final Map<String, Object?> map,
) {
  factory _ConfigDocument.absent() =>
      _ConfigDocument('', const <String, Object?>{'schema_version': 1});
}

final class const _PackOverride(final Object? value, final String source);
