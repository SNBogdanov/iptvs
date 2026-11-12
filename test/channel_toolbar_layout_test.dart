import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/screens/channel_list_chrome.dart';

void main() {
  void useWindow(WidgetTester tester, Size size, double textScale) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
  }

  Widget toolbar() {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    return MaterialApp(
      home: Scaffold(
        body: ChannelToolbar(
          searchController: controller,
          query: '',
          hintText: 'Search',
          onQueryChanged: (_) {},
          onClearQuery: () {},
          categoryControl: const SizedBox(width: 220, height: 40),
          sortControl: const SizedBox(width: 220, height: 40),
          actionControl: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChannelToolbarIconButton(
                tooltip: 'Jump',
                icon: Icons.my_location_rounded,
                onPressed: () {},
              ),
              const SizedBox(width: 8),
              ChannelToolbarIconButton(
                tooltip: 'Hide watched',
                icon: Icons.visibility_off_outlined,
                onPressed: () {},
              ),
              const SizedBox(width: 8),
              ChannelToolbarIconButton(
                tooltip: 'Refresh',
                icon: Icons.refresh,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
  }

  for (final width in const [320.0, 360.0, 480.0, 620.0, 759.0, 760.0, 800.0]) {
    for (final textScale in const [1.0, 2.0]) {
      testWidgets(
        'movie toolbar fits ${width.toInt()} px at text scale $textScale',
        (tester) async {
          useWindow(tester, Size(width, 400), textScale);
          await tester.pumpWidget(toolbar());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
