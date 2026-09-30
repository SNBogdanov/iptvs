/// How long the auto-switch shortcut rests on each channel — a per-source,
/// user-facing choice that belongs to the *future* auto-switch feature.
///
/// **This file is the setting, not the feature.** Nothing here starts a timer;
/// it is the value the feature will read, with its storage shape, its label and
/// its bounds decided once, so the feature itself does not invent them.
///
/// Why per source, in the `settings` blob, for the same reasons the buffer
/// preset is: it is a plain preference rather than a credential, so it rides the
/// source row into the cloud with no new storage and no migration, and a user
/// with a news wall and a movie wall may well want a different pace for each.
///
/// A **preset ladder rather than a free seconds field**, following
/// `BufferPreset`. The number is not arbitrary — it trades against
/// `kZapSettleDelay` and the provider's own reconnect backoff, so letting a
/// user type `1` or `600` buys two settings that cannot work (a period shorter
/// than the settle the zap already waits, and one so long the remote feels dead)
/// and puts the burden of that backoff knowledge on them. The ladder is also
/// what a D-pad can drive: a cycle, not a text field — a `TvTextField` on this
/// screen would trap the arrow keys the whole screen depends on.
library;

/// The periods on offer, in seconds, smallest first.
///
/// The floor is deliberate and is **not** arbitrary: [kZapSettleDelay] is 600 ms
/// and a zap's stop → resolve → play is one `create_link` on a
/// single-connection portal, so anything at or below the settle interval asks a
/// provider for a second link before it has handed back the first. The ceiling is
/// where a user stops believing the app is still switching at all.
enum ChannelDwell {
  seconds5(5),
  seconds10(10),
  seconds15(15),
  seconds20(20),
  seconds30(30),
  seconds60(60);

  const ChannelDwell(this.seconds);

  /// The dwell time, as the only unit the setting has.
  final int seconds;

  /// [Duration] form, for the feature's timer.
  Duration get duration => Duration(seconds: seconds);

  /// The value written to `SourceConfig.settings['channelDwellSeconds']`.
  int get storageValue => seconds;
}

/// The default, and the value a source that never touched this setting reads as.
///
/// [ChannelDwell.seconds10] — long enough to see what a channel is, short enough
/// that a user reaching for the shortcut perceives it as a switch rather than a
/// wait.
const ChannelDwell kDefaultChannelDwell = ChannelDwell.seconds10;

/// The value this app's own tests assert the default against, and the one an
/// untouched source serializes *without* writing (see
/// `SourceConfig.channelDwell`): absent means the default, so an existing
/// source's `settings` blob is byte-identical to what it was before this
/// setting existed. No migration, no cloud churn.
const int kDefaultChannelDwellSeconds = 10;

/// The stored value this build accepts. A number outside the ladder reads as the
/// default rather than as a clamp: the failure mode of a mangled preference
/// should be the default behaviour, not a silently different one — the same rule
/// `bufferPresetFromName` and `autoResumeLastChannel` follow.
ChannelDwell channelDwellFromSeconds(Object? stored) {
  final seconds = stored is int
      ? stored
      : int.tryParse('${stored ?? ''}'.trim());
  for (final dwell in ChannelDwell.values) {
    if (dwell.seconds == seconds) return dwell;
  }
  return kDefaultChannelDwell;
}

/// The next dwell in the settings tile's cycle, wrapping at the end.
ChannelDwell nextChannelDwell(ChannelDwell current) =>
    ChannelDwell.values[(current.index + 1) % ChannelDwell.values.length];

/// Short label for the settings tile's value: "5 s", "30 s".
String channelDwellLabel(ChannelDwell dwell) => '${dwell.seconds} s';

/// One-line explanation, for the tile's subtitle.
///
/// Says what the number is *for* rather than repeating the tile's own title,
/// because on a screen where nothing acts on it yet the only honest thing to
/// tell the user is what it will do.
String channelDwellHint(ChannelDwell dwell) => switch (dwell) {
  ChannelDwell.seconds5 => 'Very fast. Each channel is barely on screen.',
  ChannelDwell.seconds10 => 'Default. Long enough to see what a channel is.',
  ChannelDwell.seconds15 || ChannelDwell.seconds20 =>
    'A relaxed pace, for browsing rather than skimming.',
  ChannelDwell.seconds30 => 'Slow. Good for leaving a wall of channels running.',
  ChannelDwell.seconds60 => 'Very slow. Longest of the options.',
};
