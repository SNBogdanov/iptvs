import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        LogicalKeyboardKey,
        MethodChannel;
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/app_database.dart';
import 'data/cloud_config.dart';
import 'data/device_class.dart';
import 'data/diagnostics_log.dart';
import 'data/net.dart' show redactText;
import 'data/secure_local_storage.dart';
import 'data/source_identity_migration.dart';
import 'data/source_store.dart';
import 'data/vod_card_orientation.dart';
import 'player/clock_format.dart';
import 'player/player_chrome_prefs.dart';
import 'player/tray.dart';
import 'player/window_placement.dart';
import 'screens/profile_pick_screen.dart';
import 'theme.dart';

/// Decoded-image cache ceiling applied on Android (phone and TV).
///
/// Flutter's default is 100 MB / 1000 images. On a 1 GB Android TV box that is
/// a large slice of the whole heap, and browsing a poster grid fills it — the
/// resulting GC pressure shows up as dropped frames on weak silicon, and on the
/// smallest boxes as an OOM kill. Images are already decoded at display size
/// (`imageCacheSize`, DPR clamped to 3), so 32 MB is roughly four screenfuls of
/// the grid's ~180 px posters: the visible page never has to re-decode itself,
/// which is the failure mode a too-small cap would cause (continuous re-decode
/// is worse than the pressure it saves). Desktop deliberately keeps Flutter's
/// default — RAM is plentiful there and the bigger cache genuinely pays off
/// when scrolling back through a large catalogue.
const int kAndroidImageCacheBytes = 32 << 20;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) {
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        kAndroidImageCacheBytes;
  }
  MediaKit.ensureInitialized();
  // The Windows runner's X-button policy (hide to tray vs quit) is a persisted
  // device preference that must reach the native side before the first close.
  // Fired before the boot group below so its keychain read overlaps the others;
  // never on the critical path to the first frame.
  if (defaultTargetPlatform == TargetPlatform.windows) {
    unawaited(applyPersistedCloseToTray());
    unawaited(loadAlwaysOnTopPreference());
    // Opens at the remembered position/size and starts recording it. Also fired
    // ahead of the boot group: a restored rectangle is only correct before the
    // first frame paints into it, and the keychain read overlaps the others.
    startWindowPlacementTracking();
    // The player clock badge's regional format, read from this machine's
    // Windows settings. Also fired, not awaited, and for the same reason as the
    // chrome preferences below: nothing reads the clock until a player route is
    // opened, which is a profile pick and a catalogue load away, so the answer
    // has always landed first — while awaiting it would put a platform round
    // trip on the path to the first frame for a value nothing can consume yet.
    unawaited(detectClockFormat());
  }
  // Cross-platform, unlike the three above: the media grid's card shape. Fills
  // the notifier the grid reads, and until it answers the grid draws the default
  // portrait shape — which is what an untouched install uses anyway, so the
  // first frame is never drawn in the wrong shape.
  unawaited(loadVodCardOrientation());
  // The player's clock badge and VOD time readout, the other two device-wide
  // chrome preferences. Also fired, not awaited, and for a stronger reason than
  // the card shape above: nothing reads these until a player route is opened,
  // which is at least a profile pick and a catalogue load away — so the read
  // has always landed before any chrome exists, while awaiting it would put a
  // keychain read on the critical path to the first frame for a value that
  // cannot be consumed yet. The notifiers start at true, which is what an
  // untouched install draws anyway.
  unawaited(loadPlayerChromePrefs());
  final store = SourceStore();
  // Cloud init, opening the database and reading the source list are mutually
  // independent — only the identity migration below needs the database and the
  // sources together. Starting them at once costs the longest of the three
  // keychain/disk round trips instead of their sum, all of which is on the path
  // to the first frame. A failure here still aborts boot; it arrives wrapped in
  // a ParallelWaitError rather than on its own.
  // `detectDeviceClass` joins the tuple for the same reason as the rest: it is
  // one platform round trip with no dependency on the others, and it must
  // settle before the first frame because it decides the *layout* (a television
  // is the wide two-pane UI regardless of the logical width its density
  // reports — `isWideLayout`). Awaiting it ahead of this group added its
  // latency to time-to-first-frame for nothing.
  final (db, sources, _, _) = await (
    AppDatabase.open(),
    store.list(),
    detectDeviceClass(),
    _initialiseCloud(),
  ).wait;
  // Repairs the pre-PR4 cache namespaces, but it is an optimisation of existing
  // state, never a prerequisite for the UI: the repository rebuilds and re-keys
  // rows from the provider on its own. So it must not be able to stop the first
  // frame, and the window is shown *on* the first Dart frame — the original
  // version let a single unresolvable legacy collision throw out of `main()`,
  // so no frame was ever produced and the app looked like it would not start at
  // all. `migrateAllSourceIdentities` already swallows a per-source failure;
  // this is the last-resort guard for anything else it might throw.
  try {
    await migrateAllSourceIdentities(db, sources);
  } catch (error) {
    DiagnosticsLog.instance.addAndPrint(
      'boot',
      'source identity migration skipped: ${error.runtimeType}: '
      '${redactText('$error')}',
    );
  }
  runApp(IptvApp(db: db, store: store));
}

/// Optional cloud source panel: only initialised when build-time Supabase
/// config is present, otherwise the app runs fully offline as before.
Future<void> _initialiseCloud() async {
  if (!CloudConfig.isConfigured) return;
  await Supabase.initialize(
    url: CloudConfig.url,
    publishableKey: CloudConfig.anonKey,
    authOptions: FlutterAuthClientOptions(localStorage: SecureLocalStorage()),
  );
}

class IptvApp extends StatefulWidget {
  final AppDatabase db;
  final SourceStore store;
  const IptvApp({super.key, required this.db, required this.store});

  @override
  State<IptvApp> createState() => _IptvAppState();
}

class _IptvAppState extends State<IptvApp> {
  /// The boss key (docs/player.md "System tray icon"): F12 hides the window to
  /// the tray from anywhere in the app. A `HardwareKeyboard` handler rather
  /// than a `Shortcuts`/`Focus` binding, so it fires whatever widget holds
  /// focus (the native HDR surface forwards its keys to the runner instead and
  /// is handled there). Hiding triggers the `hidden` lifecycle, which is what
  /// stops the preview and the player.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.f12) return false;
    if (defaultTargetPlatform != TargetPlatform.windows) return false;
    DiagnosticsLog.instance.add('player', 'boss key F12 -> hideToTray');
    unawaited(hideToTray());
    return true;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // The runner hides the window to the tray (X button, tray menu, the boss
    // key) and notifies Dart here, because the Windows `hidden` lifecycle does
    // not fire for a `SW_HIDE`. The notifier below is what the preview and the
    // player listen to.
    const MethodChannel(kTrayChannel).setMethodCallHandler((call) async {
      if (call.method == 'trayHidden') {
        requestSilence();
      } else if (call.method == 'trayShown') {
        requestResume();
      }
      return null;
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IPTV Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      // The picker itself decides whether to appear (startup-mode setting +
      // profile count) and silently short-circuits to HomeShell otherwise.
      home: ProfilePickScreen(db: widget.db, store: widget.store, bootMode: true),
    );
  }
}
