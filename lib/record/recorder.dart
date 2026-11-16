import '../obd/live_poller.dart';
import 'recording_sink.dart';

String _csv(String field) => field.contains(',') || field.contains('"') ? '"${field.replaceAll('"', '""')}"' : field;

/// Writes every live sample of a drive to a CSV file: one row per sample,
/// one column per parameter, in the units the car reports (metric).
class SessionRecorder {
  SessionRecorder(this.columns, this._sink) {
    _sink?.writeln(header(columns));
  }

  final List<int> columns;
  final RecordingSink? _sink;
  int rows = 0;

  String? get path => _sink?.path;

  bool get isPersisted => _sink != null;

  static String header(List<int> columns) => [
    'time',
    for (final pid in columns)
      _csv(() {
        final def = pidDefinition(pid);
        if (def == null) return 'PID ${pid.toRadixString(16)}';
        return def.unit.isEmpty ? def.name : '${def.name} (${def.unit})';
      }()),
  ].join(',');

  static String row(List<int> columns, LiveSample sample) => [
    sample.time.toIso8601String(),
    for (final pid in columns)
      () {
        final value = sample.values[pid];
        if (value == null) return '';
        return value.toStringAsFixed(pidDefinition(pid)?.decimals ?? 2);
      }(),
  ].join(',');

  void add(LiveSample sample) {
    rows++;
    _sink?.writeln(row(columns, sample));
  }

  Future<void> close() async => _sink?.close();

  /// Opens a recorder that saves to the documents folder where possible.
  static Future<SessionRecorder> start(List<int> columns, {required DateTime time, String? vin}) async {
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${time.year}${two(time.month)}${two(time.day)}_${two(time.hour)}${two(time.minute)}${two(time.second)}';
    final sink = await openRecordingSink('drive_${stamp}_${vin ?? 'unknown'}.csv');
    return SessionRecorder(columns, sink);
  }
}
