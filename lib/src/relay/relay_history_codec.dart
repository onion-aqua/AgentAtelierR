import 'relay_protocol.dart';

/// Collects the real message fragments from one session-history snapshot.
///
/// A history read is separate from the reliable event queue. In particular,
/// [addPage] only validates `snapshot_seq`; it never changes or acknowledges
/// an event cursor. A caller must discard this assembler and restart the read
/// when [RelayFailure.code] is `HISTORY_CHANGED`.
class RelayHistoryAssembler {
  RelayHistoryAssembler({
    required this.pcId,
    required this.sessionId,
    required this.workspaceId,
  }) {
    if (!_validId(pcId) || !_validId(sessionId) || !_validId(workspaceId)) {
      throw _invalidHistory();
    }
  }

  final String pcId;
  final String sessionId;
  final String workspaceId;

  int? _revision;
  String? _nextCursor;
  bool _hasMore = true;
  String? _connectionState;
  bool _complete = false;
  Object? _failure;
  Map<String, _HistoryMessage> _messages = {};
  Map<int, String> _ordinalIds = {};

  int? get revision => _revision;
  String? get nextCursor => _nextCursor;
  bool get hasMore => _hasMore;
  String? get connectionState => _connectionState;

  /// Validates and stages a single page without exposing partial messages.
  ///
  /// Duplicate fragments are accepted only when both their text and all
  /// message metadata agree. An invalid page makes the read unusable so that
  /// a subsequent final page cannot accidentally publish a partial snapshot.
  void addPage(Json response) {
    final failure = _failure;
    if (failure != null) throw failure;
    try {
      _addValidatedPage(response);
    } on RelayFailure catch (error) {
      _failure = error;
      rethrow;
    } on Object {
      final error = _invalidHistory();
      _failure = error;
      throw error;
    }
  }

  void _addValidatedPage(Json response) {
    if (response['pc_id'] != pcId ||
        response['session_id'] != sessionId ||
        response['workspace_id'] != workspaceId) {
      throw _invalidHistory();
    }
    final pageRevision = response['history_revision'];
    if (pageRevision is! int || pageRevision <= 0) {
      throw _invalidHistory();
    }
    if (_revision != null && pageRevision != _revision) {
      throw const RelayFailure('HISTORY_CHANGED', retryable: true);
    }
    final syncState = response['sync_state'];
    final connection = response['connection_state'];
    final snapshotSeq = response['snapshot_seq'];
    final cursor = response['next_cursor'];
    final more = response['has_more'];
    final fragments = response['messages'];
    if ((syncState != 'ready' && syncState != 'syncing') ||
        (connection != 'online' && connection != 'offline') ||
        snapshotSeq is! int ||
        snapshotSeq < 0 ||
        !response.containsKey('next_cursor') ||
        (cursor != null && cursor is! String) ||
        more is! bool ||
        (more && (cursor is! String || cursor.isEmpty)) ||
        (!more && cursor != null) ||
        fragments is! List ||
        fragments.length > 100) {
      throw _invalidHistory();
    }

    // Validate against copies, so one bad fragment cannot partly mutate the
    // snapshot. A final page is committed only after every fragment is present.
    final stagedMessages = {
      for (final entry in _messages.entries) entry.key: entry.value.copy(),
    };
    final stagedOrdinals = {..._ordinalIds};
    for (final raw in fragments) {
      final fragment = _HistoryFragment.parse(raw);
      final ordinalId = stagedOrdinals[fragment.ordinal];
      if (ordinalId != null && ordinalId != fragment.messageId) {
        throw _invalidHistory();
      }
      var message = stagedMessages[fragment.messageId];
      if (message == null) {
        if (_complete) throw _invalidHistory();
        message = _HistoryMessage(fragment);
        stagedMessages[fragment.messageId] = message;
        stagedOrdinals[fragment.ordinal] = fragment.messageId;
      } else if (!message.matches(fragment)) {
        throw _invalidHistory();
      }
      final previous = message.parts[fragment.partIndex];
      if (previous != null && previous != fragment.body) {
        throw _invalidHistory();
      }
      if (_complete && previous == null) throw _invalidHistory();
      message.parts[fragment.partIndex] = fragment.body;
    }
    if (!more && stagedMessages.values.any((message) => !message.complete)) {
      throw _invalidHistory();
    }
    _messages = stagedMessages;
    _ordinalIds = stagedOrdinals;
    _revision = pageRevision;
    _connectionState = connection as String;
    _complete = _complete || !more;
    // Retried older pages may contain identical fragments. Once completed,
    // accepting those duplicates must not reopen pagination or lose its end.
    _hasMore = !_complete && more;
    _nextCursor = _complete ? null : cursor as String?;
  }

  /// Returns a fresh, normalized snapshot only after all pages were read.
  ///
  /// Callers replace their prior visible cache with this list; they must not
  /// append it, because a newer snapshot may contain edits or deletions.
  List<Json> messages() {
    final failure = _failure;
    if (failure != null) throw failure;
    if (!_complete || _revision == null) {
      throw const FormatException('会话历史尚未完整');
    }
    final ordered = _messages.values.toList()
      ..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    return [
      for (final message in ordered)
        {
          'message_id': message.messageId,
          'session_id': sessionId,
          'seq': message.ordinal,
          'role': message.role,
          'content': message.content(),
          'created_at': message.createdAt,
          'updated_at': message.updatedAt,
          'state': message.status,
          'revision': _revision,
          if (message.provisional != null) 'provisional': message.provisional,
          if (message.replacesMessageId != null)
            'replaces_message_id': message.replacesMessageId,
        },
    ];
  }
}

