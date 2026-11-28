import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_schema.dart';

/// The server/app version handshake. The integer itself is pinned to the
/// migration file so a schema change cannot land without the app constant (and
/// vice versa) being updated in the same commit.
void main() {
  test('the app version matches the latest schema migration', () {
    final migration = File(
      'supabase/migrations/20261128010000_schema_version.sql',
    ).readAsStringSync();
    expect(
      migration,
      contains('values (1, ${CloudSchema.currentVersion}, now())'),
    );
    expect(CloudSchema.deviceSettingsVersion, CloudSchema.currentVersion);
  });

  test('server/app compatibility states', () {
    expect(CloudSchema.stateFor(null), CloudSchemaState.unknown);
    expect(CloudSchema.stateFor(0), CloudSchemaState.legacy);
    expect(
      CloudSchema.stateFor(CloudSchema.currentVersion - 1),
      CloudSchemaState.outdated,
    );
    expect(
      CloudSchema.stateFor(CloudSchema.currentVersion),
      CloudSchemaState.upToDate,
    );
    expect(
      CloudSchema.stateFor(CloudSchema.currentVersion + 1),
      CloudSchemaState.newer,
    );
  });

  test('a feature is disabled until the server version is actually known', () {
    CloudSchema.resetForTest();
    expect(CloudSchema.supports(CloudSchema.deviceSettingsVersion), isFalse);
    CloudSchema.knownServerVersion = 0;
    expect(CloudSchema.supports(CloudSchema.deviceSettingsVersion), isFalse);
    CloudSchema.knownServerVersion = CloudSchema.currentVersion;
    expect(CloudSchema.supports(CloudSchema.deviceSettingsVersion), isTrue);
    CloudSchema.resetForTest();
  });
}
