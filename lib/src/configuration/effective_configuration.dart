import 'dart:convert';

import '../pack/pack_configuration.dart' show PackConfigurationScope;

/// The source kind of one effective configuration value.
enum EffectiveValueOrigin(final String wireName) {
  explicitArgument('explicit-argument'),
  projectConfig('project-config'),
  userConfig('user-config'),
  packConfig('pack-config'),
  detection('detection'),
  builtInDefault('built-in-default'),
}

/// The durable preferences Agent Resource is willing to remember.
///
/// Approval, adoption authority, destructive consent, risk acknowledgements
/// and credentials are intentionally absent: they remain per-invocation
/// decisions and are never persisted as blanket permissions.
enum EligiblePreference(
  final String wireName,
  final List<String> segments,
  final Object? defaultValue,
) {
  installTargets('cli.install.targets', [
    'cli',
    'install',
    'targets',
  ], <String>[]),
  installSkillMethod('cli.install.skill_method', [
    'cli',
    'install',
    'skill_method',
  ], null),
  retentionSnapshotDays('cli.retention.snapshot_days', [
    'cli',
    'retention',
    'snapshot_days',
  ], 90),
}

enum ConfigurationWorkflowOperation { effective, prefer }

final class const ConfigurationWorkflowRequest({
  required final ConfigurationWorkflowOperation operation,
  required final PackConfigurationScope scope,
  final bool apply = false,
  final String? cwd,
  final String? projectRoot,
  final String? home,
  final String? userConfigPath,
  final String? projectConfigPath,
  final String? configPath,
  final String? packKey,
  final List<String> explicitTargets = const <String>[],
  final String? explicitMethod,
  final int? explicitSnapshotDays,
  final List<String> preferences = const <String>[],
});

final class ConfigurationPathValue(
  final String name,
  final String path,
  final EffectiveValueOrigin origin,
  final String? source,
) {
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'path': path,
    'origin': origin.wireName,
    if (source != null) 'source': source,
  };

  String renderText() =>
      '$name: $path '
      '[${origin.wireName}${source == null ? '' : ' @ $source'}]';
}

final class EffectiveSetting(
  final String key,
  final Object? value,
  final EffectiveValueOrigin origin,
  final String? source,
) {
  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'value': value,
    'origin': origin.wireName,
    if (source != null) 'source': source,
  };

  String renderText() =>
      '$key: ${_renderValue(value)} '
      '[${origin.wireName}${source == null ? '' : ' @ $source'}]';
}

final class ConfigurationWorkflowResult(
  final String operation,
  final String outcome,
  final PackConfigurationScope scope,
  final List<ConfigurationPathValue> paths,
  final List<EffectiveSetting> settings,
  final List<EffectiveSetting> changes,
  final bool applied,
  final String? proposedConfig,
) {
  Map<String, Object?> envelope() => <String, Object?>{
    'schemaVersion': 1,
    'operation': operation,
    'outcome': outcome,
    'scope': scope.name,
    'paths': [for (final path in paths) path.toJson()],
    'settings': [for (final setting in settings) setting.toJson()],
    'eligiblePreferences': [
      for (final preference in EligiblePreference.values) preference.wireName,
    ],
    'changes': [for (final change in changes) change.toJson()],
    'applied': applied,
    if (proposedConfig != null) 'proposedConfig': proposedConfig,
  };

  String renderText() {
    final lines = <String>[
      '$operation: $outcome',
      'scope: ${scope.name}',
      'paths:',
      for (final path in paths) '  ${path.renderText()}',
      'settings:',
      for (final setting in settings) '  ${setting.renderText()}',
      'eligiblePreferences: ${[for (final preference in EligiblePreference.values) preference.wireName].join(', ')}',
    ];
    if (changes.isNotEmpty) {
      lines.add('changes:');
      for (final change in changes) {
        lines.add('  ${change.renderText()}');
      }
      lines.add('applied: $applied');
    }
    final preview = proposedConfig;
    if (preview != null) {
      lines.add('preview:');
      lines.addAll([for (final line in preview.split('\n')) '  $line']);
    }
    return lines.join('\n');
  }
}

String _renderValue(Object? value) => switch (value) {
  null => 'unset',
  final List<Object?> list => jsonEncode(list),
  final Map<String, Object?> map => jsonEncode(map),
  _ => value.toString(),
};
