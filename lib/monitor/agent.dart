import 'dart:async';
import 'dart:math' as math;

import '../obd/dtc.dart';
import '../obd/live_poller.dart';
import 'baseline.dart';

enum Severity { info, warning, critical }

/// Something the monitor noticed, phrased for the driver.
class Finding {
  Finding({
    required this.id,
    required this.severity,
    required this.title,
    required this.detail,
    required this.advice,
    required this.time,
  });

  final String id;
  final Severity severity;
  final String title;

  /// What was observed, with the numbers.
  final String detail;

  /// What to do about it.
  final String advice;
  final DateTime time;

  /// False once the condition has gone away again.
  bool active = true;
}

/// Limits for the fixed rules. Deliberately conservative: modern engines run
/// hot and use smart charging, so alarms only fire well outside normal ranges.
class MonitorThresholds {
  const MonitorThresholds({
    this.coolantWarning = 110,
    this.coolantCritical = 118,
    this.voltageLow = 12.0,
    this.voltageCritical = 11.5,
    this.voltageHigh = 15.3,
    this.fuelTrimLimit = 18,
    this.oilWarning = 135,
    this.oilCritical = 150,
    this.catalystLimit = 950,
    this.fuelLevelLow = 10,
    this.idleSpread = 90,
  });

  final double coolantWarning;
  final double coolantCritical;
  final double voltageLow;
  final double voltageCritical;
  final double voltageHigh;
  final double fuelTrimLimit;
  final double oilWarning;
  final double oilCritical;
  final double catalystLimit;
  final double fuelLevelLow;

  /// Standard deviation of idle speed (rpm) that counts as unstable.
  final double idleSpread;
}

const int _coolant = 0x05;
const int _ltft1 = 0x07;
const int _ltft2 = 0x09;
const int _map = 0x0B;
const int _rpm = 0x0C;
const int _speed = 0x0D;
const int _intake = 0x0F;
const int _maf = 0x10;
const int _fuelLevel = 0x2F;
const int _catalyst1 = 0x3C;
const int _catalyst2 = 0x3D;
const int _moduleVoltage = 0x42;
const int _ambient = 0x46;
const int _oil = 0x5C;

class _State {
  final Map<int, double> _values = {};
  final Map<int, DateTime> _seen = {};
  final List<(DateTime, double)> _idleRpm = [];
  DateTime now = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? runningSince;
  double maxCoolant = double.negativeInfinity;

  /// Latest value, or null when it is missing or stale.
  double? v(int pid) {
    final seen = _seen[pid];
    if (seen == null || now.difference(seen) > const Duration(seconds: 30)) return null;
    return _values[pid];
  }

  bool get running => (v(_rpm) ?? 0) > 400;

  Duration get runFor => runningSince == null ? Duration.zero : now.difference(runningSince!);

  bool get warm => (v(_coolant) ?? -100) >= 70;

  bool get idling => running && (v(_speed) ?? 0) < 1 && (v(_rpm) ?? 9999) < 1300;

  double? get voltage => v(_moduleVoltage) ?? v(adapterVoltagePid);

  /// Standard deviation of engine speed over the last 20 s of idling.
  double? get idleSpread {
    if (_idleRpm.length < 8) return null;
    if (_idleRpm.last.$1.difference(_idleRpm.first.$1) < const Duration(seconds: 12)) return null;
    final mean = _idleRpm.fold<double>(0, (sum, e) => sum + e.$2) / _idleRpm.length;
    final variance = _idleRpm.fold<double>(0, (sum, e) => sum + (e.$2 - mean) * (e.$2 - mean)) / _idleRpm.length;
    return math.sqrt(variance);
  }

  void apply(LiveSample sample) {
    now = sample.time;
    sample.values.forEach((pid, value) {
      _values[pid] = value;
      _seen[pid] = sample.time;
    });
    if (running) {
      runningSince ??= now;
    } else {
      runningSince = null;
    }
    final coolant = sample.values[_coolant];
    if (coolant != null && coolant > maxCoolant) maxCoolant = coolant;

    final rpm = sample.values[_rpm];
    if (!idling) {
      _idleRpm.clear();
    } else if (rpm != null) {
      _idleRpm.add((now, rpm));
      _idleRpm.removeWhere((entry) => now.difference(entry.$1) > const Duration(seconds: 20));
    }
  }
}

