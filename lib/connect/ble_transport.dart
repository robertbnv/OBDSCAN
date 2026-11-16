import 'dart:async';
import 'dart:math' as math;

import 'package:universal_ble/universal_ble.dart';

import '../obd/transport.dart';

/// Serial-over-Bluetooth-LE profiles used by OBD adapters, as
/// (service, notify characteristic, write characteristic).
const List<(String, String, String)> _knownProfiles = [
  // Most ELM327 BLE clones, Veepeak OBDCheck BLE, OBDLink CX
  ('fff0', 'fff1', 'fff2'),
  // HM-10 style modules: one characteristic for both directions
  ('ffe0', 'ffe1', 'ffe1'),
  // Vgate vLinker / "IOS-Vlink"
  ('18f0', '2af0', '2af1'),
  // Vgate iCar Pro BLE
  (
    'e7810a71-73ae-499d-8c15-faa9aef0c3f2',
    'bef8d6c9-9c21-4c9e-b632-bd58c1009f9f',
    'bef8d6c9-9c21-4c9e-b632-bd58c1009f9f',
  ),
  // Nordic UART service
  (
    '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
    '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
  ),
  // Microchip transparent UART
  (
    '49535343-fe7d-4ae5-8fa9-9fafd205e455',
    '49535343-1e4d-4bd9-ba61-23c647249616',
    '49535343-8841-43f4-a8d4-ecbe34729bb3',
  ),
];

/// Standard GATT services that never carry the serial data.
const List<String> _standardServices = ['1800', '1801', '180a', '180f'];

bool _canNotify(BleCharacteristic c) =>
    c.properties.contains(CharacteristicProperty.notify) || c.properties.contains(CharacteristicProperty.indicate);

bool _canWrite(BleCharacteristic c) =>
    c.properties.contains(CharacteristicProperty.write) ||
    c.properties.contains(CharacteristicProperty.writeWithoutResponse);

BleCharacteristic? _find(BleService service, String uuid) {
  for (final characteristic in service.characteristics) {
    if (BleUuidParser.compareStrings(characteristic.uuid, uuid)) return characteristic;
  }
  return null;
}

/// Picks the notify and write characteristics of the adapter's serial port:
/// known profiles first, then any service that offers both directions.
(BleCharacteristic, BleCharacteristic)? pickSerialCharacteristics(List<BleService> services) {
  for (final (serviceUuid, notifyUuid, writeUuid) in _knownProfiles) {
    for (final service in services) {
      if (!BleUuidParser.compareStrings(service.uuid, serviceUuid)) continue;
      final notify = _find(service, notifyUuid);
      final write = _find(service, writeUuid);
      if (notify != null && write != null && _canNotify(notify) && _canWrite(write)) return (notify, write);
    }
  }
  for (final service in services) {
    if (_standardServices.any((uuid) => BleUuidParser.compareStrings(service.uuid, uuid))) continue;
    BleCharacteristic? notify;
    BleCharacteristic? write;
    for (final characteristic in service.characteristics) {
      if (notify == null && _canNotify(characteristic)) notify = characteristic;
      if (write == null && _canWrite(characteristic)) write = characteristic;
    }
    if (notify != null && write != null) return (notify, write);
  }
  return null;
}

/// Names that Bluetooth LE OBD adapters commonly advertise.
bool looksLikeObdAdapter(BleDevice device) {
  final name = (device.name ?? '').toLowerCase();
  if (name.isEmpty) return false;
  const hints = [
    'obd',
    'elm',
    'vlink',
    'v-link',
    'vgate',
    'icar',
    'veepeak',
    'viecar',
    'carista',
    'konnwei',
    'scan',
    'vpeak',
  ];
  return hints.any(name.contains);
}

class BleTransport implements ObdTransport {
  BleTransport(this.device);

  final BleDevice device;

