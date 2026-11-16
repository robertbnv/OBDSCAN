import 'dart:async';

import '../obd/transport.dart';

class TcpTransport implements ObdTransport {
  TcpTransport(this.host, this.port);

  final String host;
  final int port;

  @override
  String get description => 'WiFi $host:$port';

  @override
  Stream<List<int>> get input => const Stream.empty();

  @override
  bool get isOpen => false;

  @override
  Future<void> open() async {
    throw TransportException('WiFi adapters cannot be reached from a web browser. Use the phone app.');
  }

  @override
  Future<void> write(List<int> bytes) async {
    throw TransportException('Not connected.');
  }

  @override
  Future<void> close() async {}
}
