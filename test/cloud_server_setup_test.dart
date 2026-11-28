import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/cloud_runtime.dart';
import 'package:iptvs/data/source_store.dart';
import 'package:iptvs/screens/cloud_sync_screen.dart';

/// The "connect a server" state (option D): a build with no server must render
/// the form, must not construct a Supabase client, and must not make a network
/// call while the user is only looking at it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late AppDatabase db;
  late SourceStore store;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_cloud_server_test');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    store = SourceStore();
  });

  tearDownAll(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    CloudRuntime.resetForTest();
  });

  testWidgets('an unconfigured build offers the server form', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: CloudSyncScreen(store: store, db: db)),
    );
    await tester.pump();

    expect(find.text('Connect a cloud server'), findsOneWidget);
    expect(find.text('Save server'), findsOneWidget);
    expect(find.text('Pair this device'), findsNothing);
    expect(CloudRuntime.hasServer, isFalse);
  });

  testWidgets('saving nothing explains what is missing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: CloudSyncScreen(store: store, db: db)),
    );
    await tester.pump();

    await tester.tap(find.text('Save server'));
    await tester.pump();

    expect(
      find.textContaining('Read the server configuration first'),
      findsOneWidget,
    );
    expect(CloudRuntime.hasServer, isFalse);
  });
}
