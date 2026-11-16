import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../app/units.dart';
import '../obd/live_poller.dart';
import '../obd/pids.dart';
import 'gauge.dart';
import 'theme.dart';

const Map<PidGroup, String> _groupTitles = {
  PidGroup.engine: 'Engine',
  PidGroup.temperature: 'Temperatures',
  PidGroup.air: 'Air and throttle',
  PidGroup.fuel: 'Fuel',
  PidGroup.electrical: 'Electrical',
  PidGroup.emissions: 'Emissions',
  PidGroup.trip: 'Trip and counters',
};

/// Every numeric value the car reports, grouped, with a recent trend line
/// and the lowest and highest reading of this drive.
class LiveDataPage extends StatelessWidget {
  const LiveDataPage(this.controller, {super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final byGroup = <PidGroup, List<PidDef>>{};
    for (final pid in controller.availablePids) {
      final def = pidDefinition(pid);
      if (def != null) byGroup.putIfAbsent(def.group, () => []).add(def);
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            for (final group in _groupTitles.keys)
              if (byGroup[group] != null) ...[
                SectionHeader(_groupTitles[group]!),
                Card(
                  child: Column(
                    children: [
                      for (final (index, def) in byGroup[group]!.indexed) ...[
                        if (index > 0) const Divider(indent: 16, endIndent: 16),
                        _LiveRow(controller, def),
                      ],
                    ],
                  ),
                ),
              ],
          ],
        ),
      ),
    );
  }
}

class _LiveRow extends StatelessWidget {
  const _LiveRow(this.controller, this.def);

  final AppController controller;
  final PidDef def;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: ValueListenableBuilder<int>(
        valueListenable: controller.liveTick,
        builder: (context, _, _) {
          final value = controller.values[def.pid];
          final range = controller.extremes[def.pid];
          final shown = value == null ? null : displayValue(def, value, controller.units);
          String bound(double v) => displayValue(def, v, controller.units).text;
          return Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(def.name, style: const TextStyle(fontSize: 14.5, height: 1.25)),
                    if (range != null)
                      Text(
                        'min ${bound(range.$1)} · max ${bound(range.$2)}',
                        style: const TextStyle(fontSize: 12, color: kMuted, fontFeatures: kTabularFigures),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(width: 64, height: 26, child: Sparkline(controller.history[def.pid] ?? const [])),
              const SizedBox(width: 12),
              SizedBox(
                width: 92,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: shown?.text ?? '–',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      if (shown != null && shown.unit.isNotEmpty)
                        TextSpan(
                          text: ' ${shown.unit}',
                          style: const TextStyle(fontSize: 12, color: kMuted),
                        ),
                    ],
                  ),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontFeatures: kTabularFigures),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
