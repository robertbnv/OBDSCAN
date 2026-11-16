/// SAE J1979 / ISO 15031-5 service 01 parameter definitions.
library;

enum PidGroup { engine, fuel, air, temperature, electrical, emissions, trip }

typedef PidDecoder = double Function(List<int> d);

class PidDef {
  const PidDef(
    this.pid,
    this.name,
    this.shortName,
    this.unit,
    this.bytes,
    this.min,
    this.max,
    this.decode, {
    this.decimals = 0,
    this.group = PidGroup.engine,
  });

  final int pid;
  final String name;

  /// Compact label for gauges and the CarPlay view.
  final String shortName;
  final String unit;

  /// Number of data bytes the ECU returns for this parameter.
  final int bytes;
  final double min;
  final double max;
  final PidDecoder decode;
  final int decimals;
  final PidGroup group;

  String get code => pid.toRadixString(16).toUpperCase().padLeft(2, '0');

  String format(double value) => value.toStringAsFixed(decimals);
}

double _a(List<int> d) => d[0].toDouble();
double _ab(List<int> d) => (d[0] * 256 + d[1]).toDouble();
double _percent(List<int> d) => d[0] * 100 / 255;
double _trim(List<int> d) => (d[0] - 128) * 100 / 128;
double _temp(List<int> d) => d[0] - 40.0;
double _signed16(List<int> d) {
  final raw = d[0] * 256 + d[1];
  return (raw >= 0x8000 ? raw - 0x10000 : raw).toDouble();
}

double _lambda(List<int> d) => _ab(d) * 2 / 65536;
double _catalystTemp(List<int> d) => _ab(d) / 10 - 40;

PidDef _o2Voltage(int pid, int bank, int sensor) => PidDef(
  pid,
  'O2 sensor voltage, bank $bank sensor $sensor',
  'O2 B${bank}S$sensor',
  'V',
  2,
  0,
  1.275,
  (d) => d[0] / 200,
  decimals: 3,
  group: PidGroup.emissions,
);

PidDef _o2Lambda(int pid, int bank, int sensor) => PidDef(
  pid,
  'Air-fuel ratio (lambda), bank $bank sensor $sensor',
  'λ B${bank}S$sensor',
  'λ',
  4,
  0,
  2,
  _lambda,
  decimals: 3,
  group: PidGroup.emissions,
);

