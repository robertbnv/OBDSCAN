import 'dart:io';

import 'package:path_provider/path_provider.dart';

class RecordingFile {
  const RecordingFile(this.name, this.path, this.bytes, this.modified);

  final String name;
  final String path;
  final int bytes;
  final DateTime modified;
}

Future<Directory> _recordingsDirectory() async {
  final documents = await getApplicationDocumentsDirectory();
  final directory = Directory('${documents.path}${Platform.pathSeparator}recordings');
  if (!await directory.exists()) await directory.create(recursive: true);
  return directory;
}

/// Appends lines to one CSV file, flushing to disk every few seconds so a
/// drive is not lost if the app is killed.
class RecordingSink {
  RecordingSink._(this.path, this._sink);

  final String path;
  final IOSink _sink;
  int _pending = 0;
  bool _flushing = false;
  bool _closed = false;

  void writeln(String line) {
    if (_closed) return;
    _sink.writeln(line);
    if (++_pending >= 25 && !_flushing) {
      _pending = 0;
      _flushing = true;
      _sink.flush().whenComplete(() => _flushing = false).ignore();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // flush() and close() must not overlap on an IOSink.
    while (_flushing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    try {
      await _sink.flush();
      await _sink.close();
    } catch (_) {
      // Nothing useful to do if the disk went away.
    }
  }
}

Future<RecordingSink?> openRecordingSink(String fileName) async {
  try {
    final directory = await _recordingsDirectory();
    final path = '${directory.path}${Platform.pathSeparator}$fileName';
    return RecordingSink._(path, File(path).openWrite());
  } catch (_) {
    return null;
  }
}

Future<List<RecordingFile>> listRecordings() async {
  try {
    final directory = await _recordingsDirectory();
    final files = <RecordingFile>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.csv')) continue;
      final stat = await entity.stat();
      files.add(RecordingFile(entity.uri.pathSegments.last, entity.path, stat.size, stat.modified));
    }
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  } catch (_) {
    return const [];
  }
}

Future<void> deleteRecording(String path) async {
  try {
    await File(path).delete();
  } catch (_) {
    // Already gone.
  }
}
