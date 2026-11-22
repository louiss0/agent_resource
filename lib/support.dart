import 'dart:convert';

import 'package:mamba/mamba.dart';

import 'src/resource_lifecycle_boundaries.dart';

/// The `agent-resource support` command.
///
/// Prints the declared lifecycle boundary matrix for every resource group:
/// which operations are supported, through which registered command, and
/// which are deferred, with the disclosed explanation. The matrix comes from
/// the single boundary contract verified against the command tree.
final class SupportCommand extends Command {
  SupportCommand()
    : super(
        options: [_format],
        longDescription:
            'Report the supported and deferred lifecycle operations of every '
            'resource group. Each supported operation names the registered '
            'command that honours it; each deferred operation explains the '
            'intentional boundary instead of surfacing it as a refusal.',
      );

  static final _format = ChoiceOption.withDefault(
    'format',
    choices: SupportOutputFormat.values,
    defaultValue: SupportOutputFormat.text,
    description: 'Output format of the support matrix.',
  );

  @override
  String get name => 'support';

  @override
  String get shortDescription =>
      'Report the lifecycle boundary matrix of every resource.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    return switch (valueOf(_format)) {
      SupportOutputFormat.json => jsonEncode(supportMatrixJson()),
      SupportOutputFormat.text => renderSupportMatrixText(),
    };
  }
}

/// The supported output formats of `agent-resource support`.
enum SupportOutputFormat {
  text('text'),
  json('json');

  const SupportOutputFormat(this.wireName);

  /// The wire spelling of the format.
  final String wireName;
}
