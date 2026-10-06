import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Use the preferences package's own test store to simulate a platform write
// failure without changing the production logger's storage interface.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';

class _DiagnosticStore extends InMemorySharedPreferencesStore {
  _DiagnosticStore([Map<String, Object>? data]) : super.withData(data ?? {});

  int writes = 0;
  bool failNextWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('test storage failure');
    }
    return super.setValue(valueType, key, value);
  }
}

class _DelayedDiagnosticStore extends _DiagnosticStore {
  _DelayedDiagnosticStore(super.data);

  final readGate = Completer<void>();
  int reads = 0;
  bool failNextRead = false;

  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    await readGate.future;
    if (failNextRead) {
      failNextRead = false;
      throw StateError('test initial read failure');
    }
    return super.getAll();
  }

  Future<List<String>> storedMessages() async {
    final values =
        (await super.getAll())['flutter.runtime_debug_logs_v1']
            as List<String>?;
    return [
      for (final row in values ?? const <String>[])
        jsonDecode(row)['message'] as String,
    ];
  }
}

Map<String, Object> _storedPriorLogs() => {
  'flutter.runtime_debug_logs_v1': [
    jsonEncode({
      'timestamp': '2026-10-06T00:00:00',
      'level': 'warning',
      'source': 'Flutter',
      'message': 'previous process diagnostic',
    }),
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'diagnostic writes coalesce and recover after a storage failure',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _DiagnosticStore();
      SharedPreferencesStorePlatform.instance = store;
      final log = RuntimeLog.forTesting();
      await log.initialize();
      await log.clear();
      for (var index = 0; index < 300; index++) {
        log.info('LLM', 'burst entry $index');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(store.writes, 1);
      expect(log.entries.length, RuntimeLog.maxEntries);
      store.failNextWrite = true;
      log.error('Flutter', 'first diagnostic after failure');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      log.info('LLM', 'recovered diagnostic');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final stored =
          (await store.getAll())['flutter.runtime_debug_logs_v1']
              as List<String>;
      expect(jsonDecode(stored.last)['message'], 'recovered diagnostic');
      expect(store.writes, 3);
      await log.clear();
      expect((await store.getAll())['flutter.runtime_debug_logs_v1'], isNull);
      log.dispose();
    },
  );

  for (final recordBeforeInitialize in [false, true]) {
    test(
      'cold startup keeps prior and first diagnostic (log first=$recordBeforeInitialize)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = _DelayedDiagnosticStore(_storedPriorLogs());
        SharedPreferencesStorePlatform.instance = store;
        final log = RuntimeLog.forTesting();
        if (recordBeforeInitialize) {
          log.error('Flutter', 'first startup diagnostic');
        }
        final initialized = log.initialize();
        if (!recordBeforeInitialize) {
          log.error('Flutter', 'first startup diagnostic');
        }
        await Future<void>.delayed(Duration.zero);
        expect(store.writes, 0);
        expect(log.entries.single.message, 'first startup diagnostic');
        store.readGate.complete();
        await initialized;
        expect(log.entries.map((entry) => entry.message), [
          'previous process diagnostic',
          'first startup diagnostic',
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(await store.storedMessages(), [
          'previous process diagnostic',
          'first startup diagnostic',
        ]);
        await log.initialize();
        expect(log.entries.length, 2);
        expect(store.reads, 1);
        log.dispose();
      },
    );
  }

  test(
    'clear during startup discards prior logs and keeps later diagnostics',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _DelayedDiagnosticStore(_storedPriorLogs());
      SharedPreferencesStorePlatform.instance = store;
      final log = RuntimeLog.forTesting();
      final initialized = log.initialize();
      log.error('Flutter', 'cleared startup diagnostic');
      final cleared = log.clear();
      log.info('LLM', 'diagnostic after clear');
      store.readGate.complete();
      await initialized;
      await cleared;
      expect(log.entries.map((entry) => entry.message), [
        'diagnostic after clear',
      ]);
      expect(await store.storedMessages(), ['diagnostic after clear']);
      log.dispose();
    },
  );

  test(
    'failed first read preserves startup diagnostics and allows retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = _DelayedDiagnosticStore(_storedPriorLogs())
        ..failNextRead = true;
      SharedPreferencesStorePlatform.instance = store;
      final log = RuntimeLog.forTesting();
      final initialized = log.initialize();
      log.error('Flutter', 'first startup diagnostic');
      final failed = expectLater(initialized, throwsStateError);
      store.readGate.complete();
      await failed;
      expect(
        log.entries.map((entry) => entry.message),
        contains('first startup diagnostic'),
      );
      await log.initialize();
      log.info('LLM', 'recovered diagnostic');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await store.storedMessages(), [
        'previous process diagnostic',
        'first startup diagnostic',
        'recovered diagnostic',
      ]);
      expect(store.reads, 2);
      log.dispose();
    },
  );
}
