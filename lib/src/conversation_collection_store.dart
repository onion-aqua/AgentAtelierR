import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import 'chat_segments.dart';

({int dialogue, int narration}) collectionTextCounts(
  String source,
  bool isUser,
) {
  if (isUser) {
    final parts = parseUserComposerParts(source);
    return (
      dialogue: parts.speech.trim().isEmpty ? 0 : 1,
      narration: [
        parts.narration,
        parts.bottomNarration,
      ].where((s) => s.trim().isNotEmpty).length,
    );
  }
  final segments = parseAssistantSegments(source)
      .where((s) => s.text.trim().isNotEmpty);
  return (
    dialogue: segments
        .where(
          (s) =>
              s.speaker == ChatSpeaker.ryza ||
              s.speaker == ChatSpeaker.character,
        )
        .length,
    narration: segments.where((s) => s.speaker == ChatSpeaker.narrator).length,
  );
}

({int dialogue, int voice, int narration}) collectionCardCounts(
  Map<String, dynamic> card,
) {
  var dialogue = 0;
  var narration = 0;
  for (final item in card['items'] as List) {
    dialogue +=
        item['dialogueCount'] as int? ??
        ((item['text'] as String).trim().isEmpty ? 0 : 1);
    narration += item['narrationCount'] as int? ?? 0;
  }
  return (
    dialogue: dialogue,
    voice: (card['audio'] as List).length,
    narration: narration,
  );
}

/// Independent of game saves and app-settings import/export.
class ConversationCollectionStore {
  ConversationCollectionStore(this.directory);
  final Directory directory;
  static Future<ConversationCollectionStore>? _instance;
  static Future<ConversationCollectionStore> open() => _instance ??= () async {
    final root = await getApplicationSupportDirectory();
    return ConversationCollectionStore(Directory('${root.path}/collections'));
  }();

  Future<void> _queue = Future.value();
  Future<T> _locked<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<List<Map<String, dynamic>>> _read(String name) async {
    final file = File('${directory.path}/$name.json');
    if (!await file.exists()) return [];
    return (jsonDecode(await file.readAsString()) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> _write(String name, List<Map<String, dynamic>> data) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/$name.json.tmp');
    await file.writeAsString(jsonEncode(data), flush: true);
    await file.rename('${directory.path}/$name.json');
  }

  Future<List<String>> _copyAudio(List<String> paths, String id) async {
    if (paths.isEmpty) return [];
    final folder = Directory('${directory.path}/$id');
    await folder.create(recursive: true);
    final files = <String>[];
    try {
      for (var i = 0; i < paths.length; i++) {
        final extension = paths[i].toLowerCase().endsWith('.wav')
            ? 'wav'
            : 'mp3';
        final relative = '$id/$i.$extension';
        await File(paths[i]).copy('${directory.path}/$relative');
        files.add(relative);
      }
      return files;
    } catch (_) {
      await folder.delete(recursive: true);
      rethrow;
    }
  }

  String path(String relative) {
    if (!RegExp(r'^(cache|favorite)_\d+/\d+\.(mp3|wav)$').hasMatch(relative)) {
      throw const FormatException('Invalid collection audio path');
    }
    return '${directory.path}/$relative';
  }

  Future<void> _removeFiles(Map<String, dynamic> record) async {
    for (final relative in (record['audio'] as List? ?? [])) {
      final file = File(path(relative as String));
      if (await file.exists()) await file.delete();
      if (await file.parent.exists() && await file.parent.list().isEmpty) {
        await file.parent.delete();
      }
    }
  }

  Future<void> cacheVoice(String key, List<String> paths) => _locked(() async {
    if (paths.isEmpty) return;
    final records = await _read('voice_cache');
    final files = await _copyAudio(
      paths,
      'cache_${DateTime.now().microsecondsSinceEpoch}',
    );
    final removed = records.where((r) => r['key'] == key).toList();
    records.removeWhere((r) => r['key'] == key);
    records.add({'key': key, 'audio': files});
    while (records.length > 50) {
      removed.add(records.removeAt(0));
    }
    await _write('voice_cache', records);
    for (final record in removed) {
      await _removeFiles(record);
    }
  });

  Future<Set<String>> availableVoiceKeys() => _locked(() async {
    final result = <String>{};
    for (final r in await _read('voice_cache')) {
      final audio = (r['audio'] as List).cast<String>();
      if (audio.isNotEmpty &&
          (await Future.wait(audio.map((p) => File(path(p)).exists())))
              .every((v) => v)) {
        result.add(r['key'] as String);
      }
    }
    return result;
  });

  Future<List<Map<String, dynamic>>> cards() =>
      _locked(() => _read('favorites'));

  /// Each selection contains key, text, isUser, saveText and saveVoice.
  Future<void> collect(
    List<Map<String, dynamic>> selections, {
    String name = '',
  }) => _locked(() async {
    final cache = await _read('voice_cache');
    final items = <Map<String, dynamic>>[];
    final sources = <String>[];
    for (final selection in selections) {
      final indexes = <int>[];
      if (selection['saveVoice'] == true) {
        final entry = cache
            .where((r) => r['key'] == selection['key'])
            .firstOrNull;
        if (entry == null) throw StateError('所选语音已过期，请重新选择');
        for (final audio in entry['audio'] as List) {
          indexes.add(sources.length);
          sources.add(path(audio as String));
        }
      }
      final counts = collectionTextCounts(
        selection['sourceText'] as String? ?? selection['text'] as String,
        selection['isUser'] == true,
      );
      items.add({
        'dialogueCount': selection['saveText'] == true ? counts.dialogue : 0,
        'narrationCount': selection['saveText'] == true ? counts.narration : 0,
        'text': selection['saveText'] == true ? selection['text'] : '',
        'isUser': selection['isUser'],
        'audioIndexes': indexes,
      });
    }
    if (items.isEmpty) return;
    final now = DateTime.now();
    final id = 'favorite_${now.microsecondsSinceEpoch}';
    final audio = await _copyAudio(sources, id);
    final cards = await _read('favorites');
    cards.add({
      'id': id,
      'name': name.trim(),
      'createdAt': now.toIso8601String(),
      'items': items,
      'audio': audio,
    });
    await _write('favorites', cards);
  });

  Future<void> rename(String id, String name) => _locked(() async {
    final records = await _read('favorites');
    final card = records.firstWhere((r) => r['id'] == id);
    card['name'] = name.trim();
    await _write('favorites', records);
  });

  Future<void> delete(String id) => _locked(() async {
    final records = await _read('favorites');
    final card = records.firstWhere((r) => r['id'] == id);
    records.remove(card);
    await _write('favorites', records);
    await _removeFiles(card);
  });

  Future<Uint8List> export(String id) => _locked(() async {
    final card = (await _read('favorites')).firstWhere((r) => r['id'] == id);
    final archive = Archive();
    final json = utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'format': 'agent-atelier-r-collection',
        'version': 1,
        ...card,
      }),
    );
    archive.addFile(ArchiveFile('collection.json', json.length, json));
    final text = (card['items'] as List)
        .map((i) => i['text'])
        .where((t) => t != '')
        .join('\n\n');
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile('conversation.txt', bytes.length, bytes));
    for (final relative in card['audio'] as List) {
      final bytes = await File(path(relative as String)).readAsBytes();
      archive.addFile(ArchiveFile(relative, bytes.length, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  });
}
