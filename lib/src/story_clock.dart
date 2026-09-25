class StoryClock {
  StoryClock({
    this.totalMinutes = 9 * 60,
    this.satiety = 80,
    List<String>? settledTurns,
  }) : settledTurns = settledTurns ?? [];

  final int totalMinutes;
  final int satiety;
  final List<String> settledTurns;

  int get day => totalMinutes ~/ 1440 + 1;
  int get hour => (totalMinutes % 1440) ~/ 60;
  int get minute => totalMinutes % 60;
  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  StoryClock? advance(String turn, Map<String, dynamic>? proposal) {
    if (settledTurns.contains(turn)) return null;
    const ranges = <String, (int, int)>{
      'conversation': (1, 6),
      'activity': (5, 90),
      'travel': (10, 180),
      'meal': (10, 60),
      'rest': (15, 120),
      'sleep': (180, 720),
      'time_skip': (1, 1440),
    };
    final raw = proposal?['time_advance'];
    final kind = raw is Map ? raw['kind'] : null;
    final minutes = raw is Map ? raw['minutes'] : null;
    final range = ranges[kind];
    final duration = range != null && minutes is int
        ? minutes.clamp(range.$1, range.$2)
        : 2;
    return advanceMinutes(duration, turn: turn);
  }

  StoryClock advanceMinutes(int minutes, {String? turn, int satietyGain = 0}) {
    final duration = minutes.clamp(0, 1440);
    final nextMinutes = totalMinutes + duration;
    final elapsedHours = nextMinutes ~/ 60 - totalMinutes ~/ 60;
    return StoryClock(
      totalMinutes: nextMinutes,
      satiety: (satiety - elapsedHours * 4 + satietyGain).clamp(0, 100),
      settledTurns: turn == null
          ? settledTurns
          : ([
              ...settledTurns,
              turn,
            ].reversed.take(100).toList().reversed.toList()),
    );
  }

  StoryClock feed(int amount) => StoryClock(
    totalMinutes: totalMinutes,
    satiety: (satiety + amount).clamp(0, 100),
    settledTurns: settledTurns,
  );

  Map<String, dynamic> toJson() => {
    'totalMinutes': totalMinutes,
    'satiety': satiety,
    'settledTurns': settledTurns,
  };

  factory StoryClock.fromJson(Object? raw) {
    if (raw is! Map) return StoryClock();
    final minutes = raw['totalMinutes'];
    final satiety = raw['satiety'];
    if (minutes is! int ||
        minutes < 0 ||
        minutes > 1440 * 36500 ||
        satiety is! int ||
        satiety < 0 ||
        satiety > 100) {
      throw const FormatException('剧情时钟存档格式无效');
    }
    final settled = raw['settledTurns'];
    if (settled != null && settled is! List) {
      throw const FormatException('剧情时钟结算记录格式无效');
    }
    return StoryClock(
      totalMinutes: minutes,
      satiety: satiety,
      settledTurns: settled is List
          ? settled
                .whereType<String>()
                .toList()
                .reversed
                .take(100)
                .toList()
                .reversed
                .toList()
          : [],
    );
  }
}
