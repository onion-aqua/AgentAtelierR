import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/foreground_dialog_coordinator.dart';

void main() {
  test('relay question preempts optional update prompt', () {
    final coordinator = ForegroundDialogCoordinator();
    addTearDown(coordinator.dispose);
    var updatePreempted = false;

    final update = coordinator.tryAcquire(
      kind: ForegroundDialogKind.update,
      onPreempt: () => updatePreempted = true,
    );
    expect(update, isNotNull);

    final relay = coordinator.tryAcquire(
      kind: ForegroundDialogKind.relayQuestion,
      onPreempt: () {},
    );
    expect(relay, isNotNull);
    expect(updatePreempted, isTrue);
    expect(coordinator.activeKind, ForegroundDialogKind.relayQuestion);

    update!.release();
    expect(coordinator.activeKind, ForegroundDialogKind.relayQuestion);
    relay!.release();
    expect(coordinator.activeKind, isNull);
  });

  test('optional update waits while relay question owns the slot', () {
    final coordinator = ForegroundDialogCoordinator();
    addTearDown(coordinator.dispose);
    final relay = coordinator.tryAcquire(
      kind: ForegroundDialogKind.relayQuestion,
      onPreempt: () {},
    );

    expect(
      coordinator.tryAcquire(
        kind: ForegroundDialogKind.update,
        onPreempt: () {},
      ),
      isNull,
    );
    relay!.release();
    expect(
      coordinator.tryAcquire(
        kind: ForegroundDialogKind.update,
        onPreempt: () {},
      ),
      isNotNull,
    );
  });
}
