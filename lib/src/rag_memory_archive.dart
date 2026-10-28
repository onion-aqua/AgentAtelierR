/// Save-owned source records. Embeddings are disposable; these full texts are not.
class RagArchiveTurn {
  const RagArchiveTurn({
    required this.turnId,
    required this.messageId,
    required this.user,
    required this.assistant,
    required this.sequence,
    required this.recordedAt,
  });

  final String turnId, messageId, user, assistant, recordedAt;
  final int sequence;

  Map<String, dynamic> toJson() => {
    'turn_id': turnId,
    'message_id': messageId,
    'user': user,
    'assistant': assistant,
    'sequence': sequence,
    'recorded_at': recordedAt,
  };

  factory RagArchiveTurn.fromJson(Object? value) {
    if (value is! Map ||
        value['sequence'] is! int ||
        (value['sequence'] as int) < 1) {
      throw const FormatException('RAG 对话归档格式无效');
    }
    String read(String key) {
      final text = value[key];
      if (text is! String || text.trim().isEmpty || text.length > 200000) {
        throw const FormatException('RAG 对话归档内容无效');
      }
      return text;
    }

    return RagArchiveTurn(
      turnId: read('turn_id'),
      messageId: read('message_id'),
      user: read('user'),
      assistant: read('assistant'),
      sequence: value['sequence'] as int,
      recordedAt: read('recorded_at'),
    );
  }
}

class RagMemoryArchive {
  RagMemoryArchive({
    required this.characterId,
    List<RagArchiveTurn> turns = const [],
    Set<String> withdrawnMessageIds = const {},
  }) : turns = List.unmodifiable(turns),
       withdrawnMessageIds = Set.unmodifiable(withdrawnMessageIds);

  final String characterId;
  final List<RagArchiveTurn> turns;
  final Set<String> withdrawnMessageIds;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'character_id': characterId,
    'turns': turns.map((turn) => turn.toJson()).toList(growable: false),
    'withdrawn_message_ids': withdrawnMessageIds.toList(growable: false),
  };

  factory RagMemoryArchive.fromJson(
    Object? value, {
    required String characterId,
  }) {
    if (value == null) return RagMemoryArchive(characterId: characterId);
    // Older tools sometimes clone an empty character template then change its
    // owner. There is no source or deletion history to leak in this case.
    if (value is Map &&
        value['version'] == 1 &&
        value['character_id'] != characterId &&
        value['turns'] is List &&
        (value['turns'] as List).isEmpty &&
        (value['withdrawn_message_ids'] == null ||
            value['withdrawn_message_ids'] is List &&
                (value['withdrawn_message_ids'] as List).isEmpty)) {
      return RagMemoryArchive(characterId: characterId);
    }
    if (value is! Map ||
        value['version'] != 1 ||
        value['character_id'] != characterId ||
        value['turns'] is! List) {
      throw const FormatException('RAG 归档与当前人物不匹配或格式无效');
    }
    final turns = (value['turns'] as List)
        .map(RagArchiveTurn.fromJson)
        .toList();
    final withdrawn = value['withdrawn_message_ids'] ?? const <String>[];
    if (withdrawn is! List ||
        withdrawn.any((id) => id is! String || id.isEmpty)) {
      throw const FormatException('RAG 归档撤回编号无效');
    }
    final messages = <String>{};
    var previousSequence = 0;
    for (final turn in turns) {
      if (!messages.add(turn.messageId) || turn.sequence <= previousSequence) {
        throw const FormatException('RAG 归档顺序或消息编号无效');
      }
      previousSequence = turn.sequence;
    }
    return RagMemoryArchive(
      characterId: characterId,
      turns: turns,
      withdrawnMessageIds: withdrawn.cast<String>().toSet(),
    );
  }

  RagMemoryArchive put({
    required String turnId,
    required String messageId,
    required String user,
    required String assistant,
    DateTime? now,
  }) {
    if (withdrawnMessageIds.contains(messageId) ||
        turnId.trim().isEmpty ||
        messageId.trim().isEmpty ||
        user.trim().isEmpty ||
        assistant.trim().isEmpty) {
      return this;
    }
    final existing = turns.indexWhere((turn) => turn.messageId == messageId);
    if (existing >= 0 &&
        turns[existing].user == user &&
        turns[existing].assistant == assistant) {
      return this;
    }
    final sequence = existing >= 0
        ? turns[existing].sequence
        : (turns.isEmpty ? 1 : turns.last.sequence + 1);
    final turn = RagArchiveTurn(
      turnId: turnId,
      messageId: messageId,
      user: user,
      assistant: assistant,
      sequence: sequence,
      recordedAt: existing >= 0
          ? turns[existing].recordedAt
          : (now ?? DateTime.now()).toUtc().toIso8601String(),
    );
    final result = [...turns];
    if (existing >= 0) {
      result[existing] = turn;
    } else {
      result.add(turn);
    }
    return RagMemoryArchive(
      characterId: characterId,
      turns: result,
      withdrawnMessageIds: withdrawnMessageIds,
    );
  }

  RagMemoryArchive withoutTurn(String turnId) => withoutMessages(
    turns
        .where((turn) => turn.turnId == turnId)
        .map((turn) => turn.messageId)
        .toSet(),
  );

  RagMemoryArchive withoutMessages(Set<String> ids) => RagMemoryArchive(
    characterId: characterId,
    turns: turns.where((turn) => !ids.contains(turn.messageId)).toList(),
    withdrawnMessageIds: {...withdrawnMessageIds, ...ids},
  );
}
