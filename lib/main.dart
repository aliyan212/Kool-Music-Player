import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:palette_generator/palette_generator.dart';
import 'dart:typed_data';
import 'package:audiotags/audiotags.dart';
import 'dart:math' as math;

void main() {
  runApp(const MyApp());
}

String formatTime(int? milliseconds) {
  if (milliseconds == null || milliseconds < 0) return "0:00";
  int totalSeconds = (milliseconds / 1000).truncate();
  int minutes = (totalSeconds / 60).truncate();
  int seconds = totalSeconds % 60;
  return "$minutes:${seconds.toString().padLeft(2, '0')}";
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Expressive Music',
      themeMode: ThemeMode.dark,
      debugShowCheckedModeBanner: false,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6750A4),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF141218),
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final ScrollController _scrollController = ScrollController();
  final AudioPlayer _player = AudioPlayer();
  final OnAudioQuery _audioQuery = OnAudioQuery();

  List<SongModel> _songs = [];
  bool _isLoading = true;
  ConcatenatingAudioSource? _currentPlaylist;

  @override
  void initState() {
    super.initState();
    requestPermission();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void requestPermission() async {
    await [Permission.audio, Permission.storage].request();
    if (await Permission.manageExternalStorage.request().isGranted) {}
    loadMusic();
  }

  Future<void> loadMusic() async {
    setState(() => _isLoading = true);
    try {

      List<SongModel> rawSongs = await _audioQuery.querySongs(uriType: UriType.EXTERNAL, ignoreCase: true);
      List<AlbumModel> albums = await _audioQuery.queryAlbums();

      final processedSongs = await compute(_processSongsInBackground, _IsolateData(rawSongs, albums));

      _currentPlaylist = ConcatenatingAudioSource(
        children: processedSongs.map((song) {
          return AudioSource.uri(Uri.parse(song.data), tag: song);
        }).toList(),
      );

      setState(() {
        _songs = processedSongs;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Error loading music: $e");
      setState(() => _isLoading = false);
    }
  }

  static List<SongModel> _processSongsInBackground(_IsolateData data) {
    List<SongModel> songs = data.songs;
    final Map<int, AlbumModel> albumMap = {for (var a in data.albums) a.id: a};

    final List<String> excludedFolders = [
      "/WhatsApp Audio/", "/WhatsApp/Media/", "/Telegram/Audio/", "/Recordings/", "/CallRecordings/"
    ];

    songs = songs.where((song) {
      return !excludedFolders.any((folder) => song.data.contains(folder));
    }).toList();

    songs.sort((a, b) {
      AlbumModel? albumA = albumMap[a.albumId];
      AlbumModel? albumB = albumMap[b.albumId];

      String artistA = albumA?.artist ?? a.artist ?? "";
      String artistB = albumB?.artist ?? b.artist ?? "";
      int artistComp = artistA.compareTo(artistB);
      if (artistComp != 0) return artistComp;

      String albumNameA = albumA?.album ?? a.album ?? "";
      String albumNameB = albumB?.album ?? b.album ?? "";
      int albumCompare = albumNameA.compareTo(albumNameB);
      if (albumCompare != 0) return albumCompare;

      return (a.track ?? 0).compareTo(b.track ?? 0);
    });

    return songs;
  }

  Future<void> _playSong(int index) async {
    try {
      if (_player.audioSource != _currentPlaylist) {
        await _player.setAudioSource(_currentPlaylist!, initialIndex: index);
      } else {
        await _player.seek(Duration.zero, index: index);
      }
      _player.play();
    } catch (e) {
      print("Error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: MiniPlayer(
        player: _player,
        songs: _songs,
        onTap: (song) {
          Navigator.push(
            context,
            PageRouteBuilder(
              opaque: false,
              pageBuilder: (_, __, ___) => NowPlayingPage(player: _player, song: song),
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                var tween = Tween(begin: const Offset(0.0, 1.0), end: Offset.zero).chain(CurveTween(curve: Curves.easeOutCubic));
                return SlideTransition(position: animation.drive(tween), child: child);
              },
            ),
          );
        },
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        interactive: true,
        thickness: 8.0,
        radius: const Radius.circular(8),
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverAppBar.large(
              title: const Text("Library"),
              centerTitle: false,
              scrolledUnderElevation: 0,
              actions: [
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    showSearch(
                      context: context,
                      delegate: SongSearchDelegate(
                        songs: _songs,
                        onPlay: (song) {
                          final index = _songs.indexWhere((s) => s.id == song.id);
                          if (index != -1) _playSong(index);
                        },
                      ),
                    );
                  },
                ),
                IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
              ],
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                    (context, index) {
                  final song = _songs[index];
                  return RepaintBoundary(
                    key: ValueKey(song.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            _playSong(index);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: QueryArtworkWidget(
                                    id: song.id,
                                    type: ArtworkType.AUDIO,
                                    artworkWidth: 56,
                                    artworkHeight: 56,
                                    keepOldArtwork: true,
                                    quality: 100,
                                    artworkFit: BoxFit.cover,
                                    nullArtworkWidget: Container(
                                      width: 56, height: 56,
                                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                      child: Icon(Icons.music_note, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          song.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)
                                      ),
                                      Text(
                                          song.artist ?? "Unknown",
                                          maxLines: 1,
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                              color: Theme.of(context).colorScheme.onSurfaceVariant
                                          )
                                      ),
                                      Text(
                                          song.album ?? "Unknown Album",
                                          maxLines: 1,
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7)
                                          )
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  onPressed: () => _playSong(index),
                                  style: IconButton.styleFrom(
                                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  ),
                                )
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
                childCount: _songs.length,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
      ),
    );
  }
}

class _IsolateData {
  final List<SongModel> songs;
  final List<AlbumModel> albums;
  _IsolateData(this.songs, this.albums);
}

class SongSearchDelegate extends SearchDelegate {
  final List<SongModel> songs;
  final Function(SongModel) onPlay;
  SongSearchDelegate({required this.songs, required this.onPlay});
  @override
  ThemeData appBarTheme(BuildContext context) => Theme.of(context);
  @override
  List<Widget>? buildActions(BuildContext context) => [IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')];
  @override
  Widget? buildLeading(BuildContext context) => IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(context, null));
  @override
  Widget buildResults(BuildContext context) => _buildList(context);
  @override
  Widget buildSuggestions(BuildContext context) => _buildList(context);
  Widget _buildList(BuildContext context) {
    final results = songs.where((song) {
      final t = song.title.toLowerCase();
      final a = (song.artist ?? "").toLowerCase();
      final q = query.toLowerCase();
      return t.startsWith(q) || a.startsWith(q);
    }).toList();
    return ListView.builder(itemCount: results.length, itemBuilder: (context, index) {

      final song = results[index];
      return ListTile(leading: QueryArtworkWidget(id: song.id, type: ArtworkType.AUDIO, nullArtworkWidget: const CircleAvatar(child: Icon(Icons.music_note))), title: Text(song.title), subtitle: Text(song.artist ?? "Unknown"), onTap: () { close(context, null); onPlay(song); });
    });
  }
}

class MiniPlayer extends StatelessWidget {
  final AudioPlayer player;
  final List<SongModel> songs;
  final Function(SongModel) onTap;
  const MiniPlayer({super.key, required this.player, required this.songs, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int?>(
      stream: player.currentIndexStream,
      builder: (context, snapshot) {
        //
        final index = snapshot.data;
        if (index == null || songs.isEmpty || index >= songs.length) return const SizedBox.shrink();
        final song = songs[index];
        return MiniPlayerTile(player: player, song: song, onTap: () => onTap(song));
      },
    );
  }
}

class MiniPlayerTile extends StatefulWidget {
  final AudioPlayer player;
  final SongModel song;
  final VoidCallback onTap;
  const MiniPlayerTile({super.key, required this.player, required this.song, required this.onTap});
  @override
  State<MiniPlayerTile> createState() => _MiniPlayerTileState();
}

class _MiniPlayerTileState extends State<MiniPlayerTile> {
  ColorScheme? _colorScheme;
  @override
  void initState() { super.initState(); _updateColor(); }
  @override
  void didUpdateWidget(covariant MiniPlayerTile oldWidget) { super.didUpdateWidget(oldWidget); if (oldWidget.song.id != widget.song.id) _updateColor(); }
  Future<void> _updateColor() async {
    try {
      Uint8List? bytes = await OnAudioQuery().queryArtwork(widget.song.id, ArtworkType.AUDIO, size: 200);
      if (bytes != null) {
        final palette = await PaletteGenerator.fromImageProvider(MemoryImage(bytes), maximumColorCount: 10);
        if (mounted) setState(() => _colorScheme = ColorScheme.fromSeed(seedColor: palette.dominantColor?.color ?? Colors.grey, brightness: Brightness.dark));
      } else { if (mounted) setState(() => _colorScheme = null); }
    } catch (_) {}
  }
  @override
  Widget build(BuildContext context) {
    final scheme = _colorScheme ?? Theme.of(context).colorScheme;
    final luminance = scheme.secondaryContainer.computeLuminance();
    final textColor = luminance > 0.5 ? Colors.black87 : Colors.white;
    final subTextColor = luminance > 0.5 ? Colors.black54 : Colors.white70;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        height: 88, margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))]),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              Positioned(bottom: 0, left: 0, right: 0, child: StreamBuilder<Duration>(stream: widget.player.positionStream, builder: (context, snap) => LinearProgressIndicator(value: ((snap.data?.inMilliseconds ?? 0) / (widget.player.duration?.inMilliseconds ?? 1)).clamp(0.0, 1.0), minHeight: 3, color: textColor.withOpacity(0.8), backgroundColor: Colors.transparent))),
              Row(children: [const SizedBox(width: 12), ClipRRect(borderRadius: BorderRadius.circular(12), child: QueryArtworkWidget(id: widget.song.id, type: ArtworkType.AUDIO, artworkHeight: 56, artworkWidth: 56, keepOldArtwork: true, nullArtworkWidget: Container(width: 56, height: 56, color: Colors.black12, child: Icon(Icons.music_note, color: textColor)))), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [Text(widget.song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.bold, color: textColor, fontSize: 14)), Text(widget.song.artist ?? "Unknown", maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: subTextColor, fontWeight: FontWeight.w500)), Text(widget.song.album ?? "Unknown Album", maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: subTextColor.withOpacity(0.8)))])), IconButton(icon: Icon(Icons.skip_previous_rounded, color: textColor), onPressed: () => widget.player.hasPrevious ? widget.player.seekToPrevious() : null), StreamBuilder<PlayerState>(stream: widget.player.playerStateStream, builder: (context, snap) => IconButton(icon: Icon((snap.data?.playing ?? false) ? Icons.pause_rounded : Icons.play_arrow_rounded, color: textColor, size: 30), onPressed: (snap.data?.playing ?? false) ? widget.player.pause : widget.player.play)), IconButton(icon: Icon(Icons.skip_next_rounded, color: textColor), onPressed: () => widget.player.hasNext ? widget.player.seekToNext() : null), const SizedBox(width: 5)]),
            ],
          ),
        ),
      ),
    );
  }
}

