
import 'package:flutter/material.dart';
import '../main.dart'; // We will refine imports later


class TagEditorDialog extends StatefulWidget {
  final SongModel song;
  final VoidCallback onSaved;
  final Future<void> Function(Future<void> Function())?
  runWithPlaybackSuspended;

  const TagEditorDialog({
    super.key,
    required this.song,
    required this.onSaved,
    this.runWithPlaybackSuspended,
  });

  @override
  State<TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<TagEditorDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;
  late final TextEditingController _albumController;
  late final TextEditingController _albumArtistController;
  late final TextEditingController _yearController;
  late final TextEditingController _genreController;
  late final TextEditingController _trackController;

  bool _isSaving = false;

  Uint8List? _newCoverBytes;
  MimeType? _newCoverMime;
  bool _removeCoverRequested = false;

  bool _matchesString(String? actual, String expected) {
    final expectedTrimmed = expected.trim();
    final actualTrimmed = (actual ?? '').trim();
    if (expectedTrimmed.isEmpty) return actualTrimmed.isEmpty;
    return actualTrimmed == expectedTrimmed;
  }

  bool _matchesInt(int? actual, int? expected) {
    if (expected == null) return actual == null || actual == 0;
    return actual == expected;
  }

  int? _normalizeYear(int? value) {
    if (value == null || value <= 0) return null;
    return value;
  }

  int? _normalizeTrack(int? value) {
    if (value == null || value <= 0) return null;
    if (value >= 1000) {
      final track = value % 1000;
      return track > 0 ? track : null;
    }
    return value;
  }

  bool _matchesTrack(int? actual, int? expected) {
    if (expected == null) return actual == null || actual == 0;
    if (actual == expected) return true;
    if (actual != null && actual >= 1000 && actual % 1000 == expected) {
      return true;
    }
    return false;
  }

  Future<void> _scanMedia(String path) async {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await OnAudioQuery().scanMedia(path);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.song.title);
    _artistController = TextEditingController(text: widget.song.artist ?? '');
    _albumController = TextEditingController(text: widget.song.album ?? '');
    _albumArtistController = TextEditingController();
    _yearController = TextEditingController();
    _genreController = TextEditingController(text: widget.song.genre ?? '');
    _trackController = TextEditingController();

