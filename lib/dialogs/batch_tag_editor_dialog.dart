import 'dart:async';
import 'dart:io';

import 'package:audiotags/audiotags.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../services/local_audio_scanner.dart';
import '../ui/shared/fast_artwork_widget.dart';
import '../utils/song_sort_utils.dart';
import '../utils/tag_write_access.dart';

enum CoverAction { keep, replace, remove }

class BatchTagEditorDialog extends StatefulWidget {
  final List<SongModel> songs;
  final VoidCallback onSaved;
  final ValueChanged<List<SongModel>>? onSongsUpdated;
  final Future<void> Function(Future<void> Function())? runWithPlaybackSuspended;

  const BatchTagEditorDialog({
    super.key,
    required this.songs,
    required this.onSaved,
    this.onSongsUpdated,
    this.runWithPlaybackSuspended,
  });

  @override
  State<BatchTagEditorDialog> createState() => _BatchTagEditorDialogState();
}

class _BatchTagEditorDialogState extends State<BatchTagEditorDialog> {
  late final TextEditingController _albumController;
  late final TextEditingController _albumArtistController;
  late final TextEditingController _artistController;
  late final TextEditingController _yearController;
  late final TextEditingController _genreController;
  late final TextEditingController _trackController;
  late final TextEditingController _titleController;

  bool _applyAlbum = false;
  bool _applyAlbumArtist = false;
  bool _applyArtist = false;
  bool _applyYear = false;
  bool _applyGenre = false;
  bool _applyTrack = false;
  bool _applyTitle = false;

  bool _albumDiffers = false;
  bool _albumArtistDiffers = false;
  bool _artistDiffers = false;
  bool _yearDiffers = false;
  bool _genreDiffers = false;
  bool _trackDiffers = false;
  bool _titleDiffers = false;

  CoverAction _coverAction = CoverAction.keep;
  Uint8List? _newCoverBytes;
  MimeType? _newCoverMime;

  bool _isSaving = false;
  double _saveProgress = 0.0;
  String _saveStatus = '';

