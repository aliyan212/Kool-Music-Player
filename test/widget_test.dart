// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:music_player/main.dart' as app;

void main() {
  test('formatTime formats mm:ss', () {
    expect(app.formatTime(null), '0:00');
    expect(app.formatTime(-1), '0:00');
    expect(app.formatTime(0), '0:00');
    expect(app.formatTime(999), '0:00');
    expect(app.formatTime(1_000), '0:01');
    expect(app.formatTime(61_000), '1:01');
    expect(app.formatTime(600_000), '10:00');
  });
}
