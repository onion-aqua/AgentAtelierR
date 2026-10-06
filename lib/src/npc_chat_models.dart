import 'dart:math' as math;

enum NpcChatRole { user, assistant }

enum NpcChatStatus { completed, interrupted, failed }

/// Persisted messages contain visible text, never service credentials.
class NpcChatMessage {
  NpcChatMessage({
    required String id,
    required this.role,
    required String text,
    required DateTime createdAt,
    this.status = NpcChatStatus.completed,
    String? translatedText,
  }) : id = _identifier(id, 'message id'),
       text = _messageText(text, allowEmpty: status != NpcChatStatus.completed),
       createdAt = createdAt.toUtc(),
       translatedText = translatedText == null
           ? null
           : _messageText(translatedText, allowEmpty: true);

  final String id;
  final NpcChatRole role;
  final String text;
  final DateTime createdAt;
  final NpcChatStatus status;
  final String? translatedText;

  NpcChatMessage copyWith({
    String? text,
    NpcChatStatus? status,
    String? translatedText,
    bool clearTranslation = false,
  }) => NpcChatMessage(
    id: id,
    role: role,
    text: text ?? this.text,
    createdAt: createdAt,
    status: status ?? this.status,
    translatedText: clearTranslation
        ? null
        : translatedText ?? this.translatedText,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.name,
    'text': text,
    'created_at': createdAt.toIso8601String(),
    'status': status.name,
    if (translatedText != null) 'translated_text': translatedText,
  };

  factory NpcChatMessage.fromJson(Object? value) {
    final json = _jsonObject(value, 'message');
    _checkKeys(
      json,
      const {'id', 'role', 'text', 'created_at', 'status', 'translated_text'},
      const {'id', 'role', 'text', 'created_at', 'status'},
    );
    final role = NpcChatRole.values
        .where((item) => item.name == json['role'])
        .firstOrNull;
    final status = NpcChatStatus.values
        .where((item) => item.name == json['status'])
        .firstOrNull;
    if (role == null || status == null) {
      throw const FormatException('Invalid NPC message role or status');
    }
    return NpcChatMessage(
      id: _jsonString(json['id'], 'message id'),
      role: role,
      text: _jsonString(json['text'], 'message text'),
      createdAt: _timestamp(json['created_at']),
      status: status,
      translatedText: json['translated_text'] == null
          ? null
          : _jsonString(json['translated_text'], 'message translation'),
    );
  }
}

class NpcChatThread {
  NpcChatThread({
    required String npcId,
    List<NpcChatMessage> messages = const [],
  }) : npcId = _identifier(npcId, 'NPC id'),
       messages = List<NpcChatMessage>.unmodifiable(messages) {
    final ids = <String>{};
    for (final message in messages) {
      if (!ids.add(message.id)) {
        throw const FormatException('Duplicate NPC message id');
      }
    }
  }

  final String npcId;
  final List<NpcChatMessage> messages;

  NpcChatThread copyWith({List<NpcChatMessage>? messages}) =>
      NpcChatThread(npcId: npcId, messages: messages ?? this.messages);

  NpcChatThread appendMessage(NpcChatMessage message) =>
      copyWith(messages: [...messages, message]);

  /// Streaming updates replace a stable message ID without duplicating history.
  NpcChatThread upsertMessage(NpcChatMessage message) {
    final index = messages.indexWhere((item) => item.id == message.id);
    if (index < 0) return appendMessage(message);
    final updated = [...messages];
    updated[index] = message;
    return copyWith(messages: updated);
  }

  Map<String, dynamic> toJson() => {
    'npc_id': npcId,
    'messages': messages.map((message) => message.toJson()).toList(),
  };

