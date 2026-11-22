/// The declarative lifecycle boundary contract.
///
/// For every resource group, each lifecycle operation is either `supported`
/// (with the registered command path that honours it) or `deferred` (with a
/// one-line explanation). The contract is the single source of truth for
/// group help, `agent-resource support` output and refusal wording, so the
/// declared surface cannot drift from the registered command tree.
library;

/// One managed resource group.
enum BoundaryResource {
  skill('skill'),
  prompt('prompt'),
  agent('agent'),
  mcp('mcp'),
  context('context');

  const BoundaryResource(this.wireName);

  /// The registered group name of the resource.
  final String wireName;
}

/// One lifecycle operation evaluated per resource.
enum LifecycleBoundaryOperation {
  create('create'),
  inspect('inspect'),
  validate('validate'),
  install('install'),
  adopt('adopt'),
  update('update'),
  migrate('migrate'),
  replace('replace'),
  remove('remove'),
  backupRestore('backup-restore'),
  recover('recover'),
  edit('edit'),
  sync('sync');

  const LifecycleBoundaryOperation(this.wireName);

  /// The stable wire name used in text and JSON output.
  final String wireName;
}

/// Whether an operation is part of the supported lifecycle surface.
enum LifecycleBoundaryStatus { supported, deferred }

/// The boundary of one operation on one resource.
final class LifecycleBoundary {
  const LifecycleBoundary({
    required this.resource,
    required this.operation,
    required this.status,
    this.commandGroup,
    this.commandPath = const <String>[],
    this.deferredReason,
  });

  /// The resource group the boundary applies to.
  final BoundaryResource resource;

  /// The lifecycle operation.
  final LifecycleBoundaryOperation operation;

  /// Whether the operation is supported or deferred.
  final LifecycleBoundaryStatus status;

  /// The registered top-level group that owns [commandPath] when it
  /// differs from [resource], e.g. a Prompt route honoured by
  /// `pack install`.
  final String? commandGroup;

  /// The command path inside the resource group honouring the operation,
  /// e.g. `['backup']` or `['conversion', 'recover']`. Empty for deferred
  /// operations.
  final List<String> commandPath;

  /// The one-line explanation disclosed for a deferred operation.
  final String? deferredReason;
}

const String _promptManagedBoundary =
    'Pack-installed Prompts live under Skill ownership records; manage them '
    'through the Skill selectors of the pack.';
const String _syncThroughUpdate =
    'Managed installations are refreshed through update; there is no '
    'separate destination-sync operation.';
const String _syncThroughReplace =
    'Registrations are refreshed through replace; there is no separate '
    'destination-sync operation.';

