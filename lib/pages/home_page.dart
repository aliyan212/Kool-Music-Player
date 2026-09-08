
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_state_controller.dart';
import '../services/playback_controller.dart';
import '../ui/shared/bottom_bars_gutter.dart';
import '../services/playback_controller.dart';
import 'tabs/album_artists_tab.dart';
import 'tabs/albums_tab.dart';
import 'tabs/library_tab.dart';
import 'tabs/playlists_tab.dart';

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, this.initialTabIndex = 0});
  final int initialTabIndex;
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final AppStateController _appState = AppStateController.instance;
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _showSearchInAppBar = ValueNotifier<bool>(false);

  double _bottomBarScrollAccumulator = 0;
  double? _lastScrollPixels;

  @override
  void initState() {
    super.initState();
    _appState.selectedTabIndex = widget.initialTabIndex;
    _appState.ensureLibraryPermissionAndLoad(fromUserAction: false);
    _appState.loadUserPlaylists();
    _appState.addListener(_onAppStateChanged);
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _appState.removeListener(_onAppStateChanged);
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _showSearchInAppBar.dispose();
    super.dispose();
  }

  void _onAppStateChanged() {
    if (mounted) setState(() {});
  }

  void _handleScroll() {
    if (_showSearchInAppBar.value && _scrollController.offset > 50) {
      _showSearchInAppBar.value = false;
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }
  void _setHideBottomBars(bool hide) {
    if (_appState.hideBottomBars == hide) return;
    _appState.hideBottomBars = hide;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _appState.notifyListeners();
    });
  }


  bool _onScrollNotification(ScrollNotification n) {
    if (!mounted) return false;
    if (n.metrics.axis != Axis.vertical) return false;

    if (n.metrics.pixels <= (n.metrics.minScrollExtent + 16)) {
      _bottomBarScrollAccumulator = 0;
      _setHideBottomBars(false);
      return false;
    }

    if (n is ScrollStartNotification) {
      _lastScrollPixels = n.metrics.pixels;
      _bottomBarScrollAccumulator = 0;
      return false;
    }

    if (n is ScrollEndNotification) {
      _bottomBarScrollAccumulator = 0;
      _lastScrollPixels = n.metrics.pixels;
      return false;
    }

    if (n is! ScrollUpdateNotification) return false;

    final delta =
        n.scrollDelta ??
        (_lastScrollPixels == null ? 0 : n.metrics.pixels - _lastScrollPixels!);
    _lastScrollPixels = n.metrics.pixels;

    if (delta.abs() < 0.5) return false;

    if (_bottomBarScrollAccumulator == 0 ||
        (_bottomBarScrollAccumulator > 0) != (delta > 0)) {
      _bottomBarScrollAccumulator = delta;
    } else {
      _bottomBarScrollAccumulator += delta;
    }

    const hideThreshold = 28.0;
    const showThreshold = 20.0;

    if (_bottomBarScrollAccumulator > hideThreshold) {
      _bottomBarScrollAccumulator = 0;
      _setHideBottomBars(true);
    } else if (_bottomBarScrollAccumulator < -showThreshold) {
      _bottomBarScrollAccumulator = 0;
      _setHideBottomBars(false);
    }

    return false;
  }

  Widget _animatedBottomBars() {
    return AnimatedSlide(
      offset: (_appState.hideBottomBars || _appState.isSelectionMode) ? const Offset(0, 1) : Offset.zero,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: (_appState.hideBottomBars || _appState.isSelectionMode) ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        
        child: buildDetailBottomBars(
          context: context,
          player: playbackController.player,
          songs: _appState.songs,
          currentIndex: playbackController.currentIndex,
          playlist: playbackController.currentPlaylist,
          onQueueChanged: (_) {},
          onOpenNowPlaying: (song) => _appState.openNowPlaying(song),
          selectedTabIndex: _appState.selectedTabIndex,
          onNavigateTab: (i) {
            _appState.selectedTabIndex = i;
            _appState.notifyListeners();
          },
        ),

      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_appState.isSelectionMode && _appState.inlineDetailContent == null,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_appState.isSelectionMode) {
          HapticFeedback.selectionClick();
          _appState.exitSelectionMode();
          return;
        }
        if (_appState.inlineDetailContent != null) {
          HapticFeedback.selectionClick();
          _appState.closeInlineDetail();
        }
      },
      child: Scaffold(
        extendBody: true,
        bottomNavigationBar: _animatedBottomBars(),
        body: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: _appState.permissionState != LibraryPermissionState.granted
              ? (_appState.permissionState == LibraryPermissionState.unknown
                    ? const Center(child: CircularProgressIndicator())
                    : _LibraryPermissionGate(
                        state: _appState.permissionState,
                        onGrant: () => _appState.ensureLibraryPermissionAndLoad(
                          fromUserAction: true,
                        ),
                        onOpenSettings: openAppSettings,
                      ))
              : _appState.isLoading
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    Offstage(
                      offstage: _appState.inlineDetailContent != null,
                      child: IndexedStack(
                        index: _appState.selectedTabIndex,
                        children: [
                          KeyedSubtree(
                            key: const PageStorageKey<String>('tab_library'),
                            child: LibraryTab(
                              scrollController: _scrollController,
                              searchController: _appState.searchController,
                              showSearchInAppBar: _showSearchInAppBar,
                            ),
                          ),
                          const KeyedSubtree(
                            key: PageStorageKey<String>('tab_albums'),
                            child: AlbumsTab(),
                          ),
                          const KeyedSubtree(
                            key: PageStorageKey<String>('tab_artists'),
                            child: AlbumArtistsTab(),
                          ),
                          const KeyedSubtree(
                            key: PageStorageKey<String>('tab_playlists'),
                            child: PlaylistsTab(),
                          ),
                        ],
                      ),
                    ),
                    if (_appState.inlineDetailContent != null)
                      _appState.inlineDetailContent!,
                  ],
                ),
        ),
      ),
    );
  }
}

class _LibraryPermissionGate extends StatelessWidget {
  final LibraryPermissionState state;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  const _LibraryPermissionGate({
    required this.state,
    required this.onGrant,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = switch (state) {
      LibraryPermissionState.permanentlyDenied => 'Music access blocked',
      LibraryPermissionState.denied => 'Allow access to your music',
      LibraryPermissionState.unknown => 'Preparing your library',
      LibraryPermissionState.granted => 'Ready',
    };

    final body = switch (state) {
      LibraryPermissionState.permanentlyDenied =>
        'Permission was denied permanently. Open Settings and enable Music/Audio access to scan your library.',
      LibraryPermissionState.denied =>
        'To show your on-device songs, the app needs permission to read your audio library. Nothing is uploaded.',
      LibraryPermissionState.unknown =>
        'We’ll ask for access only when you’re ready.',
      LibraryPermissionState.granted => 'All set!',
    };

    final buttonLabel =
        state == LibraryPermissionState.permanentlyDenied
            ? 'Open Settings'
            : 'Allow Access';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_music, size: 64, color: cs.primary),
            const SizedBox(height: 24),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: cs.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              body,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (state != LibraryPermissionState.unknown)
              FilledButton.icon(
                onPressed:
                    state == LibraryPermissionState.permanentlyDenied
                        ? onOpenSettings
                        : onGrant,
                icon: const Icon(Icons.check),
                label: Text(buttonLabel),
              ),
          ],
        ),
      ),
    );
  }
}
