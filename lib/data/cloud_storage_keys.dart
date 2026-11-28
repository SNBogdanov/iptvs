/// Keychain entries owned by cloud sync **on this device**.
///
/// Shared with `CloudRuntime`, which has to remove exactly these when the user
/// forgets or replaces the server — and must not touch sources, watch state or
/// any other local data. Keeping the names in one file is what makes "clear the
/// cloud identity" a closed list rather than a grep.
class CloudStorageKeys {
  CloudStorageKeys._();

  /// The active cloud profile (which profile this device syncs).
  static const String profileId = 'cloud_profile_id';

  /// Source ids that came from the cloud on the last pull.
  static const String sourceIds = 'cloud_source_ids';

  /// This device's E2EE key pair. Losing it only costs a re-provision from the
  /// panel; it is server-scoped, like the session.
  static const String devicePrivateKey = 'cloud_device_priv_key';
  static const String devicePublicKey = 'cloud_device_pub_key';

  /// Sticky "this profile was seen encrypted at version N" marks.
  static const String e2eeMarks = 'cloud_e2ee_marks';

  /// Everything a server switch must forget. Deliberately does **not** include
  /// `source_secrets` rows: those live in the local database and belong to the
  /// user's sources, not to the cloud account.
  static const List<String> all = <String>[
    profileId,
    sourceIds,
    devicePrivateKey,
    devicePublicKey,
    e2eeMarks,
  ];
}
