import 'package:material_ui/material_ui.dart';

import 'app/app_controller.dart';
import 'ui/connect_page.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  controller.init();
  runApp(ObdScanApp(controller: controller));
}

class ObdScanApp extends StatelessWidget {
  const ObdScanApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OBD Scan',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => controller.isConnected ? HomeShell(controller) : ConnectPage(controller),
      ),
    );
  }
}
