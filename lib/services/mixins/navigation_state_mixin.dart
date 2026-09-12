import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../../data/models/album_stat.dart';
import '../../main.dart';
import '../../pages/album_page.dart';
import '../../pages/artist_page.dart';
import '../../pages/now_playing_page.dart';
import '../../platform_exit.dart';
import '../../utils/song_sort_utils.dart';
import '../playback_controller.dart';

/// Mixin managing app-wide navigation state, tabs, inline detail pages,
/// and full-screen / dialog transitions (Now Playing, Albums, Artists, Search).
mixin NavigationStateMixin on ChangeNotifier {
  // Dependencies satisfied by AppStateController or companion mixins:
  List<SongModel> get songs;
  void updateSongMetadataInPlace(SongModel updatedSong);

  final SearchController searchController = SearchController();

  late int selectedTabIndex;
  bool nowPlayingRouteActive = false;
  DateTime? _lastNowPlayingClosedAt;

  bool hideBottomBars = false;
  Widget? inlineDetailContent;

  bool isSelectionMode = false;
  final Set<int> selectedSongIds = <int>{};

  BuildContext get context => navigatorKey.currentContext!;

  void selectTab(int index) {
    if (isSelectionMode) exitSelectionMode();
    if (inlineDetailContent != null) {
      inlineDetailContent = null;
    }
    selectedTabIndex = index;
    notifyListeners();
  }

  void showInlineDetail(Widget detailContent) {
    inlineDetailContent = detailContent;
    hideBottomBars = false;
    notifyListeners();
  }

  void closeInlineDetail() {
    if (inlineDetailContent == null) return;
    inlineDetailContent = null;
    notifyListeners();
  }

  void openSearch() {
    if (selectedTabIndex != 0) {
      selectTab(0);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (searchController.isAttached && !searchController.isOpen) {
        searchController.openView();
      }
    });
  }

  void enterSelectionMode({int? initialSongId}) {
    if (searchController.isAttached && searchController.isOpen) {
      searchController.closeView(searchController.text);
      FocusManager.instance.primaryFocus?.unfocus();
    }
    isSelectionMode = true;
    selectedSongIds.clear();
    if (initialSongId != null) selectedSongIds.add(initialSongId);
    notifyListeners();
  }

  void exitSelectionMode() {
    if (!isSelectionMode) return;
    isSelectionMode = false;
    selectedSongIds.clear();
    notifyListeners();
  }

  void toggleSelectedSongId(int songId) {
    if (selectedSongIds.contains(songId)) {
      selectedSongIds.remove(songId);
      if (selectedSongIds.isEmpty) isSelectionMode = false;
    } else {
      selectedSongIds.add(songId);
      isSelectionMode = true;
    }
    notifyListeners();
  }

  void openAboutPage() {
    context.pushNamed('about');
  }

  Future<void> confirmQuit() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;

    final shouldQuit = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Quit app?'),
          content: const Text('This will completely close the app.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: isDark ? cs.errorContainer : cs.error,
                foregroundColor: isDark ? cs.onErrorContainer : cs.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Quit'),
            ),
          ],
        );
      },
    );

    if (shouldQuit == true) {
      await PlatformExit.quit();
    }
  }

  Future<void> openNowPlaying(SongModel song) async {
    if (nowPlayingRouteActive) return;
    final lastClosed = _lastNowPlayingClosedAt;
    if (lastClosed != null &&
        DateTime.now().difference(lastClosed) <
            const Duration(milliseconds: 500)) {
      return;
    }

    nowPlayingRouteActive = true;
    try {
      await Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          barrierDismissible: false,
          barrierColor: Colors.transparent,
          barrierLabel: 'Now Playing',
          transitionDuration: const Duration(milliseconds: 360),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          pageBuilder: (_, _, _) => NowPlayingPage(
            player: playbackController.player,
            song: song,
            songs: songs,
            onQueueChanged: (_) {},
            onOpenAlbum: openAlbumPageFromSong,
            onOpenArtist: openArtistPageFromSong,
            onSongUpdated: updateSongMetadataInPlace,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curve = CurveTween(curve: Curves.fastOutSlowIn);
            final fade = Tween<double>(begin: 0.0, end: 1.0).chain(curve);

            // When returning to the miniplayer (reverse transition / pop),
            // fade out smoothly without sliding down so the gradient doesn't
            // slide down awkwardly while the Hero artwork flies back into place.
            if (animation.status == AnimationStatus.reverse) {
              return FadeTransition(
                opacity: animation.drive(fade),
                child: child,
              );
            }

            final slide = Tween<Offset>(
              begin: const Offset(0.0, 1.0),
              end: Offset.zero,
            ).chain(curve);

            return SlideTransition(
              position: animation.drive(slide),
              child: FadeTransition(
                opacity: animation.drive(fade),
                child: child,
              ),
            );
          },
        ),
      );
    } finally {
      nowPlayingRouteActive = false;
      _lastNowPlayingClosedAt = DateTime.now();
    }
  }

  void openAlbumPageFromSong(SongModel song) {
    final albumId = song.albumId;
    if (albumId == null || albumId <= 0) return;

    final albumTitle = (song.album ?? '').trim().isEmpty
        ? 'Unknown Album'
        : song.album!.trim();
    final albumArtist =
        (song.getMap["album_artist"]?.toString().trim().isNotEmpty ?? false)
            ? song.getMap["album_artist"].toString().trim()
            : ((song.artist ?? '').trim().isEmpty
                ? 'Unknown Artist'
                : song.artist!.trim());

    // Use album identity key to group tracks with the same album artist + album
    // name, even if MediaStore assigned different album IDs (e.g. guest features).
    final targetKey = albumIdentityKey(song);
    final albumSongs = songs
        .where((s) => albumIdentityKey(s) == targetKey)
        .toList();
    albumSongs.sort(compareDiscAndTrack);

    showInlineDetail(
      AlbumPage(
        player: playbackController.player,
        albumId: albumId,
        albumTitle: albumTitle,
        albumArtist: albumArtist,
        songs: albumSongs,
        librarySongs: songs,
        onQueueChanged: (_) {},
        selectedTabIndex: selectedTabIndex,
        onNavigateTab: selectTab,
        embeddedInHome: true,
        onClose: closeInlineDetail,
        onOpenNowPlaying: (s) {
          if (nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          openNowPlaying(s);
        },
        onPlaySong: (s) async {
          final albumIndex = albumSongs.indexWhere((x) => x.id == s.id);
          if (albumIndex == -1) return;
          await playbackController.playFromQueue(albumSongs, initialIndex: albumIndex);
        },
        onShuffle: () async {
          if (albumSongs.isEmpty) return;
          final shuffled = List<SongModel>.from(albumSongs)..shuffle();
          await playbackController.playFromQueue(shuffled, initialIndex: 0);
        },
      ),
    );
  }

  void openArtistPageFromSong(SongModel song) {
    final name = (song.artist ?? '').trim().isEmpty
        ? 'Unknown Artist'
        : song.artist!.trim();
    openArtistPageByName(name);
  }

  void openArtistPageByName(String artistName) {
    final normalizedArtist = artistName.trim();
    if (normalizedArtist.isEmpty) return;

    String norm(String? v) => (v ?? '').trim().toLowerCase();
    final target = norm(normalizedArtist);

    final artistSongs = songs
        .where((s) {
          final a = norm(s.artist);
          final aa = norm(albumArtistFor(s));
          return a == target || aa == target;
        })
        .toList(growable: false);

    if (artistSongs.isEmpty) return;

    // Group into albums by identity key (albumArtist + albumName) instead of
    // raw MediaStore albumId to prevent fragmentation from guest features.
    final Map<String, List<SongModel>> songsByAlbumKey = {};
    for (final s in artistSongs) {
      final key = albumIdentityKey(s);
      (songsByAlbumKey[key] ??= <SongModel>[]).add(s);
    }

    final albums = <ArtistAlbum>[];
    for (final entry in songsByAlbumKey.entries) {
      final songs = entry.value;
      songs.sort(compareDiscAndTrack);

      final title = (songs.first.album ?? '').trim().isEmpty
          ? 'Unknown Album'
          : songs.first.album!.trim();
      int year = 0;
      for (final s in songs) {
        final y = yearFromSong(s);
        if (y > 0 && (year == 0 || y < year)) year = y;
      }

      int totalMs = 0;
      for (final s in songs) {
        totalMs += (s.duration ?? 0);
      }

      // Use the first song's albumId as the representative for artwork lookups.
      final repAlbumId = songs.first.albumId ?? 0;

      albums.add(
        ArtistAlbum(
          albumId: repAlbumId,
          title: title,
          year: year,
          trackCount: songs.length,
          totalDurationMs: totalMs,
          representativeSong: songs.first,
        ),
      );
    }

    // Sort artist's albums chronologically by release year.
    albums.sort((a, b) {
      final ay = a.year == 0 ? 9999 : a.year;
      final by = b.year == 0 ? 9999 : b.year;
      final yc = ay.compareTo(by);
      if (yc != 0) return yc;
      final tc = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (tc != 0) return tc;
      return a.albumId.compareTo(b.albumId);
    });

    // Build album songs lookup by identity key for Play All.
    final albumKeyForAlbum = <int, String>{};
    for (final entry in songsByAlbumKey.entries) {
      final repId = entry.value.first.albumId ?? 0;
      albumKeyForAlbum[repId] = entry.key;
    }

    showInlineDetail(
      ArtistPage(
        player: playbackController.player,
        artistName: normalizedArtist,
        albums: albums,
        librarySongs: songs,
        onQueueChanged: (_) {},
        selectedTabIndex: selectedTabIndex,
        onNavigateTab: selectTab,
        embeddedInHome: true,
        onClose: closeInlineDetail,
        onOpenNowPlaying: (s) {
          if (nowPlayingRouteActive) {
            Navigator.of(context).pop();
            return;
          }
          openNowPlaying(s);
        },
        onOpenAlbum: (s) => openAlbumPageFromSong(s),
        onPlayAll: albums.isEmpty
            ? null
            : () async {
                final queue = <SongModel>[];
                for (final a in albums) {
                  final key = albumKeyForAlbum[a.albumId] ?? '';
                  final list = songsByAlbumKey[key] ?? const <SongModel>[];
                  final sorted = List<SongModel>.from(list);
                  sorted.sort(compareDiscAndTrack);
                  queue.addAll(sorted);
                }
                if (queue.isEmpty) return;
                await playbackController.playFromQueue(queue, initialIndex: 0);
              },
      ),
    );
  }
}
