import 'app_localization.dart';

class CharacterState {
  CharacterState({
    Map<String, int>? values,
    Map<String, int>? bands,
    this.emotion = 'neutral',
    this.reason = '',
    this.updatedAt,
    Map<String, int>? delta,
    List<String>? settled,
  }) : values =
           values ??
           {'mood': 0, 'energy': 65, 'closeness': 40, 'curiosity': 50},
       bands =
           bands ?? {'mood': 1, 'energy': 1, 'closeness': 1, 'curiosity': 1},
       delta = delta ?? {},
       settled = settled ?? [];

  /// The initial relationship state for a newly created local save.
  ///
  /// Keep this separate from [CharacterState]'s legacy runtime defaults so
  /// existing installations and state-delta tests retain their behavior.
  factory CharacterState.newSave() => CharacterState(
    values: const {'mood': 0, 'energy': 100, 'closeness': 0, 'curiosity': 20},
  );

  final Map<String, int> values;
  final Map<String, int> bands;
  final Map<String, int> delta;
  final List<String> settled;
  final String emotion;
  final String reason;
  final DateTime? updatedAt;
  static const emotions = {
    'neutral',
    'happy',
    'curious',
    'shy',
    'sad',
    'angry',
    'worried',
    'excited',
  };

  CharacterState apply(String turn, Map<String, dynamic> proposal) {
    if (settled.contains(turn)) return this;
    final raw = proposal['state_delta'];
    final why = proposal['reason'];
    if (raw is! Map ||
        why is! String ||
        why.trim().isEmpty ||
        why.length > 240) {
      return this;
    }
    if (raw.keys.any((key) => !values.containsKey(key)) ||
        raw.values.any((v) => v is! int)) {
      return this;
    }
    final next = Map<String, int>.from(values);
    final changes = <String, int>{};
    final nextBands = Map<String, int>.from(bands);
    for (final key in values.keys) {
      final limit = key == 'closeness' ? 2 : 5;
      next[key] =
          (values[key]! + ((raw[key] as int?) ?? 0).clamp(-limit, limit)).clamp(
            key == 'mood' ? -100 : 0,
            100,
          );
      changes[key] = next[key]! - values[key]!;
      final lower = key == 'mood' ? -25 : 30;
      final upper = key == 'mood' ? 25 : 70;
      var band = bands[key] ?? 1;
      final value = next[key]!;
      if (band == 0 && value >= lower + 5) band = 1;
      if (band == 2 && value <= upper - 5) band = 1;
      if (band == 1 && value < lower - 5) band = 0;
      if (band == 1 && value > upper + 5) band = 2;
      nextBands[key] = band;
    }
    return CharacterState(
      values: next,
      bands: nextBands,
      delta: changes,
      emotion: emotions.contains(proposal['emotion'])
          ? proposal['emotion'] as String
          : emotion,
      reason: why.trim(),
      updatedAt: DateTime.now(),
      settled: [...settled, turn].reversed.take(100).toList().reversed.toList(),
    );
  }

  CharacterState applyItemEffect({
    required Map<String, int> changes,
    required String reason,
    bool resetNegativeStats = false,
  }) {
    final next = Map<String, int>.from(values);
    final applied = <String, int>{};
    final nextBands = Map<String, int>.from(bands);
    for (final key in values.keys) {
      final previous = values[key]!;
      final change = changes[key] ?? 0;
      final adjusted = resetNegativeStats && previous < 0
          ? 0
          : previous + change;
      next[key] = change == 0 && !resetNegativeStats
          ? previous
          : adjusted.clamp(change < 0 ? 0 : (key == 'mood' ? -100 : 0), 100);
      applied[key] = next[key]! - previous;
      final lower = key == 'mood' ? -25 : 30;
      final upper = key == 'mood' ? 25 : 70;
      var band = bands[key] ?? 1;
      final value = next[key]!;
      if (band == 0 && value >= lower + 5) band = 1;
      if (band == 2 && value <= upper - 5) band = 1;
      if (band == 1 && value < lower - 5) band = 0;
      if (band == 1 && value > upper + 5) band = 2;
      nextBands[key] = band;
    }
    return CharacterState(
      values: next,
      bands: nextBands,
      delta: applied,
      emotion: emotion,
      reason: reason,
      updatedAt: DateTime.now(),
      settled: settled,
    );
  }

  String summary(AppLanguage language) => values.keys
      .map((key) {
        final label = switch (key) {
          'mood' => language.text('心情', 'Mood', '気分'),
          'energy' => language.text('精力', 'Energy', '元気'),
          'closeness' => language.text('亲近感', 'Closeness', '親しみ'),
          _ => language.text('好奇心', 'Curiosity', '好奇心'),
        };
        final labels = switch (key) {
          'mood' => [
            language.text('低落', 'Low', '落ち込み'),
            language.text('平静', 'Calm', '平静'),
            language.text('愉快', 'Cheerful', '楽しい'),
          ],
          'energy' => [
            language.text('疲惫', 'Tired', '疲れ'),
            language.text('正常', 'Normal', '普通'),
            language.text('充沛', 'Energetic', '元気'),
          ],
          'closeness' => [
            language.text('疏离', 'Distant', '距離感'),
            language.text('熟悉', 'Familiar', '馴染み'),
            language.text('亲近', 'Close', '親密'),
          ],
          _ => [
            language.text('兴致不高', 'Uninterested', '関心薄い'),
            language.text('关注', 'Attentive', '関心あり'),
            language.text('兴奋', 'Intrigued', '興味津々'),
          ],
        };
        final change = delta[key] ?? 0;
        return '$label：${labels[bands[key] ?? 1]} ${values[key]}${change == 0 ? '' : ' (${change > 0 ? '+' : ''}$change)'}';
      })
      .join('\n');

  Map<String, dynamic> toJson() => {
    'values': values,
    'bands': bands,
    'delta': delta,
    'emotion': emotion,
    'reason': reason,
    'updatedAt': updatedAt?.toIso8601String(),
    'settled': settled,
  };
  factory CharacterState.fromJson(dynamic raw) {
    final defaults = CharacterState();
    if (raw is! Map) return defaults;
    Map<String, int> read(String field, Map<String, int> fallback) => {
      for (final key in defaults.values.keys)
        key: raw[field] is Map && raw[field][key] is int
            ? (raw[field][key] as int).clamp(
                field == 'bands'
                    ? 0
                    : (key == 'mood' || field == 'delta' ? -100 : 0),
                field == 'bands' ? 2 : 100,
              )
            : fallback[key] ?? 0,
    };
    return CharacterState(
      values: read('values', defaults.values),
      bands: read('bands', defaults.bands),
      delta: read('delta', {}),
      emotion: emotions.contains(raw['emotion'])
          ? raw['emotion'] as String
          : 'neutral',
      reason: raw['reason'] is String
          ? (raw['reason'] as String).substring(
              0,
              (raw['reason'] as String).length.clamp(0, 240),
            )
          : '',
      updatedAt: DateTime.tryParse(raw['updatedAt']?.toString() ?? ''),
      settled: raw['settled'] is List
          ? (raw['settled'] as List).whereType<String>().take(100).toList()
          : [],
    );
  }
}
