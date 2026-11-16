import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../transport.dart';
import 'simulated_vehicle.dart';

/// The bus the simulated car speaks.
enum SimBus {
  can11(6),
  can29(7),
  iso9141(3);

  const SimBus(this.protocolNumber);

  final int protocolNumber;

  bool get isCan => this != iso9141;
}

String _hex(int byte) => byte.toRadixString(16).toUpperCase().padLeft(2, '0');

List<int> _dtcBytes(String code) {
  final letter = 'PCBU'.indexOf(code[0]);
  final first = int.parse(code[1]);
  final rest = int.parse(code.substring(2), radix: 16);
  return [(letter << 6) | (first << 4) | (rest >> 8), rest & 0xFF];
}

List<int> _supportMask(int base, Set<int> pids) {
  final mask = [0, 0, 0, 0];
  for (final pid in pids) {
    final offset = pid - base - 1;
    if (offset < 0 || offset >= 32) continue;
    mask[offset ~/ 8] |= 0x80 >> (offset % 8);
  }
  return mask;
}

/// An ELM327 emulated at the text level, wired to a [SimulatedVehicle]. It
/// reproduces echo, headers, ISO-TP framing, "SEARCHING..." and error strings,
/// so the whole driver stack is exercised exactly as with a real adapter.
class SimulatedAdapter implements ObdTransport {
  SimulatedAdapter({
    SimulatedVehicle? vehicle,
    this.bus = SimBus.can11,
    this.latency = const Duration(milliseconds: 12),
    this.chunkSize = 20,
    this.autoSearchFails = false,
    this.refuseClear = false,
  }) : vehicle = vehicle ?? SimulatedVehicle();

  final SimulatedVehicle vehicle;
  final SimBus bus;

  /// Delay before each reply, like a real adapter waiting on the bus.
  final Duration latency;

  /// Replies arrive in pieces of this many bytes, like Bluetooth LE packets.
  final int chunkSize;

  /// Emulates clone adapters whose automatic protocol search does not work.
  final bool autoSearchFails;

  /// Emulates a vehicle that refuses to clear codes (engine running).
  final bool refuseClear;

  final StreamController<List<int>> _input = StreamController<List<int>>.broadcast();
  final StringBuffer _line = StringBuffer();
  bool _open = false;

  bool _echo = true;
  bool _linefeed = true;
  bool _spaces = true;
  bool _headers = false;
  int _protocol = 0; // 0 = automatic
  bool _searched = false;

  static const Set<int> _enginePids = {
    0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x14, 0x15,
    0x1C, 0x1F, 0x20, 0x21, 0x2F, 0x30, 0x31, 0x33, 0x3C, 0x40, 0x42, 0x43, 0x44, 0x45, 0x46, 0x49,
    0x4C, 0x51, 0x5C, 0x5E, //
  };
  static const Set<int> _transmissionPids = {0x01, 0x0D};
  static const Set<int> _freezePids = {0x02, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x11};

  @override
  String get description => 'Demo car (simulated)';

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> open() async {
    _open = true;
  }

  @override
  Future<void> close() async {
    _open = false;
  }

  /// Drops the link, as when the adapter is unplugged.
  Future<void> unplug() async {
    _open = false;
    unawaited(_input.close());
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (!_open) throw TransportException('Simulated adapter is not open.');
    for (final byte in bytes) {
      if (byte == 0x0D) {
        final command = _line.toString();
        _line.clear();
        _reply(command);
      } else {
        _line.writeCharCode(byte);
      }
    }
  }

  void _reply(String command) {
    final eol = _linefeed ? '\r\n' : '\r';
    final lines = _process(command.replaceAll(' ', '').toUpperCase());
    final text = StringBuffer();
    if (_echoForThisCommand) text.write('$command$eol');
    text.write(lines.join(eol));
    text.write('$eol$eol>');
    final bytes = ascii.encode(text.toString());
    Timer(latency, () {
      if (!_open || _input.isClosed) return;
      for (var i = 0; i < bytes.length; i += chunkSize) {
        _input.add(bytes.sublist(i, math.min(i + chunkSize, bytes.length)));
      }
    });
  }

  bool _echoForThisCommand = true;

