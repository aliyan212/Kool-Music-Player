import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../utils/format_utils.dart';
import '../ui/shared/fast_artwork_widget.dart';


class SongSearchDelegate extends SearchDelegate {
  final List<SongModel> songs;
  final void Function(SongModel) onPlay;

  SongSearchDelegate({
    required this.songs,
    required this.onPlay,
  });

  @override
  ThemeData appBarTheme(BuildContext context) => Theme.of(context);

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () => query = '',
      ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _buildList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildList(context);

  Widget _buildList(BuildContext context) {
    final q = query.trim().toLowerCase();

    final results = songs.where((song) {
      final title = song.title.toLowerCase();
      final artist = (song.artist ?? '').toLowerCase();
      return title.startsWith(q) || artist.startsWith(q);
    }).toList(growable: false);

    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final song = results[index];
        final artist = (song.artist ?? '').trim().isEmpty
            ? 'Unknown Artist'
            : song.artist!.trim();
        final album = (song.album ?? '').trim().isEmpty
            ? 'Unknown Album'
            : song.album!.trim();
        final duration = song.duration == null
            ? null
            : formatTime(song.duration);
        final subtitle = duration == null
            ? '$artist • $album'
            : '$artist • $album • $duration';
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: FastArtworkWidget(
              id: song.id,
              type: ArtworkType.AUDIO,
              width: 40,
              height: 40,
              keepOldArtwork: true,
              artworkFit: BoxFit.cover,
              nullArtworkWidget: Container(
                width: 40,
                height: 40,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.music_note,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          title: Text(song.title),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            HapticFeedback.selectionClick();
            close(context, null);
            onPlay(song);
          },
        );
      },
    );
  }
}
