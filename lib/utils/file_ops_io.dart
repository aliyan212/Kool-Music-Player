import 'dart:io';

Future<void> copyFile(String fromPath, String toPath) async {
  await File(fromPath).copy(toPath);
}

Future<void> deleteFile(String path) async {
  final f = File(path);
  if (await f.exists()) {
    await f.delete();
  }
}

Future<void> writeFile(String path, String contents) async {
  final f = File(path);
  await f.writeAsString(contents);
}

Future<bool> fileExists(String path) async {
  return File(path).exists();
}
