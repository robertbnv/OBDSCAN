import 'dart:async';
import 'dart:convert';

import 'protocol.dart';
import 'transport.dart';

enum ElmErrorKind {
  noData,
  unableToConnect,
  busInitError,
  busBusy,
  busError,
  canError,
  dataError,
  rxError,
  feedbackError,
  bufferFull,
  stopped,
  unknownCommand,
  lowVoltageReset,
  adapterFault,
  timeout,
  disconnected,
}

class ElmException implements Exception {
  ElmException(this.kind, this.message);

  final ElmErrorKind kind;
  final String message;

  @override
  String toString() => message;
}

/// The adapter's answer to one command, split into payload lines.
class ElmReply {
  ElmReply({required this.command, required this.lines, required this.raw, this.error});

  final String command;

  /// Payload lines with the echo, status chatter and error markers removed.
  final List<String> lines;
  final String raw;
  final ElmErrorKind? error;

  bool get isOk => lines.any((line) => line.toUpperCase() == 'OK');

  String get text => lines.join(' ');

  static String _squash(String value) => value.toUpperCase().replaceAll(RegExp(r'\s'), '');

  static ElmReply parse(String command, String raw) {
    final squashedCommand = _squash(command);
    final lines = <String>[];
    ElmErrorKind? error;
    var first = true;
    for (final part in raw.split(RegExp(r'[\r\n]+'))) {
      final line = part.trim();
      if (line.isEmpty) continue;
      final upper = line.toUpperCase();
      if (first) {
        first = false;
        if (_squash(upper) == squashedCommand) continue; // command echo
      }
      final (drop, kind) = _classify(upper);
      error ??= kind;
      if (!drop) lines.add(line);
    }
    return ElmReply(command: command, lines: lines, raw: raw, error: error);
  }

  /// Returns whether the line should be dropped and the error it signals.
  static (bool, ElmErrorKind?) _classify(String upper) {
    if (upper == '?') return (true, ElmErrorKind.unknownCommand);
    if (upper.startsWith('SEARCHING')) return (true, null);
    if (upper.startsWith('BUS INIT')) {
      return (true, upper.contains('ERROR') ? ElmErrorKind.busInitError : null);
    }
    if (upper.contains('NO DATA')) return (true, ElmErrorKind.noData);
    if (upper.contains('UNABLE TO CONNECT')) return (true, ElmErrorKind.unableToConnect);
    if (upper.contains('CAN ERROR')) return (true, ElmErrorKind.canError);
    if (upper.contains('BUS BUSY')) return (true, ElmErrorKind.busBusy);
    if (upper.contains('BUS ERROR')) return (true, ElmErrorKind.busError);
    if (upper.contains('FB ERROR')) return (true, ElmErrorKind.feedbackError);
    if (upper.contains('DATA ERROR')) return (true, ElmErrorKind.dataError);
    if (upper.contains('RX ERROR')) return (true, ElmErrorKind.rxError);
    if (upper.contains('BUFFER FULL')) return (true, ElmErrorKind.bufferFull);
    if (upper.contains('STOPPED')) return (true, ElmErrorKind.stopped);
    if (upper.contains('LV RESET')) return (true, ElmErrorKind.lowVoltageReset);
    if (upper.contains('ACT ALERT') || upper.contains('LP ALERT')) return (true, null);
    if (RegExp(r'^ERR\d\d').hasMatch(upper)) return (true, ElmErrorKind.adapterFault);
    return (false, null);
  }
}

/// Driver for ELM327-compatible adapters: serialises commands, waits for the
/// `>` prompt and classifies the adapter's status messages.
class Elm327 {
  Elm327(this.transport, {this.commandTimeout = const Duration(seconds: 5), this.onLog});

  final ObdTransport transport;
  final Duration commandTimeout;

  /// Receives one line per command sent (`> 010C`) and reply (`< 41 0C ...`).
  final void Function(String line)? onLog;

  final StringBuffer _buffer = StringBuffer();
  final StreamController<void> _disconnects = StreamController<void>.broadcast();
  StreamSubscription<List<int>>? _subscription;
  Completer<String>? _pending;
  Future<void> _queue = Future<void>.value();
  bool _disconnected = false;

  /// Identification string, for example "ELM327 v1.5" or "STN1110 v4.2.0".
  String? version;

  /// Fires once when the link to the adapter drops.
  Stream<void> get onDisconnected => _disconnects.stream;

  bool get isConnected => transport.isOpen && !_disconnected;

  Future<void> open() async {
    _disconnected = false;
    _subscription = transport.input.listen(
      _onBytes,
      onError: (Object _, StackTrace _) => _handleDisconnect(),
      onDone: _handleDisconnect,
    );
    await transport.open();
  }

