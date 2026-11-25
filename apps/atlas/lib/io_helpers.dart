import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

/// Thin wrapper so the file_picker API (unverified version) lives in one place.
Future<(String, String)?> pickTextFile() async {
  final r = await FilePicker.platform.pickFiles(withData: true, type: FileType.any);
  if (r == null || r.files.isEmpty) return null;
  final f = r.files.single;
  final bytes = f.bytes ?? await File(f.path!).readAsBytes();
  return (f.name, utf8.decode(bytes, allowMalformed: true));
}

Future<String?> saveTextFile(String name, String text) async {
  final bytes = Uint8List.fromList(utf8.encode(text));
  final path = await FilePicker.platform.saveFile(fileName: name, bytes: bytes);
  if (path == null) return null;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await File(path).writeAsBytes(bytes); // desktop: dialog only returns the path
  }
  return path;
}
