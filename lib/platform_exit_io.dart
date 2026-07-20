import 'dart:io' show Platform, exit;

import 'package:flutter/services.dart';

class PlatformExit {
  static Future<void> quit() async {
    // Android/iOS: politely ask the host platform to close the app.
    // Desktop: terminate the process.
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemNavigator.pop();
      return;
    }

    exit(0);
  }
}
