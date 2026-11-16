import 'package:material_ui/material_ui.dart' hide Baseline;

import '../app/app_controller.dart';
import '../monitor/agent.dart';
import '../monitor/baseline.dart';
import '../obd/sim/simulated_vehicle.dart';
import 'theme.dart';

String _clock(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// The on-device monitor: what it is watching and what it has found.
class AssistantPage extends StatelessWidget {
  const AssistantPage(this.controller, {super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final agent = controller.agent;
    if (agent == null) return const SizedBox.shrink();
    final watched = MonitorAgent.watchedPids.where(controller.availablePids.contains).length;
    final active = agent.activeFindings.toList();
    final worst = active.isEmpty ? null : active.map((f) => f.severity).reduce((a, b) => a.index >= b.index ? a : b);
    final recorder = controller.recorder;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      worst == null ? Icons.verified_user_rounded : severityIcon(worst),
                      color: worst == null ? kOk : severityColor(worst),
                      size: 36,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            worst == null
                                ? 'Everything looks normal'
                                : '${active.length} thing${active.length == 1 ? '' : 's'} need${active.length == 1 ? 's' : ''} attention',
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          ValueListenableBuilder<int>(
                            valueListenable: controller.liveTick,
                            builder: (context, _, _) => Text(
                              'Watching $watched signals · ${agent.samplesSeen} readings checked this drive',
                              style: const TextStyle(color: kMuted, fontFeatures: kTabularFigures),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            controller.isDemo
                                ? 'Learning this car\'s normal values is switched off for the demo car.'
                                : 'Knows what is normal for this car in ${agent.baseline.learnedCount} of '
                                      '${Signature.values.length} areas (needs ${Baseline.sessionsRequired} drives each).',
                            style: const TextStyle(color: kMuted, height: 1.35),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (controller.isDemo && controller.demoVehicle != null) ...[
              const SectionHeader('Try it: switch on a fault'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final fault in SimFault.values)
                    FilterChip(
                      label: Text(fault.label),
                      selected: controller.demoVehicle!.activeFaults.contains(fault),
                      onSelected: (on) => controller.setDemoFault(fault, on),
                    ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(
                  'Alarms wait until a problem has lasted a while, so a finding can take up to a minute to appear.',
                  style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.4),
                ),
              ),
            ],

            const SectionHeader('Findings'),
            if (agent.findings.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Nothing so far. You get a notification as soon as a reading goes out of range or starts '
                    'to drift from what is normal for this car.',
                    style: TextStyle(color: kMuted, height: 1.45),
                  ),
                ),
              ),
            for (final finding in agent.findings) ...[_FindingCard(finding), const SizedBox(height: 10)],

            const SectionHeader('Recording'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ValueListenableBuilder<int>(
                  valueListenable: controller.liveTick,
                  builder: (context, _, _) => Text(
                    recorder == null
                        ? 'Not recording.'
                        : recorder.isPersisted
                        ? '${recorder.rows} readings saved to a CSV file. Find it in the Files app under '
                              'On My iPhone › Obdscan › recordings.'
                        : '${recorder.rows} readings captured. Saving to a file is available in the phone app.',
                    style: const TextStyle(color: kMuted, height: 1.45, fontFeatures: kTabularFigures),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FindingCard extends StatelessWidget {
  const _FindingCard(this.finding);

  final Finding finding;

  @override
  Widget build(BuildContext context) {
    final color = finding.active ? severityColor(finding.severity) : kMuted;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 5, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(severityIcon(finding.severity), color: color, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            finding.title,
                            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          finding.active ? _clock(finding.time) : 'Resolved',
                          style: const TextStyle(color: kMuted, fontSize: 12.5),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(finding.detail, style: const TextStyle(height: 1.45)),
                    const SizedBox(height: 6),
                    Text(finding.advice, style: const TextStyle(color: kMuted, height: 1.45)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
