import 'dart:convert';

class MemoryTimeline {
  static final _summarySeparators = RegExp(r'[\s\p{P}\p{S}]', unicode: true);
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
    if (value.trim().isEmpty) return '';
    final document = decode(value);
    if (document == null) return value;
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
    final today = _dateOnly(now ?? DateTime.now());
    final oldEntries = previous == null
        ? previousMemory.trim().isEmpty
              ? <Map<String, dynamic>>[]
              : _existingEntries({
                  'entries': [
                    {
                      'sequence': 1,
                      'category': 'legacy',
                      'importance': 5,
                      'summary': previousMemory,
                    },
                  ],
                })
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
    final previousLastSequence = nextSequence;
    final result = <int, Map<String, dynamic>>{
      for (final entry in oldEntries)
        entry['sequence'] as int: Map<String, dynamic>.from(entry),
    };
    for (final raw in document['entries'] as List) {
      if (raw is! Map) continue;
      final summary = '${raw['summary'] ?? ''}'.trim();
      if (summary.isEmpty) continue;
      Map<String, dynamic>? previousEntry;
      final sequence = raw['sequence'];
      if (sequence is int) previousEntry = bySequence[sequence];
      previousEntry ??= byId['${raw['id']}'];
      // The saved entry wins over a model rewrite, including after a manual edit.
      if (previousEntry != null) continue;
      // A missing historical sequence marks an entry removed by the user.
      if (sequence is int && sequence > 0 && sequence <= previousLastSequence) {
        continue;
      }
      final normalized = _normalizeEntry(
        raw,
        sequence: nextSequence + 1,
        fallbackDate: today,
        capSummary: true,
      );
      if (normalized == null) continue;
      if (_isDuplicateEvent(result.values, normalized)) continue;
      result[++nextSequence] = normalized;
    }
    final entries = result.values.toList()
      ..sort((a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int));
    return jsonEncode(
      _document(
        entries,
        updatedAt: (now ?? DateTime.now()).toIso8601String(),
        lastSequence: nextSequence,
      ),
    );
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
    final category = '${raw['category'] ?? 'other'}'.trim();
    final rawSummary = '${raw['summary'] ?? ''}';
    if (rawSummary.trim().isEmpty) return null;
    final summary = category == 'legacy' ? rawSummary : rawSummary.trim();
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
      'date': category == 'legacy'
          ? (date == null ? null : _dateOnly(date))
          : (date == null ? fallbackDate : _dateOnly(date)),
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

  static bool _isDuplicateEvent(
    Iterable<Map<String, dynamic>> entries,
    Map<String, dynamic> candidate,
  ) {
    final change = candidate['state_change'];
    if (change is! Map) {
      return entries.any((entry) => _sameEvent(entry, candidate));
    }
    Map<String, dynamic>? latest;
    for (final entry in entries) {
      final previousChange = entry['state_change'];
      if (previousChange is! Map ||
          previousChange['domain'] != change['domain']) {
        continue;
      }
      if (latest == null ||
          (entry['sequence'] as int) > (latest['sequence'] as int)) {
        latest = entry;
      }
    }
    return latest != null && _sameEvent(latest, candidate);
  }

  static bool _sameEvent(
    Map<String, dynamic> existing,
    Map<String, dynamic> candidate,
  ) {
    if (existing['category'] == 'legacy') return false;
    if (existing['date'] != candidate['date']) return false;
    final oldChange = existing['state_change'];
    final newChange = candidate['state_change'];
    if (oldChange is Map || newChange is Map) {
      if (oldChange is! Map || newChange is! Map) return false;
      if (oldChange['domain'] != newChange['domain'] ||
          oldChange['from'] != newChange['from'] ||
          oldChange['to'] != newChange['to']) {
        return false;
      }
    }
    final oldText = _comparableSummary('${existing['summary']}');
    final newText = _comparableSummary('${candidate['summary']}');
    if (oldText == newText) return true;
    final shorter = oldText.length <= newText.length ? oldText : newText;
    final longer = oldText.length > newText.length ? oldText : newText;
    if (shorter.runes.length >= 8 && longer.contains(shorter)) return true;
    if (shorter.runes.length < 8) return false;
    final oldPairs = _characterPairs(oldText);
    final newPairs = _characterPairs(newText);
    final shared = oldPairs.intersection(newPairs).length;
    final similarity = 2 * shared / (oldPairs.length + newPairs.length);
    return similarity >= 0.72;
  }

  static String _comparableSummary(String summary) =>
      summary.toLowerCase().replaceAll(_summarySeparators, '');

  static Set<String> _characterPairs(String text) {
    final runes = text.runes.toList();
    return {
      for (var i = 1; i < runes.length; i++)
        String.fromCharCodes([runes[i - 1], runes[i]]),
    };
  }

  static String _take(String value, int limit) =>
      String.fromCharCodes(value.runes.take(limit));

  static String _dateOnly(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
