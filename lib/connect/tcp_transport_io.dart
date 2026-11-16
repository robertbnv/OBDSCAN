import 'dart:async';
import 'dart:io';

import '../obd/transport.dart';

/// WiFi OBD adapters open their own access point and expose the ELM327 as a
/// raw TCP socket, most commonly at 192.168.0.10:35000.
class TcpTransport implements ObdTransport {
  TcpTransport(this.host, this.port, {this.connectTimeout = const Duration(seconds: 6)});

  final String host;
  final int port;
  final Duration connectTimeout;

  final StreamController<List<int>> _input = StreamController<List<int>>.broadcast();
  Socket? _socket;

  @override
  String get description => 'WiFi $host:$port';

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  bool get isOpen => _socket != null;

  @override
  Future<void> open() async {
    try {
      final socket = await Socket.connect(host, port, timeout: connectTimeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      socket.listen(
        (data) {
          if (!_input.isClosed) _input.add(data);
        },
        onError: (Object _) => _drop(),
        onDone: _drop,
        cancelOnError: true,
      );
    } on SocketException catch (error) {
      throw TransportException(
        'Could not reach the adapter at $host:$port (${error.osError?.message ?? error.message}). '
        "Join the adapter's WiFi network in the phone's settings first.",
      );
    } on TimeoutException {
      throw TransportException(
        'No answer from $host:$port. Join the adapter\'s WiFi network in the phone\'s settings first.',
      );
    }
  }

  void _drop() {
    _socket?.destroy();
    _socket = null;
    if (!_input.isClosed) _input.close();
  }

  @override
  Future<void> write(List<int> bytes) async {
    final socket = _socket;
    if (socket == null) throw TransportException('Not connected.');
    try {
      socket.add(bytes);
      await socket.flush();
    } catch (error) {
      _drop();
      throw TransportException('The WiFi link dropped.');
    }
  }

  @override
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    try {
      await socket?.close();
    } catch (_) {
      // Already gone.
    }
    socket?.destroy();
    if (!_input.isClosed) unawaited(_input.close());
  }
}
