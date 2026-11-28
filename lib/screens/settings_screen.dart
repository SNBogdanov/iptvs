import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../data/app_settings_store.dart';
import '../data/content_tabs_visibility.dart';
import '../data/device_class.dart';
import '../data/local_profile_store.dart';
import '../data/proxy_config.dart';
import '../data/stream_kind.dart';
import '../data/vod_card_orientation.dart';
import '../player/double_tap_action.dart';
import '../player/next_video_policy.dart';
import '../player/player_chrome_prefs.dart';
import '../player/player_controls_prefs.dart';
import '../player/seek_step.dart';
import '../player/tray.dart';
import '../player/window_placement.dart';
import '../sources/source.dart' show ContentKind, kContentSections;
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

  /// Which channel-list sections are visible; null until [_load] reads the
  /// notifier `main` seeded.
  Set<ContentKind>? _sections;
  VodCardOrientation? _cards;
  bool? _autoPlayNext;
  bool? _movieQuickPlay;
  NextVideoPlayedBehavior? _nextBehavior;
  int? _seekStep;
  ProxyConfig? _proxy;
  DoubleTapAction? _doubleTap;
  ProfilePickerStartup? _pickerStartup;

  /// Per content kind, whether its **stream** is opened through the proxy.
  /// Absent until [_load] answers; the tiles read `?? false`, the stored
  /// default.
  final Map<StreamKind, bool> _streamProxy = {};

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
    final sections = {...visibleContentTabs.value};
    final cards = VodCardOrientation.parse(
      await widget.store.rawVodCardOrientation(),
    );
    final autoPlayNext = await widget.store.autoPlayNextVideo();
    final movieQuickPlay = await widget.store.movieQuickPlay();
    final nextBehavior = await widget.store.nextVideoPlayedBehavior();
    final seekStep = await widget.store.seekStepSeconds();
    final proxyRaw = await widget.store.rawProxyConfig();
    final streamProxy = {
      for (final kind in StreamKind.values)
        kind: await widget.store.streamProxy(kind),
    };
    final doubleTap = DoubleTapAction.parse(
      await widget.store.rawDoubleTapAction(),
    );
    final pickerStartup = await const LocalProfileStore().pickerStartup();
    if (mounted) {
      setState(() {
        _closeToTray = closeToTray;
        _randomZapping = randomZapping;
        _alwaysOnTop = alwaysOnTop;
        _rememberPlacement = rememberPlacement;
        _showClock = showClock;
        _showPlaybackTimes = showPlaybackTimes;
        _showChannelName = showChannelName;
        _sections = sections;
        _cards = cards;
        _autoPlayNext = autoPlayNext;
        _movieQuickPlay = movieQuickPlay;
        _nextBehavior = nextBehavior;
        _seekStep = seekStep;
        _doubleTap = doubleTap;
        _pickerStartup = pickerStartup;
        _streamProxy
          ..clear()
          ..addAll(streamProxy);
        _proxy = ProxyConfig(
          mode: ProxyMode.parse(proxyRaw?['mode']),
          host: proxyRaw?['host'] ?? '',
          port: int.tryParse(proxyRaw?['port'] ?? '') ?? 0,
        );
      });
    }
  }

  Future<void> _toggleCloseToTray() async {
    final next = !(_closeToTray ?? true);
    setState(() => _closeToTray = next);
    await widget.store.setCloseToTray(next);
    await applyCloseToTray(next);
  }

  Future<void> _toggleMovieQuickPlay() async {
    final next = !(_movieQuickPlay ?? false);
    setState(() => _movieQuickPlay = next);
    await widget.store.setMovieQuickPlay(next);
  }

  Future<void> _toggleRandomZapping() async {
    final next = !(_randomZapping ?? false);
    setState(() => _randomZapping = next);
    await widget.store.setRandomZapping(next);
  }

  /// "Ask for a profile at startup." On = the picker appears whenever there is
  /// a choice to make (the historical `auto` behaviour); off = boot straight
  /// into the last profile, which stays the active one in the keychain. A
  /// profile with a PIN still asks for it — that gate lives in the picker and
  /// is not something this switch may bypass.
  Future<void> _toggleAskForProfile() async {
    final asking =
        (_pickerStartup ?? ProfilePickerStartup.auto) !=
        ProfilePickerStartup.off;
    final next = asking ? ProfilePickerStartup.off : ProfilePickerStartup.auto;
    setState(() => _pickerStartup = next);
    await const LocalProfileStore().setPickerStartup(next);
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
    final next = otherVodCardOrientation(_cards ?? VodCardOrientation.portrait);
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

  /// Shows or hides one content section in the channel list.
  ///
  /// The **last** visible section cannot be turned off: the list would have no
  /// content at all, and the tab row (which is the only way back) would be gone
  /// with it. Refusing here rather than silently re-enabling later keeps the
  /// switch honest — the user sees "On" and a message.
  Future<void> _toggleSection(ContentKind kind) async {
    final current = {...?_sections};
    if (current.contains(kind)) {
      if (current.length == 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('At least one section has to stay visible'),
          ),
        );
        return;
      }
      current.remove(kind);
    } else {
      current.add(kind);
    }
    setState(() => _sections = current);
    await saveVisibleContentTabs(current);
  }

  String _sectionTrailing(ContentKind kind) =>
      (_sections ?? {...kContentSections}).contains(kind) ? 'On' : 'Off';

  Future<void> _toggleAutoPlayNext() async {
    final next = !(_autoPlayNext ?? false);
    setState(() => _autoPlayNext = next);
    await widget.store.setAutoPlayNextVideo(next);
  }

  /// Cycles System → Custom → Off. A cycle rather than a picker for the same
  /// reason as the other three-way tiles: one focus stop, trailing label prints
  /// the current choice.
  Future<void> _cycleProxyMode() async {
    final current = _proxy ?? const ProxyConfig();
    final next = current.copyWith(mode: current.mode.next);
    setState(() => _proxy = next);
    await setProxyConfig(next, store: widget.store);
  }

  /// Opens the host/port editor. Saving a usable address also switches the mode
  /// to Custom: typing a server and leaving the mode on System would look like
  /// the address was ignored, which is exactly the confusion this setting
  /// exists to avoid.
  Future<void> _editProxyServer() async {
    final current = _proxy ?? const ProxyConfig();
    final edited = await showDialog<ProxyConfig>(
      context: context,
      builder: (context) => _ProxyServerDialog(initial: current),
    );
    if (edited == null) return;
    final value = edited.host.trim().isEmpty || edited.port <= 0
        ? current.copyWith(host: edited.host, port: edited.port)
        : edited.copyWith(mode: ProxyMode.custom);
    setState(() => _proxy = value);
    await setProxyConfig(value, store: widget.store);
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
            _SettingTile(
              icon: Icons.switch_account_outlined,
              title: 'Ask for a profile at startup',
              subtitle:
                  'Off opens the last used profile straight away. A profile '
                  'protected by a PIN still asks for it.',
              trailing:
                  (_pickerStartup ?? ProfilePickerStartup.auto) ==
                      ProfilePickerStartup.off
                  ? 'Off'
                  : 'On',
              onTap: _toggleAskForProfile,
            ),
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
              icon: Icons.live_tv_rounded,
              title: 'Live section',
              subtitle:
                  'Show Live in the channel list. Hidden, its channels, '
                  'categories and preview pane are skipped entirely. At least '
                  'one section has to stay visible; with only one left the tab '
                  'row is not drawn and the list opens straight into it.',
              trailing: _sectionTrailing(ContentKind.live),
              onTap: () => _toggleSection(ContentKind.live),
            ),
            _SettingTile(
              icon: Icons.movie_outlined,
              title: 'Movies section',
              subtitle:
                  'Show Movies in the channel list. Hidden, the tab and its '
                  'catalogue are skipped entirely.',
              trailing: _sectionTrailing(ContentKind.movie),
              onTap: () => _toggleSection(ContentKind.movie),
            ),
            _SettingTile(
              icon: Icons.tv_outlined,
              title: 'Series section',
              subtitle:
                  'Show Series in the channel list. Hidden, the tab and its '
                  'catalogue are skipped entirely.',
              trailing: _sectionTrailing(ContentKind.series),
              onTap: () => _toggleSection(ContentKind.series),
            ),
            _SettingTile(
              icon: Icons.grid_view_outlined,
              title: 'VOD and series card shape',
              subtitle:
                  'Portrait shows whole 2:3 posters; landscape crops them to a '
                  '16:9 band and fits far more titles on screen. Applies to the '
                  'poster grid and to the list row artwork a phone shows '
                  'instead. The Continue watching thumbnails stay landscape '
                  'either way.',
              trailing: (_cards ?? VodCardOrientation.portrait).label,
              onTap: _cycleCardOrientation,
            ),
            _SettingTile(
              icon: Icons.play_circle_outline,
              title: 'Play movies immediately',
              subtitle:
                  'Selecting a movie starts playback instead of opening its '
                  'details sheet with a Play button. A saved resume point is '
                  'still used. Series keep their details sheet.',
              trailing: (_movieQuickPlay ?? false) ? 'On' : 'Off',
              onTap: _toggleMovieQuickPlay,
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
              trailing:
                  (_nextBehavior ?? NextVideoPlayedBehavior.resumeOrSkip).label,
              onTap: _cycleNextBehavior,
            ),
            _SettingTile(
              icon: Icons.schedule_outlined,
              title: 'Clock in the player',
              subtitle:
                  'Show the wall clock: in the player\'s top bar while the '
                  'controls are up, and top-right over the picture once they '
                  'fade, on every surface.',
              trailing: (_showClock ?? true) ? 'On' : 'Off',
              onTap: _toggleShowClock,
            ),
            _SettingTile(
              icon: Icons.timelapse_outlined,
              title: 'Playback time in the player',
              subtitle:
                  'Show how far into a film or episode you are: in the control '
                  'row beside the progress bar, and bottom-right over the '
                  'picture once the controls fade. Live channels have no '
                  'progress bar, so this changes nothing there.',
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
            _SettingTile(
              icon: Icons.vpn_lock_outlined,
              title: 'Proxy',
              subtitle:
                  'System follows this device\'s own proxy (the Wi-Fi network on '
                  'a phone, Internet options on Windows). Custom uses the server '
                  'below, Off connects directly. Artwork always tries a direct '
                  'connection first and only falls back to this proxy. Video '
                  'streams follow the three switches below, which need this '
                  'mode to be on.',
              trailing: (_proxy ?? const ProxyConfig()).mode.label,
              onTap: _cycleProxyMode,
            ),
            _SettingTile(
              icon: Icons.dns_outlined,
              title: 'Proxy server',
              subtitle:
                  'Host and port for Custom mode, for example 192.168.1.4 and '
                  '8888. Saving an address also switches the mode above to '
                  'Custom. The bypass list stays whatever the system proxy '
                  'declares.',
              trailing: _proxyServerLabel(),
              onTap: _editProxyServer,
            ),
            // The proxy above describes how the app reaches a provider's API
            // and guides. A video stream is a different connection — opened by
            // the player, not by the app's own HTTP client — so it gets its own
            // switch, per kind, and defaults off (the direct route every build
            // had before these existed).
            for (final kind in StreamKind.values)
              _SettingTile(
                icon: switch (kind) {
                  StreamKind.live => Icons.live_tv_outlined,
                  StreamKind.movie => Icons.movie_outlined,
                  StreamKind.series => Icons.video_library_outlined,
                },
                title: 'Streams through the proxy: ${kind.label}',
                subtitle: switch (kind) {
                  StreamKind.live =>
                    'Fetch the channel stream itself through the proxy above. '
                        'Off opens channels directly.',
                  StreamKind.movie =>
                    'Fetch film streams through the proxy above. Off opens '
                        'them directly.',
                  StreamKind.series =>
                    'Fetch episode streams through the proxy above. Off opens '
                        'them directly.',
                },
                trailing: (_streamProxy[kind] ?? false) ? 'On' : 'Off',
                onTap: () => _toggleStreamProxy(kind),
              ),
            _SettingTile(
              icon: Icons.tune,
              title: 'Player controls',
              subtitle:
                  'Choose which buttons the player shows over the picture. '
                  'Play/pause always stays.',
              trailing: _playerControlsTrailing(),
              onTap: _openPlayerControls,
            ),
            // Touch gestures: only the phone/tablet surfaces wire them. A TV has
            // a remote; a desktop overlay keeps the double *click* as "toggle
            // fullscreen" and never reads this setting.
            if (hasTouchPlayerGestures)
              _SettingTile(
                icon: Icons.touch_app_outlined,
                title: 'Double tap on the picture',
                subtitle:
                    'Double tap the left half for back / previous, the right half '
                    'for forward / next. **Live channels always step** — this '
                    'choice is for films and episodes: Previous/Next steps to the '
                    'neighbouring title, Seek moves by the VOD seek step below.',
                trailing: (_doubleTap ?? DoubleTapAction.previousNext).label,
                onTap: _cycleDoubleTap,
              ),
            if (Platform.isAndroid && hasTouchPlayerGestures)
              _SettingTile(
                icon: Icons.swap_horiz_outlined,
                title: 'Volume and brightness swipes',
                subtitle:
                    'A vertical swipe on the picture changes one level per side. '
                    'Muting is still the button, and the brightness applies to '
                    'this player only.',
                trailing: volumeSwipeOnLeft.value
                    ? 'Volume left'
                    : 'Brightness left',
                onTap: _toggleSwipeSides,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _cycleDoubleTap() async {
    final current = _doubleTap ?? DoubleTapAction.previousNext;
    final next = current.other;
    setState(() => _doubleTap = next);
    await setDoubleTapAction(next, store: widget.store);
  }

  /// Flips which side of the picture the volume swipe lives on.
  ///
  /// The tile's trailing label reads [volumeSwipeOnLeft] directly, so a
  /// `setState` is only there to repaint this route; the notifier is what the
  /// next player session reads from the `open` payload.
  Future<void> _toggleSwipeSides() async {
    final next = !volumeSwipeOnLeft.value;
    volumeSwipeOnLeft.value = next;
    setState(() {});
    await widget.store.setPlayerVolumeSwipeOnLeft(next);
  }

  /// Flips whether [kind]'s **stream** itself is fetched through the proxy.
  ///
  /// Takes effect on the next stream opened: the value is read when a player
  /// route resolves its stream, so a playing video never changes route mid-way.
  Future<void> _toggleStreamProxy(StreamKind kind) async {
    final next = !(_streamProxy[kind] ?? false);
    setState(() => _streamProxy[kind] = next);
    await widget.store.setStreamProxy(kind, next);
  }

  Future<void> _openPlayerControls() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PlayerControlsScreen()),
    );
    // The tile's trailing count reads the notifier directly, so only a rebuild
    // of this route is needed after the sub-screen pops.
    if (mounted) setState(() {});
  }

  /// "All" or "n of m", counted over the controls **this device** offers: a
  /// television has no picture-in-picture, so a total that included it would
  /// read "9 of 10" on a screen that only lists nine rows.
  String _playerControlsTrailing() {
    final available = playerControlsForDevice();
    final prefs = playerControlsPrefs.value;
    if (prefs.hidden.isEmpty) return 'All';
    final shown = available.where(prefs.shows).length;
    return '$shown of ${available.length}';
  }

  String _proxyServerLabel() {
    final proxy = _proxy ?? const ProxyConfig();
    if (proxy.host.trim().isEmpty || proxy.port <= 0) return '—';
    return '${proxy.host.trim()}:${proxy.port}';
  }
}

