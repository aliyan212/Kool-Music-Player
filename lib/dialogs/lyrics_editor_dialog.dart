
import 'package:audiotags/audiotags.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/lyrics.dart';
import '../utils/tag_write_access.dart';


class LyricsEditorDialog extends StatefulWidget {
  final SongModel song;
  final String? currentLyrics;
  final VoidCallback onSaved;
  final void Function(String lyrics)? onLyricsSaved;
  final Future<void> Function(Future<void> Function())?
  runWithPlaybackSuspended;

  const LyricsEditorDialog({
    super.key,
    required this.song,
    this.currentLyrics,
    required this.onSaved,
    this.onLyricsSaved,
    this.runWithPlaybackSuspended,
  });

  @override
  State<LyricsEditorDialog> createState() => _LyricsEditorDialogState();
}

class _LyricsEditorDialogState extends State<LyricsEditorDialog> {
  late final TextEditingController _lyricsController;

  bool _isSaving = false;
  bool _isSynced = false;

  static const int _quickShiftMs = 250;

  @override
  void initState() {
    super.initState();
    _lyricsController = TextEditingController(text: widget.currentLyrics ?? '');
    _isSynced =
        widget.currentLyrics != null &&
        LyricsHelper.isLRC(widget.currentLyrics!);

    if (widget.currentLyrics == null || widget.currentLyrics!.isEmpty) {
      _loadExistingLyrics();
    }
  }

  Future<void> _loadExistingLyrics() async {
    final l = await LyricsHelper.getLyrics(widget.song.data);
    if (l != null && l.isNotEmpty && mounted) {
      setState(() {
        _lyricsController.text = l;
        _isSynced = LyricsHelper.isLRC(l);
      });
    }
  }

  @override
  void dispose() {
    _lyricsController.dispose();
    super.dispose();
  }

