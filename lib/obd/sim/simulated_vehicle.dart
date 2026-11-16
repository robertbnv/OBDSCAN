import 'dart:math' as math;

/// Faults that can be switched on in the demo car to exercise the monitor.
enum SimFault {
  overheating('Engine overheating'),
  chargingFailure('Alternator not charging'),
  leanMixture('Lean fuel mixture'),
  roughIdle('Rough idle'),
  newTroubleCode('New fault code (misfire)');

  const SimFault(this.label);

  final String label;
}

/// A small engine model whose sensor values evolve with time. It repeats a
/// two-minute drive cycle: idle, accelerate, cruise, slow down, idle.
class SimulatedVehicle {
  SimulatedVehicle({double Function()? elapsedSeconds, this.vin = '1HGCM82633A004352', this.warmStart = false}) {
    if (elapsedSeconds != null) {
      _elapsed = elapsedSeconds;
    } else {
      final watch = Stopwatch()..start();
      _elapsed = () => watch.elapsedMicroseconds / 1e6;
    }
  }

  late final double Function() _elapsed;
  final String vin;

  /// Start with the engine already at operating temperature.
  final bool warmStart;

  bool ignitionOn = true;
  List<String> storedCodes = ['P0420'];
  List<String> pendingCodes = ['P0171'];
  List<String> permanentCodes = ['P0420'];
  bool monitorsReset = false;

  final Map<SimFault, double> _faultStart = {};

  double get time => _elapsed();

  Set<SimFault> get activeFaults => _faultStart.keys.toSet();

  void setFault(SimFault fault, bool enabled) {
    if (!enabled) {
      _faultStart.remove(fault);
      if (fault == SimFault.newTroubleCode) storedCodes.remove('P0301');
      return;
    }
    _faultStart.putIfAbsent(fault, () => time);
    if (fault == SimFault.newTroubleCode && !storedCodes.contains('P0301')) {
      storedCodes = [...storedCodes, 'P0301'];
    }
  }

  double? _since(SimFault fault) {
    final start = _faultStart[fault];
    return start == null ? null : time - start;
  }

  bool get milOn => storedCodes.isNotEmpty;

  void clearCodes() {
    storedCodes = [];
    pendingCodes = [];
    monitorsReset = true;
    _faultStart.remove(SimFault.newTroubleCode);
  }

  double get _cycle => time % 120;

  static double _smooth(double x) {
    final t = x.clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  bool get idling => _cycle < 15 || _cycle >= 100;

  double get speed {
    final c = _cycle;
    if (c < 15) return 0;
    if (c < 35) return 90 * _smooth((c - 15) / 20);
    if (c < 80) return 90 + 2 * math.sin(c / 4);
    if (c < 100) return 90 * (1 - _smooth((c - 80) / 20));
    return 0;
  }

  double get rpm {
    final c = _cycle;
    double value;
    if (c < 15 || c >= 100) {
      value = 780 + 12 * math.sin(time * 1.7);
      if (_faultStart.containsKey(SimFault.roughIdle)) {
        value += 170 * math.sin(time * 5.3) + 90 * math.sin(time * 11.1);
      }
    } else if (c < 35) {
      // Climb through the gears: revs rise and fall back at each shift.
      final progress = (c - 15) / 20;
      final gear = (progress * 4).floor().clamp(0, 3);
      final within = progress * 4 - gear;
      value = 1500 + 1700 * within - gear * 80;
    } else if (c < 80) {
      value = 2100 + 40 * math.sin(c / 4);
    } else {
      value = 2100 - 1300 * _smooth((c - 80) / 20);
    }
    return value;
  }

  double get load {
    final c = _cycle;
    if (c < 15 || c >= 100) return 22 + 1.5 * math.sin(time * 0.9);
    if (c < 35) return 68 + 6 * math.sin(c);
    if (c < 80) return 38 + 3 * math.sin(c / 3);
    return 9;
  }

  double get throttle => 12 + load * 0.55;

  double get manifoldPressure => 28 + load * 0.72;

  double get massAirFlow => rpm * (load / 100) * 0.018 + 1.5;

  double get coolantTemp {
    final base = warmStart ? 89 + 1.5 * math.sin(time / 30) : 90 - 70 * math.exp(-time / 90);
    final overheating = _since(SimFault.overheating);
    if (overheating == null) return base;
    return math.min(126, base + overheating * 0.6);
  }

  double get oilTemp => coolantTemp * 0.96 + 2;

  double get intakeTemp => 24 + 6 * (1 - math.exp(-time / 200));

  double get voltage {
    final failing = _since(SimFault.chargingFailure);
    if (failing == null) return 14.1 + 0.08 * math.sin(time / 7);
    return math.max(11.2, 12.6 - failing * 0.02);
  }

  double get shortTermTrim {
    final lean = _faultStart.containsKey(SimFault.leanMixture);
    return (lean ? 8.0 : 0.0) + 3 * math.sin(time * 0.8);
  }

  double get longTermTrim => _faultStart.containsKey(SimFault.leanMixture) ? 21.0 : 2.3;

  double get timingAdvance => idling ? 10 + math.sin(time) : 26 + 3 * math.sin(time / 5);

  double get fuelLevel => math.max(5, 62 - time / 600);

  double get upstreamO2 => 0.5 + 0.38 * math.sin(time * 3.1);

  double get downstreamO2 => 0.66 + 0.03 * math.sin(time / 3);

  double get catalystTemp => 300 + math.min(time, 300) * 1.2;

  double get fuelRate => massAirFlow * 0.329;

  bool get closedLoop => coolantTemp > 60;

  int get runTime => time.floor().clamp(0, 65535);
}
