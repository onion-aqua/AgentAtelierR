import 'package:flutter/foundation.dart';

/// Native features available in the current app target, not the build host.
abstract final class AppPlatformCapabilities {
  static bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static bool get supportsRealtimeCalls =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get supportsLocalTts =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get supportsPhotoCapture =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static bool get supportsVoiceAlarms =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static bool get supportsCameraPairing =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static bool get supportsRemotePush =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
}