  final StreamController<List<int>> _input = StreamController<List<int>>.broadcast();
  StreamSubscription<List<int>>? _values;
  StreamSubscription<bool>? _connection;
  BleCharacteristic? _notifyCharacteristic;
  BleCharacteristic? _writeCharacteristic;
  bool _withResponse = true;
  int _chunkSize = 20;
  bool _open = false;

  @override
  String get description => 'Bluetooth ${device.name ?? device.deviceId}';

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> open() async {
    try {
      await device.connect(timeout: const Duration(seconds: 15));
      final services = await device.discoverServices(timeout: const Duration(seconds: 15));
      final picked = pickSerialCharacteristics(services);
      if (picked == null) {
        await device.disconnect();
        throw TransportException(
          '"${device.name ?? 'This device'}" does not offer a serial data service, so it is probably not an OBD adapter.',
        );
      }
      final (notify, write) = picked;
      _notifyCharacteristic = notify;
      _writeCharacteristic = write;
      // Writing without response is faster; fall back when it is not offered.
      _withResponse = !write.properties.contains(CharacteristicProperty.writeWithoutResponse);

      _values = notify.onValueReceived.listen((value) {
        if (!_input.isClosed) _input.add(value);
      });
      if (notify.properties.contains(CharacteristicProperty.notify)) {
        await notify.notifications.subscribe();
      } else {
        await notify.indications.subscribe();
      }

      try {
        final mtu = await device.requestMtu(185);
        _chunkSize = math.max(20, mtu - 3);
      } catch (_) {
        _chunkSize = 20; // the safe default for every BLE link
      }

      _connection = device.connectionStream.listen((connected) {
        if (!connected) _drop();
      });
      _open = true;
    } on TransportException {
      rethrow;
    } catch (error) {
      _cancel();
      throw TransportException('Could not connect to ${device.name ?? 'the adapter'}: $error');
    }
  }

  void _cancel() {
    unawaited(_values?.cancel());
    unawaited(_connection?.cancel());
    _values = null;
    _connection = null;
  }

  void _drop() {
    if (!_open) return;
    _open = false;
    _cancel();
    if (!_input.isClosed) _input.close();
  }

  @override
  Future<void> write(List<int> bytes) async {
    final characteristic = _writeCharacteristic;
    if (!_open || characteristic == null) throw TransportException('Not connected.');
    for (var i = 0; i < bytes.length; i += _chunkSize) {
      final chunk = bytes.sublist(i, math.min(i + _chunkSize, bytes.length));
      await characteristic.write(chunk, withResponse: _withResponse);
    }
  }

  @override
  Future<void> close() async {
    final wasOpen = _open;
    _open = false;
    _cancel();
    if (wasOpen) {
      try {
        await _notifyCharacteristic?.unsubscribe();
      } catch (_) {
        // The link may already be down.
      }
      try {
        await device.disconnect();
      } catch (_) {
        // Already disconnected.
      }
    }
    if (!_input.isClosed) unawaited(_input.close());
  }
}

/// Thin wrapper around the platform scanner with user-facing error messages.
class BleScanner {
  static Stream<BleDevice> get results => UniversalBle.scanStream;

  /// Starts scanning. Returns a message when Bluetooth cannot be used.
  static Future<String?> start() async {
    try {
      final state = await UniversalBle.getBluetoothAvailabilityState();
      switch (state) {
        case AvailabilityState.poweredOff:
          return 'Bluetooth is switched off. Turn it on and try again.';
        case AvailabilityState.unsupported:
          return 'This device has no Bluetooth LE.';
        case AvailabilityState.unauthorized:
          return 'Bluetooth access is not allowed. Enable it for this app in the system settings.';
        default:
          break;
      }
      await UniversalBle.startScan();
      return null;
    } catch (error) {
      return 'Could not start scanning: $error';
    }
  }

  static Future<void> stop() async {
    try {
      await UniversalBle.stopScan();
    } catch (_) {
      // Not scanning.
    }
  }
}
