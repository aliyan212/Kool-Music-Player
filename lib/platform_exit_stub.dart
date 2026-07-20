import 'package:flutter/services.dart';

class PlatformExit {
  static Future<void> quit() async {
    // On web, browsers generally block programmatic tab close.
    // `SystemNavigator.pop()` is usually a no-op, but it's safe.
    await SystemNavigator.pop();
  }
}