class _Rule {
  _Rule(
    this.id,
    this.severity,
    this.hold,
    this.condition, {
    required this.title,
    required this.detail,
    required this.advice,
    this.cooldown = const Duration(minutes: 10),
  });

  final String id;
  final Severity severity;

  /// How long the condition must persist before it is reported.
  final Duration hold;
  final bool Function(_State s) condition;
  final String title;
  final String Function(_State s) detail;
  final String advice;

  /// Minimum time between two reports of the same problem.
  final Duration cooldown;

  DateTime? trueSince;
  DateTime? falseSince;
  DateTime? lastRaised;
  Finding? finding;
}

class _Accumulator {
  double sum = 0;
  int count = 0;
  bool flagged = false;

  double get mean => sum / count;
}

/// Watches the live data stream and reports when something looks wrong:
/// fixed safety rules (overheating, charging, fuel trim, ...) plus drift away
/// from what this particular car has shown to be normal on earlier drives.
/// Runs entirely on the device.
class MonitorAgent {
  MonitorAgent({Baseline? baseline, this.thresholds = const MonitorThresholds()}) : baseline = baseline ?? Baseline() {
    _rules = _buildRules();
  }

  /// Samples of a signature needed in one drive before it is compared or learned.
  static const int minSamples = 60;

  final Baseline baseline;
  final MonitorThresholds thresholds;
  final _State _state = _State();
  late final List<_Rule> _rules;
  final Map<Signature, _Accumulator> _session = {};
  final StreamController<Finding> _raised = StreamController<Finding>.broadcast();
  MonitorStatus? _lastStatus;
  int _samples = 0;

  /// Newest first.
  final List<Finding> findings = [];

  /// Fires when a new finding is raised (used for notifications).
  Stream<Finding> get onFinding => _raised.stream;

  int get samplesSeen => _samples;

  Iterable<Finding> get activeFindings => findings.where((finding) => finding.active);

  /// The parameters the rules look at; used to tell the user what is covered.
  static const List<int> watchedPids = [
    _coolant, _rpm, _speed, _ltft1, _ltft2, _map, _intake, _maf, _fuelLevel, _catalyst1, _catalyst2,
    _moduleVoltage, _ambient, _oil, adapterVoltagePid, //
  ];

  void _raise(Finding finding) {
    findings.insert(0, finding);
    if (!_raised.isClosed) _raised.add(finding);
  }

  String _n(double? value, [int decimals = 0]) => value == null ? '?' : value.toStringAsFixed(decimals);

