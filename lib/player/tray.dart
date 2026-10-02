import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/app_settings_store.dart';

/// The Windows runner's native channel, registered in `flutter_window.cpp`'s
/// `RegisterNativeHdrPlayerChannel`. The tray-icon controls (`setCloseToTray`,
/// `hideToTray`, `restoreWindow`, `exitApp`) share it with the HDR player
/// surface.
const String kWindowsRunnerChannel = 'iptvs/native_hdr_player';

/// The channel the runner uses to *notify* Dart that the window was hidden to
/// the tray. Separate from [kWindowsRunnerChannel] because that one's Dart-side
/// handler is token-owned by [PlayerScreen] (`ChannelHandlerOwner`), so a
/// persistent app-level handler cannot share it.
const String kTrayChannel = 'iptvs/tray';

/// A process-wide "silence now" signal. The runner raises it when the window is
/// hidden to the tray, and the owners of playback listen and stop themselves.
///
/// This exists because the Windows `hidden` lifecycle is **not** reliable for a
/// `SW_HIDE`: the engine keeps the child Flutter view in its "visible windows"
/// set, so the state lands on `inactive` rather than `hidden` and the
/// `didChangeAppLifecycleState` observers never fire. A direct native→Dart
/// event sidesteps that.
final ValueNotifier<int> silenceRequest = ValueNotifier<int>(0);

void requestSilence() {
  silenceRequest.value++;
}

/// The window came back from the tray. Owners of playback listen and resume
/// what [silenceRequest] paused — the counterpart of [requestSilence], raised
/// by the runner's `trayShown` event.
final ValueNotifier<int> resumeRequest = ValueNotifier<int>(0);

void requestResume() {
  resumeRequest.value++;
}

/// The always-on-top preference, mirrored as a notifier so the settings screen
/// and the channel list stay in sync without re-reading the keychain on every
/// playback-state change. Loaded at boot and updated by the settings toggle.
final ValueNotifier<bool> alwaysOnTopEnabled = ValueNotifier<bool>(false);

/// Applies the X-button policy to the Windows runner. A no-op off Windows —
/// the method simply is not implemented there, so the invoke is ignored.
Future<void> applyCloseToTray(bool closeToTray) =>
    const MethodChannel(kWindowsRunnerChannel)
        .invokeMethod<void>('setCloseToTray', closeToTray);

/// Reads the persisted close-to-tray preference and pushes it to the runner.
/// The runner defaults to true; this makes a saved "off" reach it on boot.
Future<void> applyPersistedCloseToTray() async {
  const settings = AppSettingsStore();
  await applyCloseToTray(await settings.closeToTray());
}

/// Quits the app through the runner's force-quit path, bypassing the
/// close-to-tray policy. Windows only; `SystemNavigator.pop()` is a no-op there
/// (the engine handles `System.exitApplication`, not `SystemNavigator.pop`).
Future<void> exitApp() =>
    const MethodChannel(kWindowsRunnerChannel).invokeMethod<void>('exitApp');

/// Hides the window to the tray (the boss-key action). The `hidden` lifecycle
/// it triggers is what stops the preview and the player, so callers need not
/// stop anything themselves.
Future<void> hideToTray() =>
    const MethodChannel(kWindowsRunnerChannel).invokeMethod<void>('hideToTray');

/// Sets/clears the always-on-top window style on the Windows runner. A no-op off
/// Windows — the method simply is not implemented there.
Future<void> applyAlwaysOnTop(bool on) =>
    const MethodChannel(kWindowsRunnerChannel)
        .invokeMethod<void>('setAlwaysOnTop', on);

/// Reads the persisted always-on-top preference into [alwaysOnTopEnabled], so
/// the notifier reflects the saved value from the first frame.
Future<void> loadAlwaysOnTopPreference() async {
  const settings = AppSettingsStore();
  alwaysOnTopEnabled.value = await settings.alwaysOnTop();
}
