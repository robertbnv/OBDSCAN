import 'dart:async';

import 'dtc.dart';
import 'elm327.dart';
import 'obd_client.dart';
import 'pids.dart';

/// Pseudo-PID for the battery voltage the adapter measures at the OBD port
/// (`ATRV`). Available on every vehicle, unlike PID 42.
const int adapterVoltagePid = 0x10000;

final PidDef adapterVoltageDef = PidDef(
  adapterVoltagePid,
  'Battery voltage (at OBD port)',
  'Battery',
  'V',
  0,
  0,
  20,
  (d) => 0,
  decimals: 1,
  group: PidGroup.electrical,
);

/// Looks up a real or pseudo parameter definition.
PidDef? pidDefinition(int pid) => pid == adapterVoltagePid ? adapterVoltageDef : pidTable[pid];

class LiveSample {
  LiveSample(this.time, this.values);

  final DateTime time;
  final Map<int, double> values;
}

/// Continuously reads live data. [fastPids] are refreshed every cycle (the
/// dashboard); [slowPids] are worked through a few per cycle so everything
/// the car reports still gets recorded and monitored.
class LivePoller {
  LivePoller(
    this.client, {
    DateTime Function()? clock,
    this.statusInterval = const Duration(seconds: 20),
    this.voltageInterval = const Duration(seconds: 10),
  }) : _clock = clock ?? DateTime.now;

  final ObdClient client;
  final DateTime Function() _clock;
  final Duration statusInterval;
  final Duration voltageInterval;

  Set<int> fastPids = {};
  Set<int> slowPids = {};

  final StreamController<LiveSample> _samples = StreamController<LiveSample>.broadcast();
  final StreamController<MonitorStatus> _status = StreamController<MonitorStatus>.broadcast();
  final StreamController<Object> _failures = StreamController<Object>.broadcast();

  bool _running = false;
  Future<void>? _loop;
  int _cycles = 0;
  DateTime? _rateStart;

  Stream<LiveSample> get samples => _samples.stream;

  /// Warning light and readiness state, re-read every [statusInterval].
  Stream<MonitorStatus> get status => _status.stream;

  /// Emits once when polling stops because the vehicle or adapter went away.
  Stream<Object> get failures => _failures.stream;

  bool get isRunning => _running;

  /// Refresh cycles per second since polling started.
  double get cyclesPerSecond {
    final start = _rateStart;
    if (start == null) return 0;
    final seconds = _clock().difference(start).inMilliseconds / 1000;
    return seconds <= 0 ? 0 : _cycles / seconds;
  }

  void start() {
    if (_running) return;
    _running = true;
    _cycles = 0;
    _rateStart = _clock();
    _loop = _run();
  }

  Future<void> stop() async {
    _running = false;
    await _loop;
    _loop = null;
  }

  Future<void> _run() async {
    var slowIndex = 0;
    var consecutiveFailures = 0;
    DateTime? lastStatus;
    DateTime? lastVoltage;

    while (_running) {
      try {
        final values = <int, double>{};
        final fast = fastPids.where((pid) => pid != adapterVoltagePid).toList()..sort();
        if (fast.isNotEmpty) values.addAll(await client.readPids(fast));

        final slow = slowPids.difference(fastPids).where((pid) => pid != adapterVoltagePid).toList()..sort();
        if (slow.isNotEmpty && _running) {
          final count = slow.length < 6 ? slow.length : (client.batching ? 6 : 2);
          final chunk = [for (var i = 0; i < count; i++) slow[(slowIndex + i) % slow.length]];
          slowIndex = (slowIndex + count) % slow.length;
          values.addAll(await client.readPids(chunk));
        }

        final now = _clock();
        if (_running && (lastVoltage == null || now.difference(lastVoltage) >= voltageInterval)) {
          lastVoltage = now;
          final volts = await client.elm.readVoltage();
          if (volts != null) values[adapterVoltagePid] = volts;
        }

        if (values.isNotEmpty) _samples.add(LiveSample(_clock(), values));
        _cycles++;

        if (_running && (lastStatus == null || now.difference(lastStatus) >= statusInterval)) {
          lastStatus = now;
          final status = await client.readMonitorStatus();
          if (status != null) _status.add(status);
        }

        if (values.isEmpty) {
          // Engine off or nothing selected: do not spin.
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        consecutiveFailures = 0;
      } on ElmException catch (error) {
        if (!_running) break;
        consecutiveFailures++;
        if (error.kind == ElmErrorKind.disconnected || consecutiveFailures >= 5) {
          _running = false;
          _failures.add(error);
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }
}
