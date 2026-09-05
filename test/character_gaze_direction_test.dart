import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_gaze.dart';

void main() {
  test(
    'gaze follows all directions relative to face, not off-stage controls',
    () {
      const face = Offset(0, -1330);
      final left = gazeControlOffset(
        face: face,
        pointer: face + const Offset(-600, 0),
      );
      final right = gazeControlOffset(
        face: face,
        pointer: face + const Offset(600, 0),
      );
      final up = gazeControlOffset(
        face: face,
        pointer: face + const Offset(0, -600),
      );
      final down = gazeControlOffset(
        face: face,
        pointer: face + const Offset(0, 600),
      );
      expect(left.dx, -140);
      expect(right.dx, 140);
      expect(up.dy, -140);
      expect(down.dy, 140);
      expect(gazeControlOffset(face: face, pointer: face), Offset.zero);
      expect(
        gazeControlOffset(face: face, pointer: face + const Offset(50, 0)).dx,
        lessThan(right.dx),
      );
    },
  );

  test('gaze is independent of rig origin and stays bounded diagonally', () {
    const shift = Offset(-1500, 720);
    const face = Offset(0, -1330);
    const pointer = Offset(1000, -2000);
    final a = gazeControlOffset(face: face, pointer: pointer);
    final b = gazeControlOffset(face: face + shift, pointer: pointer + shift);
    expect((a - b).distance, lessThan(0.0001));
    expect(a.distance, closeTo(140, 0.0001));
  });
}
