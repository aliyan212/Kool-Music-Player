import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../services/playback_controller.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../dialogs/tag_editor_dialog.dart';
import '../dialogs/lyrics_editor_dialog.dart';

Future<void> showSongOptionsSheet({
  required BuildContext context,
  required SongModel song,
  required int index,
  required void Function(int songId) onEnterSelectionMode,
  required void Function(SongModel) onOpenNowPlaying,
  required void Function(SongModel) onOpenAlbum,
  required void Function(SongModel) onOpenArtist,
  required void Function(SongModel) onSongUpdated,
  required Future<void> Function(Future<void> Function() action, {String? targetFilePath}) runWithPlaybackSuspended,
  required Future<void> Function() onPlaySong,
}) async {
  if (!context.mounted) return;
  final hasAlbum = (song.albumId ?? 0) > 0;
  final artistName = (song.artist ?? '').trim();
  final hasArtist =
      artistName.isNotEmpty && artistName.toLowerCase() != 'unknown artist';

  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final sheetBg = cs.surface;
  final sectionLabelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
    color: cs.onSurfaceVariant,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.18,
  );

  Widget sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Text(text, style: sectionLabelStyle),
    );
  }

  AudioSource sourceForSong(SongModel s) {
    final useBackground =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final uri = playbackController.songUri(s);
    final tag = useBackground ? playbackController.toMediaItem(s) : s;
    return AudioSource.uri(uri, tag: tag);
  }

  Future<void> playNext() async {
    if (playbackController.currentPlaylist == null || playbackController.player.currentIndex == null) {
      await onPlaySong();
      return;
    }
    final insertAt = (playbackController.player.currentIndex! + 1).clamp(
      0,
      playbackController.currentPlaylist!.length,
    );
    try {
      await playbackController.currentPlaylist!.insert(insertAt, sourceForSong(song));
      HapticFeedback.selectionClick();
    } catch (_) {
      await onPlaySong();
    }
  }

  Future<void> addToQueue() async {
    if (playbackController.currentPlaylist == null) {
      await onPlaySong();
      return;
    }
    try {
      await playbackController.currentPlaylist!.add(sourceForSong(song));
      HapticFeedback.selectionClick();
    } catch (_) {
      await onPlaySong();
    }
  }

  await showModalBottomSheet(
    context: context,
    showDragHandle: true,
    backgroundColor: sheetBg,
    isScrollControlled: true,
    builder: (ctx) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.78,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Row(
                  children: [
                    ClipOval(
                      child: FastArtworkWidget(
                        id: song.id,
                        type: ArtworkType.AUDIO,
                        width: 52,
                        height: 52,
                        nullArtworkWidget: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.music_note_rounded,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.12,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist ?? 'Unknown Artist',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Divider(
                  height: 1,
                  color: cs.outlineVariant.withOpacity(isDark ? 0.35 : 0.55),
                ),
              ),

              sectionLabel('Selection'),
              ListTile(
                leading: const Icon(Icons.checklist_rounded),
                title: const Text('Select'),
                subtitle: const Text(
                  'Select multiple songs to add to a playlist',
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  HapticFeedback.selectionClick();
                  onEnterSelectionMode(song.id);
                },
              ),

              sectionLabel('Playback'),
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: const Text('Play'),
                subtitle: const Text('Start playing this track'),
                onTap: () {
                  Navigator.pop(ctx);
                  HapticFeedback.selectionClick();
                  onPlaySong();
                },
              ),
              ListTile(
                leading: const Icon(Icons.open_in_full_rounded),
                title: const Text('Open Now Playing'),
                subtitle: const Text('Jump to the player screen'),
                onTap: () {
                  Navigator.pop(ctx);
                  onOpenNowPlaying(song);
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded),
                title: const Text('Play next'),
                subtitle: const Text('Insert after the current track'),
                onTap: () {
                  Navigator.pop(ctx);
                  playNext();
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: const Text('Add to queue'),
                subtitle: const Text('Append to the end of the queue'),
                onTap: () {
                  Navigator.pop(ctx);
                  addToQueue();
                },
              ),

              if (hasAlbum || hasArtist) ...[
                sectionLabel('Library'),
                if (hasAlbum)
                  ListTile(
                    leading: const Icon(Icons.album_rounded),
                    title: const Text('Open album'),
                    subtitle: const Text('View all tracks in this album'),
                    onTap: () {
                      Navigator.pop(ctx);
                      HapticFeedback.selectionClick();
                      onOpenAlbum(song);
                    },
                  ),
                if (hasArtist)
                  ListTile(
                    leading: const Icon(Icons.person_rounded),
                    title: const Text('Open artist'),
                    subtitle: const Text('View albums by this artist'),
                    onTap: () {
                      Navigator.pop(ctx);
                      HapticFeedback.selectionClick();
                      onOpenArtist(song);
                    },
                  ),
              ],

              sectionLabel('Edit'),
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('Edit tags'),
                subtitle: const Text('Title, artist, album, cover art'),
                onTap: () async {
                  Navigator.pop(ctx);
                  HapticFeedback.selectionClick();
                  await showDialog<bool>(
                    context: context,
                    builder: (dctx) => TagEditorDialog(
                      song: song,
                      onSaved: () {},
                      onSongUpdated: onSongUpdated,
                      runWithPlaybackSuspended: (action) =>
                          runWithPlaybackSuspended(
                            action,
                            targetFilePath: song.data,
                          ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.lyrics_rounded),
                title: const Text('Edit lyrics'),
                subtitle: const Text('Paste lyrics or synced LRC'),
                onTap: () async {
                  Navigator.pop(ctx);
                  HapticFeedback.selectionClick();
                  await showDialog<bool>(
                    context: context,
                    builder: (dctx) => LyricsEditorDialog(
                      song: song,
                      currentLyrics: null,
                      onSaved: () {},
                      onLyricsSaved: (_) {},
                      runWithPlaybackSuspended: (action) =>
                          runWithPlaybackSuspended(
                            action,
                            targetFilePath: song.data,
                          ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}
