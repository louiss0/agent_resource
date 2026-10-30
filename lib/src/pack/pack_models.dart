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

final class const PackResourceResult({
  required final String type,
  required final String name,
  required final String disposition,
  final String? previousSnapshot,
  final String? snapshot,
  final bool linkOnly = false,
  final List<PackChangedPath> changedPaths = const <PackChangedPath>[],
}) {
  Map<String, Object?> toJson() => {
    'type': type,
    'name': name,
    'disposition': disposition,
    if (previousSnapshot != null) 'previousSnapshot': previousSnapshot,
    if (snapshot != null) 'snapshot': snapshot,
    'linkOnly': linkOnly,
    if (changedPaths.isNotEmpty)
      'changedPaths': [for (final path in changedPaths) path.toJson()],
  };
}

final class const PackOperationResult({
  required final String operation,
  required final String outcome,
  required final Map<String, Object?> context,
  required final Map<String, Object?> source,
  required final List<PackResourceResult> resources,
  final List<PackWarning> warnings = const <PackWarning>[],
  final bool dryRun = false,
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
  };

  Map<String, Object?> get summary {
    final counts = <String, int>{};
    for (final resource in resources) {
      counts.update(
        resource.disposition,
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
    for (final warning in warnings) {
      lines.add('warning[${warning.id}]: ${warning.message}');
    }
    for (final resource in resources) {
      final snapshot = resource.snapshot == null
          ? ''
          : ' snapshot=${resource.snapshot}';
      final link = resource.linkOnly ? ' link-only' : '';
      lines.add(
        '${resource.type} ${resource.name}: ${resource.disposition}$snapshot$link',
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
    lines.add('summary: ${summary['total']} resource(s)');
    return lines.join('\n');
  }
}
