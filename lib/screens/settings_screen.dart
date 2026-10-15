import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../data/app_settings_store.dart';
import '../data/vod_card_orientation.dart';
import '../player/next_video_policy.dart';
import '../player/player_chrome_prefs.dart';
import '../player/seek_step.dart';
import '../player/tray.dart';
import '../player/window_placement.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';

/// Global, profile-independent settings (docs/player.md "System tray icon").
///
/// Reachable from the avatar menu whatever profile is active: the settings made
/// here are device preferences, never per-profile ones, and they must keep
/// working across a profile switch.
class SettingsScreen extends StatefulWidget {
  final AppSettingsStore store;

  const SettingsScreen({super.key, required this.store});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _closeToTray;
  bool? _randomZapping;
  bool? _alwaysOnTop;
  bool? _rememberPlacement;
  bool? _showClock;
  bool? _showPlaybackTimes;
  bool? _showChannelName;
  VodCardOrientation? _cards;
  bool? _autoPlayNext;
  NextVideoPlayedBehavior? _nextBehavior;
  int? _seekStep;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final closeToTray = await widget.store.closeToTray();
    final randomZapping = await widget.store.randomZapping();
    final alwaysOnTop = await widget.store.alwaysOnTop();
    final rememberPlacement = await widget.store.rememberWindowPlacement();
    final showClock = await widget.store.showPlayerClock();
    final showPlaybackTimes = await widget.store.showPlaybackTimes();
    final showChannelName = await widget.store.showChannelName();
    final cards = VodCardOrientation.parse(
      await widget.store.rawVodCardOrientation(),
    );
    final autoPlayNext = await widget.store.autoPlayNextVideo();
    final nextBehavior = await widget.store.nextVideoPlayedBehavior();
    final seekStep = await widget.store.seekStepSeconds();
    if (mounted) {
      setState(() {
        _closeToTray = closeToTray;
        _randomZapping = randomZapping;
        _alwaysOnTop = alwaysOnTop;
        _rememberPlacement = rememberPlacement;
        _showClock = showClock;
        _showPlaybackTimes = showPlaybackTimes;
        _showChannelName = showChannelName;
        _cards = cards;
        _autoPlayNext = autoPlayNext;
        _nextBehavior = nextBehavior;
        _seekStep = seekStep;
      });
    }
  }

  Future<void> _toggleCloseToTray() async {
    final next = !(_closeToTray ?? true);
    setState(() => _closeToTray = next);
    await widget.store.setCloseToTray(next);
    await applyCloseToTray(next);
  }

  Future<void> _toggleRandomZapping() async {
    final next = !(_randomZapping ?? false);
    setState(() => _randomZapping = next);
    await widget.store.setRandomZapping(next);
  }

  Future<void> _toggleAlwaysOnTop() async {
    final next = !(_alwaysOnTop ?? false);
    setState(() => _alwaysOnTop = next);
    alwaysOnTopEnabled.value = next;
    await widget.store.setAlwaysOnTop(next);
    // Turning it off mid-playback must drop the style immediately; turning it
    // on mid-playback must raise it. The active screen re-syncs on its next
    // playback-state change, but this applies the setting's own effect now.
    if (!next) {
      await applyAlwaysOnTop(false);
    }
  }

  Future<void> _toggleRememberPlacement() async {
    final next = !(_rememberPlacement ?? true);
    setState(() => _rememberPlacement = next);
    // Turning it on records the window where it is *now*, rather than waiting
    // for the next hide - otherwise the first run after the switch opens where
    // Windows put it, which is the one run the user is watching for the effect.
    await widget.store.setRememberWindowPlacement(next);
    if (next) {
      await recordWindowPlacement(store: widget.store);
    }
  }

  /// Two shapes only, so this cycles rather than opening a picker: one less
  /// stop for a remote to reach, and the tile's trailing label already prints
  /// which one is current.
  Future<void> _cycleCardOrientation() async {
    final next = otherVodCardOrientation(
      _cards ?? VodCardOrientation.portrait,
    );
    setState(() => _cards = next);
    // Publishes through the notifier the grid listens to, so the cards behind
    // this route redraw straight away instead of on some later rebuild.
    await setVodCardOrientation(next, store: widget.store);
  }

  Future<void> _toggleShowClock() async {
    final next = !(_showClock ?? true);
    setState(() => _showClock = next);
    // Publishes to the notifier every chrome surface reads, so the next player
    // opened draws the badge the user just asked for. Nothing is listening while
    // this route is up (Settings is unreachable from a player), so a running
    // playback is deliberately left alone rather than repainted mid-session.
    showPlayerClock.value = next;
    await widget.store.setShowPlayerClock(next);
  }

  Future<void> _toggleShowPlaybackTimes() async {
    final next = !(_showPlaybackTimes ?? true);
    setState(() => _showPlaybackTimes = next);
    showPlaybackTimes.value = next;
    await widget.store.setShowPlaybackTimes(next);
  }

  Future<void> _toggleShowChannelName() async {
    final next = !(_showChannelName ?? true);
    setState(() => _showChannelName = next);
    showChannelName.value = next;
    await widget.store.setShowChannelName(next);
  }

  Future<void> _toggleAutoPlayNext() async {
    final next = !(_autoPlayNext ?? false);
    setState(() => _autoPlayNext = next);
    await widget.store.setAutoPlayNextVideo(next);
  }

  /// Two policies, so this cycles rather than opening a picker — the same
  /// one-less-stop reasoning as the card-shape tile, and the trailing label
  /// already prints which one is current. Its effect is a no-op until
  /// auto-play is on; the subtitle says so.
  Future<void> _cycleNextBehavior() async {
    final next = (_nextBehavior ?? NextVideoPlayedBehavior.resumeOrSkip).other;
    setState(() => _nextBehavior = next);
    await widget.store.setNextVideoPlayedBehavior(next);
  }

  /// A fixed ladder (5/10/15/30/60 s), so this cycles rather than opening a
  /// picker — one less stop for a remote, and the trailing label already prints
  /// the current step. Publishes through the notifier the player chrome reads,
  /// so the next player opened seeks by what the user just chose.
  Future<void> _cycleSeekStep() async {
    final next = nextSeekStep(_seekStep ?? kDefaultSeekStepSeconds);
    setState(() => _seekStep = next);
    seekStepSeconds.value = next;
    await widget.store.setSeekStepSeconds(next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            if (Platform.isWindows)
              _SettingTile(
                icon: Icons.close_fullscreen_outlined,
                title: 'Close to tray',
                subtitle:
                    'Closing the window hides it to the tray instead of '
                    'quitting. Quit from the tray icon menu, or the in-app exit.',
                trailing: (_closeToTray ?? true) ? 'On' : 'Off',
                onTap: _toggleCloseToTray,
              ),
            _SettingTile(
              icon: Icons.shuffle,
              title: 'Random zapping',
              subtitle:
                  'Zapping and the auto-switch timer pick a random channel '
                  'instead of the next one.',
              trailing: (_randomZapping ?? false) ? 'On' : 'Off',
              onTap: _toggleRandomZapping,
            ),
            if (Platform.isWindows)
              _SettingTile(
                icon: Icons.vertical_align_top,
                title: 'Always on top in fullscreen',
                subtitle:
                    'While fullscreen playback is active, the window stays '
                    'above other windows. The windowed preview stays normal.',
                trailing: (_alwaysOnTop ?? false) ? 'On' : 'Off',
                onTap: _toggleAlwaysOnTop,
              ),
            if (Platform.isWindows)
              _SettingTile(
                icon: Icons.crop_free,
                title: 'Remember window position and size',
                subtitle:
                    'Reopen the window where you left it. If the monitor it '
                    'was on is gone, Windows decides where it opens instead.',
                trailing: (_rememberPlacement ?? true) ? 'On' : 'Off',
                onTap: _toggleRememberPlacement,
              ),
            _SettingTile(
              icon: Icons.grid_view_outlined,
              title: 'VOD and series card shape',
              subtitle:
                  'Portrait shows whole 2:3 posters; landscape crops them to a '
                  '16:9 band and fits far more titles on screen. The Continue '
                  'watching thumbnails stay landscape either way.',
              trailing: (_cards ?? VodCardOrientation.portrait).label,
              onTap: _cycleCardOrientation,
            ),
            _SettingTile(
              icon: Icons.skip_next_outlined,
              title: 'Auto-play the next video',
              subtitle:
                  'When a film or episode finishes, move on to the next one in '
                  'the same list automatically. Live channels never finish, so '
                  'this changes nothing there.',
              trailing: (_autoPlayNext ?? false) ? 'On' : 'Off',
              onTap: _toggleAutoPlayNext,
            ),
            _SettingTile(
              icon: Icons.replay_circle_filled_outlined,
              title: 'Next video already watched',
              subtitle:
                  'What auto-play does with a title you have seen before: '
                  'resume a partly-watched one and skip a finished one, or '
                  'always start it over. Applies only while auto-play is on.',
              trailing: (_nextBehavior ?? NextVideoPlayedBehavior.resumeOrSkip)
                  .label,
              onTap: _cycleNextBehavior,
            ),
            _SettingTile(
              icon: Icons.schedule_outlined,
              title: 'Clock in the player',
              subtitle:
                  'Show the wall clock in the player\'s top bar, on every '
                  'surface. Hides the badge while the controls are up; nothing '
                  'draws a clock over the picture itself.',
              trailing: (_showClock ?? true) ? 'On' : 'Off',
              onTap: _toggleShowClock,
            ),
            _SettingTile(
              icon: Icons.timelapse_outlined,
              title: 'Playback time in the player',
              subtitle:
                  'Show how far into a film or episode you are, beside the '
                  'progress bar. Live channels have no progress bar, so this '
                  'changes nothing there.',
              trailing: (_showPlaybackTimes ?? true) ? 'On' : 'Off',
              onTap: _toggleShowPlaybackTimes,
            ),
            _SettingTile(
              icon: Icons.fast_forward_outlined,
              title: 'VOD seek step',
              subtitle:
                  'How far Left/Right on the progress bar, and the -/+ buttons '
                  'beside it, move a film or episode. Live channels have no '
                  'progress bar, so this changes nothing there.',
              trailing: '${_seekStep ?? kDefaultSeekStepSeconds} s',
              onTap: _cycleSeekStep,
            ),
            _SettingTile(
              icon: Icons.label_outline,
              title: 'Channel name in the player',
              subtitle:
                  'Show the channel or title. When on, the name also stays on '
                  'screen top-left while the controls are hidden, mirroring the '
                  'clock top-right.',
              trailing: (_showChannelName ?? true) ? 'On' : 'Off',
              onTap: _toggleShowChannelName,
            ),
          ],
        ),
      ),
    );
  }
}

/// A single focus-stop toggle row, mirroring the source-settings tiles so the
/// D-pad needs no sub-menu and the trailing indicator is a "On"/"Off" label
/// rather than a separately-focusable [Switch].
class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String trailing;
  final VoidCallback onTap;

  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: onTap,
      scrollOnFocus: false,
      debugLabel: 'settings.$title',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.textLo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              trailing,
              style: TextStyle(
                color: trailing == 'On'
                    ? AppColors.accent
                    : AppColors.textLo,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
