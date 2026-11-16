import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One value shown in the iOS Live Activity.
class LiveActivityItem {
  const LiveActivityItem({required this.label, required this.value, required this.unit, required this.fraction});

  final String label;
  final String value;
  final String unit;

  /// Position within the gauge range, 0..1, for the progress bar.
  final double fraction;

  Map<String, Object> toMap() => {'label': label, 'value': value, 'unit': unit, 'fraction': fraction};
}

/// Bridge to the native iOS Live Activity (see ios/Runner/LiveActivityBridge.swift).
/// From iOS 26 a Live Activity is shown on the CarPlay Dashboard automatically,
/// which is how the selected live values reach the car's screen without a
/// CarPlay app entitlement. On every other platform these calls do nothing.
class LiveActivityBridge {
  static const MethodChannel _channel = MethodChannel('obdscan/live_activity');

  bool _active = false;
  DateTime? _lastUpdate;

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> start(String vehicle) async {
    if (!_supported || _active) return;
    try {
      final started = await _channel.invokeMethod<bool>('start', {'vehicle': vehicle});
      _active = started ?? false;
    } catch (error) {
      debugPrint('Live Activity unavailable: $error');
    }
  }

  /// Pushes new values, at most once per second.
  Future<void> update(List<LiveActivityItem> items, {String? alert, bool critical = false}) async {
    if (!_active) return;
    final now = DateTime.now();
    if (_lastUpdate != null && now.difference(_lastUpdate!) < const Duration(seconds: 1)) return;
    _lastUpdate = now;
    try {
      await _channel.invokeMethod<void>('update', {
        'items': [for (final item in items.take(4)) item.toMap()],
        'alert': alert ?? '',
        'critical': critical,
      });
    } catch (error) {
      debugPrint('Live Activity update failed: $error');
    }
  }

  Future<void> end() async {
    if (!_active) return;
    _active = false;
    try {
      await _channel.invokeMethod<void>('end');
    } catch (error) {
      debugPrint('Live Activity end failed: $error');
    }
  }
}
