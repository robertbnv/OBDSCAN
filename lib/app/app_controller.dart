import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart' show BleDevice;

import '../connect/ble_transport.dart';
import '../connect/tcp_transport.dart';
import '../data/dtc_database.dart';
import '../monitor/agent.dart';
import '../monitor/baseline.dart';
import '../obd/dtc.dart';
import '../obd/elm327.dart';
import '../obd/live_poller.dart';
import '../obd/obd_client.dart';
import '../obd/pids.dart';
import '../obd/sim/simulated_adapter.dart';
import '../obd/sim/simulated_vehicle.dart';
import '../obd/transport.dart';
import '../obd/vin.dart';
import '../record/recorder.dart';
import 'live_activity.dart';
import 'notifier.dart';
import 'units.dart';

enum LinkState { disconnected, connecting, connected }

/// Application state: the connection, live values, diagnostics, the monitor
/// and user settings. Screens listen to this (and to [liveTick] for values
/// that change many times per second).
class AppController extends ChangeNotifier {
  AppController({DtcDatabase? dtcDatabase, this.saveRecordings = true}) : dtc = dtcDatabase ?? DtcDatabase();

  /// Whether drives are written to CSV files (off in tests).
  final bool saveRecordings;

  static const List<int> defaultDashboard = [0x0C, 0x0D, 0x05, 0x42, 0x04, 0x0F];
  static const int maxDashboardGauges = 8;

  final DtcDatabase dtc;
  final FindingNotifier _notifier = FindingNotifier();
  final LiveActivityBridge _liveActivity = LiveActivityBridge();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  SharedPreferences? _prefs;

  LinkState link = LinkState.disconnected;
  String progress = '';
  String? error;
  bool isDemo = false;

  ObdClient? client;
  LivePoller? _poller;
  MonitorAgent? agent;
  SessionRecorder? recorder;
  SimulatedVehicle? demoVehicle;
  VinInfo? vinInfo;
  String? fuelType;
  String transportDescription = '';

  /// Increments with every live sample.
  final ValueNotifier<int> liveTick = ValueNotifier<int>(0);
  final Map<int, double> values = {};
  final Map<int, List<double>> history = {};
  final Map<int, (double, double)> extremes = {};
  List<int> availablePids = [];
  List<int> dashboardPids = [...defaultDashboard];

  UnitSystem units = UnitSystem.metric;
  String wifiHost = '192.168.0.10';
  int wifiPort = 35000;

  DtcReport? dtcReport;
  FreezeFrame? freezeFrame;
  bool readingCodes = false;
  String? diagnosticsError;

  /// Raw adapter traffic, newest last, for troubleshooting a real adapter.
  final List<String> log = [];

  bool get isConnected => link == LinkState.connected;

  String get vehicleTitle {
    final info = vinInfo;
    if (isDemo) return 'Demo car';
    if (info?.manufacturer == null) return 'Vehicle';
    return info!.modelYear == null ? info.manufacturer! : '${info.manufacturer} ${info.modelYear}';
  }

  double get refreshRate => _poller?.cyclesPerSecond ?? 0;

  /// The dashboard selection limited to what this vehicle reports.
  List<int> get visibleDashboardPids {
    final visible = dashboardPids.where(availablePids.contains).toList();
    return visible.isNotEmpty ? visible : availablePids.take(6).toList();
  }

