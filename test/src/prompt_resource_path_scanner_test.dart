import 'package:agent_resource/src/prompt_resource_path_scanner.dart';
import 'package:test/test.dart';

void main() {
  group('PromptResourcePathScanner', () {
    test('finds whole path segments that name a resource directory', () {
      final matches = PromptResourcePathScanner.scan(
        'Read references/guide.md and run scripts\\run.sh.',
      );
      expect(matches.map((match) => match.segment), <String>[
        'references',
        'scripts',
      ]);
    });

    test('finds a segment at the start of a line', () {
      final matches = PromptResourcePathScanner.scan('assets/logo.png\n');
      expect(matches.single.segment, 'assets');
    });

    test('does not treat a word without a separator as a resource path', () {
      expect(
        PromptResourcePathScanner.scan('references are explained'),
        isEmpty,
      );
      expect(PromptResourcePathScanner.scan('scripts_total'), isEmpty);
    });

    test('does not treat a partial segment as a resource path', () {
      expect(PromptResourcePathScanner.scan('myreferences/guide.md'), isEmpty);
      expect(PromptResourcePathScanner.scan('assetsomething/x'), isEmpty);
    });

    test('reports the offset of the whole match for a location', () {
      const body = 'First line\nRead references/guide.md';
      final match = PromptResourcePathScanner.scan(body).single;
      expect(body.substring(match.matchStart).startsWith('references'), isTrue);
    });

    test('an empty body has no matches', () {
      expect(PromptResourcePathScanner.scan(''), isEmpty);
    });
  });
}
