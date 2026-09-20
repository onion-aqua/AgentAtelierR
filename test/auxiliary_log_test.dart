import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('memory and translation diagnostics survive the log filter', () async {
    SharedPreferences.setMockInitialValues({});
    final log = RuntimeLog.instance;
    log.info('Memory', 'memory diagnostic marker');
    log.warning('Translation', 'translation diagnostic marker');
    expect(
      log.entries.any((entry) => entry.message == 'memory diagnostic marker'),
      isTrue,
    );
    expect(
      log.entries.any(
        (entry) => entry.message == 'translation diagnostic marker',
      ),
      isTrue,
    );
    await Future<void>.delayed(Duration.zero);
  });
}
