import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';

void main() {
  test('panel stays within floating windows with keyboard and height lock', () {
    for (final size in [
      const Size(280, 240),
      const Size(320, 400),
      const Size(800, 360),
      const Size(400, 800),
    ]) {
      for (final keyboard in [0.0, size.height * .55]) {
        for (final fraction in [.22, .45, .68]) {
          for (final fullscreen in [false, true]) {
            final bounds = conversationPanelBounds(
              viewport: size,
              keyboardInset: keyboard,
              fraction: fraction,
              fullscreen: fullscreen,
            );
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.top, greaterThanOrEqualTo(-.001));
            expect(bounds.right, lessThanOrEqualTo(size.width));
            expect(
              bounds.bottom,
              lessThanOrEqualTo(size.height - keyboard + .001),
            );
          }
        }
      }
    }
  });

  test('resizing back restores normal phone geometry', () {
    Rect layout(Size size) => conversationPanelBounds(
      viewport: size,
      keyboardInset: 0,
      fraction: .45,
    );
    final original = layout(const Size(400, 800));
    final small = layout(const Size(280, 240));
    expect(small.bottom, 232);
    expect(layout(const Size(400, 800)), original);
    expect(original, const Rect.fromLTWH(10, 432, 380, 360));
  });
}
