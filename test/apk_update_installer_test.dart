import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/update/apk_update_installer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ApkUpdateInstaller.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('parses permission status and settings result', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getInstallPermissionStatus') {
        return <String, Object>{'required': true, 'granted': false};
      }
      expect(call.method, 'openInstallPermissionSettings');
      return <String, Object>{
        'required': true,
        'granted': false,
        'opened': true,
      };
    });

    final installer = ApkUpdateInstaller();
    final status = await installer.getInstallPermissionStatus();
    final settings = await installer.openInstallPermissionSettings();

    expect(status.required, isTrue);
    expect(status.granted, isFalse);
    expect(settings.opened, isTrue);
  });

  test('reads available private update storage', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getAvailableUpdateSpace');
      return <String, Object>{'bytes': 123456789};
    });

    expect(await ApkUpdateInstaller().getAvailableUpdateSpace(), 123456789);
  });

  test('reports unsupported split APK without inventing a base path', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'prepareCurrentApk');
      return <String, Object?>{
        'supported': false,
        'reason': 'split_apk_install',
        'packageName': 'com.example.ryza_chat_mvp',
        'versionCode': 46,
        'versionName': '1.0.4.1',
        'certificateSha256': 'a' * 64,
        'supportedAbis': <String>['arm64-v8a', 'armeabi-v7a'],
        'supportedDeltaFormats': <String>[],
        'apkPath': null,
        'sha256': null,
        'bytes': null,
      };
    });

    final result = await ApkUpdateInstaller().prepareCurrentApk();

    expect(result.supported, isFalse);
    expect(result.reason, 'split_apk_install');
    expect(result.apkPath, isNull);
    expect(result.sha256, isNull);
    expect(result.certificateSha256, 'a' * 64);
    expect(result.supportedAbis, <String>['arm64-v8a', 'armeabi-v7a']);
    expect(result.supportedDeltaFormats, isEmpty);
  });

  test('reads installed identity without preparing the current APK', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getInstalledAppInfo');
      expect(call.arguments, isNull);
      return <String, Object?>{
        'packageName': 'com.example.ryza_chat_mvp',
        'versionCode': 46,
        'versionName': '1.0.4.1',
        'certificateSha256': 'b' * 64,
        'supportedAbis': <String>['arm64-v8a'],
        'supportedDeltaFormats': <String>[],
      };
    });

    final result = await ApkUpdateInstaller().getInstalledAppInfo();

    expect(result.packageName, 'com.example.ryza_chat_mvp');
    expect(result.versionCode, 46);
    expect(result.certificateSha256, 'b' * 64);
    expect(result.supportedAbis, <String>['arm64-v8a']);
    expect(result.supportedDeltaFormats, isEmpty);
  });

  test('passes immutable manifest expectations to native validation', () async {
    const digest =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'validateApk');
      expect(call.arguments, <String, Object>{
        'path': '/private/update.apk',
        'expectedPackageName': 'com.example.ryza_chat_mvp',
        'expectedVersionCode': 47,
        'expectedSha256': digest,
      });
      return <String, Object?>{
        'valid': true,
        'packageName': 'com.example.ryza_chat_mvp',
        'versionCode': 47,
        'versionName': '1.0.4.2',
        'sha256': digest,
        'bytes': 123456,
        'signingCompatible': true,
      };
    });

    final result = await ApkUpdateInstaller().validateApk(
      path: '/private/update.apk',
      expectedPackageName: 'com.example.ryza_chat_mvp',
      expectedVersionCode: 47,
      expectedSha256: digest,
    );

    expect(result.versionCode, 47);
    expect(result.signingCompatible, isTrue);
    expect(result.bytes, 123456);
  });

  test('install call returns the verified target identity', () async {
    const digest =
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'installApk');
      return <String, Object?>{
        'launched': true,
        'packageName': 'com.example.ryza_chat_mvp',
        'versionCode': 48,
        'versionName': '1.0.4.3',
        'sha256': digest,
        'bytes': 987654,
      };
    });

    final result = await ApkUpdateInstaller().installApk(
      path: '/private/update.apk',
      expectedPackageName: 'com.example.ryza_chat_mvp',
      expectedVersionCode: 48,
      expectedSha256: digest,
    );

    expect(result.launched, isTrue);
    expect(result.sha256, digest);
  });

  test('converts platform failures into stable updater errors', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'signature_mismatch',
        message: 'The downloaded APK is not signed for this installation.',
      );
    });

    await expectLater(
      ApkUpdateInstaller().validateApk(
        path: '/private/update.apk',
        expectedPackageName: 'com.example.ryza_chat_mvp',
        expectedVersionCode: 47,
        expectedSha256: '0' * 64,
      ),
      throwsA(
        isA<ApkUpdateInstallerException>()
            .having((error) => error.code, 'code', 'signature_mismatch')
            .having(
              (error) => error.message,
              'message',
              contains('not signed'),
            ),
      ),
    );
  });

  test('rejects malformed native responses', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object>{'required': true},
    );

    await expectLater(
      ApkUpdateInstaller().getInstallPermissionStatus(),
      throwsA(
        isA<ApkUpdateInstallerException>().having(
          (error) => error.code,
          'code',
          'invalid_native_response',
        ),
      ),
    );
  });
}