const _historyRoles = {'user', 'assistant'};
const _historyStatuses = {
  'queued',
  'streaming',
  'completed',
  'cancelled',
  'failed',
};

FormatException _invalidHistory() => const FormatException('会话历史结构无效');

bool _validId(Object? value) => value is String && value.trim().isNotEmpty;

bool _validBody(String value) {
  if (value.length > 8192) return false;
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= value.length) return false;
      final next = value.codeUnitAt(index);
      if (next < 0xdc00 || next > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

final _utcTimestampPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|\+00:00)$',
);

bool _validTimestamp(Object? value) {
  if (value is! String) return false;
  final match = _utcTimestampPattern.firstMatch(value);
  if (match == null) return false;
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) return false;
  // DateTime.parse normalizes out-of-range date/time values. Reject them
  // rather than treating a malformed protocol timestamp as a different day.
  final fields = [
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
  ];
  for (var index = 0; index < fields.length; index++) {
    if (fields[index] != int.parse(match.group(index + 1)!)) return false;
  }
  return true;
}

class _HistoryFragment {
  const _HistoryFragment({
    required this.messageId,
    required this.role,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.ordinal,
    required this.status,
    required this.partIndex,
    required this.partCount,
    this.provisional,
    this.replacesMessageId,
  });

  factory _HistoryFragment.parse(Object? raw) {
    if (raw is! Map) throw _invalidHistory();
    final id = raw['message_id'];
    final role = raw['role'];
    final body = raw['body'];
    final createdAt = raw['created_at'];
    final updatedAt = raw['updated_at'];
    final ordinal = raw['ordinal'];
    final status = raw['status'];
    final partIndex = raw['part_index'];
    final partCount = raw['part_count'];
    final provisional = raw['provisional'];
    final replacesMessageId = raw['replaces_message_id'];
    if (!_validId(id) ||
        !_historyRoles.contains(role) ||
        body is! String ||
        !_validBody(body) ||
        !_validTimestamp(createdAt) ||
        !_validTimestamp(updatedAt) ||
        ordinal is! int ||
        !_historyStatuses.contains(status) ||
        partIndex is! int ||
        partCount is! int ||
        partCount < 1 ||
        partIndex < 0 ||
        partIndex >= partCount ||
        (raw.containsKey('provisional') && provisional is! bool) ||
        (raw.containsKey('replaces_message_id') &&
            (!_validId(replacesMessageId) || replacesMessageId == id)) ||
        (provisional == true &&
            (role != 'assistant' ||
                status == 'completed' ||
                status == 'queued' ||
                replacesMessageId != null))) {
      throw _invalidHistory();
    }
    return _HistoryFragment(
      messageId: id as String,
      role: role as String,
      body: body,
      createdAt: createdAt as String,
      updatedAt: updatedAt as String,
      ordinal: ordinal,
      status: status as String,
      partIndex: partIndex,
      partCount: partCount,
      provisional: provisional as bool?,
      replacesMessageId: replacesMessageId as String?,
    );
  }

  final String messageId;
  final String role;
  final String body;
  final String createdAt;
  final String updatedAt;
  final int ordinal;
  final String status;
  final int partIndex;
  final int partCount;
  final bool? provisional;
  final String? replacesMessageId;
}

class _HistoryMessage {
  _HistoryMessage(_HistoryFragment fragment)
    : messageId = fragment.messageId,
      role = fragment.role,
      createdAt = fragment.createdAt,
      updatedAt = fragment.updatedAt,
      ordinal = fragment.ordinal,
      status = fragment.status,
      partCount = fragment.partCount,
      provisional = fragment.provisional,
      replacesMessageId = fragment.replacesMessageId;

  final String messageId;
  final String role;
  final String createdAt;
  final String updatedAt;
  final int ordinal;
  final String status;
  final int partCount;
  final bool? provisional;
  final String? replacesMessageId;
  final Map<int, String> parts = {};

  bool matches(_HistoryFragment fragment) =>
      messageId == fragment.messageId &&
      role == fragment.role &&
      createdAt == fragment.createdAt &&
      updatedAt == fragment.updatedAt &&
      ordinal == fragment.ordinal &&
      status == fragment.status &&
      partCount == fragment.partCount &&
      (provisional ?? false) == (fragment.provisional ?? false) &&
      replacesMessageId == fragment.replacesMessageId;

  bool get complete => parts.length == partCount;

  _HistoryMessage copy() => _HistoryMessage(
    _HistoryFragment(
      messageId: messageId,
      role: role,
      body: '',
      createdAt: createdAt,
      updatedAt: updatedAt,
      ordinal: ordinal,
      status: status,
      partIndex: 0,
      partCount: partCount,
      provisional: provisional,
      replacesMessageId: replacesMessageId,
    ),
  )..parts.addAll(parts);

  String content() {
    if (!complete) throw _invalidHistory();
    final buffer = StringBuffer();
    for (var index = 0; index < partCount; index++) {
      final part = parts[index];
      if (part == null) throw _invalidHistory();
      buffer.write(part);
    }
    return buffer.toString();
  }
}
