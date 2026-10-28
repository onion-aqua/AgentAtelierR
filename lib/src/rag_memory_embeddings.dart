import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import 'runtime_log.dart';

typedef RagEmbeddingBackend = Future<List<List<double>>> Function(
  List<String> texts,
);

/// A genuine pretrained multilingual encoder, loaded only on first retrieval.
/// Model copy, validation, tokenization and inference run in a worker isolate.
/// No user text or vector is sent to a remote embedding endpoint.
class RagMemoryEmbeddings {
  // ignore: prefer_initializing_formals
  RagMemoryEmbeddings({RagEmbeddingBackend? backend}) : _backend = backend;

  static const modelId =
      'distiluse-multilingual-cased-v2-int8-mean-dense512-v1';
  static const dimensions = 512;
  static const maximumTokens = 128;
  static const assetDirectory = 'assets/models/memory_rag';
  static const modelSha256 =
      'b95155143f47c18ede95257def30b0097478d0b472a150bd7e247b2e276dfe8f';
  static const vocabularySha256 =
      'fe0fda7c425b48c516fc8f160d594c8022a0808447475c1a7c6d6479763f310c';

  final RagEmbeddingBackend? _backend;
  bool _disposed = false;
  bool _available = false;
  Isolate? _worker;
  ReceivePort? _receive;
  SendPort? _commands;
  Completer<void>? _ready;
  Completer<void>? _closed;
  final _pending = <int, Completer<List<List<double>>>>{};
  int _nextId = 0;
  String _stage = 'initializing';

  bool get available => !_disposed && (_available || _backend != null);

  Future<void> initialize() async {
    if (_disposed) throw StateError('The local memory encoder is disposed.');
    if (_backend != null || _available) return;
    final previous = _ready;
    if (previous != null) return previous.future;
    final ready = _ready = Completer<void>();
    unawaited(ready.future.catchError((Object _) {}));
    _closed = Completer<void>();
    _receive = ReceivePort()..listen(_handle);
    try {
      // Platform plugins and Flutter assets are requested on the root isolate.
      // Some Android engines leave flutter/assets requests from background
      // messengers pending indefinitely; hashing and inference still stay off UI.
      final support = await getApplicationSupportDirectory();
      final vocabulary = await rootBundle.load('$assetDirectory/vocab.txt');
      _worker = await Isolate.spawn(
        _runMemoryEmbeddingWorker,
        [
          _receive!.sendPort,
          support.path,
          TransferableTypedData.fromList([
            vocabulary.buffer.asUint8List(
              vocabulary.offsetInBytes,
              vocabulary.lengthInBytes,
            ),
          ]),
        ],
        onError: _receive!.sendPort,
        onExit: _receive!.sendPort,
        debugName: 'aar-local-memory-embedding',
      );
      if (_disposed) {
        _worker?.kill(priority: Isolate.immediate);
        throw StateError('The local memory encoder is disposed.');
      }
      await ready.future.timeout(const Duration(seconds: 90));
    } on Object {
      _available = false;
      _worker?.kill(priority: Isolate.immediate);
      _worker = null;
      _receive?.close();
      _receive = null;
      _commands = null;
      rethrow;
    }
  }

  void _handle(dynamic message) {
    if (message is! Map) {
      final error = StateError('The local memory encoder stopped.');
      _available = false;
      if (!(_ready?.isCompleted ?? true)) _ready!.completeError(error);
      for (final task in _pending.values) {
        if (!task.isCompleted) task.completeError(error);
      }
      _pending.clear();
      if (!(_closed?.isCompleted ?? true)) _closed!.complete();
      return;
    }
    switch (message['type']) {
      case 'stage':
        _stage = message['stage'] as String;
        RuntimeLog.instance.info('MemoryRAG', '本地模型阶段=$_stage');
      case 'model_asset':
        unawaited(_sendModelAsset(message['port'] as SendPort));
      case 'ready':
        if (_disposed) return;
        _commands = message['port'] as SendPort;
        _available = true;
        if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      case 'result':
        final task = _pending.remove(message['id']);
        if (task == null || task.isCompleted) return;
        try {
          task.complete(_validatedVectors(message['vectors'] as List));
        } on Object catch (error, stack) {
          task.completeError(error, stack);
        }
      case 'error':
        final error = StateError(
          'The local memory encoder is unavailable at $_stage '
          '(${message['error_type'] ?? 'unknown'}).',
        );
        if (!(_ready?.isCompleted ?? true)) {
          _ready!.completeError(error);
        }
        final task = _pending.remove(message['id']);
        if (task != null && !task.isCompleted) task.completeError(error);
    }
  }

