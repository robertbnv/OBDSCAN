import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../obd/dtc.dart';
import 'assistant_page.dart';
import 'dashboard_page.dart';
import 'diagnostics_page.dart';
import 'live_data_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// The connected app: four tabs under one app bar.
class HomeShell extends StatefulWidget {
  const HomeShell(this.controller, {super.key});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  AppController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final alerts = controller.agent?.activeFindings.length ?? 0;
    final codes = controller.dtcReport?.ofKind(DtcKind.stored).length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(controller.vehicleTitle),
            Text(
              controller.transportDescription,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: kMuted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(controller))),
          ),
          IconButton(tooltip: 'Disconnect', icon: const Icon(Icons.link_off_rounded), onPressed: controller.disconnect),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          DashboardPage(controller),
          LiveDataPage(controller),
          DiagnosticsPage(controller),
          AssistantPage(controller),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.speed_rounded), label: 'Dashboard'),
          const NavigationDestination(icon: Icon(Icons.show_chart_rounded), label: 'Live data'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: codes > 0,
              label: Text('$codes'),
              backgroundColor: kWarn,
              textColor: Colors.black,
              child: const Icon(Icons.build_circle_outlined),
            ),
            label: 'Diagnostics',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: alerts > 0,
              label: Text('$alerts'),
              backgroundColor: kCritical,
              child: const Icon(Icons.shield_outlined),
            ),
            label: 'Assistant',
          ),
        ],
      ),
    );
  }
}
