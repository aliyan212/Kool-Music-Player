package com.example.music_player

import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
	private val channelName = "com.example.music_player/notifications"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
			when (call.method) {
				"areNotificationsEnabled" -> {
					val enabled = NotificationManagerCompat.from(this).areNotificationsEnabled()
					result.success(enabled)
				}
				"getChannelImportance" -> {
					val channelId = call.argument<String>("channelId")
					if (channelId == null) {
						result.error("bad_args", "channelId is required", null)
						return@setMethodCallHandler
					}
					if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
						val nm = getSystemService(android.app.NotificationManager::class.java)
						val channel = nm.getNotificationChannel(channelId)
						result.success(channel?.importance)
					} else {
						result.success(null)
					}
				}
				"openAppNotificationSettings" -> {
					val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
						putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
						addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
					}
					startActivity(intent)
					result.success(true)
				}
				"openChannelNotificationSettings" -> {
					val channelId = call.argument<String>("channelId")
					if (channelId == null) {
						result.error("bad_args", "channelId is required", null)
						return@setMethodCallHandler
					}
					if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
						val intent = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
							putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
							putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
							addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
						}
						startActivity(intent)
						result.success(true)
					} else {
						val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
							putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
							addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
						}
						startActivity(intent)
						result.success(true)
					}
				}
				else -> result.notImplemented()
			}
		}
	}
}