  List<_Rule> _buildRules() {
    final t = thresholds;
    _Rule trim(String id, int pid, int bank, bool lean) => _Rule(
      id,
      Severity.warning,
      const Duration(seconds: 60),
      (s) {
        final value = s.v(pid);
        if (value == null || !s.running || !s.warm) return false;
        return lean ? value >= t.fuelTrimLimit : value <= -t.fuelTrimLimit;
      },
      title: lean ? 'Engine is running lean (bank $bank)' : 'Engine is running rich (bank $bank)',
      detail: (s) =>
          'Long term fuel trim on bank $bank is ${_n(s.v(pid), 1)} %. The engine computer is '
          '${lean ? 'adding' : 'removing'} far more fuel than normal to keep the mixture right.',
      advice: lean
          ? 'Typical causes are an intake or vacuum leak, a dirty air-flow sensor or weak fuel delivery '
                '(pump, filter). Have it checked before it sets a fault code.'
          : 'Typical causes are a leaking injector, a faulty fuel pressure regulator, a stuck purge valve '
                'or a contaminated air-flow sensor.',
    );

    return [
      _Rule(
        'coolant_critical',
        Severity.critical,
        const Duration(seconds: 5),
        (s) => (s.v(_coolant) ?? -100) >= t.coolantCritical,
        title: 'Engine is overheating',
        detail: (s) => 'Coolant temperature is ${_n(s.v(_coolant))} °C.',
        advice:
            'Stop as soon as it is safe, switch the engine off and let it cool down. '
            'Do not open the coolant cap while the engine is hot.',
        cooldown: const Duration(minutes: 3),
      ),
      _Rule(
        'coolant_high',
        Severity.warning,
        const Duration(seconds: 30),
        (s) => (s.v(_coolant) ?? -100) >= t.coolantWarning,
        title: 'Coolant temperature is high',
        detail: (s) => 'Coolant temperature has stayed at ${_n(s.v(_coolant))} °C or above.',
        advice:
            'Ease off and watch the temperature. Turning the cabin heater to full hot helps shed heat. '
            'Check the coolant level once the engine is cold.',
      ),
      _Rule(
        'not_warming',
        Severity.info,
        const Duration(seconds: 30),
        (s) => s.running && s.runFor >= const Duration(minutes: 15) && s.maxCoolant < 70 && (s.v(_ambient) ?? 10) > -15,
        title: 'Engine is not reaching operating temperature',
        detail: (s) =>
            'After ${s.runFor.inMinutes} minutes of running the coolant is still at ${_n(s.v(_coolant))} °C.',
        advice:
            'A thermostat stuck open is the usual cause. It raises fuel consumption and engine wear, '
            'and is an inexpensive repair.',
        cooldown: const Duration(hours: 2),
      ),
      _Rule(
        'voltage_critical',
        Severity.critical,
        const Duration(seconds: 20),
        (s) => s.running && s.runFor >= const Duration(seconds: 30) && (s.voltage ?? 99) < t.voltageCritical,
        title: 'Battery voltage is critically low',
        detail: (s) => 'System voltage is ${_n(s.voltage, 1)} V with the engine running.',
        advice:
            'The battery is not being charged and the engine may stall once it is drained. Switch off '
            'non-essential electrical loads and head for a workshop or a safe place to stop.',
        cooldown: const Duration(minutes: 5),
      ),
      _Rule(
        'voltage_low',
        Severity.warning,
        const Duration(seconds: 60),
        (s) => s.running && s.runFor >= const Duration(seconds: 60) && (s.voltage ?? 99) < t.voltageLow,
        title: 'Battery is not being charged',
        detail: (s) => 'System voltage has stayed at ${_n(s.voltage, 1)} V with the engine running.',
        advice: 'Have the alternator, its drive belt and the battery connections checked.',
      ),
      _Rule(
        'voltage_high',
        Severity.warning,
        const Duration(seconds: 30),
        (s) => s.running && (s.voltage ?? 0) > t.voltageHigh,
        title: 'Charging voltage is too high',
        detail: (s) => 'System voltage is ${_n(s.voltage, 1)} V.',
        advice: 'Overcharging damages the battery and electronics. Have the voltage regulator checked.',
      ),
      trim('lean_bank1', _ltft1, 1, true),
      trim('rich_bank1', _ltft1, 1, false),
      trim('lean_bank2', _ltft2, 2, true),
      trim('rich_bank2', _ltft2, 2, false),
      _Rule(
        'idle_unstable',
        Severity.warning,
        const Duration(seconds: 10),
        (s) => s.warm && (s.idleSpread ?? 0) > t.idleSpread,
        title: 'Idle speed is unstable',
        detail: (s) => 'Engine speed is swinging by about ±${_n(s.idleSpread)} rpm at idle.',
        advice:
            'A rough idle usually comes from a misfire (spark plugs, coils), a vacuum leak or a dirty '
            'throttle body.',
      ),
      _Rule(
        'coolant_sensor',
        Severity.warning,
        const Duration(seconds: 10),
        (s) => s.running && s.runFor >= const Duration(seconds: 60) && (s.v(_coolant) ?? 0) <= -40,
        title: 'Coolant temperature sensor reading is implausible',
        detail: (s) => 'The sensor reports ${_n(s.v(_coolant))} °C with the engine running.',
        advice: 'This usually means an unplugged or failed sensor or broken wiring.',
        cooldown: const Duration(hours: 1),
      ),
      _Rule(
        'intake_sensor',
        Severity.warning,
        const Duration(seconds: 10),
        (s) => s.running && s.runFor >= const Duration(seconds: 60) && (s.v(_intake) ?? 0) <= -40,
        title: 'Intake air temperature sensor reading is implausible',
        detail: (s) => 'The sensor reports ${_n(s.v(_intake))} °C with the engine running.',
        advice: 'This usually means an unplugged or failed sensor or broken wiring.',
        cooldown: const Duration(hours: 1),
      ),
      _Rule(
        'catalyst_hot',
        Severity.warning,
        const Duration(seconds: 10),
        (s) => math.max(s.v(_catalyst1) ?? 0, s.v(_catalyst2) ?? 0) >= t.catalystLimit,
        title: 'Catalytic converter is very hot',
        detail: (s) => 'Catalyst temperature is ${_n(math.max(s.v(_catalyst1) ?? 0, s.v(_catalyst2) ?? 0))} °C.',
        advice:
            'Sustained temperatures this high damage the converter. Misfires or a rich mixture are the '
            'usual cause; reduce load and have it checked.',
      ),
      _Rule(
        'oil_critical',
        Severity.critical,
        const Duration(seconds: 10),
        (s) => (s.v(_oil) ?? 0) >= t.oilCritical,
        title: 'Engine oil is overheating',
        detail: (s) => 'Oil temperature is ${_n(s.v(_oil))} °C.',
        advice: 'Reduce load immediately and let the engine cool. Check the oil level when it is safe.',
        cooldown: const Duration(minutes: 3),
      ),
      _Rule(
        'oil_high',
        Severity.warning,
        const Duration(seconds: 30),
        (s) => (s.v(_oil) ?? 0) >= t.oilWarning,
        title: 'Engine oil temperature is high',
        detail: (s) => 'Oil temperature has stayed at ${_n(s.v(_oil))} °C or above.',
        advice: 'Ease off until it drops. Check the oil level and condition.',
      ),
      _Rule(
        'fuel_low',
        Severity.info,
        const Duration(seconds: 30),
        (s) => (s.v(_fuelLevel) ?? 100) < t.fuelLevelLow,
        title: 'Fuel level is low',
        detail: (s) => 'The tank is at ${_n(s.v(_fuelLevel))} %.',
        advice: 'Refuel soon.',
        cooldown: const Duration(hours: 3),
      ),
    ];
  }

