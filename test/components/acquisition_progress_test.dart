import 'package:agent_resource/components/acquisition_progress.dart';
import 'package:interact2/interact2.dart';
import 'package:test/test.dart';

void main() {
  test('completes interact2 progress and returns the work result', () async {
    final events = <String>[];
    final component = AcquisitionProgressComponent(
      label: 'Acquiring test source',
      start: (spinner) {
        expect(
          spinner.rightPrompt(SpinnerStateType.inProgress),
          'Acquiring test source',
        );
        expect(spinner.icon, '✓');
        return SpinnerState(
          done: () {
            events.add('done');
            return () {};
          },
          failed: () {
            events.add('failed');
            return () {};
          },
        );
      },
    );
    final result = await component.render(() async {
      events.add('work');
      return 42;
    });
    expect(result, 42);
    expect(events, ['work', 'done']);
  });

  test('fails interact2 progress and preserves the work exception', () async {
    final failure = StateError('fetch failed');
    var failed = 0;
    final component = AcquisitionProgressComponent(
      start: (_) => SpinnerState(
        done: () => throw StateError('must not complete'),
        failed: () {
          failed++;
          return () {};
        },
      ),
    );
    await expectLater(
      component.render<int>(() => throw failure),
      throwsA(same(failure)),
    );
    expect(failed, 1);
  });

  test('cleanup failure does not hide the original work exception', () async {
    final failure = StateError('fetch failed');
    final component = AcquisitionProgressComponent(
      start: (_) => SpinnerState(
        done: () => throw StateError('must not complete'),
        failed: () => throw StateError('cleanup failed'),
      ),
    );
    await expectLater(
      component.render<int>(() => throw failure),
      throwsA(same(failure)),
    );
  });
}
