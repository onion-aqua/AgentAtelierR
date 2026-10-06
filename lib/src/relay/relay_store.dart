import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The complete relay registry is committed as one encrypted value. It is never
/// part of AppController exportData, role snapshots or conversation backups.
abstract interface class RelayStore {
  Future<String?> read();
  Future<void> write(String value);
}

class SecureRelayStore implements RelayStore {
  static const key = 'pc_agent_relay_v1.registry';
  final FlutterSecureStorage storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      storageNamespace: 'pc_agent_relay_v1',
      resetOnError: false,
    ),
  );
  @override
  Future<String?> read() => storage.read(key: key);
  @override
  Future<void> write(String value) => storage.write(key: key, value: value);
}
