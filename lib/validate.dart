import 'dart:convert';

import 'package:agent_resource/src/skill_validation.dart';
import 'package:mamba/mamba.dart';

typedef ValidateOperation = ValidationReport Function(String skill);

final class ValidateCommand(final ValidateOperation _validate) extends Command {
  this
    : super(
        options: [_skill],
        longDescription:
            'Validate one explicit skill directory against the pinned '
            'agentskills-core-ascii-v1 profile. Reads only immediate SKILL.md '
            'as strict UTF-8, up to 1,048,576 bytes with at most 65,536 '
            'frontmatter bytes. Linked markers are rejected. The ASCII-only '
            'name rule is product policy, not a universal specification rule; '
            'unknown fields are advisory warnings. Passing this profile is '
            'not universal compliance, security, or harness compatibility. '
            'The report is JSON. A valid '
            'report is written to stdout with status 0; an invalid report is '
            'written as JSON to stderr with status 2. Filesystem and other '
            'operational failures are human-readable status-1 errors. '
            'Validation is read-only: it does not execute scripts, follow '
            'references or network links, fetch dependencies, or mutate the '
            'skill directory.',
      );

  static final _skill = StringOption.required(
    'skill',
    description: 'Skill directory to validate.',
  );

  @override
  String get name => 'validate';

  @override
  String get shortDescription => 'Validate one skill directory.';

  @override
  String run(ValueOf valueOf, List<String> args) {
    final skill = valueOf(_skill);
    if (skill.trim().isEmpty) {
      throw MambaException('The --skill directory must not be blank.');
    }

    final report = _validate(skill);
    final output = jsonEncode(report.toJson());
    if (!report.valid) {
      throw MambaException(output, exitCode: 2);
    }
    return output;
  }
}