/// Every numeric parameter the app can decode, keyed by PID.
final Map<int, PidDef> pidTable = {
  for (final def in <PidDef>[
    const PidDef(0x04, 'Calculated engine load', 'Load', '%', 1, 0, 100, _percent),
    const PidDef(0x05, 'Engine coolant temperature', 'Coolant', '°C', 1, -40, 215, _temp, group: PidGroup.temperature),
    const PidDef(
      0x06,
      'Short term fuel trim, bank 1',
      'STFT B1',
      '%',
      1,
      -100,
      99.2,
      _trim,
      decimals: 1,
      group: PidGroup.fuel,
    ),
    const PidDef(
      0x07,
      'Long term fuel trim, bank 1',
      'LTFT B1',
      '%',
      1,
      -100,
      99.2,
      _trim,
      decimals: 1,
      group: PidGroup.fuel,
    ),
    const PidDef(
      0x08,
      'Short term fuel trim, bank 2',
      'STFT B2',
      '%',
      1,
      -100,
      99.2,
      _trim,
      decimals: 1,
      group: PidGroup.fuel,
    ),
    const PidDef(
      0x09,
      'Long term fuel trim, bank 2',
      'LTFT B2',
      '%',
      1,
      -100,
      99.2,
      _trim,
      decimals: 1,
      group: PidGroup.fuel,
    ),
    PidDef(0x0A, 'Fuel pressure (gauge)', 'Fuel press', 'kPa', 1, 0, 765, (d) => d[0] * 3.0, group: PidGroup.fuel),
    const PidDef(0x0B, 'Intake manifold absolute pressure', 'MAP', 'kPa', 1, 0, 255, _a, group: PidGroup.air),
    PidDef(0x0C, 'Engine speed', 'RPM', 'rpm', 2, 0, 8000, (d) => (d[0] * 256 + d[1]) / 4),
    const PidDef(0x0D, 'Vehicle speed', 'Speed', 'km/h', 1, 0, 255, _a),
    PidDef(0x0E, 'Timing advance', 'Timing', '°', 1, -64, 63.5, (d) => d[0] / 2 - 64, decimals: 1),
    const PidDef(0x0F, 'Intake air temperature', 'Intake', '°C', 1, -40, 215, _temp, group: PidGroup.temperature),
    PidDef(
      0x10,
      'Mass air flow',
      'MAF',
      'g/s',
      2,
      0,
      655.35,
      (d) => (d[0] * 256 + d[1]) / 100,
      decimals: 2,
      group: PidGroup.air,
    ),
    const PidDef(0x11, 'Throttle position', 'Throttle', '%', 1, 0, 100, _percent, group: PidGroup.air),
    _o2Voltage(0x14, 1, 1),
    _o2Voltage(0x15, 1, 2),
    _o2Voltage(0x16, 1, 3),
    _o2Voltage(0x17, 1, 4),
    _o2Voltage(0x18, 2, 1),
    _o2Voltage(0x19, 2, 2),
    _o2Voltage(0x1A, 2, 3),
    _o2Voltage(0x1B, 2, 4),
    const PidDef(0x1F, 'Run time since engine start', 'Run time', 's', 2, 0, 65535, _ab, group: PidGroup.trip),
    const PidDef(
      0x21,
      'Distance travelled with warning light on',
      'MIL dist',
      'km',
      2,
      0,
      65535,
      _ab,
      group: PidGroup.trip,
    ),
    PidDef(
      0x22,
      'Fuel rail pressure (relative to manifold)',
      'Rail press',
      'kPa',
      2,
      0,
      5177.3,
      (d) => (d[0] * 256 + d[1]) * 0.079,
      decimals: 1,
      group: PidGroup.fuel,
    ),
    PidDef(
      0x23,
      'Fuel rail gauge pressure',
      'Rail press',
      'kPa',
      2,
      0,
      655350,
      (d) => (d[0] * 256 + d[1]) * 10.0,
      group: PidGroup.fuel,
    ),
    _o2Lambda(0x24, 1, 1),
    _o2Lambda(0x25, 1, 2),
    _o2Lambda(0x26, 1, 3),
    _o2Lambda(0x27, 1, 4),
    _o2Lambda(0x28, 2, 1),
    _o2Lambda(0x29, 2, 2),
    _o2Lambda(0x2A, 2, 3),
    _o2Lambda(0x2B, 2, 4),
    const PidDef(0x2C, 'Commanded EGR', 'EGR', '%', 1, 0, 100, _percent, group: PidGroup.emissions),
    const PidDef(0x2D, 'EGR error', 'EGR err', '%', 1, -100, 99.2, _trim, decimals: 1, group: PidGroup.emissions),
    const PidDef(0x2E, 'Commanded evaporative purge', 'Purge', '%', 1, 0, 100, _percent, group: PidGroup.emissions),
    const PidDef(0x2F, 'Fuel tank level', 'Fuel', '%', 1, 0, 100, _percent, group: PidGroup.fuel),
    const PidDef(0x30, 'Warm-ups since codes cleared', 'Warm-ups', '', 1, 0, 255, _a, group: PidGroup.trip),
    const PidDef(
      0x31,
      'Distance travelled since codes cleared',
      'Clr dist',
      'km',
      2,
      0,
      65535,
      _ab,
      group: PidGroup.trip,
    ),
    PidDef(
      0x32,
      'Evaporative system vapour pressure',
      'Evap',
      'Pa',
      2,
      -8192,
      8191.75,
      (d) => _signed16(d) / 4,
      decimals: 1,
      group: PidGroup.emissions,
    ),
    const PidDef(0x33, 'Barometric pressure', 'Baro', 'kPa', 1, 0, 255, _a, group: PidGroup.air),
    _o2Lambda(0x34, 1, 1),
    _o2Lambda(0x35, 1, 2),
    _o2Lambda(0x36, 1, 3),
    _o2Lambda(0x37, 1, 4),
    _o2Lambda(0x38, 2, 1),
    _o2Lambda(0x39, 2, 2),
    _o2Lambda(0x3A, 2, 3),
    _o2Lambda(0x3B, 2, 4),
    const PidDef(
      0x3C,
      'Catalyst temperature, bank 1 sensor 1',
      'Cat B1S1',
      '°C',
      2,
      -40,
      6513.5,
      _catalystTemp,
      group: PidGroup.temperature,
    ),
    const PidDef(
      0x3D,
      'Catalyst temperature, bank 2 sensor 1',
      'Cat B2S1',
      '°C',
      2,
      -40,
      6513.5,
      _catalystTemp,
      group: PidGroup.temperature,
    ),
    const PidDef(
      0x3E,
      'Catalyst temperature, bank 1 sensor 2',
      'Cat B1S2',
      '°C',
      2,
      -40,
      6513.5,
      _catalystTemp,
      group: PidGroup.temperature,
    ),
    const PidDef(
      0x3F,
      'Catalyst temperature, bank 2 sensor 2',
      'Cat B2S2',
      '°C',
      2,
      -40,
      6513.5,
      _catalystTemp,
      group: PidGroup.temperature,
    ),
    PidDef(
      0x42,
      'Control module voltage',
      'Voltage',
      'V',
      2,
      0,
      65.535,
      (d) => (d[0] * 256 + d[1]) / 1000,
      decimals: 2,
      group: PidGroup.electrical,
    ),
    PidDef(
      0x43,
      'Absolute load value',
      'Abs load',
      '%',
      2,
      0,
      25700,
      (d) => (d[0] * 256 + d[1]) * 100 / 255,
      decimals: 1,
    ),
    const PidDef(
      0x44,
      'Commanded air-fuel ratio (lambda)',
      'Cmd λ',
      'λ',
      2,
      0,
      2,
      _lambda,
      decimals: 3,
      group: PidGroup.fuel,
    ),
    const PidDef(0x45, 'Relative throttle position', 'Rel thr', '%', 1, 0, 100, _percent, group: PidGroup.air),
    const PidDef(0x46, 'Ambient air temperature', 'Ambient', '°C', 1, -40, 215, _temp, group: PidGroup.temperature),
    const PidDef(0x47, 'Absolute throttle position B', 'Thr B', '%', 1, 0, 100, _percent, group: PidGroup.air),
    const PidDef(0x48, 'Absolute throttle position C', 'Thr C', '%', 1, 0, 100, _percent, group: PidGroup.air),
    const PidDef(0x49, 'Accelerator pedal position D', 'Pedal D', '%', 1, 0, 100, _percent, group: PidGroup.air),
    const PidDef(0x4A, 'Accelerator pedal position E', 'Pedal E', '%', 1, 0, 100, _percent, group: PidGroup.air),
    const PidDef(0x4B, 'Accelerator pedal position F', 'Pedal F', '%', 1, 0, 100, _percent, group: PidGroup.air),
    const PidDef(0x4C, 'Commanded throttle actuator', 'Cmd thr', '%', 1, 0, 100, _percent, group: PidGroup.air),
    const PidDef(0x4D, 'Time run with warning light on', 'MIL time', 'min', 2, 0, 65535, _ab, group: PidGroup.trip),
    const PidDef(0x4E, 'Time since codes cleared', 'Clr time', 'min', 2, 0, 65535, _ab, group: PidGroup.trip),
    const PidDef(0x52, 'Ethanol fuel percentage', 'Ethanol', '%', 1, 0, 100, _percent, group: PidGroup.fuel),
    PidDef(
      0x53,
      'Absolute evaporative system vapour pressure',
      'Evap abs',
      'kPa',
      2,
      0,
      327.675,
      (d) => (d[0] * 256 + d[1]) / 200,
      decimals: 2,
      group: PidGroup.emissions,
    ),
    PidDef(
      0x59,
      'Fuel rail absolute pressure',
      'Rail abs',
      'kPa',
      2,
      0,
      655350,
      (d) => (d[0] * 256 + d[1]) * 10.0,
      group: PidGroup.fuel,
    ),
    const PidDef(0x5A, 'Relative accelerator pedal position', 'Pedal', '%', 1, 0, 100, _percent, group: PidGroup.air),
    const PidDef(
      0x5B,
      'Hybrid battery pack remaining life',
      'Hybrid bat',
      '%',
      1,
      0,
      100,
      _percent,
      group: PidGroup.electrical,
    ),
    const PidDef(0x5C, 'Engine oil temperature', 'Oil temp', '°C', 1, -40, 210, _temp, group: PidGroup.temperature),
    PidDef(
      0x5D,
      'Fuel injection timing',
      'Inj timing',
      '°',
      2,
      -210,
      301.99,
      (d) => (d[0] * 256 + d[1]) / 128 - 210,
      decimals: 1,
      group: PidGroup.fuel,
    ),
    PidDef(
      0x5E,
      'Engine fuel rate',
      'Fuel rate',
      'L/h',
      2,
      0,
      3276.75,
      (d) => (d[0] * 256 + d[1]) / 20,
      decimals: 2,
      group: PidGroup.fuel,
    ),
    PidDef(0x61, "Driver's demand engine torque", 'Dmd torque', '%', 1, -125, 130, (d) => d[0] - 125.0),
    PidDef(0x62, 'Actual engine torque', 'Torque', '%', 1, -125, 130, (d) => d[0] - 125.0),
    const PidDef(0x63, 'Engine reference torque', 'Ref torque', 'N·m', 2, 0, 65535, _ab),
    PidDef(0x8E, 'Engine friction torque', 'Friction', '%', 1, -125, 130, (d) => d[0] - 125.0),
    PidDef(
      0xA6,
      'Odometer',
      'Odometer',
      'km',
      4,
      0,
      429496729.5,
      (d) => (d[0] * 16777216 + d[1] * 65536 + d[2] * 256 + d[3]) / 10,
      decimals: 1,
      group: PidGroup.trip,
    ),
  ])
    def.pid: def,
};

