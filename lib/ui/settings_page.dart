import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../app/units.dart';
import '../record/recording_sink.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage(this.controller, {super.key});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late Future<List<RecordingFile>> _recordings = listRecordings();

  AppController get controller => widget.controller;

  String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              children: [
                const SectionHeader('Units'),
                SegmentedButton<UnitSystem>(
                  segments: const [
                    ButtonSegment(value: UnitSystem.metric, label: Text('Metric (°C, km/h, kPa)')),
                    ButtonSegment(value: UnitSystem.imperial, label: Text('Imperial (°F, mph, psi)')),
                  ],
                  selected: {controller.units},
                  onSelectionChanged: (selection) => controller.setUnits(selection.first),
                ),

                const SectionHeader('Recorded drives'),
                FutureBuilder<List<RecordingFile>>(
                  future: _recordings,
                  builder: (context, snapshot) {
                    final files = snapshot.data ?? const <RecordingFile>[];
                    if (files.isEmpty) {
                      return const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Every drive is saved as a CSV file that opens in Excel or Numbers. '
                            'Recordings appear here after the first drive.',
                            style: TextStyle(color: kMuted, height: 1.45),
                          ),
                        ),
                      );
                    }
                    return Card(
                      child: Column(
                        children: [
                          for (final file in files)
                            ListTile(
                              title: Text(file.name, style: const TextStyle(fontSize: 14)),
                              subtitle: Text(_size(file.bytes), style: const TextStyle(color: kMuted)),
                              trailing: IconButton(
                                tooltip: 'Delete recording',
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () async {
                                  await deleteRecording(file.path);
                                  if (mounted) setState(() => _recordings = listRecordings());
                                },
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),

                const SectionHeader('Adapter log'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: controller.log.isEmpty
                        ? const Text(
                            'The raw conversation with the adapter appears here after connecting. '
                            'It helps when an adapter misbehaves.',
                            style: TextStyle(color: kMuted, height: 1.45),
                          )
                        : SizedBox(
                            height: 220,
                            child: SingleChildScrollView(
                              reverse: true,
                              child: SelectableText(
                                controller.log.join('\n'),
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
                              ),
                            ),
                          ),
                  ),
                ),

                const SectionHeader('About'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Fault code descriptions: ${controller.dtc.codeCount} generic codes from the OBDex '
                      'dataset (public domain, CC0-1.0).\n\n'
                      'Monitoring runs entirely on this device. No vehicle data leaves the phone.',
                      style: const TextStyle(color: kMuted, height: 1.45),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
