import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// The stable key that ties this **physical device's** app settings to the
/// cloud.
///
/// A reinstall gets a new anonymous Supabase user, so `devices.device_uid`
/// cannot identify the same hardware. This key is derived from a platform id
/// that survives the reinstall:
///
/// - Android: `ANDROID_ID` (stable per app-signing key and user; resets only on
///   a factory reset). Retrieved over the existing `iptvs/device` channel.
/// - Windows/Linux/macOS, and the Android fallback: a random id in this app's
///   support directory, which an MSI/uninstall does not remove.
///
/// Only `sha256('iptvs-device-v1|' + platform + ':' + raw)` leaves the device;
/// the server never sees the raw id. Keep it that way: the hash is the identity
/// in `device_settings.device_key`.
class DeviceIdentity {
  DeviceIdentity._();

  static const MethodChannel _channel = MethodChannel('iptvs/device');
  static String? _cachedKey;

  /// The 64-character lowercase hex key used by `get_device_settings` /
  /// `push_device_settings`.
  static Future<String> cloudDeviceKey() async {
    final cached = _cachedKey;
    if (cached != null) return cached;
    return _cachedKey = hashRaw(await _rawDeviceId());
  }

  /// Pure hash. Public so the derivation is pinned by a unit test instead of by
  /// trying a reinstall on hardware.
  static String hashRaw(String raw) =>
      sha256.convert(utf8.encode('iptvs-device-v1|$raw')).toString();

  static Future<String> _rawDeviceId() async {
    final platform = Platform.operatingSystem;
    if (Platform.isAndroid) {
      try {
        final id = await _channel.invokeMethod<String>('stableDeviceId');
        if (id != null && id.trim().isNotEmpty) {
          return 'android:${id.trim()}';
        }
      } catch (_) {
        // Fall through to the file id; a missing channel is not fatal.
      }
    }
    return _fileDeviceId(platform);
  }

  /// A random id in the app support directory. On Windows this survives an
  /// uninstall (the MSI only removes program files); on Android it is the
  /// fallback when the platform id is unavailable and will be lost with the
  /// app data, which is acceptable for a fallback.
  static Future<String> _fileDeviceId(String platform) async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}${Platform.pathSeparator}device_id');
    try {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return '$platform:$existing';
    } catch (_) {
      // Missing or unreadable: generate one below.
    }
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final generated = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    try {
      await file.writeAsString(generated, flush: true);
    } catch (_) {
      // Read-only support directory: the process still gets an id for this run,
      // but cannot restore settings after a reinstall.
    }
    return '$platform:$generated';
  }

  /// Test isolation: the key is process-cached by design.
  static void resetForTest() => _cachedKey = null;
}
