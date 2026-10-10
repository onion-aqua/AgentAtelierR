import 'app_localization.dart';

/// A user-selected, stable position shared by normal speech and ASMR.
/// It does not follow character animation, a save, or model-generated text.
enum TtsStereoPosition { center, left, right }

extension TtsStereoPositionLabel on TtsStereoPosition {
  String label(AppLanguage language) => switch (this) {
    TtsStereoPosition.center => language.text('居中', 'Center', '中央'),
    TtsStereoPosition.left => language.text('偏左', 'Left', '左寄り'),
    TtsStereoPosition.right => language.text('偏右', 'Right', '右寄り'),
  };
}

TtsStereoPosition parseTtsStereoPosition(Object? value) =>
    TtsStereoPosition.values.firstWhere(
      (position) => position.name == value,
      orElse: () => TtsStereoPosition.center,
    );
