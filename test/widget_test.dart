// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'package:music_player/utils/song_repair_utils.dart';
import 'package:music_player/utils/format_utils.dart';
import 'package:music_player/data/models/user_playlist.dart';
import 'package:music_player/services/app_state_controller.dart';

void main() {
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
}
