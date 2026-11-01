import 'dart:convert';

import 'package:crypto/crypto.dart';

enum const PackProcessStatus(final int code) {
  success(0),
  failure(1),
  invalidInput(2),
  cancelled(3),
  recoveryRequired(4),
  interrupted(130),
}

final class const PackWarning({
  required final String id,
  required final String message,
}) {
  Map<String, Object?> toJson() => {'id': id, 'message': message};
}

final class const PackChangedPath({
  required final String path,
  required final String change,
}) {
  Map<String, Object?> toJson() => {'path': path, 'change': change};
}

final class const PackDisposition(final String wireName) {
  static const installed = PackDisposition('installed');
  static const updated = PackDisposition('updated');
  static const observed = PackDisposition('observed');
  static const validated = PackDisposition('validated');
  static const unchanged = PackDisposition('unchanged');
  static const keptLocal = PackDisposition('keptLocal');
  static const removed = PackDisposition('removed');
  static const rolledBack = PackDisposition('rolledBack');
  static const notAttempted = PackDisposition('notAttempted');
  static const failed = PackDisposition('failed');

  static const values = <PackDisposition>[
    installed,
    updated,
    observed,
    validated,
    unchanged,
    keptLocal,
    removed,
    rolledBack,
    notAttempted,
    failed,
  ];

  static PackDisposition parse(String value) => values.firstWhere(
    (disposition) => disposition.wireName == value,
    orElse: () => throw ArgumentError.value(value, 'disposition'),
  );

  @override
  bool operator ==(Object other) =>
      other is PackDisposition && other.wireName == wireName ||
      other is String && other == wireName;

  @override
  int get hashCode => wireName.hashCode;

  @override
  String toString() => wireName;
}

final class const PackResourceResult({
  required final String type,
  required final String name,
  required final PackDisposition disposition,
  final String? previousSnapshot,
  final String? snapshot,
  final bool linkOnly = false,
  final List<PackChangedPath> changedPaths = const <PackChangedPath>[],
}) {
  Map<String, Object?> toJson() => {
    'type': type,
    'name': name,
    'disposition': disposition.wireName,
    if (previousSnapshot != null) 'previousSnapshot': previousSnapshot,
    if (snapshot != null) 'snapshot': snapshot,
    'linkOnly': linkOnly,
    if (changedPaths.isNotEmpty)
      'changedPaths': [for (final path in changedPaths) path.toJson()],
  };
}

final class const PackPolicyChange({
  required final String? bump,
  required final bool includePrerelease,
  required final bool save,
}) {
  Map<String, Object?> toJson() => {
    if (bump != null) 'bump': bump,
    'includePrerelease': includePrerelease,
    'save': save,
  };

  String renderText() {
    final pieces = <String>[
      if (bump != null) 'bump=$bump',
      'includePrerelease=$includePrerelease',
      'save=$save',
    ];
    return pieces.join(' ');
  }
}

final class const PackResourcePlan({
  required final String type,
  required final String name,
  required final String action,
  final String? method,
  final List<String> targets = const <String>[],
  final String? previousSnapshot,
  final String? snapshot,
  final String? localEdit,
  final bool linkOnly = false,
  final List<PackChangedPath> changedPaths = const <PackChangedPath>[],
  final List<String> blockers = const <String>[],
}) {
  Map<String, Object?> toJson() => {
    'type': type,
    'name': name,
    'action': action,
    if (method != null) 'method': method,
    'targets': targets,
    if (previousSnapshot != null) 'previousSnapshot': previousSnapshot,
    if (snapshot != null) 'snapshot': snapshot,
    if (localEdit != null) 'localEdit': localEdit,
    'linkOnly': linkOnly,
    'changedPaths': [for (final path in changedPaths) path.toJson()],
    'blockers': blockers,
  };

  List<String> renderText() {
    final lines = <String>[
      '$type $name: $action'
          '${method == null ? '' : ' method=$method'}'
          '${targets.isEmpty ? '' : ' targets=${targets.join(',')}'}',
    ];
    if (previousSnapshot != null || snapshot != null) {
      lines.add(
        '  snapshot: ${previousSnapshot ?? '-'} -> ${snapshot ?? 'pending'}',
      );
    }
    if (localEdit != null) lines.add('  local edit: $localEdit');
    if (linkOnly) lines.add('  ownership: link-only');
    for (final path in changedPaths) {
      final marker = switch (path.change) {
        'added' => '+',
        'removed' => '-',
        _ => '~',
      };
      lines.add('  $marker ${path.path}');
    }
    for (final blocker in blockers) {
      lines.add('  blocker: $blocker');
    }
    return lines;
  }
}

final class PackPlan {
  const PackPlan._({
    required this.planId,
    required this.operation,
    required this.context,
    required this.source,
    required this.resources,
    required this.warnings,
    this.policy,
    this.cleanupRefs = const <String>[],
  });

