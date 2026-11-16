// Recordings are CSV files in the app's documents folder. Browsers have no
// such folder, so the web build records nothing.
export 'recording_sink_stub.dart' if (dart.library.io) 'recording_sink_io.dart';
