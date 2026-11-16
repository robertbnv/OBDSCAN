import 'package:flutter_test/flutter_test.dart';
import 'package:obdscan/obd/dtc.dart';
import 'package:obdscan/obd/elm327.dart';
import 'package:obdscan/obd/frames.dart';
import 'package:obdscan/obd/obd_client.dart';
import 'package:obdscan/obd/pids.dart';
import 'package:obdscan/obd/protocol.dart';
import 'package:obdscan/obd/sim/simulated_adapter.dart';
import 'package:obdscan/obd/sim/simulated_vehicle.dart';
import 'package:obdscan/obd/vin.dart';

void main() {
  group('ElmReply.parse', () {
    test('drops the echo and keeps payload lines', () {
      final reply = ElmReply.parse('ATE0', 'ATE0\rOK\r\r');
      expect(reply.lines, ['OK']);
      expect(reply.isOk, isTrue);
      expect(reply.error, isNull);
    });

    test('drops SEARCHING and handles CR LF line ends', () {
      final reply = ElmReply.parse('0100', 'SEARCHING...\r\n7E8 06 41 00 BE 3F A8 13\r\n\r\n');
      expect(reply.lines, ['7E8 06 41 00 BE 3F A8 13']);
      expect(reply.error, isNull);
    });

    test('classifies adapter errors', () {
      expect(ElmReply.parse('0100', 'NO DATA\r').error, ElmErrorKind.noData);
      expect(ElmReply.parse('0100', 'SEARCHING...\rUNABLE TO CONNECT\r').error, ElmErrorKind.unableToConnect);
      expect(ElmReply.parse('0100', 'BUS INIT: ...ERROR\r').error, ElmErrorKind.busInitError);
      expect(ElmReply.parse('0100', 'BUS INIT: OK\r41 00 BE 3F A8 13\r').error, isNull);
      expect(ElmReply.parse('0100', 'CAN ERROR\r').error, ElmErrorKind.canError);
      expect(ElmReply.parse('ATXYZ', '?\r').error, ElmErrorKind.unknownCommand);
      expect(ElmReply.parse('0100', '7E8 06 41 00 <DATA ERROR\r').lines, isEmpty);
    });
  });

  group('ObdProtocol', () {
    test('parses ATDPN replies', () {
      expect(ObdProtocol.fromDescribeReply('A6'), ObdProtocol.can11Bit500);
      expect(ObdProtocol.fromDescribeReply('6'), ObdProtocol.can11Bit500);
      expect(ObdProtocol.fromDescribeReply('A3'), ObdProtocol.iso9141);
      expect(ObdProtocol.fromDescribeReply('A'), ObdProtocol.j1939);
      expect(ObdProtocol.fromDescribeReply('AA'), ObdProtocol.j1939);
      expect(ObdProtocol.fromDescribeReply('0'), ObdProtocol.auto);
    });
  });

  group('parseResponses', () {
    test('CAN 11-bit single frame honours the length byte and ignores padding', () {
      final responses = parseResponses(['7E8 04 41 0C 1A F8 AA AA AA'], ObdProtocol.can11Bit500);
      expect(responses, hasLength(1));
      expect(responses.single.ecu, 0x7E8);
      expect(responses.single.data, [0x41, 0x0C, 0x1A, 0xF8]);
    });

    test('CAN multi-frame VIN from two interleaved ECUs', () {
      final responses = parseResponses([
        '7E8 10 14 49 02 01 31 48 47',
        '7E9 03 7F 09 11 00 00 00 00',
        '7E8 21 43 4D 38 32 36 33 33',
        '7E8 22 41 30 30 34 33 35 32',
      ], ObdProtocol.can11Bit500);
      final vinResponse = responses.firstWhere((r) => r.ecu == 0x7E8);
      expect(vinResponse.data.length, 0x14);
      expect(extractVin(vinResponse.data), '1HGCM82633A004352');
      expect(responses.firstWhere((r) => r.ecu == 0x7E9).data, [0x7F, 0x09, 0x11]);
    });

    test('CAN multi-frame with a missing frame is discarded', () {
      final responses = parseResponses([
        '7E8 10 14 49 02 01 31 48 47',
        '7E8 22 41 30 30 34 33 35 32',
      ], ObdProtocol.can11Bit500);
      expect(responses, isEmpty);
    });

    test('CAN 29-bit without spaces', () {
      final responses = parseResponses(['18DAF110064100BE3FA813'], ObdProtocol.can29Bit500);
      expect(responses.single.ecu, 0x18DAF110);
      expect(responses.single.data, [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13]);
    });

    test('legacy bus strips header and checksum', () {
      final responses = parseResponses(['48 6B 10 41 0C 1A F8 0A'], ObdProtocol.iso9141);
      expect(responses.single.ecu, 0x10);
      expect(responses.single.data, [0x41, 0x0C, 0x1A, 0xF8]);
    });

    test('legacy VIN arrives as five numbered messages', () {
      final responses = parseResponses([
        '48 6B 10 49 02 02 48 47 43 4D 00',
        '48 6B 10 49 02 01 00 00 00 31 00',
        '48 6B 10 49 02 03 38 32 36 33 00',
        '48 6B 10 49 02 04 33 41 30 30 00',
        '48 6B 10 49 02 05 34 33 35 32 00',
      ], ObdProtocol.iso9141);
      expect(extractVin(responses.single.data), '1HGCM82633A004352');
    });
  });

  group('PID decoding', () {
    double decode(int pid, List<int> bytes) => pidTable[pid]!.decode(bytes);

    test('reference values', () {
      expect(decode(0x0C, [0x1A, 0xF8]), 1726);
      expect(decode(0x05, [0x7B]), 83);
      expect(decode(0x0D, [0x64]), 100);
      expect(decode(0x04, [0xFF]), 100);
      expect(decode(0x06, [0x80]), 0);
      expect(decode(0x07, [0x00]), -100);
      expect(decode(0x0E, [0x80]), 0);
      expect(decode(0x10, [0x01, 0xF4]), 5);
      expect(decode(0x42, [0x36, 0xB0]), 14);
      expect(decode(0x44, [0x80, 0x00]), 1);
      expect(decode(0x32, [0xFF, 0xFC]), -1);
      expect(decode(0x5C, [0x8C]), 100);
      expect(decode(0xA6, [0x00, 0x01, 0x86, 0xA0]), 10000);
    });

    test('several PIDs in one response', () {
      final values = decodeMode01([0x41, 0x0C, 0x1A, 0xF8, 0x0D, 0x64, 0x05, 0x7B]);
      expect(values, {0x0C: 1726, 0x0D: 100, 0x05: 83});
    });

    test('support mask', () {
      final pids = decodeSupportMask(0x00, [0xBE, 0x3F, 0xA8, 0x13]);
      expect(pids.containsAll([0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x20]), isTrue);
      expect(pids.contains(0x02), isFalse);
    });
  });

  group('DTC decoding', () {
    test('code letters and digits', () {
      expect(dtcFromBytes(0x01, 0x33), 'P0133');
      expect(dtcFromBytes(0x04, 0x20), 'P0420');
      expect(dtcFromBytes(0xC1, 0x00), 'U0100');
      expect(dtcFromBytes(0x91, 0x23), 'B1123');
      expect(dtcFromBytes(0x45, 0x67), 'C0567');
      expect(dtcFromBytes(0x2A, 0xBC), 'P2ABC');
    });

    test('CAN payload has a count byte, legacy payload does not', () {
      expect(decodeDtcPayload([0x43, 0x02, 0x01, 0x33, 0x04, 0x20], isCan: true), ['P0133', 'P0420']);
      expect(decodeDtcPayload([0x43, 0x00], isCan: true), isEmpty);
      expect(decodeDtcPayload([0x43, 0x01, 0x33, 0x00, 0x00, 0x00, 0x00], isCan: false), ['P0133']);
    });

    test('monitor status', () {
      final status = MonitorStatus.decode([0x82, 0x07, 0x65, 0x04])!;
      expect(status.milOn, isTrue);
      expect(status.dtcCount, 2);
      expect(status.compressionIgnition, isFalse);
      expect(status.availableTests.map((t) => t.name), contains('Catalyst'));
      expect(status.tests.firstWhere((t) => t.name == 'Evaporative system').complete, isFalse);
      expect(status.tests.firstWhere((t) => t.name == 'Catalyst').complete, isTrue);
    });

    test('structure description', () {
      expect(describeDtcStructure('P0301'), 'Powertrain code (generic), ignition system or misfire');
      expect(describeDtcStructure('P1234'), 'Powertrain code (manufacturer-specific)');
      expect(describeDtcStructure('U0100'), 'Network code (generic)');
    });
  });

  group('VIN', () {
    test('check digit', () {
      expect(vinCheckDigitValid('1HGCM82633A004352'), isTrue);
      expect(vinCheckDigitValid('1M8GDM9AXKP042788'), isTrue);
      expect(vinCheckDigitValid('1HGCM82643A004352'), isFalse);
    });

    test('decode', () {
      final info = decodeVin('1HGCM82633A004352', currentYear: 2026)!;
      expect(info.manufacturer, 'Honda');
      expect(info.country, 'United States');
      expect(info.modelYear, 2003);
      expect(decodeVin('WVWZZZ1KZAW123456', currentYear: 2026)!.manufacturer, 'Volkswagen');
      expect(decodeVin('WVWZZZ1KZAW123456', currentYear: 2026)!.modelYear, 2010);
      expect(decodeVin('TOO-SHORT'), isNull);
      expect(decodeVin('1HGCM82633A00435O'), isNull, reason: 'letter O is not allowed');
    });
  });

  group('ObdClient against the simulated car', () {
    for (final bus in SimBus.values) {
      test('full session on ${bus.name}', () async {
        var now = 50.0; // cruising
        final vehicle = SimulatedVehicle(elapsedSeconds: () => now, warmStart: true);
        final adapter = SimulatedAdapter(vehicle: vehicle, bus: bus, latency: Duration.zero);
        final client = ObdClient(Elm327(adapter));
        final progress = <String>[];
        await client.connect(onProgress: progress.add);

        expect(client.protocol.number, bus.protocolNumber);
        expect(client.elm.version, 'ELM327 v1.5');
        expect(client.vin, '1HGCM82633A004352');
        expect(client.ecus, hasLength(2));
        expect(client.supportedPids.containsAll([0x05, 0x0C, 0x0D, 0x42, 0x5C]), isTrue);
        expect(client.batching, bus.isCan);
        expect(progress, isNotEmpty);

        final values = await client.readPids([0x0C, 0x0D, 0x05, 0x42, 0x07, 0x10, 0x11, 0x5C]);
        expect(values[0x0C], closeTo(vehicle.rpm, 1));
        expect(values[0x0D], closeTo(vehicle.speed, 1));
        expect(values[0x05], closeTo(vehicle.coolantTemp, 1));
        expect(values[0x42], closeTo(vehicle.voltage, 0.01));
        expect(values[0x07], closeTo(2.3, 0.8));
        expect(values.length, 8);

        final report = await client.readDtcs();
        expect(report.status!.milOn, isTrue);
        expect(report.status!.dtcCount, 1);
        expect(report.ofKind(DtcKind.stored).map((e) => e.code), ['P0420']);
        expect(report.ofKind(DtcKind.pending).map((e) => e.code), ['P0171']);
        expect(report.permanentSupported, bus.isCan);
        if (bus.isCan) expect(report.ofKind(DtcKind.permanent).map((e) => e.code), ['P0420']);

        final freeze = await client.readFreezeFrame();
        expect(freeze!.triggerCode, 'P0420');
        expect(freeze.values[0x0C], 2400);
        expect(freeze.values[0x05], 90);

        final cleared = await client.clearDtcs();
        expect(cleared.success, isTrue);
        final after = await client.readDtcs();
        expect(after.ofKind(DtcKind.stored), isEmpty);
        expect(after.status!.milOn, isFalse);
        expect(after.status!.allComplete, isFalse, reason: 'clearing resets the readiness monitors');
        expect(await client.readFreezeFrame(), isNull);

        now = 5; // idling
        expect(await client.readPid(0x0D), 0);
        await client.disconnect();
      });
    }

    test('falls back to trying each protocol when automatic search fails', () async {
      final adapter = SimulatedAdapter(bus: SimBus.can29, latency: Duration.zero, autoSearchFails: true);
      final client = ObdClient(Elm327(adapter));
      await client.connect();
      expect(client.protocol, ObdProtocol.can29Bit500);
      expect(client.vin, '1HGCM82633A004352');
    });

    test('reports a clear error when the ignition is off', () async {
      final vehicle = SimulatedVehicle()..ignitionOn = false;
      final client = ObdClient(Elm327(SimulatedAdapter(vehicle: vehicle, latency: Duration.zero)));
      await expectLater(client.connect(), throwsA(isA<ObdException>()));
    });

    test('reports why codes could not be cleared', () async {
      final client = ObdClient(Elm327(SimulatedAdapter(latency: Duration.zero, refuseClear: true)));
      await client.connect();
      final result = await client.clearDtcs();
      expect(result.success, isFalse);
      expect(result.reason, contains('ignition'));
    });

    test('signals a dropped link', () async {
      final adapter = SimulatedAdapter(latency: Duration.zero);
      final client = ObdClient(Elm327(adapter));
      await client.connect();
      final dropped = client.elm.onDisconnected.first;
      await adapter.unplug();
      await dropped;
      await expectLater(client.readPid(0x0C), throwsA(isA<ElmException>()));
    });

    test('a new fault code raises the warning light', () async {
      final vehicle = SimulatedVehicle(warmStart: true);
      final client = ObdClient(Elm327(SimulatedAdapter(vehicle: vehicle, latency: Duration.zero)));
      await client.connect();
      vehicle.setFault(SimFault.newTroubleCode, true);
      final report = await client.readDtcs();
      expect(report.codes, containsAll(['P0420', 'P0301']));
      expect(report.status!.dtcCount, 2);
    });
  });
}
