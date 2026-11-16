import 'protocol.dart';

/// One complete diagnostic message from one ECU. [data] starts with the
/// response service id (request service + 0x40), for example 0x41.
class EcuResponse {
  EcuResponse(this.ecu, this.data);

  /// CAN identifier (0x7E8, 0x18DAF110) or the source address on older buses.
  final int ecu;
  final List<int> data;

  @override
  String toString() =>
      '${ecu.toRadixString(16).toUpperCase()}: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}';
}

final RegExp _hexOnly = RegExp(r'^[0-9A-Fa-f]+$');

List<int>? _hexToBytes(String hex) {
  if (hex.length.isOdd || !_hexOnly.hasMatch(hex)) return null;
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

/// Turns the adapter's reply lines (headers on) into complete per-ECU messages,
/// reassembling ISO-TP multi-frame messages on CAN and sequence-numbered
/// messages on the older buses.
List<EcuResponse> parseResponses(List<String> lines, ObdProtocol protocol) {
  final cleaned = [for (final line in lines) line.replaceAll(RegExp(r'\s'), '')]
      .where((line) => line.isNotEmpty && _hexOnly.hasMatch(line))
      .toList();
  return protocol.isCan ? _parseCan(cleaned, protocol) : _parseLegacy(cleaned);
}

class _Assembly {
  _Assembly(this.expected, this.data);

  final int expected;
  final List<int> data;
  int nextSequence = 1;
  bool broken = false;
}

List<EcuResponse> _parseCan(List<String> lines, ObdProtocol protocol) {
  final responses = <EcuResponse>[];
  final assemblies = <int, _Assembly>{};

  for (final line in lines) {
    // 11-bit identifiers print as 3 hex digits, 29-bit ones as 8. A line of
    // whole bytes on an "11-bit" protocol means the adapter printed 29 bits.
    final idLength = (protocol.is29Bit || line.length.isEven) ? 8 : 3;
    if (line.length < idLength + 2) continue;
    final id = int.parse(line.substring(0, idLength), radix: 16);
    final bytes = _hexToBytes(line.substring(idLength));
    if (bytes == null || bytes.isEmpty) continue;

    final frameType = bytes[0] >> 4;
    switch (frameType) {
      case 0x0: // single frame
        final length = bytes[0] & 0x0F;
        if (length == 0 || length > bytes.length - 1) continue;
        responses.add(EcuResponse(id, bytes.sublist(1, 1 + length)));
      case 0x1: // first frame of a multi-frame message
        if (bytes.length < 3) continue;
        final total = ((bytes[0] & 0x0F) << 8) | bytes[1];
        assemblies[id] = _Assembly(total, bytes.sublist(2));
      case 0x2: // consecutive frame
        final assembly = assemblies[id];
        if (assembly == null) continue;
        if ((bytes[0] & 0x0F) != (assembly.nextSequence & 0x0F)) {
          assembly.broken = true;
          continue;
        }
        assembly.nextSequence++;
        assembly.data.addAll(bytes.sublist(1));
      default: // flow control and reserved frame types carry no data
        continue;
    }
  }

  assemblies.forEach((id, assembly) {
    if (assembly.broken || assembly.data.length < assembly.expected) return;
    responses.add(EcuResponse(id, assembly.data.sublist(0, assembly.expected)));
  });
  return responses;
}

/// J1850, ISO 9141-2 and KWP2000: three header bytes, data, one checksum byte.
List<EcuResponse> _parseLegacy(List<String> lines) {
  final framesBySource = <int, List<List<int>>>{};
  for (final line in lines) {
    final bytes = _hexToBytes(line);
    if (bytes == null || bytes.length < 5) continue;
    final source = bytes[2];
    framesBySource.putIfAbsent(source, () => []).add(bytes.sublist(3, bytes.length - 1));
  }

  final responses = <EcuResponse>[];
  framesBySource.forEach((source, frames) {
    if (frames.length == 1) {
      responses.add(EcuResponse(source, frames.first));
      return;
    }
    final service = frames.first[0];
    final sameService = frames.every((frame) => frame[0] == service);
    if (sameService && (service == 0x43 || service == 0x47 || service == 0x4A)) {
      // Trouble codes: every message repeats the service id, then three codes.
      final data = <int>[service];
      for (final frame in frames) {
        data.addAll(frame.sublist(1));
      }
      responses.add(EcuResponse(source, data));
    } else if (sameService && service == 0x49 && frames.every((frame) => frame.length >= 3)) {
      // Vehicle information: service, info type, message number, payload.
      final ordered = [...frames]..sort((a, b) => a[2].compareTo(b[2]));
      final data = <int>[service, ordered.first[1]];
      for (final frame in ordered) {
        data.addAll(frame.sublist(3));
      }
      responses.add(EcuResponse(source, data));
    } else {
      for (final frame in frames) {
        responses.add(EcuResponse(source, frame));
      }
    }
  });
  return responses;
}