/// Sensible gauge ranges, narrower than the protocol's theoretical limits.
const Map<int, (double, double)> gaugeRanges = {
  0x05: (40, 130),
  0x0B: (0, 250),
  0x0C: (0, 7000),
  0x0D: (0, 240),
  0x0E: (-20, 60),
  0x0F: (-20, 80),
  0x10: (0, 250),
  0x06: (-30, 30),
  0x07: (-30, 30),
  0x08: (-30, 30),
  0x09: (-30, 30),
  0x42: (10, 16),
  0x46: (-30, 50),
  0x5C: (40, 160),
  0x5E: (0, 40),
  0x3C: (0, 1000),
  0x3D: (0, 1000),
  0x3E: (0, 1000),
  0x3F: (0, 1000),
};

(double, double) gaugeRange(int pid) {
  final custom = gaugeRanges[pid];
  if (custom != null) return custom;
  final def = pidTable[pid];
  return def == null ? (0, 100) : (def.min, def.max);
}

/// Decodes a service 01 response (`41 pid data [pid data ...]`). Handles
/// several parameters in one message, as allowed on CAN.
Map<int, double> decodeMode01(List<int> data) {
  final values = <int, double>{};
  if (data.isEmpty || data[0] != 0x41) return values;
  var index = 1;
  while (index < data.length) {
    final def = pidTable[data[index]];
    if (def == null || index + 1 + def.bytes > data.length) break;
    values[def.pid] = def.decode(data.sublist(index + 1, index + 1 + def.bytes));
    index += 1 + def.bytes;
  }
  return values;
}

