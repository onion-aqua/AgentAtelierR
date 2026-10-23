import 'dart:async';

import 'package:flutter/foundation.dart';

/// Restores saved MCP authorization in the background, once per foreground
/// visit or transition into the MCP provider. Ordinary chat notifications never
/// create a retry loop after a failed connection.
class FishMcpRestoreCoordinator {
  FishMcpRestoreCoordinator({
    required this._settings,
    required this._isEligible,
    required this._restoreConnection,
    bool initiallyForeground = true,
    this._onError,
  }) : _foreground = initiallyForeground;

  final Listenable _settings;
  final bool Function() _isEligible;
  final Future<bool> Function() _restoreConnection;
  final void Function(Object error, StackTrace stackTrace)? _onError;
  bool _foreground;
  bool _started = false;
  bool _disposed = false;
  bool _lastEligible = false;
  bool _inFlight = false;

  /// The host calls this after its first frame, never on the startup load path.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _settings.addListener(_settingsChanged);
    _lastEligible = _isEligible();
    _tryRestore();
  }

  void setForeground(bool foreground) {
    if (_disposed || foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) _tryRestore();
  }

  void _settingsChanged() {
    final eligible = _isEligible();
    if (eligible == _lastEligible) return;
    _lastEligible = eligible;
    if (eligible) _tryRestore();
  }

  void _tryRestore() {
    if (!_started || _disposed || !_foreground || !_isEligible() || _inFlight) {
      return;
    }
    _inFlight = true;
    unawaited(_runRestore());
  }

  Future<void> _runRestore() async {
    try {
      await _restoreConnection();
    } on Object catch (error, stackTrace) {
      if (!_disposed) _onError?.call(error, stackTrace);
    } finally {
      _inFlight = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) _settings.removeListener(_settingsChanged);
  }
}
