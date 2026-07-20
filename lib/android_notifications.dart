import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidNotifications {
  static const MethodChannel _channel = MethodChannel('com.example.music_player/notifications');

  static Future<bool?> areNotificationsEnabled() async {
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final enabled = await _channel.invokeMethod<bool>('areNotificationsEnabled');
      return enabled;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> getChannelImportance(String channelId) async {
    if (kIsWeb) return null;
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _channel.invokeMethod<int>('getChannelImportance', {'channelId': channelId});
    } catch (_) {
      return null;
    }
  }

  static Future<void> openAppNotificationSettings() async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('openAppNotificationSettings');
    } catch (_) {}
  }

  static Future<void> openChannelNotificationSettings(String channelId) async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('openChannelNotificationSettings', {'channelId': channelId});
    } catch (_) {}
  }
}