/// Decodes a "supported PIDs" bitmask (PIDs 00, 20, 40, ...).
Set<int> decodeSupportMask(int base, List<int> mask) {
  final supported = <int>{};
  for (var i = 0; i < 32 && i ~/ 8 < mask.length; i++) {
    if (mask[i ~/ 8] & (0x80 >> (i % 8)) != 0) supported.add(base + i + 1);
  }
  return supported;
}

const Map<int, String> fuelSystemStatus = {
  0x01: 'Open loop (engine not warm enough)',
  0x02: 'Closed loop (using oxygen sensor)',
  0x04: 'Open loop (load or deceleration fuel cut)',
  0x08: 'Open loop (system fault)',
  0x10: 'Closed loop (feedback fault)',
};

const Map<int, String> fuelTypes = {
  0x01: 'Gasoline',
  0x02: 'Methanol',
  0x03: 'Ethanol',
  0x04: 'Diesel',
  0x05: 'LPG',
  0x06: 'CNG',
  0x07: 'Propane',
  0x08: 'Electric',
  0x09: 'Bi-fuel gasoline',
  0x0A: 'Bi-fuel methanol',
  0x0B: 'Bi-fuel ethanol',
  0x0C: 'Bi-fuel LPG',
  0x0D: 'Bi-fuel CNG',
  0x0E: 'Bi-fuel propane',
  0x0F: 'Bi-fuel electric',
  0x10: 'Bi-fuel electric and combustion',
  0x11: 'Hybrid gasoline',
  0x12: 'Hybrid ethanol',
  0x13: 'Hybrid diesel',
  0x14: 'Hybrid electric',
  0x15: 'Hybrid electric and combustion',
  0x16: 'Hybrid regenerative',
  0x17: 'Bi-fuel diesel',
};