/// Host/port editor for the Custom proxy mode.
///
/// Two text fields rather than a single `host:port` string: a phone keyboard is
/// the common case, and parsing a colon out of typed input is a failure mode
/// with no upside — the port field can be numeric and clamped there.
class _ProxyServerDialog extends StatefulWidget {
  final ProxyConfig initial;

  const _ProxyServerDialog({required this.initial});

  @override
  State<_ProxyServerDialog> createState() => _ProxyServerDialogState();
}

class _ProxyServerDialogState extends State<_ProxyServerDialog> {
  late final TextEditingController _host = TextEditingController(
    text: widget.initial.host,
  );
  late final TextEditingController _port = TextEditingController(
    text: widget.initial.port > 0 ? '${widget.initial.port}' : '',
  );
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _save() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty && _port.text.trim().isEmpty) {
      // Clearing both is how a user removes an address they no longer need;
      // it is not an error.
      Navigator.of(context).pop(widget.initial.copyWith(host: '', port: 0));
      return;
    }
    if (host.isEmpty) {
      setState(() => _error = 'Enter a host name or IP address.');
      return;
    }
    if (port == null || port <= 0 || port > 65535) {
      setState(() => _error = 'The port must be a number from 1 to 65535.');
      return;
    }
    Navigator.of(context).pop(widget.initial.copyWith(host: host, port: port));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Proxy server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _host,
            autofocus: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Host',
              hintText: '192.168.1.4',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              labelText: 'Port',
              hintText: '8888',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppColors.accent)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
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
                color: trailing == 'On' ? AppColors.accent : AppColors.textLo,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which optional controls the player's chrome draws.