  Future<void> _saveLyrics() async {
    final ok = await ensureTagWriteAccess(context, widget.song.data);
    if (!ok) return;

    setState(() => _isSaving = true);
    try {
      final run = widget.runWithPlaybackSuspended;
      final expectedLyrics = _lyricsController.text.trim();

      Future<void> doSave() async {
        await LyricsHelper.saveLyrics(widget.song.data, expectedLyrics);
      }

      if (run != null) {
        await run(doSave);
      } else {
        await doSave();
      }

      if (!mounted) return;
      widget.onLyricsSaved?.call(expectedLyrics);
      widget.onSaved();
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lyrics saved successfully'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save lyrics: $e'),
          backgroundColor: Colors.red,
          action: SnackBarAction(label: 'Settings', onPressed: openAppSettings),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _insertTimestamp() {
    final selection = _lyricsController.selection;
    final text = _lyricsController.text;

    const timestamp = '[00:00.000]';
    final newText = text.replaceRange(
      selection.start,
      selection.end,
      timestamp,
    );

    _lyricsController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: selection.start + timestamp.length,
      ),
    );
    setState(() => _isSynced = true);
  }

  void _shiftTimingsByMs(int offsetMs) {
    if (!_isSynced) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Timing shift works for synced (LRC) lyrics only'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final text = _lyricsController.text;
    final shifted = LyricsHelper.shiftLrcTimings(text, offsetMs);

    _lyricsController.value = _lyricsController.value.copyWith(
      text: shifted,
      selection: TextSelection.collapsed(offset: shifted.length),
      composing: TextRange.empty,
    );

    HapticFeedback.selectionClick();
    setState(() => _isSynced = LyricsHelper.isLRC(shifted));
  }

  Future<void> _showCustomShiftDialog() async {
    if (!_isSynced) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Timing shift works for synced (LRC) lyrics only'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final controller = TextEditingController(text: '0.25');
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final textColorSecondary = isDark ? Colors.white70 : Colors.black54;
    final fillColor = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.04);

    final result = await showDialog<double>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Shift lyric timings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter seconds (can be negative). Example: -0.25',
                style: TextStyle(color: textColorSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                style: TextStyle(color: textColor),
                decoration: InputDecoration(
                  hintText: '0.25',
                  filled: true,
                  fillColor: fillColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final raw = controller.text.trim().replaceAll(',', '.');
                final seconds = double.tryParse(raw);
                Navigator.pop(ctx, seconds);
              },
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );

    if (result == null) return;

    final offsetMs = (result * 1000).round();
    if (offsetMs == 0) return;
    _shiftTimingsByMs(offsetMs);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0.0;

    final bgColor = cs.surface;
    // Use the same background for the header so the top bar matches the page.
    final headerBgColor = bgColor;
    final subHeaderBgColor = cs.surfaceContainerLow;
    final textColor = cs.onSurface;
    final textColorSecondary = cs.onSurfaceVariant;
    final textColorTertiary = cs.onSurfaceVariant.withOpacity(0.72);
    final textAreaBg = cs.surfaceContainerLow;
    final textAreaBorder = cs.outlineVariant.withOpacity(0.45);

    return Dialog.fullscreen(
      backgroundColor: bgColor,
      child: Scaffold(
        backgroundColor: bgColor,
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          backgroundColor: headerBgColor,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: false,
          titleSpacing: 16,
          title: Row(
            children: [
              Icon(Icons.lyrics_rounded, color: textColorSecondary),
              const SizedBox(width: 12),
              Text(
                'Edit Lyrics',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
            ],
          ),
          actions: [
            if (_isSynced)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'SYNCED',
                    style: TextStyle(
                      color: cs.onSecondaryContainer,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            IconButton(
              icon: Icon(Icons.close, color: textColorTertiary),
              onPressed: () => Navigator.pop(context),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: keyboardOpen && !isLandscape ? 6 : 8,
                ),
                color: subHeaderBgColor,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.song.title,
                        style: TextStyle(
                          color: textColorSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton.icon(
                            onPressed: _insertTimestamp,
                            icon: const Icon(Icons.timer_outlined, size: 18),
                            label: const Text('Insert Timestamp'),
                            style: TextButton.styleFrom(
                              foregroundColor: textColorTertiary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Shift -0.25s',
                            onPressed: _isSynced
                                ? () => _shiftTimingsByMs(-_quickShiftMs)
                                : null,
                            icon: Icon(
                              Icons.remove_circle_outline_rounded,
                              color: textColorTertiary,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Shift +0.25s',
                            onPressed: _isSynced
                                ? () => _shiftTimingsByMs(_quickShiftMs)
                                : null,
                            icon: Icon(
                              Icons.add_circle_outline_rounded,
                              color: textColorTertiary,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Custom shift…',
                            onPressed: _isSynced
                                ? _showCustomShiftDialog
                                : null,
                            icon: Icon(
                              Icons.tune_rounded,
                              color: textColorTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: textAreaBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: textAreaBorder),
                  ),
                  child: TextField(
                    controller: _lyricsController,
                    maxLines: null,
                    expands: true,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 15,
                      height: 1.55,
                    ),
                    decoration: InputDecoration(
                      hintText:
                          'Enter lyrics here...\n\nFor synced lyrics, use LRC format:\n[00:12.345]First line\n[00:15.678]Second line',
                      hintStyle: TextStyle(
                        color: textColorTertiary.withOpacity(0.5),
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(16),
                    ),
                    onChanged: (text) {
                      final nowSynced = LyricsHelper.isLRC(text);
                      if (nowSynced != _isSynced) {
                        setState(() => _isSynced = nowSynced);
                      }
                    },
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    keyboardOpen && !isLandscape ? 8 : 12,
                    16,
                    16,
                  ),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          _lyricsController.clear();
                          setState(() => _isSynced = false);
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: cs.error,
                        ),
                        child: const Text('Clear'),
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: textColorSecondary,
                          side: BorderSide(color: cs.outlineVariant),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _isSaving ? null : _saveLyrics,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
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
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
