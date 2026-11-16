/// OBD-II bus protocols as numbered by the ELM327 (`ATSP n` / `ATDPN`).
enum ObdProtocol {
  auto(0x0, 'Automatic'),
  j1850Pwm(0x1, 'SAE J1850 PWM (41.6 kbaud)'),
  j1850Vpw(0x2, 'SAE J1850 VPW (10.4 kbaud)'),
  iso9141(0x3, 'ISO 9141-2 (5 baud init)'),
  kwpSlow(0x4, 'ISO 14230-4 KWP (5 baud init)'),
  kwpFast(0x5, 'ISO 14230-4 KWP (fast init)'),
  can11Bit500(0x6, 'ISO 15765-4 CAN (11 bit, 500 kbaud)'),
  can29Bit500(0x7, 'ISO 15765-4 CAN (29 bit, 500 kbaud)'),
  can11Bit250(0x8, 'ISO 15765-4 CAN (11 bit, 250 kbaud)'),
  can29Bit250(0x9, 'ISO 15765-4 CAN (29 bit, 250 kbaud)'),
  j1939(0xA, 'SAE J1939 CAN (29 bit, 250 kbaud)'),
  user1(0xB, 'User CAN 1'),
  user2(0xC, 'User CAN 2');

  const ObdProtocol(this.number, this.label);

  final int number;
  final String label;

  /// CAN protocols frame data with ISO-TP and prefix DTC lists with a count.
  bool get isCan => number >= 0x6;

  bool get is29Bit => this == can29Bit500 || this == can29Bit250 || this == j1939;

  static ObdProtocol? fromNumber(int number) {
    for (final protocol in values) {
      if (protocol.number == number) return protocol;
    }
    return null;
  }

  /// Parses the reply of `ATDPN`. "A6" means "found automatically, protocol 6";
  /// a single character is the protocol itself (so "A" alone is J1939).
  static ObdProtocol? fromDescribeReply(String reply) {
    final text = reply.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    if (text.isEmpty) return null;
    final digit = text.length >= 2 && text[0] == 'A' ? text[1] : text[0];
    final number = int.tryParse(digit, radix: 16);
    return number == null ? null : fromNumber(number);
  }
}

/// A friendly name for the module that answered, derived from its address.
String ecuLabel(int ecu, ObdProtocol protocol) {
  if (protocol.isCan && !protocol.is29Bit) {
    return switch (ecu) {
      0x7E8 => 'Engine (ECM)',
      0x7E9 => 'Transmission (TCM)',
      _ => 'ECU ${ecu.toRadixString(16).toUpperCase()}',
    };
  }
  final source = ecu & 0xFF;
  return switch (source) {
    0x10 || 0x11 => 'Engine (ECM)',
    0x18 || 0x19 || 0x1A => 'Transmission (TCM)',
    0x28 => 'Brakes (ABS)',
    _ => 'ECU ${source.toRadixString(16).toUpperCase().padLeft(2, '0')}',
  };
}
