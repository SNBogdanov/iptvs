// The auto-advance decision, pinned without a player, a widget, or a provider.
//
// Two things are load-bearing and both live in `next_video_policy.dart`:
// the *order* of the `resumeOrSkip` rule (a finished title is skipped before
// the resume check, because a finished title has no resume row by
// construction), and the storage encoding that both the settings store and the
// tile's cycle share. A regression in either reads as "auto-play played an
// episode I already finished" or "my choice did not stick", so they are pinned
// here rather than through a media_kit widget test.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/player/next_video_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the behaviour enum', () {
    test('parse round-trips every value', () {
      for (final value in NextVideoPlayedBehavior.values) {
        expect(NextVideoPlayedBehavior.parse(value.storageValue), value);
      }
    });

    test('an unknown or absent value reads as resumeOrSkip', () {
      // Deliberately not a throw: a keychain value written by a *newer* build
      // must not crash an older one, and skip/resume is the safe answer.
      for (final raw in <String?>[null, '', 'RESUME', 'rewind', 'startOver']) {
        expect(
          NextVideoPlayedBehavior.parse(raw),
          NextVideoPlayedBehavior.resumeOrSkip,
          reason: 'raw: "$raw"',
        );
      }
    });

    test('other cycles between exactly the two policies', () {
      expect(
        NextVideoPlayedBehavior.resumeOrSkip.other,
        NextVideoPlayedBehavior.startOver,
      );
      expect(
        NextVideoPlayedBehavior.startOver.other,
        NextVideoPlayedBehavior.resumeOrSkip,
      );
    });

    test('the labels are what the settings tile prints', () {
      expect(NextVideoPlayedBehavior.resumeOrSkip.label, 'Continue / skip');
      expect(NextVideoPlayedBehavior.startOver.label, 'Start over');
    });
  });

  group('the action for one candidate', () {
    NextVideoAction decide({
      NextVideoPlayedBehavior behavior = NextVideoPlayedBehavior.resumeOrSkip,
      bool watched = false,
      bool resume = false,
    }) => nextVideoActionFor(
      behavior: behavior,
      fullyWatched: watched,
      hasResume: resume,
    );

    test('an untouched title plays from the start', () {
      expect(decide(), NextVideoAction.playFromStart);
    });

    test('a partly-watched title resumes', () {
      expect(decide(resume: true), NextVideoAction.resume);
    });

    test('a finished title is skipped', () {
      expect(decide(watched: true), NextVideoAction.skip);
    });

    test('finished wins over a stray resume row', () {
      // The ordering that matters: `savePlaybackPosition` drops a finished
      // title's resume row, so a finished title has `hasResume == false` in
      // practice — but if a stale row ever survived, skipping must still win,
      // or the user rewatches the episode auto-play was meant to step past.
      expect(
        decide(watched: true, resume: true),
        NextVideoAction.skip,
      );
    });

    test('startOver ignores both facts and always plays from the top', () {
      for (final watched in [false, true]) {
        for (final resume in [false, true]) {
          expect(
            decide(
              behavior: NextVideoPlayedBehavior.startOver,
              watched: watched,
              resume: resume,
            ),
            NextVideoAction.playFromStart,
            reason: 'watched: $watched, resume: $resume',
          );
        }
      }
    });
  });

  group('the store behind the two settings', () {
    const store = AppSettingsStore();

    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('auto-play defaults off and absence is the default', () async {
      expect(await store.autoPlayNextVideo(), isFalse);
      // Only an explicit true is written; turning it back off deletes the key.
      await store.setAutoPlayNextVideo(true);
      expect(await store.autoPlayNextVideo(), isTrue);
      await store.setAutoPlayNextVideo(false);
      expect(await store.autoPlayNextVideo(), isFalse);
      expect(await FlutterSecureStorage().read(key: 'app_auto_play_next'),
          isNull);
    });

    test('the behaviour defaults to resumeOrSkip', () async {
      expect(await store.nextVideoPlayedBehavior(),
          NextVideoPlayedBehavior.resumeOrSkip);
      await store.setNextVideoPlayedBehavior(NextVideoPlayedBehavior.startOver);
      expect(await store.nextVideoPlayedBehavior(),
          NextVideoPlayedBehavior.startOver);
    });

    test('writing the default clears the key rather than storing it', () async {
      await store.setNextVideoPlayedBehavior(NextVideoPlayedBehavior.startOver);
      await store.setNextVideoPlayedBehavior(
        NextVideoPlayedBehavior.resumeOrSkip,
      );
      expect(
        await FlutterSecureStorage().read(key: 'app_next_video_behavior'),
        isNull,
      );
      expect(await store.nextVideoPlayedBehavior(),
          NextVideoPlayedBehavior.resumeOrSkip);
    });
  });
}
