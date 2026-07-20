// Stub implementations for non-IO platforms (e.g., web).
// These should never be called because tag editing is blocked on web.

Future<void> copyFile(String fromPath, String toPath) {
  throw UnsupportedError('File I/O is not supported on this platform');
}

Future<void> deleteFile(String path) {
  throw UnsupportedError('File I/O is not supported on this platform');
}

Future<void> writeFile(String path, String contents) {
  throw UnsupportedError('File I/O is not supported on this platform');
}

Future<bool> fileExists(String path) {
  throw UnsupportedError('File I/O is not supported on this platform');
}
