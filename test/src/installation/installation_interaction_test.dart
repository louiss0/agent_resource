import 'package:agent_resource/src/installation/installation_interaction.dart';
import 'package:agent_resource/src/installation/resource_catalog.dart';
import 'package:test/test.dart';

void main() {
  test('discovered Skill caption shows its name and parent folder', () {
    const offering = SkillOffering(
      id: 'skills/engineering/implement',
      path: 'skills/engineering/implement',
      label: 'implement',
    );
    expect(resourceChoiceLabel(offering), 'implement (skills/engineering)');
    expect(offering.id, 'skills/engineering/implement');
    expect(offering.path, 'skills/engineering/implement');
  });

  test('unlabelled Skill uses its basename rather than repeating the path', () {
    expect(
      resourceChoiceLabel(
        const SkillOffering(
          id: 'skills/engineering/implement',
          path: 'skills/engineering/implement',
          label: null,
        ),
      ),
      'implement (skills/engineering)',
    );
  });

  test('root-level Skill caption uses the current parent folder', () {
    expect(
      resourceChoiceLabel(
        const SkillOffering(
          id: 'implement',
          path: 'implement',
          label: 'implement',
        ),
      ),
      'implement (.)',
    );
  });

  test('curated captions retain distinct IDs and full paths', () {
    expect(
      resourceChoiceLabel(
        const SkillOffering(
          id: 'reviewer',
          path: 'skills/review',
          label: 'Review code',
        ),
      ),
      'reviewer — Review code (skills/review)',
    );
  });

  test('Agent captions retain the native profile and file path', () {
    expect(
      resourceChoiceLabel(
        const AgentOffering(
          id: 'reviewer',
          path: 'agents/review.md',
          label: null,
          profile: NativeAgentProfile.claude,
        ),
      ),
      'reviewer ( [claude]agents/review.md)',
    );
  });
}
