import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/auto_switch.dart';
import 'package:iptvs/player/channel_dwell.dart';

void main() {
  group('AutoSwitch', () {
    late int advances;

    /// A tick fine enough to step inside the shortest rung on the ladder, which
    /// is 5 s — so the countdown is genuinely walked, not jumped.
    const tick = Duration(seconds: 1);

    /// A fixed epoch, so the deadline arithmetic is not relative to whenever the
    /// suite happened to run.
    final epoch = DateTime.utc(2026);

    AutoSwitch build({DateTime Function()? now}) => AutoSwitch(
      dwell: ChannelDwell.seconds5,
      tickInterval: tick,
      now: now,
      onAdvance: () => advances++,
    );

    /// Builds a mode whose clock follows the fake timeline.
    ///
    /// `fakeAsync` mocks `Timer` but **not** `DateTime.now`, so the mode has to
    /// be handed the fake clock explicitly — see the `_now` doc comment on
    /// `AutoSwitch`. The returned pair is the mode and the fake, so each test
    /// can dispose it.
    (AutoSwitch, FakeAsync) buildIn(FakeAsync async) =>
        (build(now: async.getClock(epoch).now), async);

    setUp(() {
      advances = 0;
    });

    test('starts off, and off means no clock and no label', () {
      final auto = build();
      addTearDown(auto.dispose);
      expect(auto.enabled, isFalse);
      expect(auto.hold, AutoSwitchHold.off);
      expect(autoSwitchChipLabel(auto), isEmpty);
    });

    test('toggling on starts a full period and says which way it went', () {
      final auto = build();
      addTearDown(auto.dispose);
      expect(auto.toggle(), isTrue, reason: 'reports the ON direction');
      expect(auto.enabled, isTrue);
      expect(auto.hold, AutoSwitchHold.none);
      expect(auto.remaining, ChannelDwell.seconds5.duration);

      expect(auto.toggle(), isFalse, reason: 'reports the OFF direction');
      expect(auto.enabled, isFalse);
    });

    test('counts the period down and advances exactly when it runs out', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        auto.enable();
        // One second short of the period: still counting, nothing switched.
        async.elapse(const Duration(seconds: 4));
        expect(advances, 0);
        expect(auto.remaining, greaterThan(Duration.zero));

        async.elapse(const Duration(seconds: 1));
        expect(advances, 1, reason: 'the switch happened on the period');
        expect(
          auto.enabled,
          isTrue,
          reason: 'advancing is not the same as switching off',
        );
        // And it armed the next period rather than running down to nothing.
        expect(auto.remaining, ChannelDwell.seconds5.duration);
        auto.dispose();
      });
    });

    test('a late tick does not push the period out by how late it was', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        auto.enable();
        // Deliberately coarse: 4 s in one tick, as a busy isolate or a
        // throttled hidden window would deliver it. The deadline is absolute,
        // so the switch is still on time.
        async.elapse(const Duration(seconds: 4));
        expect(advances, 0);
        async.elapse(const Duration(seconds: 1));
        expect(advances, 1);
        auto.dispose();
      });
    });

    test('a restart after a channel change buys a whole new period', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        auto.enable();
        async.elapse(const Duration(seconds: 4));
        auto.restart();
        expect(auto.remaining, ChannelDwell.seconds5.duration);
        // The point: a user who zaps by hand gets a full period to look at
        // what they chose instead of being pulled off it a moment later.
        async.elapse(const Duration(seconds: 4));
        expect(advances, 0);
        auto.dispose();
      });
    });

    test('a one-entry range holds instead of re-playing the same channel', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        auto.enable();
        auto.sync(settling: false, quickListOpen: false, entryCount: 1);
        expect(auto.hold, AutoSwitchHold.nothingToSwitch);
        async.elapse(const Duration(seconds: 20));
        expect(advances, 0);
        expect(autoSwitchChipLabel(auto), contains('one channel'));
        auto.dispose();
      });
    });

    test('a settle holds the clock, and an open list does too', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        auto.enable();
        auto.sync(settling: true, quickListOpen: false, entryCount: 3);
        expect(auto.hold, AutoSwitchHold.settling);
        auto.sync(settling: false, quickListOpen: true, entryCount: 3);
        expect(auto.hold, AutoSwitchHold.quickList);
        async.elapse(const Duration(seconds: 20));
        expect(
          advances,
          0,
          reason: 'neither may switch behind a resolve or a list being read',
        );
        auto.dispose();
      });
    });

    test('a hold resumes the frozen count rather than restarting it', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        auto.enable();
        async.elapse(const Duration(seconds: 2));
        auto.sync(settling: true, quickListOpen: false, entryCount: 3);
        final frozen = auto.remaining;
        async.elapse(const Duration(seconds: 30));
        expect(auto.remaining, frozen, reason: 'a hold is a freeze, not a stop');

        auto.sync(settling: false, quickListOpen: false, entryCount: 3);
        expect(auto.hold, AutoSwitchHold.none);
        // Resumes into the rest of the period it was part-way through, so a
        // list the user opened and closed does not cost them a fresh 5 s.
        expect(auto.remaining, frozen);
        auto.dispose();
      });
    });

    test('a cross-source change adopts the new period', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        // Adopted before it ever runs, so the longer pace is the one in force
        // for the whole measurement.
        auto.adoptDwell(ChannelDwell.seconds30);
        auto.enable();
        expect(auto.period, ChannelDwell.seconds30);
        expect(auto.remaining, ChannelDwell.seconds30.duration);
        async.elapse(const Duration(seconds: 20));
        expect(advances, 0, reason: 'the new, longer pace is in force');
        async.elapse(const Duration(seconds: 10));
        expect(advances, 1);
        auto.dispose();
      });
    });

    test('the label is empty when off and never blank while on', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        expect(autoSwitchChipLabel(auto), isEmpty);
        auto.enable();
        expect(autoSwitchChipLabel(auto), isNotEmpty);
        // Even frozen it says something: a chip that vanished while the mode
        // was on is how a user ends up unable to turn it off.
        auto.sync(settling: true, quickListOpen: false, entryCount: 3);
        expect(autoSwitchChipLabel(auto), contains('switching'));
        auto.dispose();
      });
    });

    test('the countdown never shows a zero it is about to act on', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        auto.enable();
        // Rounds *up*, so the last full second reads "1s" rather than flashing
        // "0s" and then switching.
        async.elapse(const Duration(milliseconds: 4900));
        expect(auto.remaining.inSeconds, 1);
        expect(autoSwitchChipLabel(auto), isNot(contains('0')));
        auto.dispose();
      });
    });

    test('dispose stops the clock', () {
      fakeAsync((async) {
        final (auto, _) = buildIn(async);
        auto.enable();
        auto.dispose();
        async.elapse(const Duration(seconds: 30));
        expect(
          advances,
          0,
          reason: 'a periodic timer that is only forgotten keeps the isolate '
              'awake forever',
        );
      });
    });
  });
}