  Future<void> _sendModelAsset(SendPort port) async {
    try {
      if (_disposed) {
        port.send(null);
        return;
      }
      final bytes = await rootBundle.load('$assetDirectory/model.onnx');
      port.send(
        TransferableTypedData.fromList([
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        ]),
      );
    } on Object {
      port.send(null);
    }
  }

  Future<List<List<double>>> embed(List<String> texts) async {
    if (_disposed) throw StateError('The local memory encoder is disposed.');
    if (texts.isEmpty) return const [];
    if (texts.length > 64 || texts.any((text) => text.runes.length > 4096)) {
      throw ArgumentError(
        'Embed bounded conversation chunks, not whole saves.',
      );
    }
    if (_backend != null) {
      final vectors = _validatedVectors(await _backend(texts));
      if (vectors.length != texts.length) {
        throw const FormatException('Embedding batch size mismatch.');
      }
      return vectors;
    }
    await initialize();
    if (_disposed || _commands == null) {
      throw StateError('The local memory encoder is not running.');
    }
    final id = ++_nextId;
    final task = Completer<List<List<double>>>();
    _pending[id] = task;
    _commands!.send({'type': 'embed', 'id': id, 'texts': texts});
    final vectors = await task.future;
    if (vectors.length != texts.length) {
      throw const FormatException('Embedding batch size mismatch.');
    }
    return vectors;
  }

  static List<List<double>> _validatedVectors(List raw) => raw
      .map((row) {
        if (row is! List || row.length != dimensions) {
          throw const FormatException('Embedding dimensions mismatch.');
        }
        final vector = row
            .map((value) {
              if (value is! num || !value.isFinite) {
                throw const FormatException(
                  'Embedding contains a non-finite value.',
                );
              }
              return value.toDouble();
            })
            .toList(growable: false);
        final norm = math.sqrt(
          vector.fold<double>(0, (sum, value) => sum + value * value),
        );
        if (norm < 1e-9) {
          throw const FormatException('Embedding is a zero vector.');
        }
        return vector.map((value) => value / norm).toList(growable: false);
      })
      .toList(growable: false);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _available = false;
    final error = StateError('The local memory encoder is disposed.');
    for (final task in _pending.values) {
      if (!task.isCompleted) task.completeError(error);
    }
    _pending.clear();
    _commands?.send({'type': 'close'});
    if (_worker != null) {
      try {
        await _closed?.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _worker?.kill(priority: Isolate.immediate);
      }
    }
    _receive?.close();
    _receive = null;
    _worker = null;
    _commands = null;
  }
}

class RagTokenizedText {
  const RagTokenizedText(this.ids, this.mask);
  final List<int> ids;
  final List<int> mask;
}

/// Cased BERT basic tokenizer followed by greedy WordPiece. In particular,
/// Chinese characters are isolated before WordPiece; whitespace-only splitting
/// would turn complete Chinese sentences into UNK for this vocabulary.
class RagWordPieceTokenizer {
  RagWordPieceTokenizer(String vocabulary)
    : _vocabulary = {
        for (final (index, value) in vocabulary.split('\n').indexed)
          value.replaceFirst(RegExp(r'\r$'), ''): index,
      } {
    for (final special in ['[PAD]', '[UNK]', '[CLS]', '[SEP]']) {
      if (!_vocabulary.containsKey(special)) {
        throw const FormatException('Incomplete BERT vocabulary.');
      }
    }
  }
  final Map<String, int> _vocabulary;
  static final _punctuation = RegExp(r'\p{P}', unicode: true);
  static final _control = RegExp(r'\p{C}', unicode: true);
  static final _whitespace = RegExp(r'\s', unicode: true);