class SquigglySeekBar extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final Function(Duration) onChanged;
  const SquigglySeekBar({super.key, required this.position, required this.duration, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final progress = (position.inMilliseconds / (duration.inMilliseconds == 0 ? 1 : duration.inMilliseconds)).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onHorizontalDragUpdate: (details) {
            final box = context.findRenderObject() as RenderBox;
            final localPos = box.globalToLocal(details.globalPosition);
            onChanged(Duration(milliseconds: ((localPos.dx / box.size.width).clamp(0.0, 1.0) * duration.inMilliseconds).toInt()));
          },
          onTapDown: (details) {
            final box = context.findRenderObject() as RenderBox;
            final localPos = box.globalToLocal(details.globalPosition);
            onChanged(Duration(milliseconds: ((localPos.dx / box.size.width).clamp(0.0, 1.0) * duration.inMilliseconds).toInt()));
          },
          child: SizedBox(
            height: 40, width: double.infinity,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: SquigglePainter(
                  progress: progress,
                  color: Theme.of(context).colorScheme.primary,
                  baseColor: Colors.white24,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class SquigglePainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color baseColor;
  SquigglePainter({required this.progress, required this.color, required this.baseColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 3.0..strokeCap = StrokeCap.round;
    final path = Path();
    final double amplitude = 6.0;
    final double frequency = 0.15;
    final double midHeight = size.height / 2;

    path.moveTo(0, midHeight);
    for (double x = 0; x <= size.width; x += 3) {
      path.lineTo(x, midHeight + amplitude * math.sin(x * frequency));
    }
    paint.color = baseColor;
    canvas.drawPath(path, paint);

    final progressWidth = size.width * progress;
    final progressPath = Path();
    progressPath.moveTo(0, midHeight);
    for (double x = 0; x <= progressWidth; x += 3) {
      progressPath.lineTo(x, midHeight + amplitude * math.sin(x * frequency));
    }
    paint.color = Colors.white;
    canvas.drawPath(progressPath, paint);

    final thumbY = midHeight + amplitude * math.sin(progressWidth * frequency);
    paint.style = PaintingStyle.fill;
    canvas.drawCircle(Offset(progressWidth, thumbY), 8.0, paint);
  }

  @override
  bool shouldRepaint(covariant SquigglePainter oldDelegate) => oldDelegate.progress != progress;
}

class NowPlayingPage extends StatefulWidget {
  final AudioPlayer player;
  final SongModel song;
  const NowPlayingPage({super.key, required this.player, required this.song});
  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  final ScrollController _lyricScrollController = ScrollController();
  ColorScheme? _colorScheme;
  late SongModel _displayedSong;
  bool _showLyrics = false;
  String? _rawLyrics;
  List<LyricLine> _lrcLines = [];
  bool _isSynced = false;
  int _currentLyricIndex = -1;

  @override
  void initState() {
    super.initState();
    _displayedSong = widget.song;
    _loadLyrics();
    Future.delayed(const Duration(milliseconds: 220), () {
      if (mounted) _updatePalette(_displayedSong.id);
    });
    widget.player.sequenceStateStream.listen((state) {
      if (state?.currentSource != null) {
        final newSong = state!.currentSource!.tag as SongModel;
        if (newSong.id != _displayedSong.id) {
          setState(() { _displayedSong = newSong; _showLyrics = false; _currentLyricIndex = -1; });
          _updatePalette(newSong.id);
          _loadLyrics();
        }
      }
    });
  }

  @override
  void dispose() { _lyricScrollController.dispose(); super.dispose(); }

  Future<void> _loadLyrics() async {
    setState(() { _rawLyrics = null; _lrcLines = []; _isSynced = false; _currentLyricIndex = -1; });
    String? lyrics = await LyricsHelper.getEmbeddedLyrics(_displayedSong.data);
    if (lyrics != null && lyrics.isNotEmpty) {
      bool isSynced = LyricsHelper.isLRC(lyrics);
      if (isSynced && mounted) setState(() { _lrcLines = LyricsHelper.parseLRC(lyrics); _isSynced = true; _rawLyrics = lyrics; });
      else if (mounted) setState(() { _rawLyrics = lyrics; _isSynced = false; });
    }
  }

  Future<void> _updatePalette(int songId) async {
    try {
      Uint8List? bytes = await OnAudioQuery().queryArtwork(songId, ArtworkType.AUDIO, size: 500);
      if (bytes == null) {
        if (mounted) setState(() => _colorScheme = null);
        return;
      }
      final palette = await PaletteGenerator.fromImageProvider(MemoryImage(bytes), maximumColorCount: 20);
      final seed = palette.vibrantColor?.color ?? palette.dominantColor?.color ?? Colors.black;
      if (mounted) setState(() => _colorScheme = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark));
    } catch (_) {}
  }

  void _scrollToActiveLine(int index) {
    if (!_lyricScrollController.hasClients) return;
    _lyricScrollController.animateTo(
      index * 50.0,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = _colorScheme ?? Theme.of(context).colorScheme;
    final bgGradient = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [scheme.primaryContainer, scheme.surface], stops: const [0.0, 0.8]);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Dismissible(
        key: const Key('play_screen_dismiss'),
        direction: DismissDirection.down,
        onDismissed: (_) => Navigator.pop(context),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          decoration: BoxDecoration(gradient: bgGradient),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton.filledTonal(icon: const Icon(Icons.keyboard_arrow_down), onPressed: () => Navigator.pop(context), style: IconButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white)),
                      Text("Now Playing", style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Colors.white70)),
                      IconButton.filledTonal(icon: Icon(_showLyrics ? Icons.image_rounded : Icons.lyrics_rounded), onPressed: () => setState(() => _showLyrics = !_showLyrics), style: IconButton.styleFrom(backgroundColor: Colors.white10, foregroundColor: Colors.white)),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _showLyrics = !_showLyrics),
                            child: AnimatedSwitcher(duration: const Duration(milliseconds: 400), child: _showLyrics ? _buildLyricsView() : _buildArtworkView()),
                          ),
                        ),
                        const SizedBox(height: 40),
                        Text(_displayedSong.title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: Colors.white), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Text(_displayedSong.artist ?? "Unknown Artist", style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white70), textAlign: TextAlign.center),
                        Text(_displayedSong.album ?? "Unknown Album", style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white54), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 30),

                        StreamBuilder<Duration>(
                          stream: widget.player.positionStream,
                          builder: (context, snapshot) {
                            final position = snapshot.data ?? Duration.zero;
                            final total = widget.player.duration ?? Duration.zero;
                            return Column(
                              children: [
                                SquigglySeekBar(position: position, duration: total, onChanged: (val) => widget.player.seek(val)),
                                Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(formatTime(position.inMilliseconds), style: const TextStyle(color: Colors.white70)), Text(formatTime(total.inMilliseconds), style: const TextStyle(color: Colors.white70))])),
                              ],
                            );
                          },
                        ),

                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            StreamBuilder<bool>(stream: widget.player.shuffleModeEnabledStream, builder: (context, snapshot) => IconButton(icon: Icon(Icons.shuffle_rounded, color: (snapshot.data ?? false) ? Colors.white : Colors.white38), onPressed: () => widget.player.setShuffleModeEnabled(!(snapshot.data ?? false)))),
                            IconButton(icon: const Icon(Icons.skip_previous_rounded, size: 40, color: Colors.white), onPressed: () => widget.player.hasPrevious ? widget.player.seekToPrevious() : null),
                            StreamBuilder<PlayerState>(stream: widget.player.playerStateStream, builder: (context, snap) => SizedBox(width: 80, height: 80, child: IconButton.filled(icon: Icon((snap.data?.playing ?? false) ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 40), style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black), onPressed: (snap.data?.playing ?? false) ? widget.player.pause : widget.player.play))),
                            IconButton(icon: const Icon(Icons.skip_next_rounded, size: 40, color: Colors.white), onPressed: () => widget.player.hasNext ? widget.player.seekToNext() : null),
                            StreamBuilder<LoopMode>(stream: widget.player.loopModeStream, builder: (context, snapshot) => IconButton(icon: Icon((snapshot.data ?? LoopMode.off) == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded, color: (snapshot.data ?? LoopMode.off) == LoopMode.off ? Colors.white38 : Colors.white), onPressed: () { final modes = {LoopMode.off: LoopMode.all, LoopMode.all: LoopMode.one, LoopMode.one: LoopMode.off}; widget.player.setLoopMode(modes[snapshot.data ?? LoopMode.off]!); })),
                          ],
                        ),
                        const SizedBox(height: 48),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArtworkView() {
    return Hero(tag: 'artwork_${_displayedSong.id}', child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 30, spreadRadius: 5, offset: const Offset(0, 10))]), child: ClipRRect(borderRadius: BorderRadius.circular(24), child: QueryArtworkWidget(id: _displayedSong.id, type: ArtworkType.AUDIO, artworkHeight: 350, artworkWidth: 350, size: 1000, keepOldArtwork: true, artworkFit: BoxFit.cover, nullArtworkWidget: Container(width: 350, height: 350, color: Colors.white10, child: const Icon(Icons.music_note, size: 120, color: Colors.white))))));
  }

  Widget _buildLyricsView() {
    if (_rawLyrics == null) return Container(alignment: Alignment.center, child: const Text("No Lyrics Found", style: TextStyle(color: Colors.white54, fontSize: 18)));

    return LayoutBuilder(
      builder: (context, constraints) {
        return StreamBuilder<Duration>(
          stream: widget.player.positionStream,
          builder: (context, snapshot) {
            final position = snapshot.data ?? Duration.zero;
            int activeIndex = -1;
            for (int i = 0; i < _lrcLines.length; i++) {
              if (_lrcLines[i].time > position) { activeIndex = i - 1; break; }
            }
            if (activeIndex == -1 && _lrcLines.isNotEmpty && position >= _lrcLines.last.time) activeIndex = _lrcLines.length - 1;
            if (activeIndex < 0) activeIndex = 0;

            if (activeIndex != _currentLyricIndex) {
              _currentLyricIndex = activeIndex;
              WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActiveLine(activeIndex));
            }

            return ListView.builder(
              controller: _lyricScrollController,
              itemCount: _lrcLines.length,
              padding: const EdgeInsets.symmetric(vertical: 20),
              itemBuilder: (context, index) {
                bool isActive = index == activeIndex;
                return InkWell(
                  onTap: () => widget.player.seek(_lrcLines[index].time),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12.0),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 300),
                      style: TextStyle(color: isActive ? Colors.white : Colors.white38, fontSize: isActive ? 28 : 18, fontWeight: isActive ? FontWeight.w800 : FontWeight.w500, height: 1.2),
                      child: Text(_lrcLines[index].content, textAlign: TextAlign.center),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class LyricLine {
  final Duration time;
  final String content;
  LyricLine(this.time, this.content);
}

class LyricsHelper {
  static Future<String?> getEmbeddedLyrics(String path) async {
    try { final tag = await AudioTags.read(path); return tag?.lyrics; } catch (e) { return null; }
  }
  static bool isLRC(String lyrics) => lyrics.contains(RegExp(r"\[\d{2}:\d{2}\.\d{2,3}\]"));
  static List<LyricLine> parseLRC(String lrc) {
    List<LyricLine> lines = [];
    final RegExp regex = RegExp(r"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)");
    for (String line in lrc.split('\n')) {
      final match = regex.firstMatch(line);
      if (match != null) lines.add(LyricLine(Duration(minutes: int.parse(match.group(1)!), seconds: int.parse(match.group(2)!), milliseconds: int.parse(match.group(3)!.padRight(3, '0'))), match.group(4)?.trim() ?? ""));
    }
    return lines;
  }
}