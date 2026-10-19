import 'package:flutter/foundation.dart';

enum ForegroundDialogKind { update, relayQuestion }

extension on ForegroundDialogKind {
  int get priority => switch (this) {
    ForegroundDialogKind.update => 10,
    ForegroundDialogKind.relayQuestion => 100,
  };
}

/// Keeps global, app-owned dialogs from stacking on top of each other.
///
/// A time-limited PC Agent question may preempt the optional update prompt.
/// The displaced presenter remains responsible for deciding whether it should
/// be offered again later.
class ForegroundDialogCoordinator extends ChangeNotifier {
  _ActiveDialog? _active;
  int _nextToken = 0;

  ForegroundDialogKind? get activeKind => _active?.kind;

  ForegroundDialogLease? tryAcquire({
    required ForegroundDialogKind kind,
    required VoidCallback onPreempt,
  }) {
    final active = _active;
    if (active != null && active.kind.priority >= kind.priority) return null;

    if (active != null) {
      _active = null;
      active.onPreempt();
    }

    final token = ++_nextToken;
    _active = _ActiveDialog(token, kind, onPreempt);
    notifyListeners();
    return ForegroundDialogLease._(this, token, kind);
  }

  void _release(int token) {
    if (_active?.token != token) return;
    _active = null;
    notifyListeners();
  }
}

class ForegroundDialogLease {
  ForegroundDialogLease._(this._owner, this._token, this.kind);

  final ForegroundDialogCoordinator _owner;
  final int _token;
  final ForegroundDialogKind kind;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(_token);
  }
}

class _ActiveDialog {
  const _ActiveDialog(this.token, this.kind, this.onPreempt);

  final int token;
  final ForegroundDialogKind kind;
  final VoidCallback onPreempt;
}
