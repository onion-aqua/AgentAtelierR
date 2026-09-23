import 'dart:convert';

class MemoryTimeline {
  static const entryLimit = 40;
  static const characterLimit = 6000;
  static const protectedCategories = <String>{
    'promise',
    'confession',
    'deep_hurt',
    'relationship_turning_point',
    'major_life_event',
  };

  static Map<String, dynamic>? decode(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> && decoded['entries'] is List
          ? decoded
          : null;
    } on FormatException {
      return null;
    }
  }

  static String normalizeExisting(String value) {
    final document = decode(value);
    if (document == null) return value.trim();
    final entries = _existingEntries(document);
    return jsonEncode(
      _document(
        entries,
        updatedAt: document['updated_at'],
        lastSequence: document['last_sequence'] as int?,
      ),
    );
  }

  static String? normalizeCandidate(
    String candidate, {
    required String previousMemory,
    DateTime? now,
  }) {
    final cleaned = candidate
        .trim()
        .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '');
    final document = decode(cleaned);
    if (document == null) return null;
    final previous = decode(previousMemory);
    final oldEntries = previous == null
        ? <Map<String, dynamic>>[]
        : _existingEntries(previous);
    final bySequence = {
      for (final entry in oldEntries) entry['sequence'] as int: entry,
    };
    final byId = {for (final entry in oldEntries) entry['id'] as String: entry};
    var nextSequence = oldEntries.fold<int>(0, (max, entry) {
      final sequence = entry['sequence'] as int;
      return sequence > max ? sequence : max;
    });
    final previousLast = previous?['last_sequence'];
    if (previousLast is int && previousLast > nextSequence) {
      nextSequence = previousLast;
    }
    final result = <int, Map<String, dynamic>>{};
    final today = _dateOnly(now ?? DateTime.now());

    for (final raw in document['entries'] as List) {
      if (raw is! Map) continue;
      final summary = '${raw['summary'] ?? ''}'.trim();
      if (summary.isEmpty) continue;
      Map<String, dynamic>? previousEntry;
      final sequence = raw['sequence'];
      if (sequence is int) previousEntry = bySequence[sequence];
      previousEntry ??= byId['${raw['id']}'];
      if (previousEntry == null) {
        for (final entry in oldEntries) {
          if (entry['summary'] == summary && entry['date'] == raw['date']) {
            previousEntry = entry;
            break;
          }
        }
      }
      final resolvedSequence =
          previousEntry?['sequence'] as int? ?? ++nextSequence;
      final normalized = _normalizeEntry(
        raw,
        sequence: resolvedSequence,
        fallbackDate: previousEntry?['date'] as String? ?? today,
        capSummary:
            previousEntry == null || previousEntry['summary'] != summary,
      );
      if (normalized == null) continue;
      // Existing transitions are historical facts; a later turn must add a new event.
      if (previousEntry?['state_change'] != null) {
        normalized['state_change'] = previousEntry!['state_change'];
      }
      result[resolvedSequence] = normalized;
    }
    for (final old in oldEntries) {
      final sequence = old['sequence'] as int;
      if (!result.containsKey(sequence) && _isProtected(old)) {
        result[sequence] = Map<String, dynamic>.from(old);
      }
    }
    final entries = result.values.toList()
      ..sort((a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int));
    _limit(entries);
    var output = jsonEncode(
      _document(
        entries,
        updatedAt: (now ?? DateTime.now()).toIso8601String(),
        lastSequence: nextSequence,
      ),
    );
    while (output.length > characterLimit) {
      final removable = _leastValuableIndex(entries);
      if (removable < 0) break;
      entries.removeAt(removable);
      output = jsonEncode(
        _document(
          entries,
          updatedAt: (now ?? DateTime.now()).toIso8601String(),
          lastSequence: nextSequence,
        ),
      );
    }
    return output;
  }

  static Map<String, dynamic> promptDocument(
    String raw,
    List<Map<String, dynamic>> selected,
  ) {
    final document = decode(normalizeExisting(raw));
    final all = (document?['entries'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    selected.sort(
      (a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int),
    );
    return {
      'current_state': document?['current_state'] ?? <String, dynamic>{},
      'rule': '当前情况以 current_state 和最新确认事件为准；status=superseded 的旧状态只用于回忆。',
      'entries': selected,
      if (all.isEmpty) 'note': '暂无长期记忆',
    };
  }

  static String currentStatePrompt(String raw) {
    final document = decode(normalizeExisting(raw));
    final states = document?['current_state'];
    if (states is! Map || states.isEmpty) return '';
    return '【已确认的当前状态】${jsonEncode(states)}。以最新状态回答当下；旧状态只用于回忆。';
  }

  static List<Map<String, dynamic>> _existingEntries(
    Map<String, dynamic> document,
  ) {
    final rawEntries = (document['entries'] as List).whereType<Map>().toList();
    final indexed = <(int, Map)>[
      for (var i = 0; i < rawEntries.length; i++) (i, rawEntries[i]),
    ];
    if (!indexed.any((item) => item.$2['sequence'] is int)) {
      indexed.sort((a, b) {
        final dateOrder = '${a.$2['date'] ?? ''}'.compareTo(
          '${b.$2['date'] ?? ''}',
        );
        return dateOrder != 0 ? dateOrder : a.$1.compareTo(b.$1);
      });
    }
    var next = indexed.fold<int>(0, (max, item) {
      final value = item.$2['sequence'];
      return value is int && value > max ? value : max;
    });
    final used = <int>{};
    final result = <Map<String, dynamic>>[];
    for (final (_, raw) in indexed) {
      var sequence = raw['sequence'];
      if (sequence is! int || sequence < 1 || used.contains(sequence)) {
        sequence = ++next;
      }
      used.add(sequence);
      final entry = _normalizeEntry(
        raw,
        sequence: sequence,
        fallbackDate: _dateOnly(DateTime.now()),
        capSummary: false,
      );
      if (entry != null) result.add(entry);
    }
    result.sort(
      (a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int),
    );
    _document(result, updatedAt: document['updated_at']);
    return result;
  }

  static Map<String, dynamic>? _normalizeEntry(
    Map raw, {
    required int sequence,
    required String fallbackDate,
    required bool capSummary,
  }) {
    final summary = '${raw['summary'] ?? ''}'.trim();
    if (summary.isEmpty) return null;
    final category = '${raw['category'] ?? 'other'}'.trim();
    final baseImportance = ((raw['importance'] as num?)?.toInt() ?? 1).clamp(
      1,
      5,
    );
    final date = DateTime.tryParse('${raw['date'] ?? ''}');
    final stateChange = raw['state_change'];
    Map<String, String>? transition;
    if (stateChange is Map) {
      final domain = '${stateChange['domain'] ?? ''}'.trim();
      final from = '${stateChange['from'] ?? ''}'.trim();
      final to = '${stateChange['to'] ?? ''}'.trim();
      if (domain.isNotEmpty && to.isNotEmpty) {
        transition = {
          'domain': _take(domain, 40),
          'from': _take(from, 60),
          'to': _take(to, 60),
        };
      }
    }
    final importance = transition == null ? baseImportance : 5;
    final quotes =
        (raw['key_quotes'] is List ? raw['key_quotes'] as List : const [])
            .whereType<String>()
            .map((quote) => _take(quote.trim(), 100))
            .where((quote) => quote.isNotEmpty)
            .take(2)
            .toList();
    final entry = <String, dynamic>{
      'sequence': sequence,
      'date': date == null ? fallbackDate : _dateOnly(date),
      'category': category.isEmpty ? 'other' : category,
      'importance': importance,
      'summary': capSummary ? _take(summary, 50) : summary,
      'status': '${raw['status'] ?? 'active'}'.trim().isEmpty
          ? 'active'
          : '${raw['status']}',
      'keywords': (raw['keywords'] is List ? raw['keywords'] as List : const [])
          .whereType<String>()
          .map((word) => _take(word.trim(), 30))
          .where((word) => word.isNotEmpty)
          .take(8)
          .toList(),
    };
    if (transition != null) entry['state_change'] = transition;
    if (quotes.isNotEmpty &&
        (importance >= 4 || protectedCategories.contains(category))) {
      entry['key_quotes'] = quotes;
    }
    return entry;
  }

  static Map<String, dynamic> _document(
    List<Map<String, dynamic>> entries, {
    Object? updatedAt,
    int? lastSequence,
  }) {
    entries.sort(
      (a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int),
    );
    final latestByDomain = <String, Map<String, dynamic>>{};
    for (final entry in entries) {
      final change = entry['state_change'];
      if (change is Map) latestByDomain['${change['domain']}'] = entry;
    }
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      entry['id'] = 'AM${(i + 1).toString().padLeft(4, '0')}';
      final change = entry['state_change'];
      if (change is Map) {
        entry['status'] =
            identical(latestByDomain['${change['domain']}'], entry)
            ? 'active'
            : 'superseded';
      }
    }
    return {
      'updated_at': updatedAt ?? DateTime.now().toIso8601String(),
      'last_sequence': entries.fold<int>(lastSequence ?? 0, (max, entry) {
        final sequence = entry['sequence'] as int;
        return sequence > max ? sequence : max;
      }),
      'current_state': {
        for (final latest in latestByDomain.entries)
          latest.key: {
            'value': (latest.value['state_change'] as Map)['to'],
            'since': latest.value['id'],
          },
      },
      'entries': entries,
    };
  }

  static void _limit(List<Map<String, dynamic>> entries) {
    while (entries.where((entry) => !_isProtected(entry)).length >
        (entryLimit - entries.where(_isProtected).length).clamp(
          0,
          entryLimit,
        )) {
      final index = _leastValuableIndex(entries);
      if (index < 0) break;
      entries.removeAt(index);
    }
  }

  static int _leastValuableIndex(List<Map<String, dynamic>> entries) {
    var result = -1;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (_isProtected(entry)) continue;
      if (result < 0 ||
          (entry['importance'] as int) <
              (entries[result]['importance'] as int) ||
          ((entry['importance'] as int) ==
                  (entries[result]['importance'] as int) &&
              (entry['sequence'] as int) <
                  (entries[result]['sequence'] as int))) {
        result = i;
      }
    }
    return result;
  }

  static bool _isProtected(Map<String, dynamic> entry) =>
      protectedCategories.contains(entry['category']) ||
      (entry['importance'] as int) >= 5 ||
      entry['state_change'] is Map;

  static String _take(String value, int limit) =>
      String.fromCharCodes(value.runes.take(limit));

  static String _dateOnly(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