  factory NpcChatThread.fromJson(Object? value) {
    final json = _jsonObject(value, 'thread');
    _checkKeys(
      json,
      const {'npc_id', 'messages'},
      const {'npc_id', 'messages'},
    );
    final raw = json['messages'];
    if (raw is! List || raw.length > 100000) {
      throw const FormatException('Invalid NPC message list');
    }
    return NpcChatThread(
      npcId: _jsonString(json['npc_id'], 'NPC id'),
      messages: raw.map(NpcChatMessage.fromJson).toList(growable: false),
    );
  }

  /// Searches the full saved transcript; only the prompt excerpt is bounded.
  /// Incomplete replies are never treated as an NPC's accepted statement.
  String memoryContext(
    String query, {
    int maxChars = 6000,
    int recentMessages = 12,
    int relevantMessages = 8,
  }) {
    if (maxChars <= 0 || messages.isEmpty) return '';
    if (recentMessages < 0 || relevantMessages < 0) {
      throw ArgumentError('Memory message limits must be nonnegative');
    }
    final units = _historyUnits(messages);
    if (units.isEmpty) return '';
    final cutoff = math.max(0, messages.length - recentMessages);
    final recent = recentMessages == 0
        ? <_MemoryUnit>[]
        : units.where((unit) => unit.endIndex >= cutoff).toList();
    final recentSet = recent.toSet();
    final older = units.where((unit) => !recentSet.contains(unit)).toList();
    final terms = _searchTerms(query);
    final frequencies = {
      for (final term in terms)
        term: units.where((unit) => unit.searchable.contains(term)).length,
    };
    final ranked = <(_MemoryUnit, double)>[];
    for (final unit in older) {
      var score = 0.0;
      for (final term in terms) {
        if (unit.searchable.contains(term)) {
          final frequency = frequencies[term]!;
          score += 1 + math.log((units.length + 1) / (frequency + 1));
        }
      }
      if (score > 0) ranked.add((unit, score));
    }
    ranked.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      return byScore == 0 ? b.$1.endIndex.compareTo(a.$1.endIndex) : byScore;
    });
    final generic = _genericRecall.hasMatch(query.toLowerCase());
    final anchorCount = generic && relevantMessages >= 4
        ? math.min(2, older.length)
        : 0;
    final selected = ranked
        .take(relevantMessages - anchorCount)
        .map((item) => item.$1)
        .toList();
    if (generic) {
      // Broad questions still retain early introductions and explicit promises,
      // even when their exact nouns are absent from this turn's question.
      final anchors = [
        ...older.take(2),
        ...older.where((unit) => _memoryFact.hasMatch(unit.searchable)),
      ];
      for (final unit in anchors) {
        if (selected.length >= relevantMessages) break;
        if (!selected.contains(unit)) selected.add(unit);
      }
    }
    selected.sort((a, b) => a.endIndex.compareTo(b.endIndex));
    final oldBudget = recent.isEmpty
        ? maxChars
        : selected.isEmpty
        ? 0
        : (maxChars * .6).floor();
    final oldText = _renderMemorySection(
      selected,
      query,
      oldBudget,
      '【较早的相关消息】',
    );
    final recentText = _renderMemorySection(
      recent,
      query,
      maxChars - oldText.length - (oldText.isEmpty ? 0 : 2),
      '【最近消息】',
      newestFirstWhenLimited: true,
    );
    return _safePrefix(
      [oldText, recentText].where((text) => text.isNotEmpty).join('\n\n'),
      maxChars,
    );
  }
}

class NpcChatState {
  NpcChatState({
    Map<String, NpcChatThread> threads = const {},
    Iterable<String> contactIds = const [],
  }) : threads = Map<String, NpcChatThread>.unmodifiable(threads),
       contactIds = Set<String>.unmodifiable(contactIds.toSet()) {
    for (final entry in threads.entries) {
      if (_identifier(entry.key, 'NPC id') != entry.value.npcId) {
        throw const FormatException('NPC thread key does not match its owner');
      }
    }
    for (final id in contactIds) {
      _identifier(id, 'NPC contact id');
    }
  }

  const NpcChatState.empty() : threads = const {}, contactIds = const {};

