/// The VOD player's seek step: how far one Left/Right press, or one `-N`/`+N`
/// tap, moves the position.
///
/// A device-wide preference (Settings → "VOD seek step"), not per-source: it is
/// a habit, like every other choice in `AppSettingsStore`, and a per-source copy
/// would ride `SourceConfig.settings` into the cloud where a paired phone has no
/// reason to inherit a television's seek step.
library;

/// The choices the Settings tile cycles through, in seconds — and therefore the
/// only values [normalizeSeekStep] will return.
///
/// Deliberately a fixed list rather than a free number: the step is chosen from
/// a remote, and a curated ladder (5/10/15/30/60) is one press per stop while a
/// numeric entry would need an IME on the one screen that is trying to avoid
/// one. Every value also maps onto a transport icon on the shared overlay except
/// 15 and 60, which fall back to the plain replay/forward glyph.
const List<int> kSeekStepChoices = [5, 10, 15, 30, 60];

/// The step used when nothing has been chosen, and the value a stored answer
/// outside [kSeekStepChoices] falls back to. 10 matches the hardcoded step this
/// preference replaced, so an install that never opens Settings seeks exactly as
/// it always did.
const int kDefaultSeekStepSeconds = 10;

/// Coerces a stored choice to one of [kSeekStepChoices], falling back to
/// [kDefaultSeekStepSeconds] for a null or unrecognised value.
///
/// Fails to the default rather than to the nearest choice: a value this build
/// does not know is one a *newer* build wrote, and guessing at it would seek
/// somewhere the user never asked for.
int normalizeSeekStep(int? value) {
  if (value != null && kSeekStepChoices.contains(value)) return value;
  return kDefaultSeekStepSeconds;
}

/// The choice after [current] in [kSeekStepChoices], wrapping at the end — so
/// the tile is a single least-surprising stop for a D-pad.
int nextSeekStep(int current) {
  final index = kSeekStepChoices.indexOf(normalizeSeekStep(current));
  return kSeekStepChoices[(index + 1) % kSeekStepChoices.length];
}
