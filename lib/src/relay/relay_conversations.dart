import 'dart:async';

import 'package:flutter/foundation.dart';

import 'relay_protocol.dart';
import 'relay_service.dart';

/// One desktop message, already normalized by the protocol adapter.
/// Task summaries and the mobile action outbox are deliberately not messages.
@immutable
class RelayHistoryMessage {
  const RelayHistoryMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    required this.state,
    required this.seq,
    required this.revision,
  });

  final String id;
  final String role;
  final String text;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String state;
  final int seq;
  final int revision;
}

@immutable
class RelayHistoryStatus {
  const RelayHistoryStatus({
    required this.loading,
    required this.loadingOlder,
    required this.error,
    required this.availability,
    required this.hasMore,
  });

  final bool loading;
  final bool loadingOlder;
  final String? error;

  /// available, not_ready, unsupported, or forbidden, from RelayService.
  final String availability;
  final bool hasMore;
}

/// Read-only view of the relay's secure history cache and its refresh state.
///
/// The service remains the only owner of the authenticated transport, protocol
/// mapping and persistent cache. This object only polls the selected session
/// while the application is in the foreground.
class RelayConversations extends ChangeNotifier {
  RelayConversations(
    this.service, {
    this.refreshInterval = const Duration(seconds: 15),
  }) : assert(refreshInterval > Duration.zero),
       _wasForeground = service.foreground {
    service.addListener(_serviceChanged);
  }

  final RelayService service;
  final Duration refreshInterval;
  final Map<(String, String), _HistoryLoad> _loads = {};
  final Map<(String, String), String> _errors = {};
  (String, String)? _active;
  String? _activeRevision;
  String? _activeHistoryEvent;
  Timer? _timer;
  bool _wasForeground;
  bool _wasActiveAllowed = false;
  bool _disposed = false;

  Json? _profile(String profileId) {
    final profile = service.profile(profileId);
    if (profile == null ||
        profile['state'] != 'confirmed' ||
        profile['device_token'] is! String ||
        (profile['device_token'] as String).isEmpty) {
      return null;
    }
    return profile;
  }

  Json? _cached(String profileId, String sessionId) {
    final profile = _profile(profileId);
    if (profile == null || profile['history_read'] == false) return null;
    try {
      return service
          .collection(profile, 'history')
          .where((row) => row['session_id'] == sessionId)
          .firstOrNull;
    } on FormatException {
      return null;
    }
  }