  final Map<String, NpcChatThread> threads;

  /// Contacts explicitly added from the main dialogue. Threads with history
  /// remain visible as a backwards-compatible migration for older saves.
  final Set<String> contactIds;

  bool hasContact(String npcId) =>
      contactIds.contains(npcId) || threads[npcId]?.messages.isNotEmpty == true;

  Set<String> get effectiveContactIds => Set<String>.unmodifiable({
    ...contactIds,
    // An empty placeholder is not evidence that the user has ever added
    // this NPC. Keep only actual history visible during legacy migration.
    for (final thread in threads.values)
      if (thread.messages.isNotEmpty) thread.npcId,
  });

  NpcChatThread threadFor(String npcId) =>
      threads[npcId] ?? NpcChatThread(npcId: npcId);

  NpcChatState withThread(NpcChatThread thread) => NpcChatState(
    threads: {...threads, thread.npcId: thread},
    contactIds: contactIds,
  );

  NpcChatState withoutThread(String npcId) => NpcChatState(
    threads: {...threads}..remove(npcId),
    contactIds: contactIds,
  );

  NpcChatState withContact(String npcId) => NpcChatState(
    threads: threads,
    contactIds: {...contactIds, _identifier(npcId, 'NPC contact id')},
  );

  NpcChatState withoutContact(String npcId) {
    final next = {...contactIds}..remove(npcId);
    return NpcChatState(threads: threads, contactIds: next);
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'threads': threads.map((id, thread) => MapEntry(id, thread.toJson())),
    'contacts': contactIds.toList()..sort(),
  };

  factory NpcChatState.fromJson(Object? value, {Set<String>? allowedNpcIds}) {
    // Older saves have no NPC chat field.
    if (value == null) return const NpcChatState.empty();
    final json = _jsonObject(value, 'NPC chat state');
    _checkKeys(
      json,
      const {'version', 'threads', 'contacts'},
      const {'version', 'threads'},
    );
    if (json['version'] is! int || json['version'] != 1) {
      throw const FormatException('Unsupported NPC chat state version');
    }
    final raw = _jsonObject(json['threads'], 'NPC threads');
    if (raw.length > 256) throw const FormatException('Too many NPC threads');
    final rawContacts = json['contacts'];
    final contacts = <String>{};
    if (rawContacts != null) {
      if (rawContacts is! List || rawContacts.length > 256) {
        throw const FormatException('Invalid NPC contacts');
      }
      for (final value in rawContacts) {
        if (value is! String || value.trim().isEmpty) {
          throw const FormatException('Invalid NPC contact id');
        }
        final id = _identifier(value, 'NPC contact id');
        if (!contacts.add(id)) {
          throw const FormatException('Duplicate NPC contact id');
        }
        if (allowedNpcIds != null && !allowedNpcIds.contains(id)) {
          throw const FormatException(
            'NPC contact belongs to another character',
          );
        }
      }
    }
    final threads = <String, NpcChatThread>{};
    for (final entry in raw.entries) {
      if (allowedNpcIds != null && !allowedNpcIds.contains(entry.key)) {
        throw const FormatException('NPC thread belongs to another character');
      }
      final thread = NpcChatThread.fromJson(entry.value);
      if (thread.npcId != entry.key) {
        throw const FormatException('NPC thread key does not match its owner');
      }
      threads[entry.key] = thread;
    }
    return NpcChatState(threads: threads, contactIds: contacts);
  }

  String memoryContextFor(
    String npcId,
    String query, {
    int maxChars = 6000,
    int recentMessages = 12,
    int relevantMessages = 8,
  }) => threadFor(npcId).memoryContext(
    query,
    maxChars: maxChars,
    recentMessages: recentMessages,
    relevantMessages: relevantMessages,
  );