  int? _normalizeYear(dynamic value) {
    if (value == null) return null;
    int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is String) {
      parsed = int.tryParse(value.trim());
    }
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  int? _normalizeTrack(dynamic value) {
    if (value == null) return null;
    int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is String) {
      parsed = int.tryParse(value.trim());
    }
    if (parsed == null || parsed <= 0) return null;
    if (parsed >= 1000) {
      final track = parsed % 1000;
      return track > 0 ? track : null;
    }
    return parsed;
  }

  MimeType _detectMimeType(Uint8List bytes, String? name) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return MimeType.jpeg;
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return MimeType.png;
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return MimeType.gif;
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return MimeType.bmp;
    }
    final lower = (name ?? '').toLowerCase();
    if (lower.endsWith('.png')) return MimeType.png;
    if (lower.endsWith('.gif')) return MimeType.gif;
    if (lower.endsWith('.bmp')) return MimeType.bmp;
    if (lower.endsWith('.tif') || lower.endsWith('.tiff')) return MimeType.tiff;
    return MimeType.jpeg;
  }

  @override
  void initState() {
    super.initState();

    final songs = widget.songs;
    final firstSong = songs.isNotEmpty ? songs.first : null;

    // 1. Album
    final firstAlbum = (firstSong?.album ?? '').trim();
    _albumDiffers = songs.any((s) => (s.album ?? '').trim() != firstAlbum);
    _applyAlbum = !_albumDiffers && firstAlbum.isNotEmpty;
    _albumController = TextEditingController(
      text: !_albumDiffers ? firstAlbum : '',
    );

    // 2. Artist
    final firstArtist = (firstSong?.artist ?? '').trim();
    _artistDiffers = songs.any((s) => (s.artist ?? '').trim() != firstArtist);
    _applyArtist = !_artistDiffers && firstArtist.isNotEmpty;
    _artistController = TextEditingController(
      text: !_artistDiffers ? firstArtist : '',
    );

    // 3. Album Artist
    final firstAlbumArtist = (firstSong?.getMap['album_artist'] ??
            firstSong?.getMap['albumArtist'] ??
            '')
        .toString()
        .trim();
    _albumArtistDiffers = songs.any((s) {
      final aa = (s.getMap['album_artist'] ?? s.getMap['albumArtist'] ?? '')
          .toString()
          .trim();
      return aa != firstAlbumArtist;
    });
    _applyAlbumArtist = !_albumArtistDiffers && firstAlbumArtist.isNotEmpty;
    _albumArtistController = TextEditingController(
      text: !_albumArtistDiffers ? firstAlbumArtist : '',
    );

    // 4. Year
    final firstYear = firstSong != null ? _normalizeYear(yearFromSong(firstSong)) : null;
    _yearDiffers = songs.any((s) {
      final y = _normalizeYear(yearFromSong(s));
      return y != firstYear;
    });
    _applyYear = !_yearDiffers && firstYear != null;
    _yearController = TextEditingController(
      text: !_yearDiffers && firstYear != null ? firstYear.toString() : '',
    );

    // 5. Genre
    final firstGenre = (firstSong?.genre ?? '').trim();
    _genreDiffers = songs.any((s) => (s.genre ?? '').trim() != firstGenre);
    _applyGenre = !_genreDiffers && firstGenre.isNotEmpty;
    _genreController = TextEditingController(
      text: !_genreDiffers ? firstGenre : '',
    );

    // 6. Track Number
    final firstTrack = firstSong != null ? _normalizeTrack(firstSong.track ?? firstSong.getMap['track']) : null;
    _trackDiffers = songs.any((s) {
      final t = _normalizeTrack(s.track ?? s.getMap['track']);
      return t != firstTrack;
    });
    _applyTrack = !_trackDiffers && firstTrack != null;
    _trackController = TextEditingController(
      text: !_trackDiffers && firstTrack != null ? firstTrack.toString() : '',
    );

    // 7. Title
    final firstTitle = (firstSong?.title ?? '').trim();
    _titleDiffers = songs.any((s) => s.title.trim() != firstTitle);
    _applyTitle = !_titleDiffers && firstTitle.isNotEmpty;
    _titleController = TextEditingController(
      text: !_titleDiffers ? firstTitle : '',
    );

    _loadExtraTags();
  }

  @override
  void dispose() {
    _albumController.dispose();
    _albumArtistController.dispose();
    _artistController.dispose();
    _yearController.dispose();
    _genreController.dispose();
    _trackController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _loadExtraTags() async {
    if (widget.songs.isEmpty) return;
    try {
      // Read audio tags from the files (sample first 10 files if list is large)
      final sampleCount = widget.songs.length.clamp(1, 15);
      final tags = await Future.wait(
        widget.songs.take(sampleCount).map((s) async {
          try {
            return await AudioTags.read(s.data);
          } catch (_) {
            return null;
          }
        }),
      );

      if (!mounted) return;

      final nonNullTags = tags.whereType<Tag>().toList();
      if (nonNullTags.isEmpty) return;

      setState(() {
        // If album artist wasn't loaded from media store, check audio tags
        if (_albumArtistController.text.isEmpty && !_applyAlbumArtist) {
          final firstAA = (nonNullTags.first.albumArtist ?? '').trim();
          final allMatch = nonNullTags
              .every((t) => (t.albumArtist ?? '').trim() == firstAA);
          if (allMatch && firstAA.isNotEmpty) {
            _albumArtistController.text = firstAA;
            _applyAlbumArtist = true;
            _albumArtistDiffers = false;
          }
        }

        // If year wasn't set or was 0, check audio tags
        if (_yearController.text.isEmpty && !_applyYear) {
          final firstY = _normalizeYear(nonNullTags.first.year);
          final allMatch =
              nonNullTags.every((t) => _normalizeYear(t.year) == firstY);
          if (allMatch && firstY != null) {
            _yearController.text = firstY.toString();
            _applyYear = true;
            _yearDiffers = false;
          }
        }

        // If genre was empty, check audio tags
        if (_genreController.text.isEmpty && !_applyGenre) {
          final firstG = (nonNullTags.first.genre ?? '').trim();
          final allMatch =
              nonNullTags.every((t) => (t.genre ?? '').trim() == firstG);
          if (allMatch && firstG.isNotEmpty) {
            _genreController.text = firstG;
            _applyGenre = true;
            _genreDiffers = false;
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _pickCoverArt() async {
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cover editing not supported on web.')),
      );
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read image file.')),
        );
        return;
      }

      final mime = _detectMimeType(bytes, file.name);
      if (!mounted) return;
      setState(() {
        _newCoverBytes = bytes;
        _newCoverMime = mime;
        _coverAction = CoverAction.replace;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to pick cover image: $e')));
    }
  }

  Future<void> _saveBatch() async {
    if (widget.songs.isEmpty) return;

    // Check write access on the first file
    final ok = await ensureTagWriteAccess(context, widget.songs.first.data);
    if (!ok) return;

    setState(() {
      _isSaving = true;
      _saveProgress = 0.0;
      _saveStatus = 'Starting batch update for ${widget.songs.length} tracks...';
    });

    try {
      final run = widget.runWithPlaybackSuspended;

      Future<void> doBatchSave() async {
        final updatedSongs = <SongModel>[];

        final expectedAlbum = _albumController.text.trim();
        final expectedAlbumArtist = _albumArtistController.text.trim();
        final expectedArtist = _artistController.text.trim();
        final expectedGenre = _genreController.text.trim();
        final expectedYear = _normalizeYear(
          int.tryParse(_yearController.text.trim()),
        );
        final expectedTrack = _normalizeTrack(
          int.tryParse(_trackController.text.trim()),
        );
        final expectedTitle = _titleController.text.trim();

        int failedCount = 0;
        for (int i = 0; i < widget.songs.length; i++) {
          final song = widget.songs[i];
          if (mounted) {
            setState(() {
              _saveProgress = (i + 1) / widget.songs.length;
              _saveStatus =
                  'Updating track ${i + 1} of ${widget.songs.length}...';
            });
          }

          try {
            Tag? existingTag;
            try {
              existingTag = await AudioTags.read(song.data);
            } catch (_) {}

            final finalTitle = _applyTitle
                ? expectedTitle
                : (existingTag?.title ?? song.title);
            final finalArtist = _applyArtist
                ? expectedArtist
                : (existingTag?.trackArtist ?? song.artist ?? '');
            final finalAlbum = _applyAlbum
                ? expectedAlbum
                : (existingTag?.album ?? song.album ?? '');
            final finalAlbumArtist = _applyAlbumArtist
                ? expectedAlbumArtist
                : (existingTag?.albumArtist ?? '');
            final finalGenre = _applyGenre
                ? expectedGenre
                : (existingTag?.genre ?? song.genre ?? '');
            final finalYear = _applyYear
                ? expectedYear
                : (existingTag?.year ??
                    _normalizeYear(yearFromSong(song)));
            final finalTrack = _applyTrack
                ? expectedTrack
                : (existingTag?.trackNumber ??
                    _normalizeTrack(song.track ?? song.getMap['track']));

            var pictures = existingTag?.pictures ?? const <Picture>[];
            if (_coverAction == CoverAction.remove) {
              pictures = pictures
                  .where((p) => p.pictureType != PictureType.coverFront)
                  .toList(growable: true);
            } else if (_coverAction == CoverAction.replace &&
                _newCoverBytes != null &&
                _newCoverBytes!.isNotEmpty) {
              pictures = pictures
                  .where((p) => p.pictureType != PictureType.coverFront)
                  .toList(growable: true);
              pictures.insert(
                0,
                Picture(
                  pictureType: PictureType.coverFront,
                  mimeType:
                      _newCoverMime ?? _detectMimeType(_newCoverBytes!, null),
                  bytes: _newCoverBytes!,
                ),
              );
            }

            final tag = Tag(
              title: finalTitle,
              trackArtist: finalArtist,
              album: finalAlbum,
              albumArtist: finalAlbumArtist,
              year: finalYear,
              genre: finalGenre,
              trackNumber: finalTrack,
              trackTotal: existingTag?.trackTotal,
              discNumber: existingTag?.discNumber,
              discTotal: existingTag?.discTotal,
              lyrics: existingTag?.lyrics,
              duration: existingTag?.duration,
              pictures: pictures,
              bpm: existingTag?.bpm,
            );

            await writeTagsSafelyWithBackup(song.data, tag);

            // Construct updated in-memory SongModel
            final updatedMap = Map<dynamic, dynamic>.from(song.getMap);
            if (_applyTitle) updatedMap['title'] = finalTitle;
            if (_applyArtist) updatedMap['artist'] = finalArtist;
            if (_applyAlbum) updatedMap['album'] = finalAlbum;
            if (_applyAlbumArtist) {
              updatedMap['album_artist'] = finalAlbumArtist;
              updatedMap['albumArtist'] = finalAlbumArtist;
            }
            if (_applyGenre) updatedMap['genre'] = finalGenre;
            if (_applyYear) updatedMap['year'] = finalYear ?? 0;
            if (_applyTrack) updatedMap['track'] = finalTrack ?? 0;

            final updatedSong = SongModel(updatedMap);
            updatedSongs.add(updatedSong);

            LocalAudioScanner.instance.registerSongPath(song.id, song.data);
            if (song.albumId != null && song.albumId! > 0) {
              LocalAudioScanner.instance.registerAlbumRepresentativePath(
                song.albumId!,
                song.data,
              );
            }

            if (_coverAction == CoverAction.remove) {
              evictArtworkCache(song.id);
              if (song.albumId != null && song.albumId! > 0) {
                evictArtworkCache(song.albumId!);
              }
            } else if (_coverAction == CoverAction.replace &&
                _newCoverBytes != null) {
              updateArtworkCache(
                song.id,
                _newCoverBytes!,
                albumId: song.albumId,
              );
            }
          } catch (songErr) {
            debugPrint('Error writing tags for track ${song.data}: $songErr');
            failedCount++;
          }
        }

        // Companion cover write for album folder
        if (_coverAction == CoverAction.replace &&
            _newCoverBytes != null &&
            widget.songs.isNotEmpty) {
          try {
            final parentDir = File(widget.songs.first.data).parent;
            if (parentDir.existsSync()) {
              final companion = File('${parentDir.path}/cover.jpg');
              await companion.writeAsBytes(_newCoverBytes!, flush: true);
            }
          } catch (_) {}
        }

        if (!mounted) return;
        final messenger = ScaffoldMessenger.maybeOf(context);
        Navigator.of(context).pop(true);

        widget.onSongsUpdated?.call(updatedSongs);
        widget.onSaved();

        final msg = failedCount > 0
            ? 'Updated ${updatedSongs.length} tracks ($failedCount failed)'
            : 'Successfully updated ${updatedSongs.length} tracks';
        messenger?.showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: failedCount > 0 ? Colors.orange : Colors.green,
          ),
        );
      }

      if (run != null) {
        await run(doBatchSave);
      } else {
        await doBatchSave();
      }
    } catch (e, st) {
      debugPrint('Error saving batch tags: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error saving tags: $e')));
    }
  }

  Widget _buildFieldRow({
    required String label,
    required TextEditingController controller,
    required bool isChecked,
    required ValueChanged<bool> onCheckedChanged,
    required bool isDiffering,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
  }) {
    final cs = Theme.of(context).colorScheme;

    String? helper;
    if (!isChecked) {
      helper = 'Keeps existing values unchanged';
    } else if (controller.text.trim().isEmpty) {
      helper = 'Will clear this field on all selected tracks';
    } else {
      helper = 'Will apply to all ${widget.songs.length} tracks';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Checkbox(
              value: isChecked,
              onChanged: _isSaving ? null : (val) => onCheckedChanged(val ?? false),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !_isSaving,
              keyboardType: keyboardType,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                labelText: label,
                hintText: isDiffering && !isChecked ? '<unchanged>' : null,
                hintStyle: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                helperText: helper,
                helperStyle: TextStyle(
                  color: isChecked
                      ? cs.primary
                      : cs.onSurfaceVariant.withValues(alpha: 0.6),
                  fontSize: 11,
                ),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (val) {
                if (!isChecked) {
                  onCheckedChanged(true);
                } else {
                  setState(() {});
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final repSong = widget.songs.isNotEmpty ? widget.songs.first : null;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Icon(Icons.tune_rounded, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Batch Tag Editor (${widget.songs.length} tracks)',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  if (!_isSaving)
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                ],
              ),
              const SizedBox(height: 10),

              // Saving progress bar
              if (_isSaving) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      LinearProgressIndicator(value: _saveProgress),
                      const SizedBox(height: 8),
                      Text(
                        _saveStatus,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.primary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
              ],

              // Scrollable content
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: cs.outlineVariant.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 20,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Tags with differing values show as <unchanged>. '
                                'Check a box or edit text to apply that value to all selected tracks.',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Artwork section
                      Text(
                        'Album Artwork',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              width: 72,
                              height: 72,
                              child: _coverAction == CoverAction.remove
                                  ? Container(
                                      color: cs.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.hide_image_rounded,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    )
                                  : _newCoverBytes != null
                                      ? Image.memory(
                                          _newCoverBytes!,
                                          fit: BoxFit.cover,
                                        )
                                      : repSong != null
                                          ? FastArtworkWidget(
                                              id: repSong.id,
                                              type: ArtworkType.AUDIO,
                                              width: 72,
                                              height: 72,
                                              nullArtworkWidget: Container(
                                                color: cs.surfaceContainerHighest,
                                                child: Icon(
                                                  Icons.music_note_rounded,
                                                  color: cs.onSurfaceVariant,
                                                ),
                                              ),
                                            )
                                          : Container(
                                              color: cs.surfaceContainerHighest,
                                              child: Icon(
                                                Icons.album_rounded,
                                                color: cs.onSurfaceVariant,
                                              ),
                                            ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                DropdownButton<CoverAction>(
                                  value: _coverAction,
                                  isExpanded: true,
                                  items: const [
                                    DropdownMenuItem(
                                      value: CoverAction.keep,
                                      child: Text('Keep existing artwork'),
                                    ),
                                    DropdownMenuItem(
                                      value: CoverAction.replace,
                                      child: Text('Choose new artwork'),
                                    ),
                                    DropdownMenuItem(
                                      value: CoverAction.remove,
                                      child: Text('Remove artwork'),
                                    ),
                                  ],
                                  onChanged: _isSaving
                                      ? null
                                      : (val) {
                                          if (val == null) return;
                                          setState(() {
                                            _coverAction = val;
                                            if (val == CoverAction.keep) {
                                              _newCoverBytes = null;
                                              _newCoverMime = null;
                                            }
                                          });
                                          if (val == CoverAction.replace &&
                                              _newCoverBytes == null) {
                                            _pickCoverArt();
                                          }
                                        },
                                ),
                                if (_coverAction == CoverAction.replace)
                                  TextButton.icon(
                                    onPressed: _isSaving ? null : _pickCoverArt,
                                    icon: const Icon(Icons.photo_library_rounded, size: 18),
                                    label: Text(
                                      _newCoverBytes != null
                                          ? 'Change Image'
                                          : 'Select Image',
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      Text(
                        'Metadata Fields',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            ),
                      ),
                      const SizedBox(height: 8),

                      _buildFieldRow(
                        label: 'Album',
                        controller: _albumController,
                        isChecked: _applyAlbum,
                        onCheckedChanged: (v) => setState(() => _applyAlbum = v),
                        isDiffering: _albumDiffers,
                      ),
                      _buildFieldRow(
                        label: 'Album Artist',
                        controller: _albumArtistController,
                        isChecked: _applyAlbumArtist,
                        onCheckedChanged: (v) =>
                            setState(() => _applyAlbumArtist = v),
                        isDiffering: _albumArtistDiffers,
                      ),
                      _buildFieldRow(
                        label: 'Artist',
                        controller: _artistController,
                        isChecked: _applyArtist,
                        onCheckedChanged: (v) => setState(() => _applyArtist = v),
                        isDiffering: _artistDiffers,
                      ),
                      _buildFieldRow(
                        label: 'Year',
                        controller: _yearController,
                        isChecked: _applyYear,
                        onCheckedChanged: (v) => setState(() => _applyYear = v),
                        isDiffering: _yearDiffers,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      ),
                      _buildFieldRow(
                        label: 'Genre',
                        controller: _genreController,
                        isChecked: _applyGenre,
                        onCheckedChanged: (v) => setState(() => _applyGenre = v),
                        isDiffering: _genreDiffers,
                      ),
                      _buildFieldRow(
                        label: 'Track Number',
                        controller: _trackController,
                        isChecked: _applyTrack,
                        onCheckedChanged: (v) => setState(() => _applyTrack = v),
                        isDiffering: _trackDiffers,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      ),
                      _buildFieldRow(
                        label: 'Title',
                        controller: _titleController,
                        isChecked: _applyTitle,
                        onCheckedChanged: (v) => setState(() => _applyTitle = v),
                        isDiffering: _titleDiffers,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSaving
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _isSaving ? null : _saveBatch,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(_isSaving ? 'Saving...' : 'Save to All'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
