import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../monitor/agent.dart';

/// Shows monitor findings as system notifications on iOS and Android, so they
/// reach the driver while the phone is locked or another app is open (and, on
/// iOS, on the CarPlay screen). In the browser, findings appear in-app only.
class FindingNotifier {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1;

  bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  Future<void> init() async {
    if (!_supported || _ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _ready = true;
    } catch (error) {
      debugPrint('Notifications unavailable: $error');
    }
  }

  Future<void> show(Finding finding) async {
    if (!_ready) return;
    final urgent = finding.severity == Severity.critical;
    try {
      await _plugin.show(
        id: _nextId++,
        title: finding.title,
        body: '${finding.detail} ${finding.advice}',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            urgent ? 'vehicle_critical' : 'vehicle_alerts',
            urgent ? 'Critical vehicle alerts' : 'Vehicle alerts',
            channelDescription: 'Problems the monitor detects in live vehicle data',
            importance: urgent ? Importance.max : Importance.high,
            priority: urgent ? Priority.max : Priority.high,
          ),
          iOS: DarwinNotificationDetails(
            interruptionLevel: urgent ? InterruptionLevel.timeSensitive : InterruptionLevel.active,
          ),
        ),
      );
    } catch (error) {
      debugPrint('Could not show notification: $error');
    }
  }
}
