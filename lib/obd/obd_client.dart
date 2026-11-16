import 'dart:math' as math;

import 'dtc.dart';
import 'elm327.dart';
import 'frames.dart';
import 'pids.dart';
import 'protocol.dart';
import 'vin.dart';

class ObdException implements Exception {
  ObdException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DtcReport {
  const DtcReport({required this.entries, required this.status, required this.permanentSupported});

  final List<DtcEntry> entries;

  /// Warning light state and code count as reported by the ECU, if readable.
  final MonitorStatus? status;

  /// Permanent codes (service 0A) only exist on vehicles from around 2010.
  final bool permanentSupported;

  List<DtcEntry> ofKind(DtcKind kind) => entries.where((entry) => entry.kind == kind).toList();

  Set<String> get codes => entries.map((entry) => entry.code).toSet();
}

class FreezeFrame {
  const FreezeFrame({required this.triggerCode, required this.values});

  /// The code that caused the snapshot to be stored.
  final String triggerCode;
  final Map<int, double> values;
}

class ClearResult {
  const ClearResult(this.success, [this.reason]);

  final bool success;
  final String? reason;
}

String _hex2(int value) => value.toRadixString(16).toUpperCase().padLeft(2, '0');

/// High-level OBD-II services on top of an [Elm327]: connection and protocol
/// detection, live data, trouble codes, readiness and vehicle information.
class ObdClient {
  ObdClient(this.elm);

  final Elm327 elm;

  ObdProtocol protocol = ObdProtocol.auto;

  /// Parameters each responding ECU supports, keyed by ECU address.
  final Map<int, Set<int>> supportedByEcu = {};

  /// The ECU that reports the most parameters; in practice the engine ECU.
  int? primaryEcu;

  String? vin;

  /// True once the vehicle has proven it answers several PIDs in one request.
  bool batching = false;

  Set<int> get supportedPids => supportedByEcu.values.expand((pids) => pids).toSet();

  /// Supported parameters the app knows how to decode, in PID order.
  List<int> get readablePids => supportedPids.where(pidTable.containsKey).toList()..sort();

  List<int> get ecus => supportedByEcu.keys.toList()..sort();

  /// Initialises the adapter, finds the vehicle's protocol and reads what the
  /// vehicle supports. [onProgress] receives short status messages.
  Future<void> connect({void Function(String message)? onProgress}) async {
    onProgress?.call('Initialising adapter');
    await elm.open();
    await elm.initialize();

    onProgress?.call('Detecting vehicle protocol');
    protocol = await _detectProtocol(onProgress);

    onProgress?.call('Reading supported sensors');
    await _discoverSupportedPids();
    if (supportedByEcu.isEmpty) {
      throw ObdException('The vehicle answered but reported no supported sensors.');
    }
    await _probeBatching();

    onProgress?.call('Identifying vehicle');
    vin = await readVin();
  }

  Future<void> disconnect() => elm.close();

  static bool _looksLikeObdData(ElmReply reply) =>
      reply.lines.any((line) => line.replaceAll(' ', '').toUpperCase().contains('4100'));

  Future<ObdProtocol> _detectProtocol(void Function(String message)? onProgress) async {
    // Automatic search first; it can take several seconds on slow-init buses.
    try {
      final reply = await elm.send('0100', timeout: const Duration(seconds: 20));
      if (_looksLikeObdData(reply)) {
        final found = await elm.describeProtocol();
        if (found != null && found != ObdProtocol.auto) return found;
      }
    } on ElmException catch (error) {
      if (error.kind == ElmErrorKind.disconnected) rethrow;
    }

    // Some clone adapters fail the automatic search but work when each
    // protocol is tried in turn.
    for (final number in const [0x6, 0x8, 0x7, 0x9, 0x5, 0x4, 0x3, 0x2, 0x1]) {
      final candidate = ObdProtocol.fromNumber(number)!;
      onProgress?.call('Trying ${candidate.label}');
      try {
        final set = await elm.send('ATTP${number.toRadixString(16).toUpperCase()}');
        if (!set.isOk) continue;
        final reply = await elm.send('0100', timeout: const Duration(seconds: 12));
        if (_looksLikeObdData(reply)) return candidate;
      } on ElmException catch (error) {
        if (error.kind == ElmErrorKind.disconnected) rethrow;
      }
    }
    throw ObdException(
      'The adapter is working but the vehicle did not answer. Check that the ignition is on '
      'and the adapter is fully seated in the OBD port.',
    );
  }