  static bool _chinese(int rune) =>
      rune >= 0x4e00 && rune <= 0x9fff ||
      rune >= 0x3400 && rune <= 0x4dbf ||
      rune >= 0x20000 && rune <= 0x2a6df ||
      rune >= 0x2a700 && rune <= 0x2b73f ||
      rune >= 0x2b740 && rune <= 0x2b81f ||
      rune >= 0x2b820 && rune <= 0x2ceaf ||
      rune >= 0xf900 && rune <= 0xfaff ||
      rune >= 0x2f800 && rune <= 0x2fa1f;

  List<int> tokenize(String text) {
    final words = <String>[];
    var current = StringBuffer();
    void flush() {
      if (current.isNotEmpty) words.add(current.toString());
      current = StringBuffer();
    }

    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      if (rune == 0 || rune == 0xfffd) continue;
      if (_whitespace.hasMatch(char)) {
        flush();
      } else if (_control.hasMatch(char)) {
        continue;
      } else if (_chinese(rune) ||
          rune >= 33 && rune <= 47 ||
          rune >= 58 && rune <= 64 ||
          rune >= 91 && rune <= 96 ||
          rune >= 123 && rune <= 126 ||
          _punctuation.hasMatch(char)) {
        flush();
        words.add(char);
      } else {
        current.write(char);
      }
    }
    flush();
    final ids = <int>[];
    for (final word in words) {
      final chars = word.runes.toList();
      if (chars.length > 100) {
        ids.add(_vocabulary['[UNK]']!);
        continue;
      }
      final pieces = <int>[];
      var start = 0;
      while (start < chars.length) {
        int? token;
        var end = chars.length;
        while (end > start) {
          final piece =
              '${start == 0 ? '' : '##'}${String.fromCharCodes(chars.sublist(start, end))}';
          token = _vocabulary[piece];
          if (token != null) break;
          end--;
        }
        if (token == null) {
          pieces
            ..clear()
            ..add(_vocabulary['[UNK]']!);
          break;
        }
        pieces.add(token);
        start = end;
      }
      ids.addAll(pieces);
    }
    return ids;
  }

  RagTokenizedText encode(String text, {int maxTokens = 128, int? padTo}) {
    if (maxTokens < 2 ||
        maxTokens > 512 ||
        padTo != null && (padTo < 2 || padTo > maxTokens)) {
      throw ArgumentError('Invalid BERT sequence length.');
    }
    final tokens = tokenize(text).take((padTo ?? maxTokens) - 2);
    final ids = <int>[_vocabulary['[CLS]']!, ...tokens, _vocabulary['[SEP]']!];
    final mask = List<int>.filled(ids.length, 1, growable: true);
    if (padTo != null) {
      while (ids.length < padTo) {
        ids.add(_vocabulary['[PAD]']!);
        mask.add(0);
      }
    }
    return RagTokenizedText(ids, mask);
  }
}

Future<String> _validatedLocalModel(String supportPath, SendPort owner) async {
  final directory = Directory(
    '$supportPath/rag_models/${RagMemoryEmbeddings.modelId}',
  );
  await directory.create(recursive: true);
  final file = File('${directory.path}/model.onnx');
  final hash = Sha256();
  Future<bool> valid(File value) async =>
      await value.exists() &&
      (await hash.hash(await value.readAsBytes())).bytes
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join() ==
          RagMemoryEmbeddings.modelSha256;
  if (!await valid(file)) {
    final incoming = ReceivePort();
    owner.send({'type': 'model_asset', 'port': incoming.sendPort});
    final TransferableTypedData bytes;
    try {
      final value = await incoming.first.timeout(const Duration(seconds: 45));
      if (value is! TransferableTypedData) {
        throw const FormatException('Memory model asset is missing.');
      }
      bytes = value;
    } finally {
      incoming.close();
    }
    final pending = File('${file.path}.tmp');
    await pending.writeAsBytes(bytes.materialize().asUint8List(), flush: true);
    if (!await valid(pending)) {
      await pending.delete();
      throw const FormatException('Memory model integrity check failed.');
    }
    if (await file.exists()) await file.delete();
    await pending.rename(file.path);
  }
  return file.path;
}

