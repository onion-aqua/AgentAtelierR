import 'character_expression.dart';
import 'character_performance.dart';

class QueuedPerformance {
  const QueuedPerformance(
    this.action,
    this.expression,
    this.expiresAt, {
    this.motionGroupId,
  });

  const QueuedPerformance.motion(
    this.motionGroupId,
    this.expression,
    this.expiresAt,
  ) : action = CharacterAction.none;

  final CharacterAction action;
  final CharacterExpression expression;
  final DateTime expiresAt;
  final String? motionGroupId;
}

/// Short-lived intentions, never a backlog of obsolete conversation gestures.
class CharacterPerformanceQueue {
  CharacterPerformanceQueue({this.onDiagnostic});
  final void Function(String)? onDiagnostic;
  final _items = <QueuedPerformance>[];
  String _id(QueuedPerformance item) => item.motionGroupId ?? item.action.name;
  void clear() {
    if (_items.isNotEmpty) {
      onDiagnostic?.call('清空待播动作：${_items.map(_id).join(',')}');
    }
    _items.clear();
  }

  void _expire(DateTime now) {
    _items.removeWhere((item) {
      final expired = !item.expiresAt.isAfter(now);
      if (expired) onDiagnostic?.call('过期丢弃：${_id(item)}；超过5秒等待期限');
      return expired;
    });
  }

  void _makeRoom() {
    if (_items.length >= 2) {
      onDiagnostic?.call('队列已满，移除：${_id(_items.removeAt(0))}');
    }
  }

  void add(
    CharacterAction action,
    CharacterExpression expression,
    DateTime now,
  ) {
    _expire(now);
    if (action == CharacterAction.none) return;
    if (_items.any(
      (item) => item.action == action && item.expression == expression,
    )) {
      onDiagnostic?.call('队列去重：${action.name}');
      return;
    }
    _makeRoom();
    onDiagnostic?.call('入队：${action.name}');
    _items.add(
      QueuedPerformance(
        action,
        expression,
        now.add(const Duration(seconds: 5)),
      ),
    );
  }

  void addMotionGroup(
    String motionGroupId,
    CharacterExpression expression,
    DateTime now,
  ) {
    final normalized = motionGroupId.trim().toLowerCase();
    if (normalized.isEmpty) return;
    _expire(now);
    if (_items.any((item) => item.motionGroupId == normalized)) {
      onDiagnostic?.call('队列去重：$normalized');
      return;
    }
    _makeRoom();
    onDiagnostic?.call('入队：$normalized');
    _items.add(
      QueuedPerformance.motion(
        normalized,
        expression,
        now.add(const Duration(seconds: 5)),
      ),
    );
  }

  QueuedPerformance? take(DateTime now) {
    _expire(now);
    if (_items.isEmpty) return null;
    final item = _items.removeAt(0);
    onDiagnostic?.call('出队：${_id(item)}');
    return item;
  }

  bool get isNotEmpty => _items.isNotEmpty;
}
