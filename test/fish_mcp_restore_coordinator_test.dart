import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_restore_coordinator.dart';

void main() {
  test(
    'startup waits for the host first-frame signal and starts only once',
    () async {
      final settings = _TtsSettings(enabled: true, mcpSelected: true);
      addTearDown(settings.dispose);
      var restores = 0;
      final coordinator = FishMcpRestoreCoordinator(
        settings: settings,
        isEligible: () => settings.eligible,
        restoreConnection: () async {
          restores++;
          return true;
        },
      );
      addTearDown(coordinator.dispose);
      settings.notifyChatChange();
      await Future<void>.delayed(Duration.zero);
      expect(restores, 0);
      coordinator.start();
      coordinator.start();
      expect(restores, 1);
      await Future<void>.delayed(Duration.zero);
      settings.notifyChatChange();
      expect(restores, 1);
    },
  );

  test(
    'only enabled MCP settings trigger restore and failed calls do not loop',
    () async {
      final settings = _TtsSettings();
      addTearDown(settings.dispose);
      var restores = 0;
      final coordinator = FishMcpRestoreCoordinator(
        settings: settings,
        isEligible: () => settings.eligible,
        restoreConnection: () async {
          restores++;
          return false;
        },
      );
      addTearDown(coordinator.dispose);
      coordinator.start();
      settings.configure(enabled: true, mcpSelected: false);
      expect(restores, 0);
      settings.configure(enabled: false, mcpSelected: true);
      expect(restores, 0);
      settings.configure(enabled: true, mcpSelected: true);
      expect(restores, 1);
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 100; i++) {
        settings.notifyChatChange();
      }
      expect(restores, 1);
      settings.configure(enabled: true, mcpSelected: false);
      settings.configure(enabled: true, mcpSelected: true);
      expect(restores, 2);
    },
  );

  test(
    'background settings wait until foreground and resume permits one retry',
    () async {
      final settings = _TtsSettings();
      addTearDown(settings.dispose);
      var restores = 0;
      final coordinator = FishMcpRestoreCoordinator(
        settings: settings,
        isEligible: () => settings.eligible,
        initiallyForeground: false,
        restoreConnection: () async {
          restores++;
          return false;
        },
      );
      addTearDown(coordinator.dispose);
      coordinator.start();
      settings.configure(enabled: true, mcpSelected: true);
      expect(restores, 0);
      coordinator.setForeground(true);
      expect(restores, 1);
      await Future<void>.delayed(Duration.zero);
      coordinator.setForeground(true);
      settings.notifyChatChange();
      expect(restores, 1);
      coordinator.setForeground(false);
      coordinator.setForeground(true);
      expect(restores, 2);
    },
  );

  test('a pending restore remains single flight across provider and lifecycle changes', () async {
    final settings = _TtsSettings(enabled: true, mcpSelected: true);
    addTearDown(settings.dispose);
    final pending = Completer<bool>();
    var restores = 0;
    final coordinator = FishMcpRestoreCoordinator(
      settings: settings,
      isEligible: () => settings.eligible,
      restoreConnection: () {
        restores++;
        return pending.future;
      },
    );
    addTearDown(coordinator.dispose);
    coordinator.start();
    settings.configure(enabled: false, mcpSelected: true);
    settings.configure(enabled: true, mcpSelected: true);
    coordinator.setForeground(false);
    coordinator.setForeground(true);
    expect(restores, 1);
    pending.complete(false);
    await Future<void>.delayed(Duration.zero);
    settings.notifyChatChange();
    expect(restores, 1);
    coordinator.setForeground(false);
    coordinator.setForeground(true);
    expect(restores, 2);
  });

  test(
    'restore exceptions are contained and wait for a new resume to retry',
    () async {
      final settings = _TtsSettings(enabled: true, mcpSelected: true);
      addTearDown(settings.dispose);
      var restores = 0;
      final errors = <Object>[];
      final coordinator = FishMcpRestoreCoordinator(
        settings: settings,
        isEligible: () => settings.eligible,
        restoreConnection: () {
          restores++;
          throw StateError('offline');
        },
        onError: (error, _) => errors.add(error),
      );
      addTearDown(coordinator.dispose);
      coordinator.start();
      await Future<void>.delayed(Duration.zero);
      expect(restores, 1);
      expect(errors.single, isStateError);
      settings.notifyChatChange();
      expect(restores, 1);
      coordinator.setForeground(false);
      coordinator.setForeground(true);
      await Future<void>.delayed(Duration.zero);
      expect(restores, 2);
      expect(errors, hasLength(2));
    },
  );

  test(
    'dispose before first frame and after start prevents further attempts',
    () async {
      final settings = _TtsSettings(enabled: true, mcpSelected: true);
      addTearDown(settings.dispose);
      var restores = 0;
      Future<bool> restore() async {
        restores++;
        return false;
      }

      final beforeFrame = FishMcpRestoreCoordinator(
        settings: settings,
        isEligible: () => settings.eligible,
        restoreConnection: restore,
      );
      beforeFrame.dispose();
      beforeFrame.start();
      expect(restores, 0);
      final coordinator = FishMcpRestoreCoordinator(
        settings: settings,
        isEligible: () => settings.eligible,
        restoreConnection: restore,
      );
      coordinator.start();
      await Future<void>.delayed(Duration.zero);
      expect(restores, 1);
      coordinator.dispose();
      coordinator.dispose();
      settings.configure(enabled: false, mcpSelected: false);
      settings.configure(enabled: true, mcpSelected: true);
      coordinator.setForeground(false);
      coordinator.setForeground(true);
      coordinator.start();
      expect(restores, 1);
    },
  );
}

class _TtsSettings extends ChangeNotifier {
  _TtsSettings({this.enabled = false, this.mcpSelected = false});

  bool enabled;
  bool mcpSelected;
  bool get eligible => enabled && mcpSelected;

  void configure({required bool enabled, required bool mcpSelected}) {
    this.enabled = enabled;
    this.mcpSelected = mcpSelected;
    notifyListeners();
  }

  void notifyChatChange() => notifyListeners();
}
