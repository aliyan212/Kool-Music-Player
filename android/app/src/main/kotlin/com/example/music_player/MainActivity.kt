package com.example.music_player

import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import android.content.ContentValues
import android.media.MediaScannerConnection
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
	private val channelName = "com.example.music_player/notifications"
	private val mediaStoreChannelName = "com.example.music_player/media_store"

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

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaStoreChannelName).setMethodCallHandler { call, result ->
			when (call.method) {
				"updateMediaStoreTags" -> {
					val path = call.argument<String>("path")
					if (path == null) {
						result.error("bad_args", "path is required", null)
						return@setMethodCallHandler
					}
					try {
						val title = call.argument<String>("title")
						val artist = call.argument<String>("artist")
						val album = call.argument<String>("album")
						val year = call.argument<Int>("year")
						val track = call.argument<Int>("track")
						val genre = call.argument<String>("genre")

						val values = ContentValues().apply {
							if (title != null) put(MediaStore.Audio.Media.TITLE, title)
							if (artist != null) put(MediaStore.Audio.Media.ARTIST, artist)
							if (album != null) put(MediaStore.Audio.Media.ALBUM, album)
							if (year != null && year > 0) put(MediaStore.Audio.Media.YEAR, year)
							if (track != null && track > 0) put(MediaStore.Audio.Media.TRACK, track)
							if (genre != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
								put(MediaStore.Audio.Media.GENRE, genre)
							}
							put(MediaStore.Audio.Media.DATE_MODIFIED, System.currentTimeMillis() / 1000)
						}

						val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
						val count = contentResolver.update(
							uri,
							values,
							"${MediaStore.Audio.Media.DATA} = ?",
							arrayOf(path)
						)

						// Also trigger MediaScannerConnection so the system extracts thumbnails or refreshes related caches
						MediaScannerConnection.scanFile(this, arrayOf(path), null) { _, _ -> }

						result.success(count > 0)
					} catch (e: Exception) {
						try {
							MediaScannerConnection.scanFile(this, arrayOf(path), null) { _, _ -> }
						} catch (_: Exception) {}
						result.success(false)
					}
				}
				else -> result.notImplemented()
			}
		}
	}
}
