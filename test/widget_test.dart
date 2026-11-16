import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:obdscan/app/app_controller.dart';
import 'package:obdscan/main.dart';
import 'package:obdscan/ui/gauge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lets timers and async work run, as the simulated car answers in real time.
Future<void> settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('demo car: connect, dashboard, diagnostics, disconnect', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // A tall phone-shaped surface, so lists build everything the test looks for.
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = AppController(saveRecordings: false);
    await tester.runAsync(controller.init);

    await tester.pumpWidget(ObdScanApp(controller: controller));
    expect(find.text('Connect to your car'), findsOneWidget);

    await tester.tap(find.text('Start demo'));
    await settle(tester, () => controller.isConnected);
    expect(controller.error, isNull);
    expect(
      controller.isConnected,
      isTrue,
      reason: 'link=${controller.link} progress="${controller.progress}" log=${controller.log.join(' | ')}',
    );
    expect(controller.client!.vin, '1HGCM82633A004352');

    // Dashboard shows gauges fed with live values.
    await settle(tester, () => controller.values.containsKey(0x0C));
    expect(find.byType(RadialGauge), findsWidgets);
    expect(find.text('RPM'), findsOneWidget);
    expect(controller.values[0x0C], greaterThan(500));

    // Diagnostics lists the stored code with its description.
    await settle(tester, () => controller.dtcReport != null && !controller.readingCodes);
    await tester.tap(find.text('Diagnostics'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('P0420'), findsWidgets);
    expect(find.textContaining('Catalyst System Efficiency'), findsWidgets);
    expect(find.text('Check-engine light is on'), findsOneWidget);

    await tester.tap(find.byTooltip('Disconnect'));
    await settle(tester, () => !controller.isConnected && controller.client == null);
    expect(controller.client, isNull, reason: 'teardown must finish');
    expect(find.text('Connect to your car'), findsOneWidget);
  });
}
