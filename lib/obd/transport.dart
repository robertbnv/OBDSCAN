import 'dart:async';

/// A raw byte pipe to an ELM327-compatible adapter (Bluetooth LE, WiFi or the
/// built-in simulator). Everything above this interface is platform independent.
abstract class ObdTransport {
  /// Human readable description, for example "WiFi 192.168.0.10:35000".
  String get description;

  /// Bytes received from the adapter. The stream closes when the link drops.
  Stream<List<int>> get input;

  bool get isOpen;

  Future<void> open();

  Future<void> write(List<int> bytes);

  Future<void> close();
}

/// Thrown when a transport cannot be opened or written to.
class TransportException implements Exception {
  TransportException(this.message);

  final String message;

  @override
  String toString() => message;
}
