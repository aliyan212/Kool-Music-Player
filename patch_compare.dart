import 'dart:io';

void main() {
  var file = File('lib/main.dart');
  var content = file.readAsStringSync();
  
  final replaceStr = '''
  int _compareDiscAndTrack(SongModel a, SongModel b) {
    final aDisc = a.getMap['disc_number'] is int ? a.getMap['disc_number'] as int : 0;
    final bDisc = b.getMap['disc_number'] is int ? b.getMap['disc_number'] as int : 0;
    final at = a.track ?? 0;
    final bt = b.track ?? 0;
    
    var ad = aDisc > 0 ? aDisc : (at >= 1000 ? (at ~/ 1000) : 0);
    var bd = bDisc > 0 ? bDisc : (bt >= 1000 ? (bt ~/ 1000) : 0);
    
    // Treat missing/0 disc as Disc 1 to align with explicit Disc 1 tags
    if (ad == 0) ad = 1;
    if (bd == 0) bd = 1;

    if (ad != bd) return ad.compareTo(bd);
    
    final an = at >= 1000 ? (at % 1000) : at;
    final bn = bt >= 1000 ? (bt % 1000) : bt;
    
    // 0 is usually unknown track, push to end
    final finalAt = an == 0 ? 99999 : an;
    final finalBt = bn == 0 ? 99999 : bn;
    return finalAt.compareTo(finalBt);
  }
''';

  final pattern = RegExp(
    r'int _compareDiscAndTrack\(SongModel a, SongModel b\) \{[^\}]*\}\n', 
    multiLine: true, 
    dotAll: true
  );

  content = content.replaceFirst(pattern, replaceStr);
  
  file.writeAsStringSync(content);
}
