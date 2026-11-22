import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/resource_lifecycle_boundaries.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

/// Collects every command name in the subtree of [group].
Set<String> _descendantNames(GroupCommand group) {
  final names = <String>{};
  void visit(Command command) {
    names.add(command.name);
    if (command is GroupCommand) {
      for (final child in command.commands) {
        visit(child);
      }
    }
  }

  for (final child in group.commands) {
    visit(child);
  }
  return names;
}

/// Whether the relative [path] resolves inside [group].
bool _pathExists(GroupCommand group, List<String> path) {
  var children = group.commands;
  for (final segment in path) {
    final command = children.where((c) => c.name == segment).firstOrNull;
    if (command == null) return false;
    children = command is GroupCommand ? command.commands : const [];
  }
  return true;
}

/// The conventional command spelling a deferred operation would have.
const Map<LifecycleBoundaryOperation, List<String>>
_deferredCommandCandidates = <LifecycleBoundaryOperation, List<String>>{
  LifecycleBoundaryOperation.create: ['create'],
  LifecycleBoundaryOperation.inspect: ['inspect'],
  LifecycleBoundaryOperation.validate: ['validate'],
  LifecycleBoundaryOperation.install: ['install'],
  LifecycleBoundaryOperation.adopt: ['adopt'],
  LifecycleBoundaryOperation.update: ['update'],
  LifecycleBoundaryOperation.migrate: ['migrate'],
  LifecycleBoundaryOperation.replace: ['replace'],
  LifecycleBoundaryOperation.remove: ['remove', 'delete', 'unregister'],
  LifecycleBoundaryOperation.backupRestore: ['backup', 'restore'],
  LifecycleBoundaryOperation.recover: ['recover'],
  LifecycleBoundaryOperation.edit: ['edit'],
  LifecycleBoundaryOperation.sync: ['sync'],
};

void main() {
  final executor = createExecutor();

  GroupCommand resourceGroup(BoundaryResource resource) => executor.commands
      .whereType<GroupCommand>()
      .singleWhere((command) => command.name == resource.wireName);

  group('resource lifecycle boundaries', () {
    test('every resource declares every operation exactly once', () {
      for (final resource in BoundaryResource.values) {
        final operations = boundariesFor(resource);
        expect(
          operations.length,
          LifecycleBoundaryOperation.values.length,
          reason: resource.wireName,
        );
      }
    });

    for (final boundary in lifecycleBoundaries) {
      final label =
          '${boundary.resource.wireName} ${boundary.operation.wireName}';
      if (boundary.status == LifecycleBoundaryStatus.supported) {
        test('$label resolves to a registered command', () {
          final group = resourceGroup(boundary.resource);
          expect(boundary.commandPath, isNotEmpty, reason: label);
          expect(
            _pathExists(group, boundary.commandPath),
            isTrue,
            reason: '${boundary.resource.wireName} '
                '${boundary.commandPath.join(' ')} is not registered',
          );
        });
      } else {
        test('$label has no registered command', () {
          final group = resourceGroup(boundary.resource);
          expect(
            boundary.deferredReason,
            isNotNull,
            reason: 'deferred $label needs a disclosed explanation',
          );
          // A deferred operation means no direct lifecycle command; nested
          // helpers of another operation (e.g. prompt conversion restore)
          // do not count as offering it.
          final names = group.commands.map((c) => c.name).toSet();
          for (final candidate
              in _deferredCommandCandidates[boundary.operation]!) {
            expect(
              names.contains(candidate),
              isFalse,
              reason: '${boundary.resource.wireName} $candidate is registered '
                  'but $label is declared deferred',
            );
          }
        });
      }
    }
  });
}