    _loadExtraTags();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _albumArtistController.dispose();
    _yearController.dispose();
    _genreController.dispose();
    _trackController.dispose();
    super.dispose();
  }

  MimeType? _mimeFromFileName(String? name) {
    final lower = (name ?? '').toLowerCase();
    if (lower.endsWith('.png')) return MimeType.png;
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return MimeType.jpeg;
    if (lower.endsWith('.gif')) return MimeType.gif;
    if (lower.endsWith('.bmp')) return MimeType.bmp;
    if (lower.endsWith('.tif') || lower.endsWith('.tiff')) return MimeType.tiff;
    return null;
  }

  Future<void> _pickCoverArt() async {
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cover editing is not supported on web builds.'),
        ),
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
          const SnackBar(
            content: Text('Could not read image bytes. Try a smaller image.'),
          ),
        );
        return;
      }

      final mime = _mimeFromFileName(file.name);
      if (!mounted) return;
      setState(() {
        _newCoverBytes = bytes;
        _newCoverMime = mime;
        _removeCoverRequested = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to pick cover image: $e')));
    }
  }

  Future<void> _loadExtraTags() async {
    try {
      final tag = await AudioTags.read(widget.song.data);
      if (!mounted || tag == null) return;

      setState(() {
        final title = (tag.title ?? '').trim();
        if (title.isNotEmpty) _titleController.text = title;

        final artist = (tag.trackArtist ?? '').trim();
        if (artist.isNotEmpty) _artistController.text = artist;

        final album = (tag.album ?? '').trim();
        if (album.isNotEmpty) _albumController.text = album;

        final genre = (tag.genre ?? '').trim();
        if (genre.isNotEmpty) _genreController.text = genre;

        _albumArtistController.text = (tag.albumArtist ?? '').trim();
        final year = _normalizeYear(tag.year);
        final track = _normalizeTrack(tag.trackNumber);
        _yearController.text = year?.toString() ?? '';
        _trackController.text = track?.toString() ?? '';
      });
    } catch (_) {}
  }

  Future<void> _saveTags() async {
    final ok = await _ensureTagWriteAccess(context, widget.song.data);
    if (!ok) return;

    setState(() => _isSaving = true);
    try {
      final run = widget.runWithPlaybackSuspended;

      Future<void> doSave() async {
        final existingTag = await AudioTags.read(widget.song.data);

        final expectedTitle = _titleController.text.trim();
        final expectedArtist = _artistController.text.trim();
        final expectedAlbum = _albumController.text.trim();
        final expectedAlbumArtist = _albumArtistController.text.trim();
        final expectedGenre = _genreController.text.trim();
        final expectedYear = _normalizeYear(
          int.tryParse(_yearController.text.trim()),
        );
        final expectedTrack = _normalizeTrack(
          int.tryParse(_trackController.text.trim()),
        );

        // Cover art handling: replace/update the front cover picture.
        var pictures = existingTag?.pictures ?? const <Picture>[];
        final newCover = _newCoverBytes;
        final removeCover = _removeCoverRequested;

        if (removeCover || (newCover != null && newCover.isNotEmpty)) {
          pictures = pictures
              .where((p) => p.pictureType != PictureType.coverFront)
              .toList(growable: true);
        }

        if (!removeCover && newCover != null && newCover.isNotEmpty) {
          pictures.insert(
            0,
            Picture(
              pictureType: PictureType.coverFront,
              mimeType: _newCoverMime,
              bytes: newCover,
            ),
          );
        }

        final tag = Tag(
          title: expectedTitle,
          trackArtist: expectedArtist,
          album: expectedAlbum,
          albumArtist: expectedAlbumArtist,
          year: expectedYear,
          genre: expectedGenre,
          trackNumber: expectedTrack,
          trackTotal: existingTag?.trackTotal,
          discNumber: existingTag?.discNumber,
          discTotal: existingTag?.discTotal,
          lyrics: existingTag?.lyrics,
          duration: existingTag?.duration,
          pictures: pictures,
          bpm: existingTag?.bpm,
        );

        await _writeTagsSafelyWithBackup(
          widget.song.data,
          tag,
          verify: () async {
            final verify = await AudioTags.read(widget.song.data);
            final okTitle = _matchesString(verify?.title, expectedTitle);
            final okArtist = _matchesString(
              verify?.trackArtist,
              expectedArtist,
            );
            final okAlbum = _matchesString(verify?.album, expectedAlbum);
            final okAlbumArtist = _matchesString(
              verify?.albumArtist,
              expectedAlbumArtist,
            );
            final okGenre = _matchesString(verify?.genre, expectedGenre);
            final okYear = _matchesInt(verify?.year, expectedYear);
            final okTrack = _matchesTrack(verify?.trackNumber, expectedTrack);

            final coverRequested =
                _newCoverBytes != null && _newCoverBytes!.isNotEmpty;
            final coverRemoved = _removeCoverRequested;
            final verifyPictures = verify?.pictures ?? const <Picture>[];
            final hasCoverFront = verifyPictures.any(
              (p) =>
                  p.pictureType == PictureType.coverFront && p.bytes.isNotEmpty,
            );
            final coverOk =
                (coverRequested ? hasCoverFront : true) &&
                (coverRemoved ? !hasCoverFront : true);

            return okTitle &&
                okArtist &&
                okAlbum &&
                okAlbumArtist &&
                okGenre &&
                okYear &&
                okTrack &&
                coverOk;
          },
        );
      }

      if (run != null) {
        await run(doSave);
      } else {
        await doSave();
      }

      await _scanMedia(widget.song.data).timeout(
        _tagScanTimeout,
        onTimeout: () {
          debugPrint('Timed out scanning media after tag write.');
        },
      );
      if (!mounted) return;

      widget.onSaved();
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tags saved successfully'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save tags: $e'),
          backgroundColor: Colors.red,
          action: SnackBarAction(label: 'Settings', onPressed: openAppSettings),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = cs.surface;
    // Make the header use the same background so the top bar matches the page.
    final headerBgColor = bgColor;
    final textColor = cs.onSurface;
    final textColorSecondary = cs.onSurfaceVariant;
    final textColorTertiary = cs.onSurfaceVariant.withOpacity(0.72);

    return Dialog(
      backgroundColor: bgColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: headerBgColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.edit_rounded, color: textColorSecondary),
                  const SizedBox(width: 12),
                  Text(
                    'Edit Tags',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, color: textColorTertiary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            width: 74,
                            height: 74,
                            color: cs.surfaceContainerHighest,
                            child: _newCoverBytes != null
                                ? Image.memory(
                                    _newCoverBytes!,
                                    fit: BoxFit.cover,
                                  )
                                : QueryArtworkWidget(
                                    id: widget.song.id,
                                    type: ArtworkType.AUDIO,
                                    artworkWidth: 74,
                                    artworkHeight: 74,
                                    keepOldArtwork: true,
                                    artworkFit: BoxFit.cover,
                                    nullArtworkWidget: Icon(
                                      Icons.image_rounded,
                                      color: textColorSecondary,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Cover Art',
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              if (_removeCoverRequested ||
                                  _newCoverBytes != null)
                                Text(
                                  _removeCoverRequested
                                      ? 'Will remove embedded artwork'
                                      : 'New cover selected (will embed into file)',
                                  style: TextStyle(
                                    color: textColorSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              const SizedBox(height: 10),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Wrap(
                                  spacing: 10,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: _isSaving
                                          ? null
                                          : _pickCoverArt,
                                      icon: const Icon(
                                        Icons.photo_library_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Change cover'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: textColorSecondary,
                                        side: BorderSide(
                                          color: cs.outlineVariant,
                                        ),
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: _isSaving
                                          ? null
                                          : () {
                                              setState(() {
                                                _newCoverBytes = null;
                                                _newCoverMime = null;
                                                _removeCoverRequested = true;
                                              });
                                            },
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Remove'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: cs.error,
                                        side: BorderSide(
                                          color: cs.outlineVariant,
                                        ),
                                      ),
                                    ),
                                    if (_removeCoverRequested ||
                                        _newCoverBytes != null)
                                      TextButton(
                                        onPressed: _isSaving
                                            ? null
                                            : () {
                                                setState(() {
                                                  _newCoverBytes = null;
                                                  _newCoverMime = null;
                                                  _removeCoverRequested = false;
                                                });
                                              },
                                        child: const Text('Use embedded'),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _buildTextField(
                      _titleController,
                      'Title',
                      Icons.music_note_rounded,
                      context,
                    ),
                    _buildTextField(
                      _artistController,
                      'Artist',
                      Icons.person_rounded,
                      context,
                    ),
                    _buildTextField(
                      _albumController,
                      'Album',
                      Icons.album_rounded,
                      context,
                    ),
                    _buildTextField(
                      _albumArtistController,
                      'Album Artist',
                      Icons.people_rounded,
                      context,
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: _buildTextField(
                            _yearController,
                            'Year',
                            Icons.calendar_today_rounded,
                            context,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildTextField(
                            _trackController,
                            'Track #',
                            Icons.tag_rounded,
                            context,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    _buildTextField(
                      _genreController,
                      'Genre',
                      Icons.category_rounded,
                      context,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: textColorSecondary,
                        side: BorderSide(color: cs.outlineVariant),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _isSaving ? null : _saveTags,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _isSaving
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: cs.onPrimary,
                              ),
                            )
                          : const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    IconData icon,
    BuildContext context, {
    TextInputType? keyboardType,
  }) {
    final cs = Theme.of(context).colorScheme;
    final textColor = cs.onSurface;
    final labelColor = cs.onSurfaceVariant;
    final iconColor = cs.onSurfaceVariant.withOpacity(0.75);
    final fillColor = cs.surfaceContainerLow;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: TextStyle(color: textColor),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: labelColor),
          prefixIcon: Icon(icon, color: iconColor, size: 20),
          filled: true,
          fillColor: fillColor,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.3)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: cs.primary, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
      ),
    );
  }
}