  /// Sends a request and returns the positive responses for it.
  Future<List<EcuResponse>> request(String command, {Duration? timeout}) async {
    final all = await _requestAll(command, timeout: timeout);
    final expected = int.parse(command.substring(0, 2), radix: 16) + 0x40;
    return all.where((response) => response.data.isNotEmpty && response.data[0] == expected).toList();
  }

  Future<List<EcuResponse>> _requestAll(String command, {Duration? timeout}) async {
    final reply = await elm.send(command, timeout: timeout);
    switch (reply.error) {
      case ElmErrorKind.unableToConnect ||
          ElmErrorKind.busInitError ||
          ElmErrorKind.canError ||
          ElmErrorKind.busError ||
          ElmErrorKind.busBusy ||
          ElmErrorKind.feedbackError ||
          ElmErrorKind.lowVoltageReset:
        throw ElmException(reply.error!, 'Lost communication with the vehicle (${reply.error!.name}).');
      default:
        break;
    }
    return parseResponses(reply.lines, protocol);
  }

  Future<void> _discoverSupportedPids() async {
    supportedByEcu.clear();
    for (final base in const [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0]) {
      final responses = await request('01${_hex2(base)}');
      var more = false;
      for (final response in responses) {
        final data = response.data;
        if (data.length < 6 || data[1] != base) continue;
        final found = decodeSupportMask(base, data.sublist(2, 6));
        supportedByEcu.putIfAbsent(response.ecu, () => <int>{}).addAll(found);
        if (found.contains(base + 0x20)) more = true;
      }
      if (!more) break;
    }
    primaryEcu = null;
    var best = -1;
    for (final ecu in ecus) {
      final count = supportedByEcu[ecu]!.length;
      if (count > best) {
        best = count;
        primaryEcu = ecu;
      }
    }
  }

  /// CAN vehicles may answer up to six PIDs per request, which multiplies the
  /// refresh rate. Verified with a real two-PID request before being relied on.
  Future<void> _probeBatching() async {
    batching = false;
    if (!protocol.isCan) return;
    final candidates = readablePids.where((pid) => supportedByEcu[primaryEcu]?.contains(pid) ?? false).take(2).toList();
    if (candidates.length < 2) return;
    try {
      final responses = await request('01${candidates.map(_hex2).join()}');
      batching = responses.any((response) {
        final values = decodeMode01(response.data);
        return candidates.every(values.containsKey);
      });
    } on ElmException {
      batching = false;
    }
  }

  /// Reads live values. Unsupported or unanswered parameters are simply absent.
  Future<Map<int, double>> readPids(List<int> pids) async {
    final wanted = pids.where(pidTable.containsKey).toList();
    final result = <int, double>{};
    final chunkSize = batching ? 6 : 1;
    for (var i = 0; i < wanted.length; i += chunkSize) {
      final chunk = wanted.sublist(i, math.min(i + chunkSize, wanted.length));
      final responses = await request('01${chunk.map(_hex2).join()}');
      // Prefer the engine ECU when several modules report the same parameter.
      responses.sort((a, b) => (a.ecu == primaryEcu ? 0 : 1).compareTo(b.ecu == primaryEcu ? 0 : 1));
      for (final response in responses) {
        decodeMode01(response.data).forEach((pid, value) {
          if (chunk.contains(pid)) result.putIfAbsent(pid, () => value);
        });
      }
    }
    return result;
  }

  Future<double?> readPid(int pid) async => (await readPids([pid]))[pid];

  /// Warning light state, stored code count and readiness monitors.
  Future<MonitorStatus?> readMonitorStatus() async {
    final responses = await request('0101');
    MonitorStatus? merged;
    for (final response in responses) {
      if (response.data.length < 6 || response.data[1] != 0x01) continue;
      final status = MonitorStatus.decode(response.data.sublist(2, 6));
      if (status == null) continue;
      if (merged == null) {
        merged = status;
      } else {
        // Keep the engine ECU's monitor list but combine the warning state.
        final base = response.ecu == primaryEcu ? status : merged;
        merged = MonitorStatus(
          milOn: merged.milOn || status.milOn,
          dtcCount: merged.dtcCount + status.dtcCount,
          compressionIgnition: base.compressionIgnition,
          tests: base.tests,
        );
      }
    }
    return merged;
  }

