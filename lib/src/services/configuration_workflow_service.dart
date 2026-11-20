import 'dart:io' show FileSystemException, Platform;

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart' show MambaException;
import 'package:toml/toml.dart' show TomlDocument, TomlException;

import '../pack/pack_configuration.dart'
    show
        PackConfiguration,
        PackConfigurationException,
        PackConfigurationScope,
        packConfigurationFileName;
import '../pack/pack_models.dart' show PackProcessStatus;
import '../configuration/effective_configuration.dart';

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
    final settings = <EffectiveSetting>[
      for (final preference in EligiblePreference.values)
        _setting(
          preference,
          request,
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
      targetDocument.map,
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
    Map<String, Object?> existing,
    Map<EligiblePreference, Object?> assignments,
    String configPath,
    PackConfigurationScope scope,
  ) {
    final proposed = <String, Object?>{...existing, 'schema_version': 1};
    final cli = _mapCopy(proposed['cli']);
    final install = _mapCopy(cli['install']);
    final retention = _mapCopy(cli['retention']);
    for (final entry in assignments.entries) {
      switch (entry.key) {
        case EligiblePreference.installTargets:
          install['targets'] = entry.value;
        case EligiblePreference.installSkillMethod:
          install['skill_method'] = entry.value;
        case EligiblePreference.retentionSnapshotDays:
          retention['snapshot_days'] = entry.value;
      }
    }
    cli['install'] = install;
    cli['retention'] = retention;
    proposed['cli'] = cli;
    try {
      final source =
          '${TomlDocument.fromMap(proposed).toString().trimRight()}\n';
      PackConfiguration.parse(source, configPath: configPath, scope: scope);
      return source;
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

  Map<String, Object?> _mapCopy(Object? value) => switch (value) {
    final Map<String, Object?> map => <String, Object?>{...map},
    _ => <String, Object?>{},
  };

  void _writeDocument(String configPath, String source) {
    try {
      final file = _fileSystem.file(configPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(source, flush: true);
    } on FileSystemException catch (error) {
      throw MambaException(
        'Could not write configuration $configPath: ${error.message}',
        exitCode: PackProcessStatus.failure.code,
      );
    }
  }

  EffectiveSetting _setting(
    EligiblePreference preference,
    ConfigurationWorkflowRequest request,
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
    final processCwd = path.normalize(_fileSystem.currentDirectory.path);
    final cwdOverride = request.cwd;
    final cwd = cwdOverride == null
        ? processCwd
        : _resolveAgainst(cwdOverride, processCwd);
    final projectRootOverride = request.projectRoot;
    final projectRoot = projectRootOverride == null
        ? cwd
        : _resolveAgainst(projectRootOverride, cwd);
    final userOverride = request.userConfigPath;
    final userPath = userOverride == null
        ? _discoveredUserPath(request, processCwd)
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
        projectRootOverride == null ? 'cwd' : '--project-root',
      ),
    ];
    return _ResolvedPaths(userPath, projectPath, selectedPath, descriptors);
  }

  String _discoveredUserPath(
    ConfigurationWorkflowRequest request,
    String processCwd,
  ) {
    final homeOverride = request.home;
    final home = homeOverride == null
        ? null
        : _resolveAgainst(homeOverride, processCwd);
    try {
      return PackConfiguration.userConfigPath(
        environment: _environment,
        operatingSystem: _operatingSystem,
        home: home,
      );
    } on PackConfigurationException catch (error) {
      throw MambaException(
        'Cannot discover the user configuration: ${error.message}',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
  }

  String get _environmentSource => switch (_operatingSystem) {
    'windows' => 'APPDATA',
    'macos' => 'HOME',
    _ => 'HOME',
  };

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
        return _ConfigDocument(map);
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

final class _ResolvedPaths(
  final String userPath,
  final String projectPath,
  final String selectedPath,
  final List<ConfigurationPathValue> descriptors,
);

final class const _ConfigDocument(final Map<String, Object?> map) {
  factory _ConfigDocument.absent() =>
      _ConfigDocument(const <String, Object?>{'schema_version': 1});
}
