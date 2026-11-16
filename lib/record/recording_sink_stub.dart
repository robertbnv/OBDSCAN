class RecordingFile {
  const RecordingFile(this.name, this.path, this.bytes, this.modified);

  final String name;
  final String path;
  final int bytes;
  final DateTime modified;
}

class RecordingSink {
  String get path => '';

  void writeln(String line) {}

  Future<void> close() async {}
}

Future<RecordingSink?> openRecordingSink(String fileName) async => null;

Future<List<RecordingFile>> listRecordings() async => const [];

Future<void> deleteRecording(String path) async {}
