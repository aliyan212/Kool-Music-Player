import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';

final ValueNotifier<bool> appIsForeground = ValueNotifier<bool>(true);
final GlobalKey<DynamicColorBuilderState> dynamicColorBuilderKey =
    GlobalKey<DynamicColorBuilderState>();

class AppLifecycleObserver with WidgetsBindingObserver {
  DateTime? _lastDynamicRefresh;
  int? _lastDynamicSignature;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Treat only resumed as foreground to aggressively stop periodic streams.
    appIsForeground.value = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      // Refresh Material You / dynamic colors without recreating the app.
      final now = DateTime.now();
      final last = _lastDynamicRefresh;
      if (last == null || now.difference(last) > const Duration(seconds: 2)) {
        _lastDynamicRefresh = now;
        _maybeRefreshDynamicColor();
      }
    }
  }

  Future<void> _maybeRefreshDynamicColor() async {
    // Only Android supports dynamic colors via platform palette.
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final core = await DynamicColorPlugin.getCorePalette();
      final accent = await DynamicColorPlugin.getAccentColor();

      int? signature;
      if (core != null) {
        // Sample a stable set of tones as a signature.
        signature = Object.hashAll([
          core.primary.get(40),
          core.primary.get(80),
          core.secondary.get(40),
          core.tertiary.get(40),
          core.neutral.get(10),
          core.neutral.get(90),
          core.neutralVariant.get(30),
          core.error.get(40),
          accent?.toARGB32(),
        ]);
      } else {
        signature = accent?.toARGB32();
      }

      if (signature == null) return;
      if (_lastDynamicSignature == signature) return;
      _lastDynamicSignature = signature;

      dynamicColorBuilderKey.currentState?.initPlatformState();
    } catch (_) {
      // Ignore: dynamic color not available.
    }
  }
}
