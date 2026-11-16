// WiFi adapters are plain TCP sockets, which browsers cannot open. The web
// build therefore gets a stub that explains this instead of failing to compile.
export 'tcp_transport_stub.dart' if (dart.library.io) 'tcp_transport_io.dart';
