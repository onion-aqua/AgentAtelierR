import 'package:audioplayers/audioplayers.dart';

import 'resource_resolver.dart';

/// Audio players bypass DefaultAssetBundle. Resolve managed replacements to a
/// verified local file, retaining the normal Flutter asset as the fallback.
Future<Source> resourceAudioSource(String path) async {
  final key = path.startsWith('assets/') ? path : 'assets/$path';
  final file = await ResourceAssetResolver.instance.resolveActiveFile(key);
  return file == null
      ? AssetSource(key.substring('assets/'.length))
      : DeviceFileSource(file.path);
}
