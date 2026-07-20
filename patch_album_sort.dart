import 'dart:io';

void main() {
  var file = File('lib/main.dart');
  var content = file.readAsStringSync();
  
  // Quick regex to find the albumSongs.sort block and replace it
  final pattern = RegExp(
    r'albumSongs\.sort\(\(a, b\) \{[^\}]*\}\);', 
    multiLine: true, 
    dotAll: true
  );
  
  final replaceStr = '''albumSongs.sort((a, b) {
      final t = _compareDiscAndTrack(a, b);
      if (t != 0) return t;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });''';

  // Replace content
  // Since there are multiple albumSongs.sort matches possibly, let's just do text replace
  content = content.replaceFirst('''albumSongs.sort((a, b) {
      // MediaStore sometimes encodes disc+track as disc*1000 + track (e.g. 1001).
      // Sort by disc then track for consistent album ordering.
      final aDisc = a.getMap['disc_number'] is int
          ? a.getMap['disc_number'] as int
          : 0;
      final bDisc = b.getMap['disc_number'] is int
          ? b.getMap['disc_number'] as int
          : 0;
      final at = a.track ?? 0;
      final bt = b.track ?? 0;
      final ad = aDisc > 0 ? aDisc : (at >= 1000 ? (at ~/ 1000) : 0);
      final bd = bDisc > 0 ? bDisc : (bt >= 1000 ? (bt ~/ 1000) : 0);
      if (ad != bd) return ad.compareTo(bd);
      final an = at >= 1000 ? (at % 1000) : at;
      final bn = bt >= 1000 ? (bt % 1000) : bt;
      final t = an.compareTo(bn);
      if (t != 0) return t;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });''', replaceStr);
  
  file.writeAsStringSync(content);
}
