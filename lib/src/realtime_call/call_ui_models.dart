import 'package:flutter/foundation.dart';

enum CallUiPhase {
  idle,
  incoming,
  preparing,
  dialing,
  listening,
  thinking,
  speaking,
  interrupted,
  ended,
  failed,
}

enum CallHistoryStatus { completed, missed, rejected, cancelled, failed }

@immutable
class CallContact {
  const CallContact({
    required this.id,
    required this.displayName,
    this.subtitle,
    this.avatarAsset,
  });

  final String id;
  final String displayName;
  final String? subtitle;
  final String? avatarAsset;
}

@immutable
class CallHistoryEntry {
  const CallHistoryEntry({
    required this.contactId,
    required this.contactName,
    required this.startedAt,
    required this.duration,
    required this.incoming,
    required this.status,
  });

  final String contactId;
  final String contactName;
  final DateTime startedAt;
  final Duration duration;
  final bool incoming;
  final CallHistoryStatus status;
}

@immutable
class CallUiSnapshot {
  const CallUiSnapshot({
    this.phase = CallUiPhase.idle,
    this.contact,
    this.elapsed = Duration.zero,
    this.muted = false,
    this.speaker = true,
    this.caption = '',
    this.captionTranslation = '',
    this.interimTranscript = '',
    this.statusMessage,
    this.error,
  });

  final CallUiPhase phase;
  final CallContact? contact;

  /// Begins only after microphone, transport and the conversation are ready.
  final Duration elapsed;
  final bool muted;
  final bool speaker;
  final String caption;
  final String captionTranslation;
  final String interimTranscript;
  final String? statusMessage;
  final String? error;

  bool get hasCall => phase != CallUiPhase.idle;
  bool get isActive => switch (phase) {
    CallUiPhase.preparing ||
    CallUiPhase.dialing ||
    CallUiPhase.listening ||
    CallUiPhase.thinking ||
    CallUiPhase.speaking ||
    CallUiPhase.interrupted => true,
    _ => false,
  };
}

/// The phone UI observes the real call lifecycle; it never starts a timer or
/// labels a call connected merely because the user pressed the green button.
abstract class CallUiController extends ChangeNotifier {
  List<CallContact> get contacts;
  List<CallHistoryEntry> get history;
  CallUiSnapshot get snapshot;

  Future<void> startCall(String contactId);
  Future<void> offerCall(String contactId);
  Future<void> acceptCall();
  Future<void> declineCall();
  Future<void> endCall();
  Future<void> setMuted(bool value);
  Future<void> setSpeaker(bool value);
  Future<void> sendText(String text);
  Future<void> interrupt();
}
