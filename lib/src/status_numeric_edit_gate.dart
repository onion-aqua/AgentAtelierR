import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_localization.dart';

typedef StatusNumericEditBuilder = Widget Function(
  BuildContext context,
  Widget title,
  ValueListenable<bool> access,
);

class _StatusEditAccess extends ChangeNotifier
    implements ValueListenable<bool> {
  bool _enabled = false;
  @override
  bool get value => _enabled;

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _enabled = false;
    super.dispose();
  }
}

/// A local editing session. It is never exported or restored from save data.
/// The live access handle also guards callbacks retained by an older frame.
class StatusNumericEditGate extends StatefulWidget {
  const StatusNumericEditGate({
    super.key,
    required this.title,
    required this.language,
    required this.resetToken,
    required this.builder,
  });

  static const requiredTaps = 10;
  static const maximumTapInterval = Duration(milliseconds: 1500);
  final String title;
  final AppLanguage language;
  final Object resetToken;
  final StatusNumericEditBuilder builder;

  @override
  State<StatusNumericEditGate> createState() => _StatusNumericEditGateState();
}

class _StatusNumericEditGateState extends State<StatusNumericEditGate>
    with WidgetsBindingObserver {
  final _titleKey = GlobalKey();
  final _access = _StatusEditAccess();
  Timer? _expiry;
  int _taps = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _resetSequence() {
    _expiry?.cancel();
    _expiry = null;
    _taps = 0;
  }

  void _lock() {
    _resetSequence();
    _access.setEnabled(false);
  }

  @override
  void didUpdateWidget(covariant StatusNumericEditGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetToken != widget.resetToken) _lock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _lock();
  }

  void _tapTitle() {
    if (_access.value) return;
    _expiry?.cancel();
    _taps++;
    if (_taps == StatusNumericEditGate.requiredTaps) {
      _resetSequence();
      _access.setEnabled(true);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            widget.language.text(
              '已开启本次数值编辑，退出状态页后重新锁定。',
              'Editing enabled for this visit. It locks again when you leave.',
              '今回の数値編集を有効にしました。状態画面を閉じると再ロックされます。',
            ),
          ),
        ),
      );
    } else {
      _expiry = Timer(StatusNumericEditGate.maximumTapInterval, _resetSequence);
    }
  }

  void _pointerDown(PointerDownEvent event) {
    final box = _titleKey.currentContext?.findRenderObject();
    if (box is! RenderBox ||
        !box.hasSize ||
        !(Offset.zero & box.size).contains(box.globalToLocal(event.position))) {
      _resetSequence();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _pointerDown,
    onPointerSignal: (_) => _resetSequence(),
    child: ValueListenableBuilder<bool>(
      valueListenable: _access,
      builder: (context, _, child) => widget.builder(
        context,
        GestureDetector(
          key: _titleKey,
          behavior: HitTestBehavior.opaque,
          onTap: _tapTitle,
          child: Text(
            widget.title,
            key: const ValueKey('status-numeric-edit-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        _access,
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resetSequence();
    // Relock before discarding the handle so stale route callbacks cannot edit.
    _access.dispose();
    super.dispose();
  }
}