  List<RelayHistoryMessage> messages(String profileId, String sessionId) {
    final cached = _cached(profileId, sessionId);
    final rows = cached?['messages'];
    if (rows is! List) return const [];
    final byId = <String, RelayHistoryMessage>{};
    for (final raw in rows) {
      if (raw is! Map || raw['session_id'] != sessionId) continue;
      final id = raw['message_id'];
      final role = raw['role'];
      final text = raw['content'];
      final seq = raw['seq'];
      final revision = raw['revision'];
      if (id is! String ||
          id.isEmpty ||
          role is! String ||
          role.isEmpty ||
          text is! String ||
          seq is! int ||
          seq < 0 ||
          revision is! int ||
          revision < 0) {
        continue;
      }
      final message = RelayHistoryMessage(
        id: id,
        role: role,
        text: text,
        createdAt: DateTime.tryParse(raw['created_at']?.toString() ?? ''),
        updatedAt: DateTime.tryParse(raw['updated_at']?.toString() ?? ''),
        state: raw['state'] is String ? raw['state'] as String : 'completed',
        seq: seq,
        revision: revision,
      );
      final previous = byId[id];
      if (previous == null || message.revision >= previous.revision) {
        byId[id] = message;
      }
    }
    final ordered = byId.values.toList()
      ..sort((a, b) {
        final order = a.seq.compareTo(b.seq);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    return List.unmodifiable(ordered);
  }

  RelayHistoryStatus history(String profileId, String sessionId) {
    final cached = _cached(profileId, sessionId);
    final profile = _profile(profileId);
    final valid = profile != null && profile['history_read'] != false;
    final load = valid ? _loads[(profileId, sessionId)] : null;
    final rawAvailability = cached?['availability'];
    final cache = profile?['cache'];
    final feature = cache is Map ? cache['history_feature'] : null;
    final availability = feature is Map && feature['supported'] == false
        ? 'unsupported'
        : profile?['history_read'] == false
        ? 'forbidden'
        : {
            'available',
            'not_ready',
            'unsupported',
            'forbidden',
          }.contains(rawAvailability)
        ? rawAvailability as String
        : 'not_ready';
    return RelayHistoryStatus(
      loading: load != null && !load.older,
      loadingOlder: load?.older == true,
      error: valid
          ? _errors[(profileId, sessionId)] ??
                (cached?['error'] is String ? cached!['error'] as String : null)
          : null,
      availability: availability,
      hasMore: cached?['has_more'] == true,
    );
  }

  Future<void> refresh(String profileId, String sessionId) =>
      _load(profileId, sessionId, older: false);

  Future<void> loadOlder(String profileId, String sessionId) {
    if (!history(profileId, sessionId).hasMore) return Future.value();
    return _load(profileId, sessionId, older: true);
  }

  Future<void> _load(
    String profileId,
    String sessionId, {
    required bool older,
  }) {
    final profile = _profile(profileId);
    if (_disposed ||
        sessionId.isEmpty ||
        profile == null ||
        profile['history_read'] == false) {
      return Future.value();
    }
    final key = (profileId, sessionId);
    final pending = _loads[key];
    if (pending != null) return pending.done.future;
    final load = _HistoryLoad(older);
    _loads[key] = load;
    _errors.remove(key);
    _notify();
    unawaited(_performLoad(key, load));
    return load.done.future;
  }

  Future<void> _performLoad((String, String) key, _HistoryLoad load) async {
    try {
      await service.refreshSessionHistory(key.$1, key.$2, older: load.older);
    } on Object catch (error) {
      final profile = _profile(key.$1);
      if (!_disposed && profile != null && profile['history_read'] != false) {
        _errors[key] = error is RelayFailure
            ? error.toString()
            : '历史记录暂时无法读取，请稍后重试';
      }
    } finally {
      if (identical(_loads[key], load)) _loads.remove(key);
      load.done.complete();
      _notify();
    }
  }

  void activate(String? profileId, String? sessionId) {
    if (_disposed) return;
    final next =
        profileId == null ||
            sessionId == null ||
            sessionId.isEmpty ||
            _profile(profileId) == null
        ? null
        : (profileId, sessionId);
    if (_active == next) return;
    _active = next;
    _activeRevision = null;
    _activeHistoryEvent = null;
    _wasActiveAllowed = _selectedCanRead;
    if (next != null && _wasActiveAllowed) _observeRevision(next);
    _updateTimer();
    if (next != null && service.foreground && _wasActiveAllowed) {
      unawaited(refresh(next.$1, next.$2));
    }
    _notify();
  }

  void _serviceChanged() {
    if (_disposed) return;
    _errors.removeWhere(
      (key, _) =>
          _profile(key.$1) == null ||
          _profile(key.$1)?['history_read'] == false,
    );
    if (_active != null && _profile(_active!.$1) == null) {
      _active = null;
    }
    final resumed = !_wasForeground && service.foreground;
    _wasForeground = service.foreground;
    final allowed = _selectedCanRead;
    final permissionRestored = !_wasActiveAllowed && allowed;
    _wasActiveAllowed = allowed;
    _updateTimer();
    final active = _active;
    final changed = active != null && allowed && _observeRevision(active);
    if (active != null &&
        allowed &&
        service.foreground &&
        (resumed || changed || permissionRestored)) {
      unawaited(refresh(active.$1, active.$2));
    }
    _notify();
  }

  bool _observeRevision((String, String) active) {
    final profile = _profile(active.$1);
    if (profile == null) return false;
    try {
      final session = service
          .collection(profile, 'sessions')
          .where((row) => row['session_id'] == active.$2)
          .firstOrNull;
      final revision = session?['history_revision']?.toString();
      final event = service
          .collection(profile, 'events')
          .where(
            (row) =>
                row['type'] == 'session.history.updated' &&
                (row['session_id'] == active.$2 ||
                    (row['payload'] is Map &&
                        (row['payload'] as Map)['session_id'] == active.$2)),
          )
          .lastOrNull;
      final eventId = event?['event_id']?.toString();
      final changed =
          (revision != null && revision != _activeRevision) ||
          (eventId != null && eventId != _activeHistoryEvent);
      if (revision != null) _activeRevision = revision;
      if (eventId != null) _activeHistoryEvent = eventId;
      return changed;
    } on FormatException {
      return false;
    }
  }

  void _updateTimer() {
    if (!_selectedCanRead || !service.foreground) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(refreshInterval, (_) {
      final active = _active;
      if (active != null && _selectedCanRead && service.foreground) {
        unawaited(refresh(active.$1, active.$2));
      }
    });
  }

  bool get _selectedCanRead {
    final active = _active;
    if (active == null) return false;
    final profile = _profile(active.$1);
    return profile != null && profile['history_read'] != false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    service.removeListener(_serviceChanged);
    _timer?.cancel();
    _timer = null;
    _active = null;
    _errors.clear();
    super.dispose();
  }
}

class _HistoryLoad {
  _HistoryLoad(this.older);
  final bool older;
  final Completer<void> done = Completer<void>();
}
