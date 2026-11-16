import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../app/units.dart';
import '../obd/dtc.dart';
import '../obd/live_poller.dart';
import '../obd/protocol.dart';
import 'code_detail_page.dart';
import 'theme.dart';

/// Vehicle identity, warning light, trouble codes, freeze frame and
/// emission readiness monitors.
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage(this.controller, {super.key});

  final AppController controller;

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear fault codes?'),
        content: const Text(
          'This erases stored and pending codes, the freeze frame and the readiness monitors, and '
          'switches the warning light off.\n\n'
          'It does not repair anything: if the fault is still there, the code comes back. The readiness '
          'monitors need several drives to complete again, which matters before an emissions test.\n\n'
          'Do this with the ignition on and the engine off.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kCritical, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear codes'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final result = await controller.clearCodes();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.success ? 'Fault codes cleared.' : (result.reason ?? 'Could not clear the codes.')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = controller.client;
    final report = controller.dtcReport;
    final status = report?.status;
    final info = controller.vinInfo;
    final protocol = client?.protocol ?? ObdProtocol.auto;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const SectionHeader('Vehicle'),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  children: [
                    _InfoRow('VIN', client?.vin ?? 'Not reported by this vehicle', mono: client?.vin != null),
                    if (info != null) _InfoRow('Decoded', info.summary),
                    if (controller.fuelType != null) _InfoRow('Fuel', controller.fuelType!),
                    _InfoRow('Protocol', protocol.label),
                    _InfoRow(
                      'Control units',
                      [for (final ecu in client?.ecus ?? const <int>[]) ecuLabel(ecu, protocol)].join(', '),
                    ),
                    _InfoRow('Adapter', client?.elm.version ?? 'Unknown'),
                  ],
                ),
              ),
            ),

            SectionHeader(
              'Fault codes',
              trailing: controller.readingCodes
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
            ),
            _StatusCard(
              status: status,
              onRead: controller.readingCodes ? null : controller.refreshDiagnostics,
              onClear: controller.readingCodes || report == null ? null : () => _confirmClear(context),
            ),
            if (controller.diagnosticsError != null) ...[
              const SizedBox(height: 8),
              Text(controller.diagnosticsError!, style: const TextStyle(color: kWarn)),
            ],
            if (report != null) ...[
              for (final kind in DtcKind.values)
                if (report.ofKind(kind).isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
                          child: Text(
                            '${kind.label} (${report.ofKind(kind).length})',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                          child: Text(_kindHelp(kind), style: const TextStyle(color: kMuted, fontSize: 12.5)),
                        ),
                        for (final entry in report.ofKind(kind))
                          ListTile(
                            title: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${entry.code}  ',
                                    style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: kTabularFigures),
                                  ),
                                  TextSpan(text: controller.dtc.title(entry.code)),
                                ],
                              ),
                            ),
                            subtitle: Text(ecuLabel(entry.ecu, protocol), style: const TextStyle(color: kMuted)),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => Navigator.of(context)
                                .push(MaterialPageRoute<void>(builder: (_) => CodeDetailPage(controller, entry.code))),
                          ),
                      ],
                    ),
                  ),
                ],
              if (report.entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('No fault codes are stored in any control unit.', style: TextStyle(color: kMuted)),
                ),
            ],

            if (controller.freezeFrame != null) ...[const SectionHeader('Freeze frame'), _FreezeFrameCard(controller)],

            if (status != null && status.availableTests.isNotEmpty) ...[
              const SectionHeader('Readiness monitors'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(
                    children: [
                      for (final test in status.availableTests)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                            children: [
                              Icon(
                                test.complete ? Icons.check_circle_rounded : Icons.timelapse_rounded,
                                size: 20,
                                color: test.complete ? kOk : kWarn,
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: Text(test.name)),
                              Text(
                                test.complete ? 'Complete' : 'Not complete',
                                style: TextStyle(color: test.complete ? kMuted : kWarn, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(
                  'The car tests each emission system by itself while driving. All monitors should be complete '
                  'before an emissions inspection.',
                  style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.4),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _kindHelp(DtcKind kind) => switch (kind) {
    DtcKind.stored => 'Faults the car has confirmed. These switch the warning light on.',
    DtcKind.pending => 'Seen once, not yet confirmed. They become confirmed if the fault repeats.',
    DtcKind.permanent => 'Cannot be erased by a scan tool; they clear by themselves once the car verifies the repair.',
  };
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(color: kMuted)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontWeight: mono ? FontWeight.w600 : FontWeight.w400,
                letterSpacing: mono ? 0.8 : 0,
                fontFeatures: kTabularFigures,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.onRead, required this.onClear});

  final MonitorStatus? status;
  final VoidCallback? onRead;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final on = status?.milOn ?? false;
    final color = status == null ? kMuted : (on ? kWarn : kOk);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(on ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded, color: color, size: 34),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status == null ? 'Reading…' : (on ? 'Check-engine light is on' : 'Check-engine light is off'),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      if (status != null)
                        Text(
                          status!.dtcCount == 0
                              ? 'The car reports no confirmed fault codes.'
                              : 'The car reports ${status!.dtcCount} confirmed fault code${status!.dtcCount == 1 ? '' : 's'}.',
                          style: const TextStyle(color: kMuted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onRead,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Read again'),
                ),
                OutlinedButton.icon(
                  onPressed: onClear,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Clear codes'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FreezeFrameCard extends StatelessWidget {
  const _FreezeFrameCard(this.controller);

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final frame = controller.freezeFrame!;
    final pids = frame.values.keys.toList()..sort();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sensor readings at the moment ${frame.triggerCode} was detected',
              style: const TextStyle(color: kMuted, height: 1.4),
            ),
            const SizedBox(height: 8),
            for (final pid in pids)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(child: Text(pidDefinition(pid)!.name)),
                    Builder(
                      builder: (context) {
                        final shown = displayValue(pidDefinition(pid)!, frame.values[pid]!, controller.units);
                        return Text(
                          '${shown.text} ${shown.unit}',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: kTabularFigures),
                        );
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
