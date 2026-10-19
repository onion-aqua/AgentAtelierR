import 'package:flutter/services.dart';

/// Typed Dart facade for Android's package installer confirmation flow.
class ApkUpdateInstaller {
  ApkUpdateInstaller({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'agent_atelier_r/apk_update_installer';

  final MethodChannel _channel;

  Future<int> getAvailableUpdateSpace() async {
    final value = await _invokeMap('getAvailableUpdateSpace');
    final bytes = value['bytes'];
    if (bytes is num && bytes.toInt() >= 0) return bytes.toInt();
    throw const ApkUpdateInstallerException(
      code: 'invalid_native_response',
      message: 'Android update response is missing available storage.',
    );
  }

  Future<InstallPermissionStatus> getInstallPermissionStatus() async {
    final value = await _invokeMap('getInstallPermissionStatus');
    return InstallPermissionStatus.fromMap(value);
  }

  Future<InstallPermissionSettingsResult>
  openInstallPermissionSettings() async {
    final value = await _invokeMap('openInstallPermissionSettings');
    return InstallPermissionSettingsResult.fromMap(value);
  }

  /// Reads cheap installed-package identity without hashing or copying the APK.
  Future<InstalledAppInfo> getInstalledAppInfo() async {
    final value = await _invokeMap('getInstalledAppInfo');
    return InstalledAppInfo.fromMap(value);
  }

  /// Copies the currently installed universal APK into no-backup app storage.
  ///
  /// A split APK install cannot be reconstructed from only `base.apk`; in that
  /// case [CurrentApkSnapshot.supported] is false and callers must use a full
  /// package update instead of applying a binary patch.
  Future<CurrentApkSnapshot> prepareCurrentApk() async {
    final value = await _invokeMap('prepareCurrentApk');
    return CurrentApkSnapshot.fromMap(value);
  }

  Future<ApkValidationInfo> validateApk({
    required String path,
    required String expectedPackageName,
    required int expectedVersionCode,
    required String expectedSha256,
  }) async {
    final value = await _invokeMap(
      'validateApk',
      _arguments(
        path: path,
        expectedPackageName: expectedPackageName,
        expectedVersionCode: expectedVersionCode,
        expectedSha256: expectedSha256,
      ),
    );
    return ApkValidationInfo.fromMap(value);
  }

  /// Revalidates, stages, and opens Android's user-confirmed installer UI.
  Future<ApkInstallLaunchResult> installApk({
    required String path,
    required String expectedPackageName,
    required int expectedVersionCode,
    required String expectedSha256,
  }) async {
    final value = await _invokeMap(
      'installApk',
      _arguments(
        path: path,
        expectedPackageName: expectedPackageName,
        expectedVersionCode: expectedVersionCode,
        expectedSha256: expectedSha256,
      ),
    );
    return ApkInstallLaunchResult.fromMap(value);
  }

  Map<String, Object> _arguments({
    required String path,
    required String expectedPackageName,
    required int expectedVersionCode,
    required String expectedSha256,
  }) => <String, Object>{
    'path': path,
    'expectedPackageName': expectedPackageName,
    'expectedVersionCode': expectedVersionCode,
    'expectedSha256': expectedSha256,
  };

  Future<Map<String, Object?>> _invokeMap(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    try {
      final value = await _channel.invokeMapMethod<String, Object?>(
        method,
        arguments,
      );
      if (value == null) {
        throw const ApkUpdateInstallerException(
          code: 'invalid_native_response',
          message: 'Android returned an empty update-installer response.',
        );
      }
      return value;
    } on PlatformException catch (error) {
      throw ApkUpdateInstallerException(
        code: error.code,
        message: error.message ?? 'Android could not process the update.',
        details: error.details,
      );
    } on MissingPluginException {
      throw const ApkUpdateInstallerException(
        code: 'platform_not_supported',
        message: 'APK installation is only available in the Android app.',
      );
    }
  }
}

class InstallPermissionStatus {
  const InstallPermissionStatus({
    required this.required,
    required this.granted,
  });

  factory InstallPermissionStatus.fromMap(Map<String, Object?> value) =>
      InstallPermissionStatus(
        required: _requiredBool(value, 'required'),
        granted: _requiredBool(value, 'granted'),
      );

  final bool required;
  final bool granted;
}

class InstallPermissionSettingsResult extends InstallPermissionStatus {
  const InstallPermissionSettingsResult({
    required super.required,
    required super.granted,
    required this.opened,
  });

  factory InstallPermissionSettingsResult.fromMap(Map<String, Object?> value) =>
      InstallPermissionSettingsResult(
        required: _requiredBool(value, 'required'),
        granted: _requiredBool(value, 'granted'),
        opened: _requiredBool(value, 'opened'),
      );

  final bool opened;
}

class InstalledAppInfo {
  const InstalledAppInfo({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.certificateSha256,
    required this.supportedAbis,
    required this.supportedDeltaFormats,
  });

  factory InstalledAppInfo.fromMap(Map<String, Object?> value) =>
      InstalledAppInfo(
        packageName: _requiredString(value, 'packageName'),
        versionCode: _requiredInt(value, 'versionCode'),
        versionName: value['versionName'] as String?,
        certificateSha256: _requiredString(value, 'certificateSha256'),
        supportedAbis: _requiredStringList(value, 'supportedAbis'),
        supportedDeltaFormats: _requiredStringList(
          value,
          'supportedDeltaFormats',
          allowEmpty: true,
        ),
      );

  final String packageName;
  final int versionCode;
  final String? versionName;
  final String certificateSha256;
  final List<String> supportedAbis;
  final List<String> supportedDeltaFormats;
}

class CurrentApkSnapshot {
  const CurrentApkSnapshot({
    required this.supported,
    required this.reason,
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.certificateSha256,
    required this.supportedAbis,
    required this.supportedDeltaFormats,
    required this.apkPath,
    required this.sha256,
    required this.bytes,
  });

  factory CurrentApkSnapshot.fromMap(Map<String, Object?> value) {
    final supported = _requiredBool(value, 'supported');
    return CurrentApkSnapshot(
      supported: supported,
      reason: value['reason'] as String?,
      packageName: _requiredString(value, 'packageName'),
      versionCode: _requiredInt(value, 'versionCode'),
      versionName: value['versionName'] as String?,
      certificateSha256: _requiredString(value, 'certificateSha256'),
      supportedAbis: _requiredStringList(value, 'supportedAbis'),
      supportedDeltaFormats: _requiredStringList(
        value,
        'supportedDeltaFormats',
        allowEmpty: true,
      ),
      apkPath: value['apkPath'] as String?,
      sha256: value['sha256'] as String?,
      bytes: (value['bytes'] as num?)?.toInt(),
    );
  }

  final bool supported;
  final String? reason;
  final String packageName;
  final int versionCode;
  final String? versionName;
  final String certificateSha256;
  final List<String> supportedAbis;
  final List<String> supportedDeltaFormats;
  final String? apkPath;
  final String? sha256;
  final int? bytes;
}

class ApkValidationInfo {
  const ApkValidationInfo({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.sha256,
    required this.bytes,
    required this.signingCompatible,
  });

  factory ApkValidationInfo.fromMap(Map<String, Object?> value) {
    if (!_requiredBool(value, 'valid')) {
      throw const ApkUpdateInstallerException(
        code: 'apk_invalid',
        message: 'Android rejected the update APK.',
      );
    }
    return ApkValidationInfo(
      packageName: _requiredString(value, 'packageName'),
      versionCode: _requiredInt(value, 'versionCode'),
      versionName: value['versionName'] as String?,
      sha256: _requiredString(value, 'sha256'),
      bytes: _requiredInt(value, 'bytes'),
      signingCompatible: _requiredBool(value, 'signingCompatible'),
    );
  }

  final String packageName;
  final int versionCode;
  final String? versionName;
  final String sha256;
  final int bytes;
  final bool signingCompatible;
}

class ApkInstallLaunchResult {
  const ApkInstallLaunchResult({
    required this.launched,
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.sha256,
    required this.bytes,
  });

  factory ApkInstallLaunchResult.fromMap(Map<String, Object?> value) =>
      ApkInstallLaunchResult(
        launched: _requiredBool(value, 'launched'),
        packageName: _requiredString(value, 'packageName'),
        versionCode: _requiredInt(value, 'versionCode'),
        versionName: value['versionName'] as String?,
        sha256: _requiredString(value, 'sha256'),
        bytes: _requiredInt(value, 'bytes'),
      );

  final bool launched;
  final String packageName;
  final int versionCode;
  final String? versionName;
  final String sha256;
  final int bytes;
}

class ApkUpdateInstallerException implements Exception {
  const ApkUpdateInstallerException({
    required this.code,
    required this.message,
    this.details,
  });

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'ApkUpdateInstallerException($code): $message';
}

bool _requiredBool(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is bool) return field;
  throw ApkUpdateInstallerException(
    code: 'invalid_native_response',
    message: 'Android update response is missing $key.',
  );
}

int _requiredInt(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is num) return field.toInt();
  throw ApkUpdateInstallerException(
    code: 'invalid_native_response',
    message: 'Android update response is missing $key.',
  );
}

String _requiredString(Map<String, Object?> value, String key) {
  final field = value[key];
  if (field is String && field.isNotEmpty) return field;
  throw ApkUpdateInstallerException(
    code: 'invalid_native_response',
    message: 'Android update response is missing $key.',
  );
}

List<String> _requiredStringList(
  Map<String, Object?> value,
  String key, {
  bool allowEmpty = false,
}) {
  final field = value[key];
  if (field is List &&
      (allowEmpty || field.isNotEmpty) &&
      field.every((item) => item is String)) {
    return List<String>.unmodifiable(field.cast<String>());
  }
  throw ApkUpdateInstallerException(
    code: 'invalid_native_response',
    message: 'Android update response is missing $key.',
  );
}
