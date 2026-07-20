import 'dart:io';

void main() {
  var file = File('lib/main.dart');
  var content = file.readAsStringSync();
  
  // 1. Add _compareDiscAndTrack
  final compareFunction = '''
  int _compareDiscAndTrack(SongModel a, SongModel b) {
    final aDisc = a.getMap['disc_number'] is int ? a.getMap['disc_number'] as int : 0;
    final bDisc = b.getMap['disc_number'] is int ? b.getMap['disc_number'] as int : 0;
    final at = a.track ?? 0;
    final bt = b.track ?? 0;
    final ad = aDisc > 0 ? aDisc : (at >= 1000 ? (at ~/ 1000) : 0);
    final bd = bDisc > 0 ? bDisc : (bt >= 1000 ? (bt ~/ 1000) : 0);
    if (ad != bd) return ad.compareTo(bd);
    final an = at >= 1000 ? (at % 1000) : at;
    final bn = bt >= 1000 ? (bt % 1000) : bt;
    // 0 is usually unknown track, push to end
    final finalAt = an == 0 ? 99999 : an;
    final finalBt = bn == 0 ? 99999 : bn;
    return finalAt.compareTo(finalBt);
  }
''';

  if (!content.contains('_compareDiscAndTrack')) {
    content = content.replaceFirst(
      '  int _trackForCompare(SongModel s) {',
      '  $compareFunction\n  int _trackForCompare(SongModel s) {'
    );
  }

  // 2. Replace _trackForCompare usage
  content = content.replaceAll(
    '_trackForCompare(a).compareTo(_trackForCompare(b))',
    '_compareDiscAndTrack(a, b)'
  );

  // 3. Replace trackForCompare usage (which might be locally defined somewhere)
  content = content.replaceAll(
    'trackForCompare(a).compareTo(trackForCompare(b))',
    '_compareDiscAndTrack(a, b)'
  );

  // 4. Update Songs.sort in Artist page
  content = content.replaceAll('''
      songs.sort((a, b) {
        final t = (a.track ?? 0).compareTo(b.track ?? 0);
        if (t != 0) return t;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });''', '''
      songs.sort((a, b) {
        final t = _compareDiscAndTrack(a, b);
        if (t != 0) return t;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });''');

  // 5. Update the local trackForCompare inside `_getAlbumSongs` or similar to just use _compareDiscAndTrack
  
  file.writeAsStringSync(content);
}