@pragma('vm:entry-point')
Future<void> _runMemoryEmbeddingWorker(List<dynamic> args) async {
  final owner = args[0] as SendPort;
  final commands = ReceivePort();
  OrtSession? session;
  OrtSessionOptions? options;
  try {
    owner.send({'type': 'stage', 'stage': 'validate_model'});
    final model = await _validatedLocalModel(args[1] as String, owner);
    final vocabularyData = (args[2] as TransferableTypedData)
        .materialize()
        .asUint8List();
    final vocabularyHash = (await Sha256().hash(vocabularyData)).bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    if (vocabularyHash != RagMemoryEmbeddings.vocabularySha256) {
      throw const FormatException('Memory vocabulary integrity check failed.');
    }
    final tokenizer = RagWordPieceTokenizer(utf8.decode(vocabularyData));
    owner.send({'type': 'stage', 'stage': 'create_session'});
    OrtEnv.instance.init(logId: 'AgentAtelierMemory');
    options = OrtSessionOptions()
      ..setIntraOpNumThreads(2)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    // The package's fromFile FFI path uses char*, while Windows ORT expects
    // wchar_t*. Buffer construction avoids corrupt path decoding on Windows.
    session = Platform.isWindows
        ? OrtSession.fromBuffer(await File(model).readAsBytes(), options)
        : OrtSession.fromFile(File(model), options);
    if (session.inputNames.length != 2 ||
        !session.inputNames.contains('input_ids') ||
        !session.inputNames.contains('attention_mask') ||
        session.outputNames.single != 'sentence_embedding') {
      throw const FormatException('Unexpected memory model graph.');
    }
    owner.send({'type': 'ready', 'port': commands.sendPort});
    await for (final message in commands) {
      if (message is! Map) continue;
      if (message['type'] == 'close') break;
      if (message['type'] != 'embed') continue;
      try {
        final texts = (message['texts'] as List).cast<String>();
        final vectors = <List<double>>[];
        // Small bounded batches keep memory/CPU predictable on mobile devices.
        for (var start = 0; start < texts.length; start += 4) {
          final batch = texts.sublist(start, math.min(start + 4, texts.length));
          final encoded = batch.map(tokenizer.encode).toList();
          final length = encoded
              .map((item) => item.ids.length)
              .reduce(math.max);
          final inputs = <String, OrtValue>{};
          final run = OrtRunOptions();
          List<OrtValue?>? output;
          try {
            final ids = <int>[], masks = <int>[];
            for (final row in batch) {
              final input = tokenizer.encode(row, padTo: length);
              ids.addAll(input.ids);
              masks.addAll(input.mask);
            }
            inputs['input_ids'] = OrtValueTensor.createTensorWithDataList(
              Int64List.fromList(ids),
              [batch.length, length],
            );
            inputs['attention_mask'] = OrtValueTensor.createTensorWithDataList(
              Int64List.fromList(masks),
              [batch.length, length],
            );
            output = session.run(run, inputs);
            vectors.addAll(
              RagMemoryEmbeddings._validatedVectors(
                output.single!.value as List,
              ),
            );
          } finally {
            for (final input in inputs.values) {
              input.release();
            }
            for (final value in output ?? const <OrtValue?>[]) {
              value?.release();
            }
            run.release();
          }
        }
        owner.send({'type': 'result', 'id': message['id'], 'vectors': vectors});
      } on Object catch (error) {
        owner.send({
          'type': 'error',
          'id': message['id'],
          'error_type': error.runtimeType.toString(),
        });
      }
    }
  } on Object catch (error) {
    owner.send({'type': 'error', 'error_type': error.runtimeType.toString()});
  } finally {
    session?.release();
    options?.release();
    // OrtEnv is process-global; another isolate/native model may still use it.
    commands.close();
  }
}