  List<String> _process(String command) {
    _echoForThisCommand = _echo;
    if (command.isEmpty) return const ['?'];
    if (command.startsWith('AT')) return _processAt(command.substring(2));
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(command) || command.length.isOdd) return const ['?'];
    return _processObd([for (var i = 0; i < command.length; i += 2) int.parse(command.substring(i, i + 2), radix: 16)]);
  }

  void _resetSettings() {
    _echo = true;
    _linefeed = true;
    _spaces = true;
    _headers = false;
    _protocol = 0;
    _searched = false;
  }

  List<String> _processAt(String at) {
    bool flag(String value) => value.endsWith('1');
    if (at == 'Z' || at == 'WS') {
      _resetSettings();
      return const ['', 'ELM327 v1.5'];
    }
    if (at == 'D') {
      _resetSettings();
      return const ['OK'];
    }
    if (at == 'I') return const ['ELM327 v1.5'];
    if (at == '@1') return const ['OBDII to RS232 Interpreter'];
    if (at == 'RV') return ['${vehicle.voltage.toStringAsFixed(1)}V'];
    if (at == 'DPN') {
      return [(_protocol == 0 && _searched ? 'A' : '') + _activeProtocol.toRadixString(16).toUpperCase()];
    }
    if (at == 'DP') return [_protocol == 0 ? 'AUTO' : 'PROTOCOL $_protocol'];
    if (RegExp(r'^E[01]$').hasMatch(at)) {
      _echo = flag(at);
      return const ['OK'];
    }
    if (RegExp(r'^L[01]$').hasMatch(at)) {
      _linefeed = flag(at);
      return const ['OK'];
    }
    if (RegExp(r'^S[01]$').hasMatch(at)) {
      _spaces = flag(at);
      return const ['OK'];
    }
    if (RegExp(r'^H[01]$').hasMatch(at)) {
      _headers = flag(at);
      return const ['OK'];
    }
    final protocol = RegExp(r'^(?:SP|TP)A?([0-9A-C])$').firstMatch(at);
    if (protocol != null) {
      _protocol = int.parse(protocol.group(1)!, radix: 16);
      _searched = false;
      return const ['OK'];
    }
    if (RegExp(r'^(AT[012]|ST[0-9A-F]{2}|CAF[01]|CFC[01]|M[01]|AL|NL|PC)$').hasMatch(at)) return const ['OK'];
    return const ['?'];
  }

  int get _activeProtocol => _protocol != 0 ? _protocol : (_searched ? bus.protocolNumber : 0);

  List<String> _processObd(List<int> request) {
    final prefix = <String>[];
    if (_protocol == 0) {
      if (!_searched) {
        prefix.add('SEARCHING...');
        if (!vehicle.ignitionOn || autoSearchFails) return [...prefix, 'UNABLE TO CONNECT'];
        _searched = true;
      }
    } else if (_protocol != bus.protocolNumber) {
      return [if (_protocol >= 6) 'CAN ERROR' else 'BUS INIT: ...ERROR'];
    }
    if (!vehicle.ignitionOn) return const ['NO DATA'];

    final lines = <String>[...prefix];
    for (var ecu = 0; ecu < 2; ecu++) {
      final payload = _answer(ecu, request);
      if (payload != null) lines.addAll(_format(ecu, payload));
    }
    if (lines.length == prefix.length) lines.add('NO DATA');
    return lines;
  }

  // ---------------------------------------------------------------------------
  // Diagnostic services

  /// The payload ECU [ecu] (0 = engine, 1 = transmission) answers with, or
  /// null when it stays silent.
  List<int>? _answer(int ecu, List<int> request) {
    final service = request[0];
    final engine = ecu == 0;
    switch (service) {
      case 0x01:
        final supported = engine ? _enginePids : _transmissionPids;
        final pids = bus.isCan ? request.skip(1).take(6) : request.skip(1).take(1);
        final payload = <int>[0x41];
        for (final pid in pids) {
          final data = _mode01(ecu, pid, supported);
          if (data != null) payload.addAll([pid, ...data]);
        }
        return payload.length > 1 ? payload : null;
      case 0x02:
        if (!engine || request.length < 2) return null;
        return _freezeFrame(request[1]);
      case 0x03:
        return _dtcPayload(0x43, engine ? vehicle.storedCodes : const []);
      case 0x07:
        return _dtcPayload(0x47, engine ? vehicle.pendingCodes : const []);
      case 0x0A:
        if (!bus.isCan) return null;
        return _dtcPayload(0x4A, engine ? vehicle.permanentCodes : const []);
      case 0x04:
        if (refuseClear) return engine ? [0x7F, 0x04, 0x22] : null;
        if (engine) vehicle.clearCodes();
        return [0x44];
      case 0x09:
        if (!engine || request.length < 2) return null;
        if (request[1] == 0x00) return [0x49, 0x00, 0x40, 0x00, 0x00, 0x00];
        if (request[1] == 0x02) return [0x49, 0x02, if (bus.isCan) 0x01, ...ascii.encode(vehicle.vin)];
        return null;
      default:
        return null;
    }
  }

  List<int> _dtcPayload(int service, List<String> codes) {
    final bytes = [for (final code in codes) ..._dtcBytes(code)];
    return [service, if (bus.isCan) codes.length, ...bytes];
  }

  List<int>? _freezeFrame(int pid) {
    if (vehicle.storedCodes.isEmpty) {
      return pid == 0x02 ? [0x42, 0x02, 0x00, 0x00, 0x00] : null;
    }
    const snapshot = <int, List<int>>{
      0x04: [0x8C], // load 54.9 %
      0x05: [0x82], // coolant 90 °C
      0x06: [0x85], // STFT +3.9 %
      0x07: [0x8A], // LTFT +7.8 %
      0x0B: [0x3E], // MAP 62 kPa
      0x0C: [0x25, 0x80], // 2400 rpm
      0x0D: [0x58], // 88 km/h
      0x0E: [0xB4], // timing 26 °
      0x0F: [0x46], // intake 30 °C
      0x11: [0x59], // throttle 34.9 %
    };
    if (pid == 0x00) return [0x42, 0x00, 0x00, ..._supportMask(0x00, _freezePids)];
    if (pid == 0x02) return [0x42, 0x02, 0x00, ..._dtcBytes(vehicle.storedCodes.first)];
    final data = snapshot[pid];
    return data == null ? null : [0x42, pid, 0x00, ...data];
  }

  static int _clampByte(double value) => value.round().clamp(0, 255);

  static List<int> _word(double value) {
    final raw = value.round().clamp(0, 65535);
    return [raw >> 8, raw & 0xFF];
  }

  static int _percentByte(double percent) => _clampByte(percent * 255 / 100);

  static int _trimByte(double percent) => _clampByte(percent * 128 / 100 + 128);

  List<int>? _mode01(int ecu, int pid, Set<int> supported) {
    if (pid % 0x20 == 0) {
      // "Supported PIDs" requests are always answered by an ECU that has
      // anything to report in or beyond that range.
      final hasAny = supported.any((p) => p > pid);
      return hasAny ? _supportMask(pid, supported) : null;
    }
    if (!supported.contains(pid)) return null;
    final v = vehicle;
    if (ecu == 1) {
      return switch (pid) {
        0x01 => const [0x00, 0x00, 0x00, 0x00],
        0x0D => [_clampByte(v.speed)],
        _ => null,
      };
    }
    return switch (pid) {
      0x01 => [
        (v.milOn ? 0x80 : 0) | v.storedCodes.length,
        v.monitorsReset ? 0x77 : 0x07,
        0x65,
        v.monitorsReset ? 0x65 : 0x04,
      ],
      0x03 => [v.closedLoop ? 0x02 : 0x01, 0x00],
      0x04 => [_percentByte(v.load)],
      0x05 => [_clampByte(v.coolantTemp + 40)],
      0x06 => [_trimByte(v.shortTermTrim)],
      0x07 => [_trimByte(v.longTermTrim)],
      0x0B => [_clampByte(v.manifoldPressure)],
      0x0C => _word(v.rpm * 4),
      0x0D => [_clampByte(v.speed)],
      0x0E => [_clampByte((v.timingAdvance + 64) * 2)],
      0x0F => [_clampByte(v.intakeTemp + 40)],
      0x10 => _word(v.massAirFlow * 100),
      0x11 => [_percentByte(v.throttle)],
      0x13 => const [0x03],
      0x14 => [_clampByte(v.upstreamO2 * 200), _trimByte(v.shortTermTrim)],
      0x15 => [_clampByte(v.downstreamO2 * 200), 0xFF],
      0x1C => const [0x01],
      0x1F => _word(v.runTime.toDouble()),
      0x21 => _word(v.milOn ? 120 : 0),
      0x2F => [_percentByte(v.fuelLevel)],
      0x30 => [v.monitorsReset ? 0 : 87],
      0x31 => _word(v.monitorsReset ? 0 : 1432),
      0x33 => const [101],
      0x3C => _word((v.catalystTemp + 40) * 10),
      0x42 => _word(v.voltage * 1000),
      0x43 => _word(v.load * 0.9 * 255 / 100),
      0x44 => _word(32768),
      0x45 => [_percentByte(v.throttle - 12)],
      0x46 => const [58],
      0x49 => [_percentByte(v.throttle)],
      0x4C => [_percentByte(v.throttle)],
      0x51 => const [0x01],
      0x5C => [_clampByte(v.oilTemp + 40)],
      0x5E => _word(v.fuelRate * 20),
      _ => null,
    };
  }

  // ---------------------------------------------------------------------------
  // Bus framing

  String _join(Iterable<int> bytes) => bytes.map(_hex).join(_spaces ? ' ' : '');

  List<String> _format(int ecu, List<int> payload) =>
      bus.isCan ? _formatCan(ecu, payload) : _formatLegacy(ecu, payload);

  List<String> _formatCan(int ecu, List<int> payload) {
    final id = bus == SimBus.can11 ? (ecu == 0 ? '7E8' : '7E9') : (ecu == 0 ? '18DAF110' : '18DAF118');
    final padding = ecu == 0 ? 0xAA : 0x00;
    final frames = <List<int>>[];
    if (payload.length <= 7) {
      frames.add([payload.length, ...payload]);
    } else {
      frames.add([0x10 | (payload.length >> 8), payload.length & 0xFF, ...payload.take(6)]);
      var sequence = 1;
      for (var i = 6; i < payload.length; i += 7) {
        frames.add([0x20 | (sequence & 0x0F), ...payload.sublist(i, math.min(i + 7, payload.length))]);
        sequence++;
      }
    }
    for (final frame in frames) {
      while (frame.length < 8) {
        frame.add(padding);
      }
    }
    if (_headers) {
      final header = _spaces && bus == SimBus.can29
          ? [for (var i = 0; i < 8; i += 2) id.substring(i, i + 2)].join(' ')
          : id;
      return [for (final frame in frames) '$header${_spaces ? ' ' : ''}${_join(frame)}'];
    }
    if (frames.length == 1) return [_join(payload)];
    return [
      payload.length.toRadixString(16).toUpperCase().padLeft(3, '0'),
      for (var i = 0; i < frames.length; i++)
        '${(i & 0x0F).toRadixString(16).toUpperCase()}: ${_join(frames[i].skip(i == 0 ? 2 : 1))}',
    ];
  }

  List<String> _formatLegacy(int ecu, List<int> payload) {
    final source = ecu == 0 ? 0x10 : 0x18;
    final service = payload[0];
    final messages = <List<int>>[];
    if (service == 0x43 || service == 0x47) {
      final codes = payload.sublist(1);
      if (codes.isEmpty) messages.add([service, 0, 0, 0, 0, 0, 0]);
      for (var i = 0; i < codes.length; i += 6) {
        final chunk = codes.sublist(i, math.min(i + 6, codes.length));
        messages.add([service, ...chunk, ...List.filled(6 - chunk.length, 0)]);
      }
    } else if (service == 0x49 && payload[1] == 0x02) {
      final vin = [0, 0, 0, ...payload.sublist(2)];
      for (var i = 0; i < vin.length; i += 4) {
        messages.add([0x49, 0x02, i ~/ 4 + 1, ...vin.sublist(i, math.min(i + 4, vin.length))]);
      }
    } else {
      messages.add(payload);
    }
    return [
      for (final message in messages)
        if (_headers)
          _join(() {
            final frame = [0x48, 0x6B, source, ...message];
            return [...frame, frame.fold<int>(0, (sum, byte) => sum + byte) & 0xFF];
          }())
        else
          _join(message),
    ];
  }
}