/// The complete boundary contract.
const List<LifecycleBoundary> lifecycleBoundaries = <LifecycleBoundary>[
  // Skill: the complete lifecycle surface.
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.create,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['create'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.inspect,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['inspect'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.validate,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['validate'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.install,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['install'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.adopt,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['adopt'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.update,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['update'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.migrate,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['migrate'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.replace,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['replace'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.remove,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['remove'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.backupRestore,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['backup'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.recover,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['recover'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.edit,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['edit'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.skill,
    operation: LifecycleBoundaryOperation.sync,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: _syncThroughUpdate,
  ),
  // Prompt: authoring and read surfaces only; ownership stays with Skills.
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.create,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['create'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.inspect,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['inspect'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.validate,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['validate'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.install,
    status: LifecycleBoundaryStatus.supported,
    commandGroup: 'pack',
    commandPath: <String>['install'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.adopt,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: _promptManagedBoundary,
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.update,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: _promptManagedBoundary,
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.migrate,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: _promptManagedBoundary,
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.replace,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: _promptManagedBoundary,
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.remove,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: _promptManagedBoundary,
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.backupRestore,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'Managed Prompt artifacts are backed up and restored through their '
        'parent Skill records; conversion restore covers only conversion '
        'transactions.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.recover,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['conversion', 'recover'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.edit,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'There is no direct prompt edit; author a replacement with prompt '
        'create or edit the parent Skill.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.prompt,
    operation: LifecycleBoundaryOperation.sync,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: _promptManagedBoundary,
  ),
  // Agent: authoring, installation and managed lifecycle; no source update.
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.create,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['create'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.inspect,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['inspect'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.validate,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['validate'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.install,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['install'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.adopt,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['adopt'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.update,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'Agents have no source-bound update; re-author the definition and '
        'replace the managed installation.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.migrate,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'agent convert republishes across harnesses; there is no '
        'installation-route migration for Agents.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.replace,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['replace'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.remove,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['remove'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.backupRestore,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['backup'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.recover,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['recover'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.edit,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['edit'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.agent,
    operation: LifecycleBoundaryOperation.sync,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: _syncThroughReplace,
  ),
  // MCP: static checking plus journaled registration lifecycle.
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.create,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['register'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.inspect,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['inspect'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.validate,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['validate'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.install,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['register'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.adopt,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['adopt'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.update,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'Registrations have no in-place update; replace the registration.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.migrate,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'mcp convert republishes across harnesses; there is no '
        'registration-route migration.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.replace,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['replace'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.remove,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['unregister'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.backupRestore,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['backup'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.recover,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['recover'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.edit,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'Ordinary editing of registrations is not offered; unregister and '
        'register the corrected entry.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.mcp,
    operation: LifecycleBoundaryOperation.sync,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: _syncThroughReplace,
  ),
  // Context: template lifecycle plus one-shot injection.
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.create,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['create'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.inspect,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['inspect'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.validate,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'Templates are validated during create and edit; there is no '
        'standalone validation.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.install,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'Templates are local files; context inject publishes a copy into a '
        'destination instead of installing.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.adopt,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: 'Context templates are not adopted into a managed ledger.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.update,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'Edit the template and inject it again; injected destination files '
        'are not tracked.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.migrate,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: 'Context templates have no installation routes.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.replace,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: 'Context templates are edited in place, not replaced.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.remove,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['delete'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.backupRestore,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason: 'Context templates have no managed backup ledger.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.recover,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'Context templates run no managed transactions; there is nothing '
        'to recover.',
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.edit,
    status: LifecycleBoundaryStatus.supported,
    commandPath: <String>['edit'],
  ),
  LifecycleBoundary(
    resource: BoundaryResource.context,
    operation: LifecycleBoundaryOperation.sync,
    status: LifecycleBoundaryStatus.deferred,
    deferredReason:
        'context inject is a one-shot publication; editing a template does '
        'not update files it was previously injected into.',
  ),
];

/// The disclosed reason a direct `prompt install` is deferred.
const String promptDirectInstallBoundary =
    'Only a direct `prompt install` is deferred; Skill-backed Prompts '
    'publish through `pack install --type prompt` and derived templates '
    'through `skill install`/`pack install --prompt-target`.';

/// Per-resource notes that qualify the operation matrix.
const Map<BoundaryResource, List<String>> lifecycleBoundaryNotes =
    <BoundaryResource, List<String>>{
      BoundaryResource.skill: <String>[
        'Native validity and installation eligibility are reported '
            'separately; a natively valid Skill can still be ineligible for '
            'a selected target or method.',
      ],
      BoundaryResource.prompt: <String>[
        'Skill-backed Prompts publish through `pack install --type prompt` '
            'and derived Pi templates through `skill install`/`pack install '
            '--prompt-target`; only a direct `prompt install` is deferred. '
            'Both routes record Skill ownership.',
      ],
      BoundaryResource.mcp: <String>[
        'MCP inspection and validation are static checks; they make no '
            'runtime, connectivity or credential-success claims.',
        'Claude user and local MCP scopes are inspect-only for mutation.',
      ],
    };

/// The boundary of one operation on one resource.
LifecycleBoundary lifecycleBoundary(
  BoundaryResource resource,
  LifecycleBoundaryOperation operation,
) => lifecycleBoundaries.singleWhere(
  (boundary) =>
      boundary.resource == resource && boundary.operation == operation,
);

/// The boundaries of one resource, in declared operation order.
List<LifecycleBoundary> boundariesFor(BoundaryResource resource) =>
    <LifecycleBoundary>[
      for (final operation in LifecycleBoundaryOperation.values)
        lifecycleBoundary(resource, operation),
    ];

/// The text block rendered into resource-group help.
String renderBoundaryHelp(BoundaryResource resource) {
  final entries = <LifecycleBoundary>[
    for (final operation in LifecycleBoundaryOperation.values)
      lifecycleBoundary(resource, operation),
  ];
  final supported = [
    for (final entry in entries)
      if (entry.status == LifecycleBoundaryStatus.supported)
        entry.operation.wireName,
  ];
  final lines = <String>[
    'Lifecycle boundaries:',
    '  supported: ${supported.join(', ')}',
  ];
  for (final entry in entries) {
    if (entry.status == LifecycleBoundaryStatus.deferred) {
      lines.add(
        '  deferred ${entry.operation.wireName}: '
        '${entry.deferredReason}',
      );
    }
  }
  for (final note in lifecycleBoundaryNotes[resource] ?? const <String>[]) {
    lines.add('  note: $note');
  }
  return lines.join('\n');
}

/// The text rendering of the whole support matrix.
String renderSupportMatrixText() {
  final lines = <String>[];
  for (final resource in BoundaryResource.values) {
    lines.add('${resource.wireName}:');
    for (final operation in LifecycleBoundaryOperation.values) {
      final boundary = lifecycleBoundary(resource, operation);
      if (boundary.status == LifecycleBoundaryStatus.supported) {
        lines.add(
          '  ${operation.wireName}: supported '
          '(${boundary.commandGroup ?? resource.wireName} ${boundary.commandPath.join(' ')})',
        );
      } else {
        lines.add(
          '  ${operation.wireName}: deferred — ${boundary.deferredReason}',
        );
      }
    }
    for (final note in lifecycleBoundaryNotes[resource] ?? const <String>[]) {
      lines.add('  note: $note');
    }
  }
  return lines.join('\n');
}

/// The versioned JSON envelope of the whole support matrix.
Map<String, Object?> supportMatrixJson() => <String, Object?>{
  'schemaVersion': 1,
  'command': 'support',
  'outcome': 'reported',
  'resources': <String, Object?>{
    for (final resource in BoundaryResource.values)
      resource.wireName: <String, Object?>{
        'operations': <String, Object?>{
          for (final operation in LifecycleBoundaryOperation.values)
            operation.wireName: () {
              final boundary = lifecycleBoundary(resource, operation);
              return <String, Object?>{
                'status': boundary.status.name,
                if (boundary.status == LifecycleBoundaryStatus.supported)
                  'command': <String>[
                    boundary.commandGroup ?? resource.wireName,
                    ...boundary.commandPath,
                  ].join(' ')
                else
                  'reason': boundary.deferredReason,
              };
            }(),
        },
        'notes': lifecycleBoundaryNotes[resource] ?? const <String>[],
      },
  },
};
