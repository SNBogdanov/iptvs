import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/seek_step.dart';

/// The seek-step ladder is pure logic: the Settings tile cycles it, the store
/// normalises it, and three player surfaces read it. A wrong answer here is a
/// button that seeks somewhere other than it says, so the rules are pinned
/// rather than left to the surfaces to each get right.
void main() {
  group('normalizeSeekStep', () {
    test('keeps every offered choice', () {
      for (final step in kSeekStepChoices) {
        expect(normalizeSeekStep(step), step);
      }
    });

    test('null reads as the default', () {
      expect(normalizeSeekStep(null), kDefaultSeekStepSeconds);
    });

    test('an unlisted value falls to the default, not the nearest choice', () {
      // A value this build does not know is one a *newer* build wrote. Snapping
      // to the nearest choice would seek somewhere the user never asked for;
      // the default is the honest fallback.
      expect(normalizeSeekStep(7), kDefaultSeekStepSeconds);
      expect(normalizeSeekStep(0), kDefaultSeekStepSeconds);
      expect(normalizeSeekStep(-10), kDefaultSeekStepSeconds);
      expect(normalizeSeekStep(999), kDefaultSeekStepSeconds);
    });
  });

  group('nextSeekStep', () {
    test('advances through the ladder in order', () {
      expect(nextSeekStep(5), 10);
      expect(nextSeekStep(10), 15);
      expect(nextSeekStep(15), 30);
      expect(nextSeekStep(30), 60);
    });

    test('wraps at the end', () {
      expect(nextSeekStep(60), kSeekStepChoices.first);
    });

    test('normalises its input first, so a stray value still advances', () {
      // Both a null/unknown current step and the default land on the same next
      // stop, which is what keeps the tile a single press from a bad state.
      expect(nextSeekStep(7), 15);
      expect(nextSeekStep(kDefaultSeekStepSeconds), 15);
    });
  });
}
