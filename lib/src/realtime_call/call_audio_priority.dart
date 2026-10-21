import 'package:flutter/foundation.dart';

/// One in-app call owns audible output. User volume preferences are preserved.
final class CallAudioPriority extends ValueNotifier<bool> {
  CallAudioPriority._() : super(false);
  static final instance = CallAudioPriority._();
}
