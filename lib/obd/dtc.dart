/// Diagnostic trouble code decoding and readiness monitor status.
library;

enum DtcKind {
  stored('Confirmed'),
  pending('Pending'),
  permanent('Permanent');

  const DtcKind(this.label);

  final String label;
}

class DtcEntry {
  const DtcEntry(this.code, this.kind, this.ecu);

  final String code;
  final DtcKind kind;
  final int ecu;

  @override
  bool operator ==(Object other) => other is DtcEntry && other.code == code && other.kind == kind && other.ecu == ecu;

  @override
  int get hashCode => Object.hash(code, kind, ecu);
}

/// Two bytes to a code such as P0420: the top two bits select the system
/// letter, the next two the first digit, the remaining 12 bits three hex digits.
String dtcFromBytes(int high, int low) {
  const letters = ['P', 'C', 'B', 'U'];
  final letter = letters[(high >> 6) & 0x03];
  final first = (high >> 4) & 0x03;
  final rest = ((high & 0x0F) << 8) | low;
  return '$letter$first${rest.toRadixString(16).toUpperCase().padLeft(3, '0')}';
}

/// Decodes a service 03 / 07 / 0A response. On CAN the service id is followed
/// by a count byte; on the older buses the codes follow directly.
List<String> decodeDtcPayload(List<int> data, {required bool isCan}) {
  if (data.isEmpty) return const [];
  var start = 1;
  var end = data.length;
  if (isCan) {
    if (data.length < 2) return const [];
    start = 2;
    final declared = 2 + data[1] * 2;
    if (declared < end) end = declared;
  }
  final codes = <String>[];
  for (var i = start; i + 1 < end; i += 2) {
    if (data[i] == 0 && data[i + 1] == 0) continue; // padding
    final code = dtcFromBytes(data[i], data[i + 1]);
    if (!codes.contains(code)) codes.add(code);
  }
  return codes;
}

class MonitorTest {
  const MonitorTest(this.name, {required this.available, required this.complete});

  final String name;
  final bool available;
  final bool complete;
}

/// Service 01 PID 01: warning light state and emission readiness monitors.
class MonitorStatus {
  const MonitorStatus({
    required this.milOn,
    required this.dtcCount,
    required this.compressionIgnition,
    required this.tests,
  });

  final bool milOn;
  final int dtcCount;

  /// True for diesel engines, which use a different monitor set.
  final bool compressionIgnition;
  final List<MonitorTest> tests;

  Iterable<MonitorTest> get availableTests => tests.where((test) => test.available);

  bool get allComplete => availableTests.every((test) => test.complete);

  static const _spark = [
    'Catalyst',
    'Heated catalyst',
    'Evaporative system',
    'Secondary air system',
    'A/C refrigerant',
    'Oxygen sensor',
    'Oxygen sensor heater',
    'EGR / VVT system',
  ];

  static const _compression = [
    'NMHC catalyst',
    'NOx / SCR aftertreatment',
    null,
    'Boost pressure',
    null,
    'Exhaust gas sensor',
    'Particulate filter',
    'EGR / VVT system',
  ];

  /// [data] is the four data bytes A..D that follow `41 01`.
  static MonitorStatus? decode(List<int> data) {
    if (data.length < 4) return null;
    final a = data[0], b = data[1], c = data[2], d = data[3];
    final compression = b & 0x08 != 0;
    final tests = <MonitorTest>[
      MonitorTest('Misfire', available: b & 0x01 != 0, complete: b & 0x10 == 0),
      MonitorTest('Fuel system', available: b & 0x02 != 0, complete: b & 0x20 == 0),
      MonitorTest('Comprehensive components', available: b & 0x04 != 0, complete: b & 0x40 == 0),
    ];
    final names = compression ? _compression : _spark;
    for (var bit = 0; bit < 8; bit++) {
      final name = names[bit];
      if (name == null) continue;
      tests.add(MonitorTest(name, available: c & (1 << bit) != 0, complete: d & (1 << bit) == 0));
    }
    return MonitorStatus(milOn: a & 0x80 != 0, dtcCount: a & 0x7F, compressionIgnition: compression, tests: tests);
  }
}

/// Describes what a code's structure says about it, for codes that are not in
/// the bundled database (typically manufacturer-specific ones).
String describeDtcStructure(String code) {
  if (code.length != 5) return 'Unknown code';
  final system = switch (code[0]) {
    'P' => 'Powertrain',
    'C' => 'Chassis',
    'B' => 'Body',
    'U' => 'Network',
    _ => 'Unknown',
  };
  // Generic ranges per SAE J2012: x0xxx, P2xxx, P3400-P3FFF and U3xxx.
  final upperP3 = code[0] == 'P' && code[1] == '3' && (int.tryParse(code[2], radix: 16) ?? 0) >= 4;
  final generic = code[1] == '0' || (code[0] == 'P' && code[1] == '2') || upperP3 || (code[0] == 'U' && code[1] == '3');
  final scope = generic ? 'generic' : 'manufacturer-specific';
  var area = '';
  if (code[0] == 'P' && (code[1] == '0' || code[1] == '2')) {
    area = switch (code[2]) {
      '0' || '1' || '2' => ', fuel and air metering',
      '3' => ', ignition system or misfire',
      '4' => ', auxiliary emission controls',
      '5' => ', speed control and idle',
      '6' => ', computer and output circuits',
      '7' || '8' || '9' => ', transmission',
      'A' || 'B' || 'C' => ', hybrid propulsion',
      _ => '',
    };
  }
  return '$system code ($scope)$area';
}
