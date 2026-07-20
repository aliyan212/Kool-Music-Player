import 'dart:io';

void main() {
  var file = File('lib/main.dart');
  var content = file.readAsStringSync();
  
  // We need to inject a track compare inside _processSongsInBackground, roughly where trackForCompare is.
  final localCompare = '''
    int trackForCompare(SongModel s) {
      final t = s.track ?? 0;
      return t == 0 ? 99999 : t;
    }''';
    
  final localCompareReplacement = '''
    int _compareDiscAndTrackLocal(SongModel a, SongModel b) {
      final aDisc = a.getMap['disc_number'] is int ? a.getMap['disc_number'] as int : 0;
      final bDisc = b.getMap['disc_number'] is int ? b.getMap['disc_number'] as int : 0;
      final at = a.track ?? 0;
      final bt = b.track ?? 0;
      
      var ad = aDisc > 0 ? aDisc : (at >= 1000 ? (at ~/ 1000) : 0);
      var bd = bDisc > 0 ? bDisc : (bt >= 1000 ? (bt ~/ 1000) : 0);
      
      if (ad == 0) ad = 1;
      if (bd == 0) bd = 1;
      if (ad != bd) return ad.compareTo(bd);
      
      final an = at >= 1000 ? (at % 1000) : at;
      final bn = bt >= 1000 ? (bt % 1000) : bt;
      
      final finalAt = an == 0 ? 99999 : an;
      final finalBt = bn == 0 ? 99999 : bn;
      return finalAt.compareTo(finalBt);
    }
''';

  content = content.replaceFirst(localCompare, localCompareReplacement);
  
  // And replace the usage inside `songs.sort(` inside the static method
  // Specifically the one above string compare. We can just regex `final trackComp = _compareDiscAndTrack(a, b);`
  // Wait, there are multiple occurrences of `final trackComp = _compareDiscAndTrack(a, b);` in the file.
  // In _processSongsInBackground it is at line ~2224.
  // Wait, we replaced it before. Let's just replace `final trackComp = _compareDiscAndTrack(a, b);` with `final trackComp = _compareDiscAndTrackLocal(a, b);` where it's near `String albumNameA`.
  
  content = content.replaceFirst('final trackComp = _compareDiscAndTrack(a, b);\n      if (trackComp != 0) return trackComp;\n\n      final titleComp = compareSortStrings(a.title, b.title);', 'final trackComp = _compareDiscAndTrackLocal(a, b);\n      if (trackComp != 0) return trackComp;\n\n      final titleComp = compareSortStrings(a.title, b.title);');
  
  file.writeAsStringSync(content);
}