  Future<void> close() async {
    _disconnected = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _failPending(ElmException(ElmErrorKind.disconnected, 'Connection closed.'));
    await transport.close();
  }

  void _onBytes(List<int> bytes) {
    for (final byte in bytes) {
      if (byte == 0x3E) {
        // '>' prompt: the adapter finished answering.
        final text = _buffer.toString();
        _buffer.clear();
        final pending = _pending;
        _pending = null;
        if (pending != null && !pending.isCompleted) pending.complete(text);
      } else if (byte != 0) {
        // The ELM327 can emit stray NUL bytes that must be ignored.
        _buffer.writeCharCode(byte & 0x7F);
      }
    }
  }

  void _handleDisconnect() {
    if (_disconnected) return;
    _disconnected = true;
    _failPending(ElmException(ElmErrorKind.disconnected, 'The adapter disconnected.'));
    if (!_disconnects.isClosed) _disconnects.add(null);
  }

  void _failPending(ElmException error) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  /// Sends one command and waits for the adapter's prompt. Commands are queued,
  /// so callers may fire requests without coordinating with each other.
  Future<ElmReply> send(String command, {Duration? timeout}) {
    final result = Completer<ElmReply>();
    _queue = _queue.then((_) async {
      try {
        result.complete(await _exchange(command, timeout ?? commandTimeout));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<ElmReply> _exchange(String command, Duration timeout) async {
    if (!isConnected) {
      throw ElmException(ElmErrorKind.disconnected, 'Not connected to an adapter.');
    }
    _buffer.clear();
    final pending = _pending = Completer<String>();
    onLog?.call('> $command');
    try {
      await transport.write(ascii.encode('$command\r'));
    } catch (error) {
      _pending = null;
      throw ElmException(ElmErrorKind.disconnected, 'Could not send to the adapter: $error');
    }
    String raw;
    try {
      raw = await pending.future.timeout(timeout);
    } on TimeoutException {
      // Give a slow adapter a moment to finish, so its late answer is not
      // mistaken for the reply to the next command.
      try {
        await pending.future.timeout(const Duration(milliseconds: 1500));
      } on TimeoutException {
        // Still silent.
      } on ElmException {
        // Disconnected while waiting; reported as a timeout below.
      }
      if (identical(_pending, pending)) _pending = null;
      _buffer.clear();
      onLog?.call('< (timeout)');
      throw ElmException(ElmErrorKind.timeout, 'The adapter did not answer "$command" in time.');
    }
    final reply = ElmReply.parse(command, raw);
    onLog?.call('< ${reply.lines.isEmpty ? (reply.error?.name ?? '(empty)') : reply.lines.join(' | ')}');
    return reply;
  }

  /// Resets the adapter and applies the settings the parser relies on:
  /// echo off, linefeeds off, spaces off, headers on, automatic protocol.
  Future<void> initialize() async {
    ElmReply identity;
    try {
      identity = await send('ATZ', timeout: const Duration(seconds: 8));
    } on ElmException catch (error) {
      if (error.kind != ElmErrorKind.timeout) rethrow;
      identity = await send('ATI');
    }
    version = _extractVersion(identity) ?? _extractVersion(await send('ATI'));

    await _apply('ATE0', required: true);
    await _apply('ATL0');
    await _apply('ATS0');
    await _apply('ATH1', required: true);
    await _apply('ATAT1');
    await _apply('ATSP0', required: true);
  }

  String? _extractVersion(ElmReply reply) {
    for (final line in reply.lines) {
      final upper = line.toUpperCase();
      if (upper.contains('ELM') || upper.contains('STN') || upper.contains('OBD')) return line;
    }
    return null;
  }

  Future<void> _apply(String command, {bool required = false}) async {
    final reply = await send(command);
    if (required && !reply.isOk) {
      throw ElmException(
        reply.error ?? ElmErrorKind.adapterFault,
        'The adapter rejected "$command" (answered "${reply.raw.trim()}"). It may not be ELM327 compatible.',
      );
    }
  }

  /// The protocol the adapter is currently using (`ATDPN`).
  Future<ObdProtocol?> describeProtocol() async {
    final reply = await send('ATDPN');
    return ObdProtocol.fromDescribeReply(reply.text);
  }

  /// Battery voltage measured at the OBD connector (`ATRV`), in volts.
  Future<double?> readVoltage() async {
    final reply = await send('ATRV');
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(reply.text);
    return match == null ? null : double.tryParse(match.group(1)!);
  }
}