  /// Feeds one live data sample to the monitor.
  void addSample(LiveSample sample) {
    _samples++;
    final s = _state..apply(sample);
    final now = sample.time;

    for (final rule in _rules) {
      if (rule.condition(s)) {
        rule.falseSince = null;
        rule.trueSince ??= now;
        final cooledDown = rule.lastRaised == null || now.difference(rule.lastRaised!) >= rule.cooldown;
        if (rule.finding == null && cooledDown && now.difference(rule.trueSince!) >= rule.hold) {
          final finding = Finding(
            id: rule.id,
            severity: rule.severity,
            title: rule.title,
            detail: rule.detail(s),
            advice: rule.advice,
            time: now,
          );
          rule.finding = finding;
          rule.lastRaised = now;
          _raise(finding);
        }
      } else {
        rule.trueSince = null;
        if (rule.finding != null) {
          rule.falseSince ??= now;
          if (now.difference(rule.falseSince!) >= const Duration(seconds: 20)) {
            rule.finding!.active = false;
            rule.finding = null;
          }
        }
      }
    }

    _trackSignatures(sample, s);
  }

  void _collect(Signature signature, double? value, DateTime now) {
    if (value == null) return;
    final acc = _session.putIfAbsent(signature, _Accumulator.new)
      ..sum += value
      ..count += 1;
    if (acc.flagged || acc.count < minSamples || acc.count % 30 != 0) return;
    final deviation = baseline.compare(signature, acc.mean);
    if (deviation == null) return;
    acc.flagged = true;
    final d = signature.decimals;
    final higher = deviation.current > deviation.normal;
    _raise(
      Finding(
        id: 'baseline_${signature.name}',
        severity: signature == Signature.cruiseCoolant || signature == Signature.chargingVoltage
            ? Severity.warning
            : Severity.info,
        title: '${signature.label} is ${higher ? 'higher' : 'lower'} than usual for this car',
        detail:
            'It is averaging ${deviation.current.toStringAsFixed(d)} ${signature.unit} on this drive; '
            'on earlier drives it was around ${deviation.normal.toStringAsFixed(d)} ${signature.unit}.',
        advice: _deviationAdvice(signature, higher),
        time: now,
      ),
    );
  }

