import 'dart:convert';

import 'memory_timeline.dart';

/// A small, deterministic memory layer inspired by Horae's append-only
/// timeline. It deliberately records only high-signal statements. The LLM may
/// enrich the timeline later, but it cannot be the only source of truth.
class MemoryLedgerFact {
  const MemoryLedgerFact({
    required this.category,
    required this.summary,
    required this.keywords,
    required this.importance,
    required this.sourceMessageId,
    required this.observedAt,
    this.sourceRole = 'conversation',
    this.confidence = 0.95,
  });

  final String category;
  final String summary;
  final List<String> keywords;
  final int importance;
  final String sourceMessageId;
  final DateTime observedAt;
  final String sourceRole;
  final double confidence;

  Map<String, dynamic> toJson() => {
    'date': _dateOnly(observedAt),
    'category': category,
    'importance': importance,
    'summary': summary,
    'keywords': keywords,
    'source': 'local_ledger',
    'source_role': sourceRole,
    'source_message_id': sourceMessageId,
    'observed_at': observedAt.toIso8601String(),
    'confidence': confidence,
  };

  static String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class MemoryLedger {
  MemoryLedger._();

  static const _sentenceBoundary = r'[。！？!?；;\n]+';
  // Reasoning/tool blocks are implementation details and must never become
  // facts. Answer/code tags are stripped while their body is retained.
  static final _hiddenBlocks = RegExp(
    r'<(?:think|tool_call|function_call|horae|horaeevent)\b[^>]*>[\s\S]*?</(?:think|tool_call|function_call|horae|horaeevent)>',
    caseSensitive: false,
  );
  static final _unclosedHiddenBlock = RegExp(
    r'<(?:think|tool_call|function_call|horae|horaeevent)\b[^>]*>[\s\S]*$',
    caseSensitive: false,
  );
  static final _stripMarkup = RegExp(
    r'<\/?(?:answer|code)\b[^>]*>|<[^>]+>|\[/?(?:think|answer|code|tool_call|function_call)[^\]]*\]',
    caseSensitive: false,
  );
  static final _latinToken = RegExp(
    r'[a-z0-9][a-z0-9_\-]{1,}',
    caseSensitive: false,
  );
  static final _cjkRun = RegExp(r'[\u3400-\u9fff\uf900-\ufaff]+');
  static final _commonWords = <String>{
    '然后',
    '但是',
    '已经',
    '现在',
    '今天',
    '我们',
    '你们',
    '自己',
    '这个',
    '那个',
    '什么',
    '怎么',
    '可以',
    '一下',
    'いる',
    'する',
    'こと',
  };

  /// Extracts only statements with an explicit durable signal. This is a
  /// conservative fallback, so a false negative is safer than inventing a
  /// relationship, item, or promise.
  static List<MemoryLedgerFact> extractTurn({
    required String userText,
    required String assistantText,
    required String sourceMessageId,
    DateTime? now,
  }) {
    final observedAt = now ?? DateTime.now();
    if (sourceMessageId.trim().isEmpty) return const [];
    final sentences = <({String text, String role})>[];
    for (final (text, role) in <(String, String)>[
      (userText, 'user'),
      (assistantText, 'assistant'),
    ]) {
      final source = _clean(text);
      if (source.isEmpty) continue;
      for (final sentence
          in source
              .split(RegExp(_sentenceBoundary))
              .map(_clean)
              .where((value) => value.length >= 4)) {
        sentences.add((text: sentence, role: role));
      }
    }
    if (sentences.isEmpty) return const [];

    final facts = <MemoryLedgerFact>[];
    final seen = <String>{};
    void add(String category, RegExp signal, {int importance = 3}) {
      for (final sentence in sentences) {
        if (!signal.hasMatch(sentence.text)) continue;
        final keywords = _keywords(sentence.text)
            .take(8)
            .toList(growable: false);
        if (keywords.isEmpty) continue;
        final summary = _bounded(sentence.text, 140);
        final key = '$category|${_comparable(summary)}';
        if (!seen.add(key)) continue;
        facts.add(
          MemoryLedgerFact(
            category: category,
            summary: summary,
            keywords: keywords,
            importance: importance,
            sourceMessageId: sourceMessageId,
            sourceRole: sentence.role,
            observedAt: observedAt,
          ),
        );
      }
    }

    add(
      'promise',
      RegExp(
        r'约定|答应|承诺|约好|计划|明天|下次|之后一起|一定会|promise|agree|tomorrow|next time|約束|約束した|明日|次は',
        caseSensitive: false,
      ),
      importance: 5,
    );
    add(
      'item',
      RegExp(
        r'送给|给你|收到|获得|拿到|找到|买到|丢失|扔掉|消耗|用掉|带来|gift|received|found|lost|used up|プレゼント|見つけ',
        caseSensitive: false,
      ),
    );
    add(
      'scene',
      RegExp(
        r'到达|去了|前往|来到|回到|离开|抵达|在.{0,16}(?:森林|工坊|海岸|岛|村|城|湖|旅馆|街道|海边)|arrive|went to|leave|location|到着|向かう',
        caseSensitive: false,
      ),
    );
    add(
      'relationship_turning_point',
      RegExp(
        r'成为朋友|关系|喜欢你|爱你|讨厌|生气|和好|原谅|告白|背叛|分手|结婚|朋友了|love you|confess|betray|break up|marry|友達|好き|仲直り|告白',
        caseSensitive: false,
      ),
      importance: 5,
    );
    add(
      'user_preference',
      RegExp(
        r'我喜欢|我讨厌|我希望|请不要|不要叫我|叫我|我的名字是|i like|i hate|please don.t|call me|私の名前は',
        caseSensitive: false,
      ),
      importance: 4,
    );
    add(
      'mood',
      RegExp(
        r'开心|高兴|难过|伤心|生气|害怕|兴奋|担心|失落|happy|sad|angry|afraid|excited|worried|嬉しい|悲しい|怒って|心配',
        caseSensitive: false,
      ),
      importance: 2,
    );
    return facts;
  }

  /// Merge local facts as append-only candidates. Existing entries always win
  /// on duplicate sequence/id, and the timeline's deletion and similarity
  /// guards remain in charge of deduplication.
  static String? mergeIntoTimeline(
    String previousMemory,
    Iterable<MemoryLedgerFact> facts, {
    DateTime? now,
  }) {
    final pending = facts.toList(growable: false);
    if (pending.isEmpty) {
      return MemoryTimeline.normalizeExisting(previousMemory);
    }
    return MemoryTimeline.normalizeCandidate(
      jsonEncode({
        'entries': [for (final fact in pending) fact.toJson()],
      }),
      previousMemory: previousMemory,
      now: now,
    );
  }

  static String _clean(String value) {
    final withoutMarkup = value
        .replaceAll(_hiddenBlocks, ' ')
        .replaceAll(_unclosedHiddenBlock, ' ')
        .replaceAll(_stripMarkup, ' ')
        .split('\n')
        .where(
          (line) => !RegExp(
            r'^\s*(?:译文|翻译|translation|日本語訳)\s*[:：]',
            caseSensitive: false,
          ).hasMatch(line),
        )
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return withoutMarkup;
  }

  static Iterable<String> _keywords(String value) sync* {
    final lower = value.toLowerCase();
    for (final match in _latinToken.allMatches(lower)) {
      final token = match.group(0)!;
      if (token.length >= 2 && !_commonWords.contains(token)) yield token;
    }
    for (final match in _cjkRun.allMatches(value)) {
      final run = match.group(0)!;
      final chars = run.runes.toList();
      for (var i = 0; i < chars.length; i++) {
        final one = String.fromCharCode(chars[i]);
        if (!_commonWords.contains(one)) yield one;
        if (i + 1 < chars.length) {
          final pair = String.fromCharCodes([chars[i], chars[i + 1]]);
          if (!_commonWords.contains(pair)) yield pair;
        }
      }
    }
  }

  static String _bounded(String value, int maxChars) =>
      String.fromCharCodes(value.runes.take(maxChars));

  static String _comparable(String value) => value.toLowerCase().replaceAll(
    RegExp(r'[\s\p{P}\p{S}]', unicode: true),
    '',
  );
}