  String memoryContextForMainChat(
    String query, {
    Iterable<String>? npcIds,
    int maxChars = 6000,
  }) {
    if (maxChars <= 0) return '';
    final selected = (npcIds ?? threads.keys)
        .toSet()
        .map((id) => threads[id])
        .whereType<NpcChatThread>()
        .where((thread) => thread.messages.isNotEmpty)
        .toList();
    if (selected.isEmpty) return '';
    const heading = '以下是用户与 NPC 的消息记录，可引用已记录的内容；不表示主角亲历、NPC 在场或未完成事项已得到同意。';
    final result = <String>[heading];
    var remaining = maxChars - heading.length - 2;
    for (var index = 0; index < selected.length && remaining > 32; index++) {
      final thread = selected[index];
      final label = '【NPC ${thread.npcId}】\n';
      final budget = remaining ~/ (selected.length - index);
      final excerpt = thread.memoryContext(
        query,
        maxChars: budget - label.length - 2,
      );
      if (excerpt.isEmpty) continue;
      final block = '$label$excerpt';
      result.add(block);
      remaining -= block.length + 2;
    }
    return result.length == 1 ? '' : _safePrefix(result.join('\n\n'), maxChars);
  }
}

String _identifier(String value, String label) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$').hasMatch(value)) {
    throw FormatException('Invalid $label');
  }
  return value;
}

String _messageText(String value, {required bool allowEmpty}) {
  if (value.length > 200000 || (!allowEmpty && value.trim().isEmpty)) {
    throw const FormatException('Invalid NPC message text');
  }
  return value;
}

Map<String, dynamic> _jsonObject(Object? value, String label) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('Invalid $label');
  }
  return Map<String, dynamic>.from(value);
}

String _jsonString(Object? value, String label) {
  if (value is! String) throw FormatException('Invalid $label');
  return value;
}

void _checkKeys(
  Map<String, dynamic> json,
  Set<String> allowed,
  Set<String> required,
) {
  if (json.keys.any((key) => !allowed.contains(key)) ||
      required.any((key) => !json.containsKey(key))) {
    throw const FormatException('Invalid NPC chat fields');
  }
}

DateTime _timestamp(Object? value) {
  final text = _jsonString(value, 'message timestamp');
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(text);
  final parsed = DateTime.tryParse(text);
  if (match == null || parsed == null) {
    throw const FormatException('Invalid NPC message timestamp');
  }
  final numbers = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  final calendar = DateTime.utc(
    numbers[0],
    numbers[1],
    numbers[2],
    numbers[3],
    numbers[4],
    numbers[5],
  );
  if (calendar.year != numbers[0] ||
      calendar.month != numbers[1] ||
      calendar.day != numbers[2] ||
      calendar.hour != numbers[3] ||
      calendar.minute != numbers[4] ||
      calendar.second != numbers[5]) {
    throw const FormatException('Invalid NPC message calendar date');
  }
  final offset = match.group(7)!;
  if (offset != 'Z' &&
      (int.parse(offset.substring(1, 3)) > 23 ||
          int.parse(offset.substring(4, 6)) > 59)) {
    throw const FormatException('Invalid NPC message timezone');
  }
  return parsed.toUtc();
}

class _MemoryUnit {
  _MemoryUnit(this.records, this.endIndex, this.unanswered)
    : searchable = records
          .map((message) => '${message.text}\n${message.translatedText ?? ''}')
          .join('\n')
          .toLowerCase();
  final List<NpcChatMessage> records;
  final int endIndex;
  final bool unanswered;
  final String searchable;
}

List<_MemoryUnit> _historyUnits(List<NpcChatMessage> messages) {
  final units = <_MemoryUnit>[];
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    if (message.status != NpcChatStatus.completed) continue;
    if (message.role == NpcChatRole.assistant) {
      units.add(_MemoryUnit([message], index, false));
      continue;
    }
    final records = <NpcChatMessage>[message];
    var end = index;
    while (end + 1 < messages.length &&
        messages[end + 1].role == NpcChatRole.assistant) {
      end++;
      if (messages[end].status == NpcChatStatus.completed) {
        records.add(messages[end]);
      }
    }
    units.add(_MemoryUnit(records, end, records.length == 1));
    index = end;
  }
  return units;
}