  Future<List<DtcEntry>?> _readDtcService(String service, DtcKind kind) async {
    final responses = await request(service, timeout: const Duration(seconds: 10));
    if (responses.isEmpty) return null;
    final entries = <DtcEntry>[];
    for (final response in responses) {
      for (final code in decodeDtcPayload(response.data, isCan: protocol.isCan)) {
        entries.add(DtcEntry(code, kind, response.ecu));
      }
    }
    return entries;
  }

  /// Reads confirmed, pending and permanent trouble codes from every ECU.
  Future<DtcReport> readDtcs() async {
    final status = await readMonitorStatus();
    final stored = await _readDtcService('03', DtcKind.stored);
    final pending = await _readDtcService('07', DtcKind.pending);
    List<DtcEntry>? permanent;
    if (protocol.isCan) {
      permanent = await _readDtcService('0A', DtcKind.permanent);
    }
    return DtcReport(
      entries: [...?stored, ...?pending, ...?permanent],
      status: status,
      permanentSupported: permanent != null,
    );
  }

  /// Clears trouble codes, freeze frame data and readiness results.
  Future<ClearResult> clearDtcs() async {
    final responses = await _requestAll('04', timeout: const Duration(seconds: 10));
    if (responses.any((response) => response.data.isNotEmpty && response.data[0] == 0x44)) {
      return const ClearResult(true);
    }
    for (final response in responses) {
      final data = response.data;
      if (data.length >= 3 && data[0] == 0x7F && data[1] == 0x04) {
        return ClearResult(
          false,
          data[2] == 0x22
              ? 'The vehicle refused: conditions not correct. Switch the ignition on with the engine off and try again.'
              : 'The vehicle refused the request (code 0x${_hex2(data[2])}).',
        );
      }
    }
    return const ClearResult(false, 'The vehicle did not confirm the request.');
  }

  /// The snapshot of sensor values stored when a fault was first detected.
  Future<FreezeFrame?> readFreezeFrame() async {
    final trigger = await request('020200');
    String? code;
    for (final response in trigger) {
      final data = response.data;
      if (data.length >= 5 && data[1] == 0x02 && (data[3] != 0 || data[4] != 0)) {
        code = dtcFromBytes(data[3], data[4]);
        break;
      }
    }
    if (code == null) return null;

    var supported = <int>{};
    for (final response in await request('020000')) {
      final data = response.data;
      if (data.length >= 7 && data[1] == 0x00) {
        supported = decodeSupportMask(0x00, data.sublist(3, 7));
        break;
      }
    }
    final values = <int, double>{};
    for (final pid in supported.where((pid) => pid != 0x02 && pidTable.containsKey(pid)).toList()..sort()) {
      for (final response in await request('02${_hex2(pid)}00')) {
        final data = response.data;
        final def = pidTable[pid]!;
        if (data.length >= 3 + def.bytes && data[1] == pid) {
          values[pid] = def.decode(data.sublist(3, 3 + def.bytes));
          break;
        }
      }
    }
    return FreezeFrame(triggerCode: code, values: values);
  }

  /// Reads the VIN from the vehicle (service 09 PID 02). Null on older
  /// vehicles that do not report it.
  Future<String?> readVin() async {
    try {
      final responses = await request('0902', timeout: const Duration(seconds: 10));
      for (final response in responses) {
        final found = extractVin(response.data);
        if (found != null) return found;
      }
    } on ElmException catch (error) {
      if (error.kind == ElmErrorKind.disconnected) rethrow;
    }
    return null;
  }

  /// Fuel type (service 01 PID 51), if reported.
  Future<String?> readFuelType() async {
    if (!supportedPids.contains(0x51)) return null;
    for (final response in await request('0151')) {
      if (response.data.length >= 3 && response.data[1] == 0x51) return fuelTypes[response.data[2]];
    }
    return null;
  }
}
