// What auto-advance does with the sibling a film/episode plays into next.
//
// Its own leaf module, and **pure**: which of the two policies is stored, how
// one is parsed, and — given a candidate's watched state — whether it is played
// or skipped, are all decided here and nowhere else. That is the same
// separation `vod_step_session.dart` makes for stepping, and for the same
// reason: the interesting behaviour is pinned by a unit test rather than by a
// media_kit widget test that needs a real player and a real provider.
//
// Deliberately knows nothing about the keychain or the database. The store owns
// the encoding (an opaque `storageValue`), the player owns the reads, and this
// file owns only the decision.

/// How auto-advance treats a next title that was already played.
enum NextVideoPlayedBehavior {
  /// Resume a partially-watched title from its saved position, and skip one
  /// that was played to the end. The escape hatch is deliberate: the alternative
  /// is a user who rewatches a season having to sit through every finished
  /// episode again.
  resumeOrSkip('resume_or_skip', 'Continue / skip'),

  /// Always start the next title from the beginning, whether or not it was
  /// watched. For a rewatch this is the only useful answer — resuming into the
  /// last minute of an episode the user meant to see again is worse than a fresh
  /// start.
  startOver('start_over', 'Start over');

  const NextVideoPlayedBehavior(this.storageValue, this.label);

  /// The opaque string written to the keychain. The enum owns the encoding; the
  /// store carries it without interpreting it (same contract as
  /// [VodCardOrientation]).
  final String storageValue;

  /// The settings tile's trailing label.
  final String label;

  /// Parses a stored value, defaulting to [resumeOrSkip] for anything absent or
  /// unrecognised — the same fail-to-default shape the other stored enums use,
  /// so a value a future build wrote can never read as a crash or as a
  /// different policy here.
  static NextVideoPlayedBehavior parse(String? raw) {
    for (final value in NextVideoPlayedBehavior.values) {
      if (value.storageValue == raw) return value;
    }
    return NextVideoPlayedBehavior.resumeOrSkip;
  }

  /// The other policy — the settings tile cycles rather than opening a picker,
  /// exactly like the card-shape toggle.
  NextVideoPlayedBehavior get other =>
      this == NextVideoPlayedBehavior.resumeOrSkip
      ? NextVideoPlayedBehavior.startOver
      : NextVideoPlayedBehavior.resumeOrSkip;
}

/// What the player should do with one candidate sibling.
enum NextVideoAction {
  /// Open it from the top — a title never started, or one the policy says to
  /// replay.
  playFromStart,

  /// Open it and seek to its saved position.
  resume,

  /// Don't play it; try the sibling after it. Only ever answered by
  /// [nextVideoActionFor] for a fully-watched title under
  /// [NextVideoPlayedBehavior.resumeOrSkip].
  skip,
}

/// The action for one candidate, given what is known about it.
///
/// Order matters and is the whole of the rule: **under `resumeOrSkip`, a
/// finished title is skipped before the resume check even runs** — a finished
/// title has no resume row by construction (`savePlaybackPosition` drops it),
/// so a "skip only if there is no resume" ordering would play the finished
/// title from the top instead of stepping past it. `startOver` ignores both
/// facts and always plays from the top.
NextVideoAction nextVideoActionFor({
  required NextVideoPlayedBehavior behavior,
  required bool fullyWatched,
  required bool hasResume,
}) {
  if (behavior == NextVideoPlayedBehavior.startOver) {
    return NextVideoAction.playFromStart;
  }
  if (fullyWatched) return NextVideoAction.skip;
  return hasResume ? NextVideoAction.resume : NextVideoAction.playFromStart;
}

