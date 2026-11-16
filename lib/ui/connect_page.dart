import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:universal_ble/universal_ble.dart' show BleDevice;

import '../app/app_controller.dart';
import '../connect/ble_transport.dart';
import 'code_detail_page.dart';
import 'settings_page.dart';
import 'theme.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage(this.controller, {super.key});

  final AppController controller;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  late final TextEditingController _host = TextEditingController(text: widget.controller.wifiHost);
  late final TextEditingController _port = TextEditingController(text: '${widget.controller.wifiPort}');
  final Map<String, BleDevice> _devices = {};
  StreamSubscription<BleDevice>? _scan;
  Timer? _scanTimeout;
  bool _scanning = false;
  String? _scanError;

  AppController get controller => widget.controller;

  bool get _busy => controller.link == LinkState.connecting;

  @override
  void dispose() {
    _stopScan();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _devices.clear();
      _scanError = null;
      _scanning = true;
    });
    _scan = BleScanner.results.listen((device) {
      if (mounted) setState(() => _devices[device.deviceId] = device);
    });
    final problem = await BleScanner.start();
    if (!mounted) return;
    if (problem != null) {
      await _stopScan();
      setState(() => _scanError = problem);
      return;
    }
    _scanTimeout = Timer(const Duration(seconds: 20), _stopScan);
  }

  Future<void> _stopScan() async {
    _scanTimeout?.cancel();
    _scanTimeout = null;
    await _scan?.cancel();
    _scan = null;
    if (_scanning) await BleScanner.stop();
    if (mounted && _scanning) setState(() => _scanning = false);
    _scanning = false;
  }

  Future<void> _connectBle(BleDevice device) async {
    await _stopScan();
    await controller.connectBle(device);
  }

  void _connectWifi() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter the adapter address and a port between 1 and 65535.')));
      return;
    }
    controller.connectWifi(host, port);
  }

  List<BleDevice> get _sortedDevices {
    int rank(BleDevice d) => looksLikeObdAdapter(d) ? 0 : ((d.name ?? '').isNotEmpty ? 1 : 2);
    return _devices.values.toList()..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : (b.rssi ?? -999).compareTo(a.rssi ?? -999);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OBD Scan'),
        actions: [
          IconButton(
            tooltip: 'Look up a fault code',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => showCodeLookup(context, controller),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(controller))),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Connect to your car', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                    SizedBox(height: 6),
                    Text(
                      'Plug the adapter into the OBD port (usually under the dashboard on the driver\'s side) '
                      'and switch the ignition on. The car is identified automatically.',
                      style: TextStyle(color: kMuted, height: 1.4),
                    ),
                  ],
                ),
              ),
              if (_busy) _ProgressCard(controller.progress),
              if (controller.error != null && !_busy) _ErrorCard(controller.error!),
              if (!kIsWeb) ...[
                const SectionHeader('Bluetooth LE adapter'),
                _bluetoothCard(),
                const SectionHeader('WiFi adapter'),
                _wifiCard(),
              ],
              const SectionHeader('No adapter yet?'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Demo car', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                        kIsWeb
                            ? 'A simulated car with live data, stored fault codes and faults you can switch on. '
                                  'Bluetooth and WiFi adapters are available in the phone app.'
                            : 'A simulated car with live data, stored fault codes and faults you can switch on '
                                  'to see how the monitor reacts.',
                        style: const TextStyle(color: kMuted, height: 1.4),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _busy ? null : controller.connectDemo,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Start demo'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bluetoothCard() {
    final devices = _sortedDevices;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _scanning ? 'Searching for adapters…' : 'Find adapters nearby',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_scanning) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                FilledButton.tonal(
                  onPressed: _busy ? null : (_scanning ? _stopScan : _startScan),
                  child: Text(_scanning ? 'Stop' : 'Scan'),
                ),
              ],
            ),
            if (_scanError != null) ...[
              const SizedBox(height: 8),
              Text(_scanError!, style: const TextStyle(color: kWarn)),
            ],
            if (devices.isEmpty && !_scanning && _scanError == null) ...[
              const SizedBox(height: 8),
              const Text(
                'Works with Bluetooth LE (4.0+) ELM327-compatible adapters. Older "classic Bluetooth" '
                'adapters cannot be used on iPhone.',
                style: TextStyle(color: kMuted, height: 1.4),
              ),
            ],
            for (final device in devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.bluetooth_rounded, color: looksLikeObdAdapter(device) ? kAccent : kMuted),
                title: Text((device.name ?? '').isEmpty ? 'Unnamed device' : device.name!),
                subtitle: Text(
                  looksLikeObdAdapter(device) ? 'Looks like an OBD adapter' : 'Signal ${device.rssi ?? '?'} dBm',
                  style: const TextStyle(color: kMuted),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _busy ? null : () => _connectBle(device),
              ),
          ],
        ),
      ),
    );
  }

  Widget _wifiCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'First join the adapter\'s WiFi network in the phone\'s settings, then connect here.',
              style: TextStyle(color: kMuted, height: 1.4),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Address'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _connectWifi,
              icon: const Icon(Icons.wifi_rounded),
              label: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 16),
            Expanded(child: Text(message.isEmpty ? 'Connecting…' : '$message…')),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: kCritical.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: kCritical.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline_rounded, color: kCritical),
            const SizedBox(width: 12),
            Expanded(child: Text(message, style: const TextStyle(height: 1.4))),
          ],
        ),
      ),
    );
  }
}
