import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_motion_layers.dart';

void main() {
  test(
    'unrelated gesture tracks remain active when another group completes',
    () {
      final layers = CharacterMotionLayers();
      final now = DateTime(2026);
      layers.claim(1, 'body', {2}, now.add(const Duration(seconds: 2)));
      expect(layers.canOverlap({6, 7}), isTrue);
      layers.claim(2, 'hands', {6, 7}, now.add(const Duration(seconds: 3)));
      expect(layers.release(1), {2});
      expect(layers.active.single.groupId, 'hands');
      expect(layers.release(2), {6, 7});
      expect(layers.isNotEmpty, isFalse);
    },
  );

  test('replacing one occupied track cannot release the new owner', () {
    final layers = CharacterMotionLayers();
    final now = DateTime(2026);
    layers.claim(1, 'both_hands', {6, 7}, now);
    layers.claim(2, 'left_hand', {6}, now);
    expect(layers.release(1), {7});
    expect(layers.release(2), {6});
    expect(layers.active, isEmpty);
  });
}