///
/// A route of its own rather than ten more rows in Settings: the parent list is
/// already long, and this is one coherent question ("what does the player look
/// like") asked because the overlay felt cluttered. Every row is a plain
/// toggle — the trailing "On"/"Off" is the state and the tap is the only
/// action, the same one-focus-stop rule the rest of Settings uses.
class PlayerControlsScreen extends StatelessWidget {
  const PlayerControlsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Player controls')),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: playerControlsPrefs,
          builder: (context, _) {
            final prefs = playerControlsPrefs.value;
            // A television offers no picture-in-picture, so its row is not
            // drawn at all — see [playerControlsForDevice].
            final available = playerControlsForDevice().toSet();
            Widget tile(PlayerControl control) => _SettingTile(
              icon: _iconFor(control),
              title: control.label,
              subtitle: _subtitleFor(control),
              trailing: prefs.shows(control) ? 'On' : 'Off',
              onTap: () => unawaited(
                setPlayerControlVisible(control, !prefs.shows(control)),
              ),
            );
            return ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                const _GroupLabel('Transport'),
                for (final control in const [
                  PlayerControl.previousNext,
                  PlayerControl.seek10,
                  PlayerControl.mute,
                  PlayerControl.volume,
                ])
                  if (available.contains(control)) tile(control),
                const _GroupLabel('Buttons'),
                for (final control in const [
                  PlayerControl.quickList,
                  PlayerControl.favorite,
                  PlayerControl.subtitles,
                  PlayerControl.aspect,
                  PlayerControl.pip,
                  PlayerControl.info,
                ])
                  if (available.contains(control)) tile(control),
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text(
                    'Play/pause is always shown: it is the one control whose '
                    'absence would leave nothing to press.',
                    style: TextStyle(color: AppColors.textLo, fontSize: 12),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static IconData _iconFor(PlayerControl control) => switch (control) {
    PlayerControl.previousNext => Icons.skip_next_outlined,
    PlayerControl.seek10 => Icons.replay_10_outlined,
    PlayerControl.mute => Icons.volume_off_outlined,
    PlayerControl.volume => Icons.linear_scale,
    PlayerControl.quickList => Icons.format_list_bulleted,
    PlayerControl.favorite => Icons.star_outline_rounded,
    PlayerControl.subtitles => Icons.closed_caption_outlined,
    PlayerControl.aspect => Icons.aspect_ratio,
    PlayerControl.pip => Icons.picture_in_picture_alt_outlined,
    PlayerControl.info => Icons.info_outline,
  };

  static String _subtitleFor(PlayerControl control) => switch (control) {
    PlayerControl.previousNext =>
      'Step to the previous or next channel (or film) from the player.',
    PlayerControl.seek10 =>
      'The -10 s and +10 s buttons. Films and episodes only — live has no '
          'position to seek.',
    PlayerControl.mute => 'The mute button.',
    PlayerControl.volume =>
      'The volume slider beside mute. The phone\'s own volume keys keep '
          'working either way.',
    PlayerControl.quickList =>
      'The channel-list button for a live session, where a controller exists.',
    PlayerControl.favorite => 'The favorite star on a live channel.',
    PlayerControl.subtitles =>
      'The subtitle menu, when the stream carries a subtitle track.',
    PlayerControl.aspect => 'The aspect-ratio chip.',
    PlayerControl.pip =>
      'The picture-in-picture button, where the device has it.',
    PlayerControl.info => 'The stream-information button.',
  };
}

class _GroupLabel extends StatelessWidget {
  final String text;

  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.textLo, fontSize: 12),
      ),
    );
  }
}
