import 'package:agent_resource/components/agent_profile.dart';
import 'package:agent_resource/components/installation_approval.dart';
import 'package:agent_resource/components/installation_source.dart';
import 'package:agent_resource/components/prompt_support.dart';
import 'package:agent_resource/components/resource_selector.dart';
import 'package:agent_resource/components/skill_target_selector.dart';
import 'package:test/test.dart';

void main() {
  test('profile maps selected index and cancellation', () async {
    expect(
      await AgentProfileComponent(
        select: (p) {
          expect(p.options, ['claude', 'codex', 'pi-common']);
          return 1;
        },
      ).render(),
      'codex',
    );
    expect(await AgentProfileComponent(select: (_) => -1).render(), isNull);
  });
  test('approval uses safe default and waits for enter', () async {
    expect(
      await InstallationApprovalComponent(
        hasTerminal: () => true,
        confirm: (p) {
          expect(p.defaultValue, isFalse);
          expect(p.waitForNewLine, isTrue);
          return true;
        },
      ).render(),
      isTrue,
    );
  });
  test('approval fails closed without a terminal', () async {
    expect(
      await InstallationApprovalComponent(
        hasTerminal: () => false,
        confirm: (_) => fail('prompt must not run'),
      ).render(),
      isFalse,
    );
  });
  test('source trims and treats blank as cancellation', () async {
    expect(
      await InstallationSourceComponent(input: (_) => '  path  ').render(),
      'path',
    );
    expect(
      await InstallationSourceComponent(input: (_) => '  ').render(),
      isNull,
    );
  });
  test('resource selection passes options and avoids empty prompt', () async {
    expect(
      await ResourceSelectorComponent(
        options: ['a'],
        select: (p) {
          expect(p.options, ['a']);
          return [0];
        },
      ).render(),
      [0],
    );
    expect(
      await ResourceSelectorComponent(
        options: [],
        select: (_) => fail('called'),
      ).render(),
      isEmpty,
    );
  });
  test('target defaults are converted to a boolean mask', () async {
    expect(
      await SkillTargetSelectorComponent(
        options: ['a', 'b', 'c'],
        defaults: [0, 2],
        select: (p) {
          expect(p.defaults, [true, false, true]);
          return [2];
        },
      ).render(),
      [2],
    );
    expect(
      await SkillTargetSelectorComponent(
        options: [],
        select: (_) => fail('called'),
      ).render(),
      isEmpty,
    );
  });
  test('reset failure does not mask the original prompt failure', () {
    final failure = StateError('prompt');
    var resetCalled = false;
    expect(
      () => runPrompt(
        () => throw failure,
        reset: () {
          resetCalled = true;
          throw StateError('reset');
        },
      ),
      throwsA(same(failure)),
    );
    expect(resetCalled, isTrue);
  });
}
