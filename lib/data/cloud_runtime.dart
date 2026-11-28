import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_settings_store.dart';
import 'cloud_config.dart';
import 'cloud_endpoint.dart';
import 'cloud_storage_keys.dart';
import 'secure_local_storage.dart';

/// The cloud server this process is talking to.
///
/// Since option D the endpoint is **not** a build constant: it is read from the
/// keychain at boot (falling back to the build's default once), and the
/// Supabase client is created from whichever endpoint wins. See
/// `cloud/runtime-server.md`.
///
/// One process talks to one server. Changing the endpoint therefore requires a
/// restart: `Supabase.initialize` is process-global and auth sessions are
/// per-server, so switching behind the running client would leave two live
/// clients and a token that belongs to neither.
class CloudRuntime {
  CloudRuntime._();

  static CloudEndpoint? _endpoint;
  static SupabaseClient? _client;

  /// The configured endpoint, or null when this device has no server yet.
  static CloudEndpoint? get endpoint => _endpoint;

  /// Whether a server is configured. Everything cloud-facing gates on this:
  /// with no server the app must not create an anonymous session, fetch a
  /// profile or show a cloud badge.
  static bool get hasServer => _endpoint != null;

  /// The panel link for the configured server, falling back to the build-time
  /// value for installs that still carry one.
  static String get panelUrl => _endpoint?.panelUrl ?? CloudConfig.panelUrl;

  /// Reads the endpoint for this boot and initializes Supabase when one exists.
  ///
  /// Order: the keychain wins; a build-time default is copied into the keychain
  /// (so a later build without the defines keeps the server) and used; no
  /// server means no initialization at all — no anonymous user, no traffic.
  ///
  /// No network call happens here. Nothing on the boot path may wait for the
  /// server; an unreachable server is a problem for the cloud screen, not for
  /// starting the app.
  static Future<void> load({AppSettingsStore? settings}) async {
    final store = settings ?? const AppSettingsStore();
    CloudEndpoint? stored;
    try {
      stored = await store.cloudEndpoint();
    } catch (_) {
      // An unreadable keychain is "not configured", never a boot failure.
      stored = null;
    }
    final resolution = resolveCloudEndpoint(
      stored: stored,
      buildDefault: CloudConfig.defaultEndpoint,
    );
    final endpoint = resolution.endpoint;
    if (endpoint == null) return;
    if (resolution.fromBuild) {
      try {
        // Persist the build's default once, so a later build without the
        // defines keeps talking to the same server.
        await store.setCloudEndpoint(endpoint);
      } catch (_) {
        // A failed migration costs a re-entry, not the server: the default is
        // still in hand for this run.
      }
    }
    await initialize(endpoint);
  }

  /// Creates the Supabase client for [endpoint]. Callable **once** per process;
  /// changing servers calls [forget] and asks for a restart instead.
  static Future<void> initialize(CloudEndpoint endpoint) async {
    await Supabase.initialize(
      url: endpoint.url,
      publishableKey: endpoint.anonKey,
      authOptions: FlutterAuthClientOptions(localStorage: SecureLocalStorage()),
    );
    _client = Supabase.instance.client;
    // Only claim the endpoint once the client exists: a failed initialization
    // must not leave `hasServer` true with nothing behind it.
    _endpoint = endpoint;
  }

  /// The client for the configured server.
  ///
  /// Throws when no server is configured: every caller is supposed to have
  /// checked [hasServer] first, so a throw here is a programming error rather
  /// than a state a user can reach.
  static SupabaseClient get client {
    final client = _client;
    if (client != null) return client;
    if (!hasServer) {
      throw StateError('No cloud server is configured');
    }
    return Supabase.instance.client;
  }

  /// Forgets the server and everything server-scoped on this device.
  ///
  /// Clears the persisted Supabase session, the cloud identity/profile cache
  /// and the E2EE device keys. Local sources, favorites, watch state and app
  /// settings are deliberately untouched. The caller must restart: the old
  /// client is still the process-global one.
  static Future<void> forget({
    AppSettingsStore? settings,
    FlutterSecureStorage? secureStorage,
  }) async {
    final client = _client;
    if (client != null) {
      try {
        // Local scope first: the server may be gone, and waiting on it must not
        // keep the user on this screen. The token itself is dropped below.
        await client.auth
            .signOut(scope: SignOutScope.local)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // Best effort; the persisted session is deleted either way.
      }
    }
    final storage = secureStorage ?? const FlutterSecureStorage();
    try {
      await SecureLocalStorage(storage).clear();
    } catch (_) {
      // Keychain unavailable: still clear the rest and the endpoint.
    }
    for (final key in CloudStorageKeys.all) {
      try {
        await storage.delete(key: key);
      } catch (_) {
        // Same rule as above: one unreadable key must not block the others.
      }
    }
    try {
      await (settings ?? const AppSettingsStore()).clearCloudEndpoint();
    } catch (_) {
      // If the endpoint cannot be cleared, the next boot keeps it; report
      // nothing here, the settings screen surfaces the failure.
    }
    _endpoint = null;
    _client = null;
  }

  /// Test isolation: the runtime is process-wide by design.
  static void resetForTest() {
    _endpoint = null;
    _client = null;
  }
}