final _genericRecall = RegExp(
  r'以前|之前|曾经|约定|答应|说过|记得|回忆|往事|promise|remember|earlier|before|agreed|previous|覚えて|約束|前に',
);
final _memoryFact = RegExp(
  r'约定|答应|承诺|记住|名字|叫我|生日|喜欢|讨厌|promise|call me|name is|birthday|favorite|覚えて|約束|好き|名前',
);

Set<String> _searchTerms(String query) {
  const stop = {
    '之前',
    '以前',
    '我们',
    '你们',
    '什么',
    '怎么',
    '这个',
    '那个',
    '一下',
    '可以',
    'the',
    'and',
    'you',
    'that',
    'this',
    'with',
    'what',
    'remember',
    'before',
  };
  final result = <String>{};
  final input = query.toLowerCase();
  for (final word in RegExp(r"[a-z0-9][a-z0-9_'-]+").allMatches(input)) {
    if (!stop.contains(word.group(0))) result.add(word.group(0)!);
  }
  for (final match in RegExp(
    r'[\u3005\u3040-\u30ff\u3400-\u9fff]+',
  ).allMatches(input)) {
    final runes = match.group(0)!.runes.toList();
    for (var index = 0; index + 1 < runes.length; index++) {
      final term = String.fromCharCodes(runes.sublist(index, index + 2));
      if (!stop.contains(term)) result.add(term);
    }
  }
  return result.take(128).toSet();
}

String _renderMemorySection(
  List<_MemoryUnit> source,
  String query,
  int maxChars,
  String title, {
  bool newestFirstWhenLimited = false,
}) {
  if (source.isEmpty || maxChars < title.length + 48) return '';
  final count = math
      .min(source.length, (maxChars - title.length) ~/ 80)
      .clamp(1, source.length);
  final units = newestFirstWhenLimited
      ? source.skip(source.length - count).toList()
      : source.take(count).toList();
  final unitBudget = (maxChars - title.length - 1) ~/ units.length - 2;
  final blocks = <String>[title];
  for (final unit in units) {
    final lines = <String>[];
    final perMessage = math.max(1, (unitBudget - 50) ~/ unit.records.length);
    for (final message in unit.records) {
      final label = message.role == NpcChatRole.user
          ? unit.unanswered
                ? '用户（已发送，尚无已完成回复）'
                : '用户'
          : 'NPC';
      lines.add('$label：${_excerpt(message.text, query, perMessage)}');
    }
    blocks.add(
      _safePrefix(
        '[${unit.records.first.createdAt.toIso8601String()}]\n${lines.join('\n')}',
        unitBudget,
      ),
    );
  }
  return _safePrefix(blocks.join('\n\n'), maxChars);
}

String _excerpt(String text, String query, int maxChars) {
  if (text.length <= maxChars) return text;
  final terms = _searchTerms(query);
  final lower = text.toLowerCase();
  var match = -1;
  for (final term in terms) {
    match = lower.indexOf(term);
    if (match >= 0) break;
  }
  var start = match < 0 ? 0 : math.max(0, match - maxChars ~/ 3);
  if (start > 0 && _lowSurrogate(text.codeUnitAt(start))) start--;
  final body = _safePrefix(text.substring(start), math.max(0, maxChars - 2));
  return '${start > 0 ? '…' : ''}$body…';
}

String _safePrefix(String text, int maxChars) {
  if (maxChars <= 0) return '';
  if (text.length <= maxChars) return text;
  var end = maxChars;
  if (end > 0 && _highSurrogate(text.codeUnitAt(end - 1))) end--;
  return text.substring(0, end);
}

bool _highSurrogate(int code) => code >= 0xd800 && code <= 0xdbff;
bool _lowSurrogate(int code) => code >= 0xdc00 && code <= 0xdfff;