  String _deviationAdvice(Signature signature, bool higher) => switch (signature) {
    Signature.idleRpm =>
      higher
          ? 'A higher idle can come from a vacuum leak, a sticking throttle or the engine compensating for a load.'
          : 'A lower idle can point to a dirty throttle body or an idle control problem.',
    Signature.idleMap =>
      higher
          ? 'Weaker intake vacuum at idle suggests an air leak or a valve timing problem.'
          : 'Stronger vacuum than usual can mean a restricted intake.',
    Signature.idleMaf =>
      'A change in idle air flow often points to an air leak after the sensor or a contaminated air-flow sensor.',
    Signature.longTrimBank1 || Signature.longTrimBank2 =>
      higher
          ? 'The engine computer is adding more fuel than it used to. Look for air leaks or weakening fuel delivery.'
          : 'The engine computer is removing more fuel than it used to. Look for a leaking injector or a sensor fault.',
    Signature.chargingVoltage =>
      'A change in charging voltage can indicate a tiring alternator, regulator or battery, or a slipping belt.',
    Signature.cruiseCoolant =>
      higher
          ? 'Running hotter than usual can mean low coolant, a sticking thermostat or a blocked radiator.'
          : 'Running cooler than usual normally means a thermostat stuck open.',
  };

  void _trackSignatures(LiveSample sample, _State s) {
    if (!s.running || !s.warm || s.runFor < const Duration(minutes: 3)) return;
    final values = sample.values;
    final now = sample.time;
    if (s.idling) {
      _collect(Signature.idleRpm, values[_rpm], now);
      _collect(Signature.idleMap, values[_map], now);
      _collect(Signature.idleMaf, values[_maf], now);
    }
    _collect(Signature.longTrimBank1, values[_ltft1], now);
    _collect(Signature.longTrimBank2, values[_ltft2], now);
    _collect(Signature.chargingVoltage, values[_moduleVoltage] ?? values[adapterVoltagePid], now);
    if ((s.v(_speed) ?? 0) >= 50) _collect(Signature.cruiseCoolant, values[_coolant], now);
  }

  /// Feeds the periodic warning-light status. Returns true when codes were
  /// added since the last check, so the caller should read them.
  bool addStatus(MonitorStatus status) {
    final previous = _lastStatus;
    _lastStatus = status;
    if (previous == null) return false;
    return status.dtcCount > previous.dtcCount || (status.milOn && !previous.milOn);
  }

  /// Reports fault codes that appeared during this drive.
  void reportNewCodes(List<String> descriptions, DateTime time) {
    if (descriptions.isEmpty) return;
    _raise(
      Finding(
        id: 'new_code_${time.millisecondsSinceEpoch}',
        severity: Severity.warning,
        title: descriptions.length == 1 ? 'New fault code stored' : '${descriptions.length} new fault codes stored',
        detail: descriptions.join('\n'),
        advice:
            'Open Diagnostics for the full description. If the engine runs roughly or the warning light '
            'is flashing, reduce load and have it checked soon.',
        time: time,
      ),
    );
  }

  /// Ends the drive: readings that were steady and unremarkable are added to
  /// what counts as normal for this car. Returns the signatures learned.
  List<Signature> finishSession() {
    final learned = <Signature>[];
    _session.forEach((signature, acc) {
      if (acc.count >= minSamples && !acc.flagged) {
        baseline.learn(signature, acc.mean);
        learned.add(signature);
      }
    });
    _session.clear();
    return learned;
  }

  void dispose() {
    _raised.close();
  }
}
