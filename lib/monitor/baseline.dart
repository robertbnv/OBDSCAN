import 'dart:math' as math;

/// A steady-state reading the monitor learns for one specific car, so it can
/// tell when that car starts behaving differently from its own normal.
enum Signature {
  idleRpm('Warm idle speed', 'rpm', 0, 120, false),
  idleMap('Intake vacuum at idle', 'kPa', 0, 8, false),
  idleMaf('Air flow at idle', 'g/s', 1, 0.30, true),
  longTrimBank1('Long term fuel trim, bank 1', '%', 1, 8, false),
  longTrimBank2('Long term fuel trim, bank 2', '%', 1, 8, false),
  chargingVoltage('Charging voltage', 'V', 1, 0.6, false),
  cruiseCoolant('Coolant temperature at speed', '°C', 0, 8, false);

  const Signature(this.label, this.unit, this.decimals, this.margin, this.marginIsRelative);

  final String label;
  final String unit;
  final int decimals;

  /// Smallest change worth reporting: absolute, or a fraction of the normal
  /// value when [marginIsRelative].
  final double margin;
  final bool marginIsRelative;
}

/// Running mean and spread of one signature across past drives.
class SignatureStats {
  SignatureStats({this.sessions = 0, this.mean = 0, this.sumSquares = 0});

  int sessions;
  double mean;
  double sumSquares; // Welford's running sum of squared differences

  double get standardDeviation => sessions < 2 ? 0 : math.sqrt(sumSquares / (sessions - 1));

  void add(double value) {
    sessions++;
    final delta = value - mean;
    mean += delta / sessions;
    sumSquares += delta * (value - mean);
  }

  Map<String, dynamic> toJson() => {'n': sessions, 'm': mean, 's': sumSquares};

  static SignatureStats fromJson(Map<String, dynamic> json) => SignatureStats(
    sessions: (json['n'] as num?)?.toInt() ?? 0,
    mean: (json['m'] as num?)?.toDouble() ?? 0,
    sumSquares: (json['s'] as num?)?.toDouble() ?? 0,
  );
}

class Deviation {
  const Deviation(this.signature, this.current, this.normal);

  final Signature signature;
  final double current;
  final double normal;
}

/// What is normal for one car, learned over several drives.
class Baseline {
  Baseline([Map<Signature, SignatureStats>? stats]) : stats = stats ?? {};

  /// Drives needed before the baseline is trusted enough to raise findings.
  static const int sessionsRequired = 3;

  final Map<Signature, SignatureStats> stats;

  bool isLearned(Signature signature) => (stats[signature]?.sessions ?? 0) >= sessionsRequired;

  int get learnedCount => Signature.values.where(isLearned).length;

  /// Returns a deviation when [current] is further from this car's normal
  /// than both the signature's margin and three standard deviations.
  Deviation? compare(Signature signature, double current) {
    final known = stats[signature];
    if (known == null || known.sessions < sessionsRequired) return null;
    final margin = signature.marginIsRelative ? signature.margin * known.mean.abs() : signature.margin;
    final threshold = math.max(margin, 3 * known.standardDeviation);
    if ((current - known.mean).abs() <= threshold) return null;
    return Deviation(signature, current, known.mean);
  }

  void learn(Signature signature, double sessionMean) {
    stats.putIfAbsent(signature, SignatureStats.new).add(sessionMean);
  }

  Map<String, dynamic> toJson() => {for (final entry in stats.entries) entry.key.name: entry.value.toJson()};

  static Baseline fromJson(Map<String, dynamic> json) {
    final stats = <Signature, SignatureStats>{};
    for (final signature in Signature.values) {
      final value = json[signature.name];
      if (value is Map<String, dynamic>) stats[signature] = SignatureStats.fromJson(value);
    }
    return Baseline(stats);
  }
}