  factory PackPlan.create({
    required String operation,
    required Map<String, Object?> context,
    required Map<String, Object?> source,
    required List<PackResourcePlan> resources,
    List<PackWarning> warnings = const <PackWarning>[],
    PackPolicyChange? policy,
    List<String> cleanupRefs = const <String>[],
  }) {
    final identity = <String, Object?>{
      'planVersion': 1,
      'operation': operation,
      'context': context,
      'source': source,
      'resources': [for (final resource in resources) resource.toJson()],
      'warnings': [for (final warning in warnings) warning.toJson()],
      if (policy != null) 'policy': policy.toJson(),
      'cleanupRefs': cleanupRefs,
    };
    final digest = sha256.convert(utf8.encode(jsonEncode(identity))).toString();
    return PackPlan._(
      planId: 'plan_v1_$digest',
      operation: operation,
      context: Map<String, Object?>.unmodifiable(context),
      source: Map<String, Object?>.unmodifiable(source),
      resources: List<PackResourcePlan>.unmodifiable(resources),
      warnings: List<PackWarning>.unmodifiable(warnings),
      policy: policy,
      cleanupRefs: List<String>.unmodifiable(cleanupRefs),
    );
  }

  final String planId;
  final String operation;
  final Map<String, Object?> context;
  final Map<String, Object?> source;
  final List<PackResourcePlan> resources;
  final List<PackWarning> warnings;
  final PackPolicyChange? policy;
  final List<String> cleanupRefs;

  Map<String, Object?> toJson() => {
    'planId': planId,
    'operation': operation,
    'context': context,
    'source': source,
    'resources': [for (final resource in resources) resource.toJson()],
    'warnings': [for (final warning in warnings) warning.toJson()],
    if (policy != null) 'policy': policy!.toJson(),
    if (cleanupRefs.isNotEmpty) 'cleanupRefs': cleanupRefs,
  };

  String renderText() {
    final lines = <String>[
      'review plan $planId',
      '  operation: $operation',
      '  context: ${_renderMap(context)}',
      '  source: ${_renderMap(source)}',
    ];
    if (policy != null) lines.add('  policy: ${policy!.renderText()}');
    if (cleanupRefs.isNotEmpty) {
      lines.add('  cleanup: ${cleanupRefs.join(', ')}');
    }
    for (final resource in resources) {
      lines.addAll(resource.renderText());
    }
    for (final warning in warnings) {
      lines.add('  warning[${warning.id}]: ${warning.message}');
    }
    return lines.join('\n');
  }

  static String _renderMap(Map<String, Object?> value) => value.entries
      .map((entry) => '${entry.key}=${entry.value ?? '-'}')
      .join(' ');
}

final class const PackOperationResult({
  required final String operation,
  required final String outcome,
  required final Map<String, Object?> context,
  required final Map<String, Object?> source,
  required final List<PackResourceResult> resources,
  final List<PackWarning> warnings = const <PackWarning>[],
  final bool dryRun = false,
  final PackPlan? plan,
}) {
  Map<String, Object?> envelope() => {
    'schemaVersion': 1,
    'operation': operation,
    'outcome': outcome,
    'context': context,
    'source': source,
    'resources': [for (final resource in resources) resource.toJson()],
    'warnings': [for (final warning in warnings) warning.toJson()],
    'summary': summary,
    'dryRun': dryRun,
    if (plan != null) 'plan': plan!.toJson(),
  };

  Map<String, Object?> get summary {
    final counts = <String, int>{};
    for (final resource in resources) {
      counts.update(
        resource.disposition.wireName,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final ordered = counts.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return <String, Object?>{
      'total': resources.length,
      for (final entry in ordered) entry.key: entry.value,
    };
  }

  String renderText() {
    final lines = <String>['$operation: $outcome'];
    if (plan != null) {
      lines.add(plan!.renderText());
      if (resources.isNotEmpty) lines.add('outcomes:');
      for (final resource in resources) {
        final snapshot = resource.snapshot == null
            ? ''
            : ' snapshot=${resource.snapshot}';
        final link = resource.linkOnly ? ' link-only' : '';
        lines.add(
          '  ${resource.type} ${resource.name}: ${resource.disposition.wireName}'
          '$snapshot$link',
        );
      }
    } else {
      for (final warning in warnings) {
        lines.add('warning[${warning.id}]: ${warning.message}');
      }
      for (final resource in resources) {
        final snapshot = resource.snapshot == null
            ? ''
            : ' snapshot=${resource.snapshot}';
        final link = resource.linkOnly ? ' link-only' : '';
        lines.add(
          '${resource.type} ${resource.name}: ${resource.disposition.wireName}'
          '$snapshot$link',
        );
        for (final path in resource.changedPaths) {
          final marker = switch (path.change) {
            'added' => '+',
            'removed' => '-',
            _ => '~',
          };
          lines.add('  $marker ${path.path}');
        }
      }
    }
    lines.add('summary: ${summary['total']} resource(s)');
    return lines.join('\n');
  }
}
