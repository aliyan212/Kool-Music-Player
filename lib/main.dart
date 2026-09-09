export 'utils/song_repair_utils.dart' show repairSongMetadataMap, repairSongMetadataList;
export 'services/app_lifecycle_observer.dart' show appIsForeground;
import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:permission_handler/permission_handler.dart';

import 'android_notifications.dart';
import 'app_audio_handler.dart';
import 'core/theme/app_theme.dart';
import 'pages/about_page.dart';
import 'pages/boot_page.dart';
import 'pages/home_page.dart';
import 'services/app_lifecycle_observer.dart';

AppAudioHandler? audioHandler;
Future<dynamic>? audioHandlerInitFuture;

int _autoExitSuppressCount = 0;
bool get suppressAutoExit => _autoExitSuppressCount > 0;
void pushAutoExitSuppress() => _autoExitSuppressCount++;
void popAutoExitSuppress() {
  if (_autoExitSuppressCount > 0) _autoExitSuppressCount--;
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final GoRouter appRouter = GoRouter(
  navigatorKey: navigatorKey,
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) {
        final tabRaw = state.uri.queryParameters['tab'];
        final tab = int.tryParse(tabRaw ?? '0') ?? 0;
        return MyHomePage(initialTabIndex: tab);
      },
    ),
    GoRoute(
      path: '/about',
      name: 'about',
      builder: (context, state) => const AboutPage(),
    ),
  ],
);

Future<bool> ensureNotificationPermissionIfNeeded() async {
  if (kIsWeb) return true;
  if (defaultTargetPlatform != TargetPlatform.android) return true;

  const audioChannelId = 'com.example.music_player.channel.audio.v2';

  final status = await Permission.notification.status;
  if (status.isGranted || status.isLimited) return true;
  if (status.isPermanentlyDenied) return false;

  final result = await Permission.notification.request();
  final granted = result.isGranted || result.isLimited;
  if (!granted) return false;

  final appEnabled = await AndroidNotifications.areNotificationsEnabled();
  if (appEnabled == false) return false;

  final importance = await AndroidNotifications.getChannelImportance(
    audioChannelId,
  );
  if (importance == 0) return false;

  return true;
}

final themeNotifier = ThemeNotifier();
final appLifecycleObserver = AppLifecycleObserver();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS)) {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      try {
        final setLocale = DynamicLibrary.process()
            .lookupFunction<
              Int8 Function(Int32, Pointer<Utf8>),
              int Function(int, Pointer<Utf8>)
            >('setlocale');
        final localeC = "C".toNativeUtf8();
        setLocale(1, localeC);
        malloc.free(localeC);
      } catch (e) {
        debugPrint('Failed to set locale: $e');
      }
    }
    JustAudioMediaKit.ensureInitialized(
      linux: true,
      windows: true,
      macOS: true,
    );
  }
  WidgetsBinding.instance.addObserver(appLifecycleObserver);
  runApp(const BootApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  SystemUiOverlayStyle _overlayForBrightness(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      key: dynamicColorBuilderKey,
      builder: (lightDynamic, darkDynamic) {
        final fallbackLight = ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C2A8),
          brightness: Brightness.light,
        );
        final fallbackDark = ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C2A8),
          brightness: Brightness.dark,
        );

        final lightScheme = (lightDynamic?.harmonized() ?? fallbackLight);
        final darkScheme = (darkDynamic?.harmonized() ?? fallbackDark);

        return ValueListenableBuilder<ThemeMode>(
          valueListenable: themeNotifier,
          builder: (context, themeMode, _) {
            final platformBrightness = MediaQuery.platformBrightnessOf(context);
            final effectiveBrightness = switch (themeMode) {
              ThemeMode.light => Brightness.light,
              ThemeMode.dark => Brightness.dark,
              ThemeMode.system => platformBrightness,
            };

            SystemChrome.setSystemUIOverlayStyle(
              _overlayForBrightness(effectiveBrightness),
            );

            return MaterialApp.router(
              title: 'Expressive Music',
              themeMode: themeMode,
              debugShowCheckedModeBanner: false,
              routerConfig: appRouter,
              theme: buildTheme(lightScheme, Brightness.light),
              darkTheme: buildTheme(darkScheme, Brightness.dark),
            );
          },
        );
      },
    );
  }
}