  Future<void> init() async {
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      units = prefs.getString('units') == 'imperial' ? UnitSystem.imperial : UnitSystem.metric;
      wifiHost = prefs.getString('wifiHost') ?? wifiHost;
      wifiPort = prefs.getInt('wifiPort') ?? wifiPort;
      final saved = prefs.getStringList('dashboard');
      if (saved != null && saved.isNotEmpty) {
        dashboardPids = saved.map(int.tryParse).whereType<int>().toList();
      }
    } catch (error) {
      debugPrint('Settings unavailable: $error');
    }
    try {
      await dtc.load();
    } catch (error) {
      debugPrint('Fault code database unavailable: $error');
    }
    notifyListeners();
  }

  void _log(String line) {
    log.add(line);
    if (log.length > 400) log.removeRange(0, log.length - 400);
  }

  // ---------------------------------------------------------------------------
  // Connection

  Future<void> connectDemo() {
    final vehicle = demoVehicle = SimulatedVehicle();
    return _connect(SimulatedAdapter(vehicle: vehicle, latency: const Duration(milliseconds: 35)), demo: true);
  }

  Future<void> connectWifi(String host, int port) {
    wifiHost = host;
    wifiPort = port;
    _prefs?.setString('wifiHost', host);
    _prefs?.setInt('wifiPort', port);
    return _connect(TcpTransport(host, port));
  }

  Future<void> connectBle(BleDevice device) => _connect(BleTransport(device));

  Future<void> _connect(ObdTransport transport, {bool demo = false}) async {
    if (link != LinkState.disconnected) return;
    link = LinkState.connecting;
    error = null;
    isDemo = demo;
    progress = 'Connecting to ${transport.description}';
    log.clear();
    notifyListeners();

    final elm = Elm327(transport, onLog: _log);
    final newClient = ObdClient(elm);
    try {
      await newClient.connect(
        onProgress: (message) {
          progress = message;
          notifyListeners();
        },
      );
      fuelType = await newClient.readFuelType();
    } catch (failure) {
      try {
        await elm.close();
      } catch (_) {
        // Nothing was open.
      }
      link = LinkState.disconnected;
      error = _describe(failure);
      if (!demo) demoVehicle = null;
      notifyListeners();
      return;
    }

    client = newClient;
    transportDescription = transport.description;
    vinInfo = newClient.vin == null ? null : decodeVin(newClient.vin!);
    availablePids = [...newClient.readablePids, adapterVoltagePid];
    values.clear();
    history.clear();
    extremes.clear();
    dtcReport = null;
    freezeFrame = null;
    diagnosticsError = null;

    final newAgent = agent = MonitorAgent(baseline: _loadBaseline(newClient.vin));
    _subscriptions.add(newAgent.onFinding.listen(_onFinding));
    recorder = saveRecordings
        ? await SessionRecorder.start(
            availablePids,
            time: DateTime.now(),
            vin: newClient.vin,
          ).timeout(const Duration(seconds: 3), onTimeout: () => SessionRecorder(availablePids, null))
        : SessionRecorder(availablePids, null);

    final poller = _poller = LivePoller(newClient);
    _applyPollingSets();
    _subscriptions
      ..add(poller.samples.listen(_onSample))
      ..add(poller.status.listen(_onStatus))
      ..add(poller.failures.listen((_) => _onLinkLost()))
      ..add(elm.onDisconnected.listen((_) => _onLinkLost()));
    poller.start();

    link = LinkState.connected;
    progress = '';
    notifyListeners();

    unawaited(_notifier.init());
    unawaited(_liveActivity.start(vehicleTitle));
    unawaited(refreshDiagnostics());
  }

  String _describe(Object failure) {
    if (failure is ObdException || failure is TransportException || failure is ElmException) return '$failure';
    return 'Unexpected error: $failure';
  }

  Future<void> disconnect() async {
    if (link != LinkState.connected) return;
    link = LinkState.disconnected;
    await _teardown();
    notifyListeners();
  }

  Future<void> _onLinkLost() async {
    if (link != LinkState.connected) return;
    link = LinkState.disconnected;
    error = 'The connection to the adapter was lost.';
    await _teardown();
    notifyListeners();
  }

  Future<void> _teardown() async {
    // Cancelling takes effect at once; there is nothing to wait for.
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    await _poller?.stop();
    _poller = null;

    final finished = agent;
    if (finished != null) {
      finished.finishSession();
      if (!isDemo) _saveBaseline(client?.vin, finished.baseline);
      finished.dispose();
    }
    agent = null;
    await recorder?.close();
    recorder = null;
    await _liveActivity.end();
    try {
      await client?.disconnect();
    } catch (_) {
      // The link is already down.
    }
    client = null;
    demoVehicle = null;
  }

  // ---------------------------------------------------------------------------
  // Live data

  void _applyPollingSets() {
    final poller = _poller;
    if (poller == null) return;
    poller.fastPids = visibleDashboardPids.toSet();
    poller.slowPids = availablePids.toSet();
  }

  void _onSample(LiveSample sample) {
    sample.values.forEach((pid, value) {
      values[pid] = value;
      final series = history.putIfAbsent(pid, () => <double>[])..add(value);
      if (series.length > 90) series.removeAt(0);
      final range = extremes[pid];
      extremes[pid] = range == null ? (value, value) : (math.min(range.$1, value), math.max(range.$2, value));
    });
    agent?.addSample(sample);
    recorder?.add(sample);
    liveTick.value++;
    _pushLiveActivity();

    // Screens that show slower-moving state (findings resolving, badges)
    // refresh once a second rather than on every sample.
    final now = DateTime.now();
    if (now.difference(_lastSlowRefresh) >= const Duration(seconds: 1)) {
      _lastSlowRefresh = now;
      notifyListeners();
    }
  }

  DateTime _lastSlowRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// Where [value] sits in the gauge range of [pid], from 0 to 1.
  double gaugeFraction(int pid, double value) {
    final (low, high) = pid == adapterVoltagePid ? (10.0, 16.0) : gaugeRange(pid);
    if (high <= low) return 0;
    return ((value - low) / (high - low)).clamp(0.0, 1.0);
  }

  void _pushLiveActivity() {
    final items = <LiveActivityItem>[];
    for (final pid in visibleDashboardPids.take(4)) {
      final def = pidDefinition(pid);
      final value = values[pid];
      if (def == null || value == null) continue;
      final shown = displayValue(def, value, units);
      items.add(
        LiveActivityItem(
          label: def.shortName,
          value: shown.text,
          unit: shown.unit,
          fraction: gaugeFraction(pid, value),
        ),
      );
    }
    final alert = agent?.activeFindings.firstOrNull;
    _liveActivity.update(items, alert: alert?.title, critical: alert?.severity == Severity.critical);
  }

  void setDashboard(List<int> pids) {
    dashboardPids = pids.take(maxDashboardGauges).toList();
    _prefs?.setStringList('dashboard', [for (final pid in dashboardPids) '$pid']);
    _applyPollingSets();
    notifyListeners();
  }

  void setUnits(UnitSystem system) {
    units = system;
    _prefs?.setString('units', system.name);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Diagnostics

  Future<void> refreshDiagnostics() async {
    final active = client;
    if (active == null || readingCodes) return;
    readingCodes = true;
    diagnosticsError = null;
    notifyListeners();
    try {
      dtcReport = await active.readDtcs();
      freezeFrame = await active.readFreezeFrame();
    } catch (failure) {
      diagnosticsError = _describe(failure);
    } finally {
      readingCodes = false;
      notifyListeners();
    }
  }

  Future<ClearResult> clearCodes() async {
    final active = client;
    if (active == null) return const ClearResult(false, 'Not connected.');
    try {
      final result = await active.clearDtcs();
      await refreshDiagnostics();
      return result;
    } catch (failure) {
      return ClearResult(false, _describe(failure));
    }
  }

  Future<void> _onStatus(MonitorStatus status) async {
    final monitor = agent;
    if (monitor == null || !monitor.addStatus(status)) return;
    final before = dtcReport?.codes ?? <String>{};
    await refreshDiagnostics();
    final report = dtcReport;
    if (report == null) return;
    var fresh = report.codes.difference(before);
    if (fresh.isEmpty) fresh = report.ofKind(DtcKind.stored).map((entry) => entry.code).toSet();
    monitor.reportNewCodes([for (final code in fresh) '$code  ${dtc.title(code)}'], DateTime.now());
  }

  void _onFinding(Finding finding) {
    unawaited(_notifier.show(finding));
    notifyListeners();
  }

  void setDemoFault(SimFault fault, bool enabled) {
    demoVehicle?.setFault(fault, enabled);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // What is normal for each car, stored per VIN

  String _baselineKey(String? vin) => 'baseline.${vin ?? 'unknown'}';

  Baseline _loadBaseline(String? vin) {
    if (isDemo) return Baseline();
    try {
      final stored = _prefs?.getString(_baselineKey(vin));
      if (stored != null) return Baseline.fromJson(jsonDecode(stored) as Map<String, dynamic>);
    } catch (error) {
      debugPrint('Could not load baseline: $error');
    }
    return Baseline();
  }

  void _saveBaseline(String? vin, Baseline baseline) {
    _prefs?.setString(_baselineKey(vin), jsonEncode(baseline.toJson()));
  }

  @override
  void dispose() {
    liveTick.dispose();
    super.dispose();
  }
}
