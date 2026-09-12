// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'package:music_player/utils/song_repair_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music_player/data/models/album_stat.dart';
import 'package:music_player/data/models/sort_mode.dart';
import 'package:music_player/utils/format_utils.dart';
import 'package:music_player/utils/song_sort_utils.dart';
import 'package:music_player/utils/tag_write_access.dart';
import 'package:music_player/data/models/user_playlist.dart';
import 'package:music_player/services/app_state_controller.dart';
import 'package:music_player/services/playback_controller.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('formatTime formats mm:ss', () {
    expect(formatTime(null), '0:00');
    expect(formatTime(-1), '0:00');
    expect(formatTime(0), '0:00');
    expect(formatTime(999), '0:00');
    expect(formatTime(1_000), '0:01');
    expect(formatTime(61_000), '1:01');
    expect(formatTime(600_000), '10:00');
  });

  test('repairSongMetadataMap fills blank values from real tags and display names', () {
    final repaired = repairSongMetadataMap(
      <dynamic, dynamic>{
        'id': 42,
        'title': '',
        'artist': '',
        'album': '',
        'album_artist': '',
        'year': null,
        'track': null,
        '_display_name_wo_ext': 'Track Name',
        '_display_name': 'Track Name.mp3',
        'data': '/storage/emulated/0/Music/Album/Track Name.mp3',
      },
      title: 'Track Name',
      artist: 'Artist Name',
      album: 'Album Name',
      albumArtist: 'Album Artist Name',
      year: 2024,
      track: 7,
    );

    expect(repaired['title'], 'Track Name');
    expect(repaired['artist'], 'Artist Name');
    expect(repaired['album'], 'Album Name');
    expect(repaired['album_artist'], 'Album Artist Name');
    expect(repaired['year'], 2024);
    expect(repaired['track'], 7);

    final filenameFallback = repairSongMetadataMap(
      <dynamic, dynamic>{
        'title': '',
        'artist': 'unknown',
        '_display_name_wo_ext': 'Track Name',
        'data': '/storage/emulated/0/Music/Track Name.mp3',
      },
    );

    expect(filenameFallback['title'], 'Track Name');
    expect(filenameFallback['artist'], 'Unknown Artist');
  });

  test('repairSongMetadataMap preserves valid metadata', () {
    final original = <dynamic, dynamic>{
      'title': 'Already Good',
      'artist': 'Existing Artist',
      'album': 'Existing Album',
      'album_artist': 'Existing Album Artist',
      'year': 1999,
      'track': 12,
    };

    final repaired = repairSongMetadataMap(original, title: 'Replacement');
    expect(repaired['title'], 'Already Good');
    expect(repaired['artist'], 'Existing Artist');
    expect(repaired['year'], 1999);
    expect(repaired['track'], 12);
  });

  test('repairSongMetadataList keeps SongModel objects valid', () async {
    final list = <SongModel>[
      SongModel({
        '_id': 1,
        'title': '',
        'artist': '',
        'album': '',
        'album_artist': '',
        '_data': '/storage/emulated/0/Music/Example Song.mp3',
        '_display_name': 'Example Song.mp3',
        '_display_name_wo_ext': 'Example Song',
        '_size': 1234,
      }),
    ];

    final repaired = await repairSongMetadataList(list, tagTitle: 'Example Song');
    expect(repaired.single.title, 'Example Song');
  });

  test('UserPlaylist.fromJson parses ints, doubles and string songIds and timestamps correctly', () {
    final raw = {
      'id': 'joke_id',
      'name': 'joke',
      'songIds': [64287, 64306.0, '64237'],
      'createdAtMs': 1725785000000.0,
      'updatedAtMs': 1725785000000,
    };

    final playlist = UserPlaylist.fromJson(raw);
    expect(playlist, isNotNull);
    expect(playlist!.id, 'joke_id');
    expect(playlist.name, 'joke');
    expect(playlist.songIds, [64287, 64306, 64237]);
    expect(playlist.createdAtMs, 1725785000000);
    expect(playlist.updatedAtMs, 1725785000000);
  });

  test('AppStateController.selectTab clears inlineDetailContent when switching or reselecting tabs', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final appState = AppStateController.instance;

    // Simulate opening an inline detail (e.g. album) on tab 1
    appState.selectedTabIndex = 1;
    appState.inlineDetailContent = const Text('Album Detail');
    expect(appState.inlineDetailContent, isNotNull);

    // Clicking a different tab should clear inline detail and switch tab
    appState.selectTab(3);
    expect(appState.inlineDetailContent, isNull);
    expect(appState.selectedTabIndex, 3);

    // Simulate opening an inline detail on tab 3, then tapping tab 3 again
    appState.inlineDetailContent = const Text('Playlist Detail');
    expect(appState.inlineDetailContent, isNotNull);
    appState.selectTab(3);
    expect(appState.inlineDetailContent, isNull);
    expect(appState.selectedTabIndex, 3);
  });

  test('AppStateController.openSearch switches to tab 0 and clears inlineDetailContent', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final appState = AppStateController.instance;

    appState.selectedTabIndex = 2;
    appState.inlineDetailContent = const Text('Artist Detail');
    expect(appState.selectedTabIndex, 2);
    expect(appState.inlineDetailContent, isNotNull);

    appState.openSearch();
    expect(appState.selectedTabIndex, 0);
    expect(appState.inlineDetailContent, isNull);
  });

  testWidgets('PageController with keepPage false mounts at correct target page without stale offset', (tester) async {
    int activePage = 1;
    PageController controller = PageController(initialPage: activePage, keepPage: false);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PageView.builder(
          controller: controller,
          itemCount: 5,
          itemBuilder: (context, index) => Text('Page $index'),
        ),
      ),
    );

    expect(find.text('Page 1'), findsOneWidget);
    expect(controller.page?.round(), 1);

    // Unmount PageView and update controller to page 3 (simulating switching views)
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(),
      ),
    );

    controller.dispose();
    activePage = 3;
    controller = PageController(initialPage: activePage, keepPage: false);

    // Mount in a different view (simulating fullscreen view)
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PageView.builder(
          controller: controller,
          itemCount: 5,
          itemBuilder: (context, index) => Text('Page $index'),
        ),
      ),
    );

    expect(find.text('Page 3'), findsOneWidget);
    expect(controller.page?.round(), 3);
  });

  test('PlaybackController maintains currentQueue and in-place metadata updates', () {
    final song1 = SongModel({
      '_id': 101,
      'title': 'Song One',
      'artist': 'Artist A',
      'album': 'Album X',
      '_data': '/storage/emulated/0/Music/song1.mp3',
    });
    final song2 = SongModel({
      '_id': 102,
      'title': 'Song Two',
      'artist': 'Artist B',
      'album': 'Album Y',
      '_data': '/storage/emulated/0/Music/song2.mp3',
    });

    playbackController.songs = [song1, song2];
    playbackController.currentQueue = [song1, song2];

    expect(playbackController.currentQueue.length, 2);
    expect(playbackController.currentQueue.first.title, 'Song One');

    final updatedSong1 = SongModel({
      '_id': 101,
      'title': 'Updated Title',
      'artist': 'Artist A',
      'album': 'Album X',
      '_data': '/storage/emulated/0/Music/song1.mp3',
    });

    AppStateController.instance.songs = [song1, song2];
    AppStateController.instance.updateSongMetadataInPlace(updatedSong1);

    expect(playbackController.songs.first.title, 'Updated Title');
    expect(playbackController.currentQueue.first.title, 'Updated Title');
  });

  test('AppStateController updateSongsMetadataInPlace updates multiple songs and album artist in a single pass', () {
    final song1 = SongModel({
      '_id': 201,
      'title': 'Track 1',
      'artist': 'Old Artist',
      'album': 'Album Alpha',
      '_data': '/storage/emulated/0/Music/track1.mp3',
    });
    final song2 = SongModel({
      '_id': 202,
      'title': 'Track 2',
      'artist': 'Old Artist',
      'album': 'Album Alpha',
      '_data': '/storage/emulated/0/Music/track2.mp3',
    });

    AppStateController.instance.songs = [song1, song2];
    playbackController.songs = [song1, song2];
    playbackController.currentQueue = [song1, song2];

    final updatedSong1 = SongModel({
      '_id': 201,
      'title': 'Track 1',
      'artist': 'New Artist',
      'album': 'Album Alpha',
      'album_artist': 'New Artist',
      '_data': '/storage/emulated/0/Music/track1.mp3',
    });
    final updatedSong2 = SongModel({
      '_id': 202,
      'title': 'Track 2',
      'artist': 'New Artist',
      'album': 'Album Alpha',
      'album_artist': 'New Artist',
      '_data': '/storage/emulated/0/Music/track2.mp3',
    });

    AppStateController.instance.updateSongsMetadataInPlace([updatedSong1, updatedSong2]);

    expect(AppStateController.instance.songs[0].artist, 'New Artist');
    expect(AppStateController.instance.songs[1].artist, 'New Artist');
    expect(playbackController.songs[0].artist, 'New Artist');
    expect(playbackController.songs[1].artist, 'New Artist');
    expect(playbackController.currentQueue[0].artist, 'New Artist');
    expect(playbackController.currentQueue[1].artist, 'New Artist');
    expect(albumArtistFor(AppStateController.instance.songs[0]), 'New Artist');
  });

  test('runWithPlaybackSuspendedForTagWrite executes action directly when file does not match playing song', () async {
    bool executed = false;
    await playbackController.runWithPlaybackSuspendedForTagWrite(
      () async {
        executed = true;
      },
      targetFilePath: '/some/unrelated/path.mp3',
    );
    expect(executed, isTrue);
  });

  test('yearFromSong extracts year directly, from fallback fields, or regex', () {
    final s1 = SongModel({'_id': 1, 'year': 2024});
    expect(yearFromSong(s1), 2024);

    final s2 = SongModel({'_id': 2, 'year': '2019'});
    expect(yearFromSong(s2), 2019);

    final s3 = SongModel({'_id': 3, 'year': 'Recorded in 1985 (Remastered)'});
    expect(yearFromSong(s3), 1985);

    final s4 = SongModel({'_id': 4, 'year': 0, 'date': 2008});
    expect(yearFromSong(s4), 2008);

    final s5 = SongModel({'_id': 5, 'year': null, 'recording_time': '1995'});
    expect(yearFromSong(s5), 1995);

    final s6 = SongModel({'_id': 6, 'year': 0});
    expect(yearFromSong(s6), 0);
  });

  test('writeMp3Id3YearAndId3v1 writes and updates ID3v2 TYER frame and ID3v1 trailer', () async {
    final tempDir = await Directory.systemTemp.createTemp('mp3_test');
    final mp3File = File('${tempDir.path}/test_track.mp3');

    // Build a synthetic MP3 file with ID3v2.3 header, TIT2 frame, and 50 bytes of padding
    final header = [0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40]; // 64 bytes tag body
    final tit2Frame = [
      0x54, 0x49, 0x54, 0x32, // 'TIT2'
      0x00, 0x00, 0x00, 0x05, // size 5
      0x00, 0x00,             // flags
      0x00,                   // enc ISO-8859-1
      0x53, 0x6F, 0x6E, 0x67, // 'Song'
    ];
    final padding = List<int>.filled(64 - tit2Frame.length, 0);
    final audioData = List<int>.filled(128, 0xFF); // Fake MP3 frames

    await mp3File.writeAsBytes([...header, ...tit2Frame, ...padding, ...audioData]);

    // 1. Initial write with year = 2024
    await writeMp3Id3YearAndId3v1(
      path: mp3File.path,
      year: 2024,
      title: 'Song',
      artist: 'Artist',
    );

    var bytes = await mp3File.readAsBytes();

    // Verify TYER frame in ID3v2
    final tyerStart = 10 + tit2Frame.length;
    expect(ascii.decode(bytes.sublist(tyerStart, tyerStart + 4)), 'TYER');
    expect(ascii.decode(bytes.sublist(tyerStart + 11, tyerStart + 15)), '2024');

    // Verify ID3v1 trailer at EOF
    expect(bytes.length >= 128, isTrue);
    final id3v1Trailer = bytes.sublist(bytes.length - 128);
    expect(ascii.decode(id3v1Trailer.sublist(0, 3)), 'TAG');
    expect(ascii.decode(id3v1Trailer.sublist(93, 97)), '2024');

    // 2. Update year to 1999
    await writeMp3Id3YearAndId3v1(
      path: mp3File.path,
      year: 1999,
    );

    bytes = await mp3File.readAsBytes();

    // Verify updated TYER frame in ID3v2
    expect(ascii.decode(bytes.sublist(tyerStart + 11, tyerStart + 15)), '1999');

    // Verify updated ID3v1 trailer
    final updatedTrailer = bytes.sublist(bytes.length - 128);
    expect(ascii.decode(updatedTrailer.sublist(0, 3)), 'TAG');
    expect(ascii.decode(updatedTrailer.sublist(93, 97)), '1999');

    // Cleanup
    await tempDir.delete(recursive: true);
  });

  group('Album Year Determination Algorithm', () {
    test('computeAlbumYearFromYears correctly computes mode and latest-year fallback', () {
      // Empty or all zero
      expect(computeAlbumYearFromYears([]), 0);
      expect(computeAlbumYearFromYears([0, 0, 0]), 0);

      // Single year
      expect(computeAlbumYearFromYears([2014]), 2014);

      // Mode / majority year wins
      expect(computeAlbumYearFromYears([2012, 2015, 2015, 2015, 2020]), 2015);
      expect(computeAlbumYearFromYears([0, 2015, 2015, 2018]), 2015);

      // All distinct: latest year is selected
      expect(computeAlbumYearFromYears([2010, 2019, 2014, 2017]), 2019);

      // Tie in frequency: latest year among the winners is selected
      expect(computeAlbumYearFromYears([2012, 2012, 2018, 2018]), 2018);
    });

    test('computeAlbumYearMap groups songs by albumIdentityKey and computes years', () {
      final s1 = SongModel({
        '_id': 1,
        'title': 'Track 1',
        'artist': 'Artist A',
        'album': 'Greatest Hits',
        'album_artist': 'Artist A',
        'year': 2010,
      });
      final s2 = SongModel({
        '_id': 2,
        'title': 'Track 2',
        'artist': 'Artist A feat. Guest',
        'album': 'Greatest Hits',
        'album_artist': 'Artist A',
        'year': 2010,
      });
      final s3 = SongModel({
        '_id': 3,
        'title': 'Track 3',
        'artist': 'Artist A',
        'album': 'Greatest Hits',
        'album_artist': 'Artist A',
        'year': 2015,
      });
      final s4 = SongModel({
        '_id': 4,
        'title': 'Other Track',
        'artist': 'Artist B',
        'album': 'Debut',
        'year': 2023,
      });

      final map = computeAlbumYearMap([s1, s2, s3, s4]);
      final keyA = albumIdentityKey(s1);
      final keyB = albumIdentityKey(s4);

      // s1, s2, s3 share same album artist & title; two tracks 2010, one 2015 -> mode 2010
      expect(map[keyA], 2010);
      expect(map[keyB], 2023);
    });
  });

  group('Sort Preferences Persistence', () {
    test('loadSavedSortPreferences restores saved SortMode, AlbumsSort, and AlbumArtistsSort', () async {
      SharedPreferences.setMockInitialValues({
        'library_sort_mode_v1': SortMode.year.name,
        'albums_sort_mode_v1': AlbumsSort.yearDesc.name,
        'album_artists_sort_mode_v1': AlbumArtistsSort.mostAlbums.name,
      });

      final appState = AppStateController.instance;
      await appState.loadSavedSortPreferences();

      expect(playbackController.sortMode, SortMode.year);
      expect(appState.albumsSort, AlbumsSort.yearDesc);
      expect(appState.albumArtistsSort, AlbumArtistsSort.mostAlbums);
    });

    test('applySort saves and updates library sort mode', () async {
      final appState = AppStateController.instance;
      await appState.applySort(SortMode.artist);

      expect(playbackController.sortMode, SortMode.artist);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('library_sort_mode_v1'), SortMode.artist.name);
    });

    test('applyAlbumsSort saves and updates albums sort mode', () async {
      final appState = AppStateController.instance;
      await appState.applyAlbumsSort(AlbumsSort.leastTracks);

      expect(appState.albumsSort, AlbumsSort.leastTracks);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('albums_sort_mode_v1'), AlbumsSort.leastTracks.name);
    });

    test('applyAlbumArtistsSort saves and updates album artists sort mode', () async {
      final appState = AppStateController.instance;
      await appState.applyAlbumArtistsSort(AlbumArtistsSort.mostTracks);

      expect(appState.albumArtistsSort, AlbumArtistsSort.mostTracks);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('album_artists_sort_mode_v1'), AlbumArtistsSort.mostTracks.name);
    });
  });
}
