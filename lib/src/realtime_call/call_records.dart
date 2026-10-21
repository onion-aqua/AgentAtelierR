import 'call_ui_models.dart';

/// Save-scoped metadata and recognized/spoken text. Raw microphone audio is
/// never recorded. Unspoken/cancelled model continuations are not memories.
class CallRecord {
  const CallRecord({
    required this.id,
    required this.contactId,
    required this.contactName,
    required this.startedAt,
    required this.incoming,
    this.seconds = 0,
    this.status = CallHistoryStatus.cancelled,
    this.turns = const [],
  });
  final String id, contactId, contactName;
  final DateTime startedAt;
  final bool incoming;
  final int seconds;
  final CallHistoryStatus status;
  final List<Map<String, String>> turns;
  CallRecord copyWith({
    int? seconds,
    CallHistoryStatus? status,
    List<Map<String, String>>? turns,
  }) => CallRecord(
    id: id,
    contactId: contactId,
    contactName: contactName,
    startedAt: startedAt,
    incoming: incoming,
    seconds: seconds ?? this.seconds,
    status: status ?? this.status,
    turns: turns ?? this.turns,
  );
  CallHistoryEntry get history => CallHistoryEntry(
    contactId: contactId,
    contactName: contactName,
    startedAt: startedAt,
    duration: Duration(seconds: seconds),
    incoming: incoming,
    status: status,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'contact_id': contactId,
    'contact_name': contactName,
    'started_at': startedAt.toIso8601String(),
    'incoming': incoming,
    'seconds': seconds,
    'status': status.name,
    'turns': turns,
  };
  factory CallRecord.fromJson(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid call record');
    String field(String key, int limit) {
      final value = raw[key];
      if (value is! String || value.isEmpty || value.length > limit) {
        throw const FormatException('Invalid call record field');
      }
      return value;
    }

    final time = DateTime.tryParse(field('started_at', 50));
    final seconds = raw['seconds'];
    final status = CallHistoryStatus.values
        .where((v) => v.name == raw['status'])
        .firstOrNull;
    final turns = raw['turns'];
    if (time == null ||
        seconds is! int ||
        seconds < 0 ||
        seconds > 86400 ||
        status == null ||
        raw['incoming'] is! bool ||
        turns is! List ||
        turns.length > 100) {
      throw const FormatException('Invalid call record');
    }
    final safeTurns = <Map<String, String>>[];
    for (final turn in turns) {
      if (turn is! Map ||
          turn['user'] is! String ||
          turn['assistant'] is! String ||
          (turn['user'] as String).length > 4000 ||
          (turn['assistant'] as String).length > 6000) {
        throw const FormatException('Invalid call transcript');
      }
      safeTurns.add({
        'user': turn['user'] as String,
        'assistant': turn['assistant'] as String,
      });
    }
    return CallRecord(
      id: field('id', 100),
      contactId: field('contact_id', 100),
      contactName: field('contact_name', 160),
      startedAt: time.toUtc(),
      incoming: raw['incoming'] as bool,
      seconds: seconds,
      status: status,
      turns: List.unmodifiable(safeTurns),
    );
  }
}

List<CallRecord> parseCallRecords(Object? value) {
  if (value == null) return const [];
  if (value is! List || value.length > 100) {
    throw const FormatException('Invalid call history');
  }
  return value.map(CallRecord.fromJson).toList();
}
