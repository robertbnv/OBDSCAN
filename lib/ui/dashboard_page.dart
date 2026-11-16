import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../app/units.dart';
import '../obd/live_poller.dart';
import 'gauge.dart';
import 'theme.dart';

/// Gauge colour: amber and red where a reading is outside its safe range.
Color gaugeColor(int pid, double value) {
  switch (pid) {
    case 0x05:
      return value >= 118 ? kCritical : (value >= 110 ? kWarn : kAccent);
    case 0x0C:
      return value >= 6500 ? kCritical : (value >= 5500 ? kWarn : kAccent);
    case 0x42 || adapterVoltagePid:
      if (value < 11.5 || value > 15.3) return kCritical;
      return value < 12.0 ? kWarn : kAccent;
    case 0x5C:
      return value >= 150 ? kCritical : (value >= 135 ? kWarn : kAccent);
    default:
      return kAccent;
  }
}

/// The user's selection of live values as large gauges. The first four are
/// also what the CarPlay Live Activity shows.
class DashboardPage extends StatelessWidget {
  const DashboardPage(this.controller, {super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final pids = controller.visibleDashboardPids;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 190).floor().clamp(2, 4);
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: ValueListenableBuilder<int>(
                        valueListenable: controller.liveTick,
                        builder: (context, _, _) => Text(
                          'Live · ${controller.refreshRate.toStringAsFixed(1)} updates/s',
                          style: const TextStyle(color: kMuted, fontSize: 13, fontFeatures: kTabularFigures),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => showDashboardEditor(context, controller),
                      icon: const Icon(Icons.tune_rounded, size: 18),
                      label: const Text('Edit'),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              sliver: SliverGrid.count(
                crossAxisCount: columns,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [for (final pid in pids) _GaugeCard(controller, pid)],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _GaugeCard extends StatelessWidget {
  const _GaugeCard(this.controller, this.pid);

  final AppController controller;
  final int pid;

  @override
  Widget build(BuildContext context) {
    final def = pidDefinition(pid)!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: ValueListenableBuilder<int>(
          valueListenable: controller.liveTick,
          builder: (context, _, _) {
            final value = controller.values[pid];
            final shown = value == null ? null : displayValue(def, value, controller.units);
            return RadialGauge(
              label: def.shortName,
              valueText: shown?.text ?? '–',
              unit: shown?.unit ?? displayValue(def, 0, controller.units).unit,
              fraction: value == null ? 0 : controller.gaugeFraction(pid, value),
              color: value == null ? kAccent : gaugeColor(pid, value),
            );
          },
        ),
      ),
    );
  }
}

/// Bottom sheet for choosing which values appear on the dashboard.
Future<void> showDashboardEditor(BuildContext context, AppController controller) {
  final selected = [...controller.visibleDashboardPids];
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kSurface,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        const limit = AppController.maxDashboardGauges;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          builder: (context, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Dashboard gauges', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                          Text(
                            '${selected.length} of $limit selected · the first four also show on CarPlay',
                            style: const TextStyle(color: kMuted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () {
                              controller.setDashboard(selected);
                              Navigator.of(context).pop();
                            },
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scroll,
                  children: [
                    for (final pid in controller.availablePids)
                      CheckboxListTile(
                        value: selected.contains(pid),
                        title: Text(pidDefinition(pid)!.name),
                        subtitle: selected.contains(pid)
                            ? Text('Position ${selected.indexOf(pid) + 1}', style: const TextStyle(color: kMuted))
                            : null,
                        onChanged: (checked) => setState(() {
                          if (checked == true) {
                            if (selected.length < limit) selected.add(pid);
                          } else {
                            selected.remove(pid);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
