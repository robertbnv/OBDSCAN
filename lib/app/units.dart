import '../obd/pids.dart';

enum UnitSystem { metric, imperial }

/// A value converted for display, with its unit and number of decimals.
class DisplayValue {
  const DisplayValue(this.value, this.unit, this.decimals);

  final double value;
  final String unit;
  final int decimals;

  String get text => value.toStringAsFixed(decimals);
}

double _convert(String unit, double value) => switch (unit) {
  '°C' => value * 9 / 5 + 32,
  'km/h' || 'km' => value * 0.621371,
  'kPa' => value * 0.1450377,
  'L/h' => value * 0.264172,
  _ => value,
};

String _convertUnit(String unit) => switch (unit) {
  '°C' => '°F',
  'km/h' => 'mph',
  'km' => 'mi',
  'kPa' => 'psi',
  'L/h' => 'gal/h',
  _ => unit,
};

DisplayValue displayValue(PidDef def, double value, UnitSystem system) {
  if (system == UnitSystem.metric) return DisplayValue(value, def.unit, def.decimals);
  final unit = _convertUnit(def.unit);
  // Pressures in psi need a decimal that whole kilopascals do not.
  final decimals = unit == 'psi' && def.decimals == 0 ? 1 : def.decimals;
  return DisplayValue(_convert(def.unit, value), unit, decimals);
}

(double, double) displayRange(PidDef def, (double, double) range, UnitSystem system) {
  if (system == UnitSystem.metric) return range;
  return (_convert(def.unit, range.$1), _convert(def.unit, range.$2));
}
