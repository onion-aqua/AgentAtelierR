import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum ImageGenerationTaskStatus {
  queued,
  generating,
  completed,
  failed,
  cancelled,
}

const _unchangedImageTaskValue = Object();

@immutable
class ImageGenerationTask {
  const ImageGenerationTask({
    required this.id,
    required this.prompt,
    required this.status,
    required this.createdAt,
    required this.protocol,
    required this.seen,
    this.outcomeUnknown = false,
    this.completedAt,
    this.model,
    this.localPath,
    this.mimeType,
    this.error,
    this.messageId,
  });

  final String id;
  final String prompt;
  final ImageGenerationTaskStatus status;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String protocol;
  final String? model;
  final String? localPath;
  final String? mimeType;
  final String? error;
  final String? messageId;
  final bool seen;
  final bool outcomeUnknown;

  bool get isActive =>
      status == ImageGenerationTaskStatus.queued ||
      status == ImageGenerationTaskStatus.generating;

  bool get hasImage =>
      status == ImageGenerationTaskStatus.completed && localPath != null;

  ImageGenerationTask copyWith({
    String? prompt,
    ImageGenerationTaskStatus? status,
    DateTime? createdAt,
    Object? completedAt = _unchangedImageTaskValue,
    String? protocol,
    Object? model = _unchangedImageTaskValue,
    Object? localPath = _unchangedImageTaskValue,
    Object? mimeType = _unchangedImageTaskValue,
    Object? error = _unchangedImageTaskValue,
    Object? messageId = _unchangedImageTaskValue,
    bool? seen,
    bool? outcomeUnknown,
  }) => ImageGenerationTask(
    id: id,
    prompt: prompt ?? this.prompt,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
    completedAt: identical(completedAt, _unchangedImageTaskValue)
        ? this.completedAt
        : completedAt as DateTime?,
    protocol: protocol ?? this.protocol,
    model: identical(model, _unchangedImageTaskValue)
        ? this.model
        : model as String?,
    localPath: identical(localPath, _unchangedImageTaskValue)
        ? this.localPath
        : localPath as String?,
    mimeType: identical(mimeType, _unchangedImageTaskValue)
        ? this.mimeType
        : mimeType as String?,
    error: identical(error, _unchangedImageTaskValue)
        ? this.error
        : error as String?,
    messageId: identical(messageId, _unchangedImageTaskValue)
        ? this.messageId
        : messageId as String?,
    seen: seen ?? this.seen,
    outcomeUnknown: outcomeUnknown ?? this.outcomeUnknown,
  );
}

/// Stores generated images independently from chat saves.
///
/// Only relative, store-owned filenames are written to the manifest. Original
/// response bytes are copied into the application support directory and can be
/// read again after process restart through [readImage].
class ImageGenerationStore extends ChangeNotifier {
  ImageGenerationStore({
    Future<Directory> Function()? directoryProvider,
    DateTime Function()? clock,
    String Function()? idGenerator,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _clock = clock ?? DateTime.now,
       _idGenerator = idGenerator ?? _newId;

  static const _manifestName = 'tasks.v1.json';
  static const _manifestVersion = 1;
  static const _maxImageBytes = 32 * 1024 * 1024;
  static const _maxPromptLength = 16000;
  static const _maxErrorLength = 1200;
  static final _validId = RegExp(r'^img_[0-9a-f]{32}$');
  static final _validImageFilename = RegExp(
    r'^img_[0-9a-f]{32}\.(?:png|jpg|webp|gif|avif)$',
  );
  static final math.Random _secureRandom = math.Random.secure();

  final Future<Directory> Function() _directoryProvider;
  final DateTime Function() _clock;
  final String Function() _idGenerator;
  final List<ImageGenerationTask> _tasks = [];
  Future<void> _operations = Future<void>.value();
  Directory? _directory;
  bool _loaded = false;
  bool _disposed = false;

  List<ImageGenerationTask> get tasks => List.unmodifiable(_tasks);

  int get activeCount => _tasks.where((task) => task.isActive).length;

  bool get isGenerating => activeCount > 0;

  int get unseenCompletedCount => _tasks
      .where(
        (task) =>
            task.status == ImageGenerationTaskStatus.completed && !task.seen,
      )
      .length;

  bool get hasUnseenCompleted => unseenCompletedCount > 0;

  Future<void> load() => _enqueue(_load);

  ImageGenerationTask? taskById(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  Future<ImageGenerationTask> createTask({
    required String prompt,
    String protocol = 'auto',
    String? model,
    String? messageId,
  }) => _enqueue(() async {
    await _load();
    final normalizedPrompt = _requiredText(prompt, 'prompt', _maxPromptLength);
    final id = _nextUniqueId();
    final task = ImageGenerationTask(
      id: id,
      prompt: normalizedPrompt,
      status: ImageGenerationTaskStatus.queued,
      createdAt: _clock().toUtc(),
      protocol: _boundedText(protocol, fallback: 'auto', maxLength: 64),
      model: _optionalText(model, 256),
      messageId: _optionalText(messageId, 256),
      seen: true,
    );
    final next = [task, ..._tasks];
    await _persist(next);
    _tasks
      ..clear()
      ..addAll(next);
    _notify();
    return task;
  });

  Future<ImageGenerationTask> markGenerating(
    String id, {
    String? protocol,
    Object? model = _unchangedImageTaskValue,
  }) => _enqueue(() async {
    await _load();
    final current = _requireTask(id);
    if (current.status != ImageGenerationTaskStatus.queued) {
      throw StateError('只有排队中的生图任务可以开始。');
    }
    final updated = current.copyWith(
      status: ImageGenerationTaskStatus.generating,
      protocol: protocol == null
          ? null
          : _boundedText(protocol, fallback: current.protocol, maxLength: 64),
      model: identical(model, _unchangedImageTaskValue)
          ? _unchangedImageTaskValue
          : _optionalText(model as String?, 256),
      error: null,
      seen: true,
    );
    await _replace(current, updated);
    return updated;
  });

  Future<ImageGenerationTask> complete(
    String id, {
    required Uint8List bytes,
    String? mimeType,
    String? protocol,
    Object? model = _unchangedImageTaskValue,
    Object? messageId = _unchangedImageTaskValue,
  }) {
    if (bytes.isEmpty || bytes.length > _maxImageBytes) {
      return Future.error(const FormatException('生成图片为空或超过 32 MB，无法保存。'));
    }
    final snapshot = Uint8List.fromList(bytes);
    late final ({String mimeType, String extension}) imageType;
    try {
      imageType = _detectImageType(snapshot, declaredMimeType: mimeType);
    } on FormatException catch (error, stackTrace) {
      return Future.error(error, stackTrace);
    }
    return _enqueue(() async {
      await _load();
      final current = _requireTask(id);
      if (current.status != ImageGenerationTaskStatus.generating &&
          current.status != ImageGenerationTaskStatus.queued) {
        throw StateError('任务已经结束，不能重复写入生成结果。');
      }
      final directory = await _managedDirectory();
      final filename = '${current.id}.${imageType.extension}';
      final finalFile = _file(directory, filename);
      final pendingFile = _file(directory, '$filename.pending');
      if (await finalFile.exists()) {
        throw StateError('任务图片已存在，拒绝覆盖。');
      }
      try {
        await pendingFile.writeAsBytes(snapshot, flush: true);
        await pendingFile.rename(finalFile.path);
        final updated = current.copyWith(
          status: ImageGenerationTaskStatus.completed,
          completedAt: _clock().toUtc(),
          protocol: protocol == null
              ? null
              : _boundedText(
                  protocol,
                  fallback: current.protocol,
                  maxLength: 64,
                ),
          model: identical(model, _unchangedImageTaskValue)
              ? _unchangedImageTaskValue
              : _optionalText(model as String?, 256),
          messageId: identical(messageId, _unchangedImageTaskValue)
              ? _unchangedImageTaskValue
              : _optionalText(messageId as String?, 256),
          localPath: finalFile.path,
          mimeType: imageType.mimeType,
          error: null,
          seen: false,
        );
        await _replace(current, updated);
        return updated;
      } catch (_) {
        await _deleteOwnedFile(pendingFile);
        await _deleteOwnedFile(finalFile);
        rethrow;
      }
    });
  }

  Future<ImageGenerationTask> fail(
    String id,
    Object error, {
    bool outcomeUnknown = false,
  }) => _finishWithoutImage(
    id,
    ImageGenerationTaskStatus.failed,
    _safeErrorText(error),
    outcomeUnknown: outcomeUnknown,
  );

  Future<ImageGenerationTask> cancel(String id) =>
      _finishWithoutImage(id, ImageGenerationTaskStatus.cancelled, null);

  Future<ImageGenerationTask> retry(
    String id, {
    bool allowUnknownOutcome = false,
  }) => _enqueue(() async {
    await _load();
    final current = _requireTask(id);
    if (current.status == ImageGenerationTaskStatus.queued &&
        !current.outcomeUnknown) {
      return current;
    }
    if (current.status != ImageGenerationTaskStatus.failed &&
        current.status != ImageGenerationTaskStatus.cancelled) {
      throw StateError('只有失败或已取消的任务可以重新排队。');
    }
    if (current.outcomeUnknown && !allowUnknownOutcome) {
      throw StateError('远端生成结果未知，重新提交可能重复计费，请先明确确认。');
    }
    final updated = current.copyWith(
      status: ImageGenerationTaskStatus.queued,
      completedAt: null,
      localPath: null,
      mimeType: null,
      error: null,
      seen: true,
      outcomeUnknown: false,
    );
    await _replace(current, updated);
    return updated;
  });

  Future<ImageGenerationTask> linkMessage(String id, String? messageId) =>
      _enqueue(() async {
        await _load();
        final current = _requireTask(id);
        final updated = current.copyWith(
          messageId: _optionalText(messageId, 256),
        );
        await _replace(current, updated);
        return updated;
      });

  Future<void> markSeen(String id) => _enqueue(() async {
    await _load();
    final current = _requireTask(id);
    if (current.seen) return;
    await _replace(current, current.copyWith(seen: true));
  });

  Future<void> markAllCompletedSeen() => _enqueue(() async {
    await _load();
    var changed = false;
    final next = [
      for (final task in _tasks)
        if (task.status == ImageGenerationTaskStatus.completed && !task.seen)
          (changed = true, task.copyWith(seen: true)).$2
        else
          task,
    ];
    if (!changed) return;
    await _persist(next);
    _tasks
      ..clear()
      ..addAll(next);
    _notify();
  });

  Future<Uint8List> readImage(String id) => _enqueue(() async {
    await _load();
    final task = _requireTask(id);
    final path = task.localPath;
    if (!task.hasImage || path == null) {
      throw StateError('任务没有可读取的图片。');
    }
    final file = File(path);
    if (!await _isOwnedImageFile(file, expectedId: task.id)) {
      throw StateError('生成图片已丢失或损坏。');
    }
    return file.readAsBytes();
  });

  Future<void> delete(String id) => _enqueue(() async {
    await _load();
    final current = _requireTask(id);
    if (current.isActive) throw StateError('请先取消正在生成的任务。');
    final next = _tasks.where((task) => task.id != id).toList();
    await _persist(next);
    _tasks
      ..clear()
      ..addAll(next);
    _notify();
    final path = current.localPath;
    if (path != null) await _deleteOwnedFile(File(path));
  });

  Future<ImageGenerationTask> _finishWithoutImage(
    String id,
    ImageGenerationTaskStatus status,
    String? error, {
    bool outcomeUnknown = false,
  }) => _enqueue(() async {
    await _load();
    final current = _requireTask(id);
    if (!current.isActive) throw StateError('任务已经结束。');
    final updated = current.copyWith(
      status: status,
      completedAt: _clock().toUtc(),
      localPath: null,
      mimeType: null,
      error: error,
      seen: true,
      outcomeUnknown: outcomeUnknown,
    );
    await _replace(current, updated);
    return updated;
  });

  Future<void> _replace(
    ImageGenerationTask current,
    ImageGenerationTask updated,
  ) async {
    final index = _tasks.indexWhere((task) => task.id == current.id);
    if (index < 0) throw StateError('生图任务不存在。');
    final next = [..._tasks]..[index] = updated;
    await _persist(next);
    _tasks
      ..clear()
      ..addAll(next);
    _notify();
  }

  ImageGenerationTask _requireTask(String id) {
    if (!_validId.hasMatch(id)) throw StateError('生图任务不存在。');
    final task = taskById(id);
    if (task == null) throw StateError('生图任务不存在。');
    return task;
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_disposed) return Future.error(StateError('生图任务存储已关闭。'));
    final result = _operations.then((_) async {
      if (_disposed) throw StateError('生图任务存储已关闭。');
      return operation();
    });
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _load() async {
    if (_loaded) return;
    final directory = await _managedDirectory();
    final decoded = await _readManifest(directory);
    final restored = <ImageGenerationTask>[];
    final seenIds = <String>{};
    var changed = false;
    if (decoded case {'tasks': final List<dynamic> records}) {
      for (final raw in records) {
        if (raw is! Map) {
          changed = true;
          continue;
        }
        final result = await _restoreTask(
          Map<String, dynamic>.from(raw),
          directory,
        );
        final task = result.task;
        changed |= result.changed;
        if (task == null || !seenIds.add(task.id)) {
          changed = true;
          continue;
        }
        restored.add(task);
      }
    } else if (decoded != null) {
      changed = true;
    }
    restored.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _tasks
      ..clear()
      ..addAll(restored);
    _loaded = true;
    if (changed) {
      try {
        await _persist(restored);
      } on FileSystemException {
        // Valid recovered tasks remain usable even if cleanup cannot be saved.
      }
    }
    _notify();
  }

  Future<({ImageGenerationTask? task, bool changed})> _restoreTask(
    Map<String, dynamic> record,
    Directory directory,
  ) async {
    final id = record['id'];
    final prompt = record['prompt'];
    final statusName = record['status'];
    final createdRaw = record['createdAt'];
    if (id is! String ||
        !_validId.hasMatch(id) ||
        prompt is! String ||
        prompt.trim().isEmpty ||
        prompt.length > _maxPromptLength ||
        statusName is! String ||
        createdRaw is! String) {
      return (task: null, changed: true);
    }
    final status = ImageGenerationTaskStatus.values
        .where((candidate) => candidate.name == statusName)
        .firstOrNull;
    final createdAt = DateTime.tryParse(createdRaw)?.toUtc();
    if (status == null || createdAt == null) {
      return (task: null, changed: true);
    }
    var restoredStatus = status;
    var completedAt = _parseDate(record['completedAt']);
    String? localPath;
    var mimeType = _optionalText(_stringOrNull(record['mimeType']), 64);
    var error = _optionalText(_stringOrNull(record['error']), _maxErrorLength);
    var outcomeUnknown = record['outcomeUnknown'] == true;
    var changed = false;
    final filename = record['imageFile'];
    if (status == ImageGenerationTaskStatus.completed) {
      if (filename is String &&
          _validImageFilename.hasMatch(filename) &&
          filename.startsWith('$id.') &&
          await _isOwnedImageFile(_file(directory, filename), expectedId: id)) {
        localPath = _file(directory, filename).path;
        final detected = _detectImageType(await File(localPath).readAsBytes());
        if (mimeType != detected.mimeType) changed = true;
        mimeType = detected.mimeType;
        if (outcomeUnknown) {
          outcomeUnknown = false;
          changed = true;
        }
      } else {
        restoredStatus = ImageGenerationTaskStatus.failed;
        completedAt ??= _clock().toUtc();
        mimeType = null;
        error = '生成图片已丢失或损坏。';
        outcomeUnknown = false;
        changed = true;
      }
    } else if (status == ImageGenerationTaskStatus.generating) {
      // The request may have reached a paid provider. Never resubmit it on
      // startup because the outcome is unknown.
      restoredStatus = ImageGenerationTaskStatus.failed;
      completedAt ??= _clock().toUtc();
      error = '应用在生成期间中断，远端结果状态未知，请确认后再重试。';
      outcomeUnknown = true;
      changed = true;
    } else if (status == ImageGenerationTaskStatus.queued) {
      // There is no process-wide dispatcher that can safely adopt old queued
      // work. Mark it retryable instead of leaving a permanent loading ring.
      restoredStatus = ImageGenerationTaskStatus.failed;
      completedAt ??= _clock().toUtc();
      error = '应用在请求提交前中断，本次任务尚未生成，可以手动重试。';
      outcomeUnknown = false;
      changed = true;
    } else if (status != ImageGenerationTaskStatus.failed && outcomeUnknown) {
      outcomeUnknown = false;
      changed = true;
    }
    final task = ImageGenerationTask(
      id: id,
      prompt: prompt.trim(),
      status: restoredStatus,
      createdAt: createdAt,
      completedAt: completedAt,
      protocol: _boundedText(
        _stringOrNull(record['protocol']),
        fallback: 'auto',
        maxLength: 64,
      ),
      model: _optionalText(_stringOrNull(record['model']), 256),
      localPath: localPath,
      mimeType: mimeType,
      error: error,
      messageId: _optionalText(_stringOrNull(record['messageId']), 256),
      seen: record['seen'] is bool ? record['seen'] as bool : true,
      outcomeUnknown: outcomeUnknown,
    );
    return (task: task, changed: changed);
  }

  Future<Map<String, dynamic>?> _readManifest(Directory directory) async {
    for (final name in [_manifestName, '$_manifestName.bak']) {
      final file = _file(directory, name);
      try {
        if (!await file.exists()) continue;
        final length = await file.length();
        if (length <= 0 || length > 16 * 1024 * 1024) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['version'] == _manifestVersion) {
          return Map<String, dynamic>.from(decoded);
        }
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  Future<void> _persist(List<ImageGenerationTask> tasks) async {
    final directory = await _managedDirectory();
    final manifest = _file(directory, _manifestName);
    final temporary = _file(directory, '$_manifestName.pending');
    final backup = _file(directory, '$_manifestName.bak');
    final payload = jsonEncode({
      'version': _manifestVersion,
      'tasks': tasks.map(_taskRecord).toList(),
    });
    await temporary.writeAsString(payload, flush: true);
    var backedUp = false;
    try {
      if (await backup.exists()) await backup.delete();
      if (await manifest.exists()) {
        await manifest.rename(backup.path);
        backedUp = true;
      }
      await temporary.rename(manifest.path);
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The committed manifest is already authoritative.
        }
      }
    } catch (_) {
      if (!await manifest.exists() && backedUp && await backup.exists()) {
        try {
          await backup.rename(manifest.path);
        } on FileSystemException {
          // Keep the backup for recovery on the next startup.
        }
      }
      rethrow;
    } finally {
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on FileSystemException {
          // A stale pending manifest is ignored during load.
        }
      }
    }
  }

  Map<String, dynamic> _taskRecord(ImageGenerationTask task) {
    String? imageFile;
    final path = task.localPath;
    if (path != null) {
      final filename = File(path).uri.pathSegments.last;
      if (_validImageFilename.hasMatch(filename) &&
          filename.startsWith('${task.id}.')) {
        imageFile = filename;
      }
    }
    return {
      'id': task.id,
      'prompt': task.prompt,
      'status': task.status.name,
      'createdAt': task.createdAt.toUtc().toIso8601String(),
      if (task.completedAt case final completedAt?)
        'completedAt': completedAt.toUtc().toIso8601String(),
      'protocol': task.protocol,
      'model': ?task.model,
      'imageFile': ?imageFile,
      'mimeType': ?task.mimeType,
      'error': ?task.error,
      'messageId': ?task.messageId,
      'seen': task.seen,
      'outcomeUnknown': task.outcomeUnknown,
    };
  }

  Future<Directory> _managedDirectory() async {
    if (_directory case final directory?) return directory;
    final requested = (await _directoryProvider()).absolute;
    await requested.create(recursive: true);
    final resolved = Directory(await requested.resolveSymbolicLinks());
    _directory = resolved;
    return resolved;
  }

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
      '${support.path}${Platform.pathSeparator}image_generations',
    );
  }

  static File _file(Directory directory, String name) =>
      File('${directory.path}${Platform.pathSeparator}$name');

  Future<bool> _isOwnedImageFile(
    File file, {
    required String expectedId,
  }) async {
    final filename = file.uri.pathSegments.last;
    if (!_validImageFilename.hasMatch(filename) ||
        !filename.startsWith('$expectedId.')) {
      return false;
    }
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final directory = await _managedDirectory();
      if (file.parent.absolute.path != directory.absolute.path) return false;
      final length = await file.length();
      if (length <= 0 || length > _maxImageBytes) return false;
      _detectImageType(await file.readAsBytes());
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<void> _deleteOwnedFile(File file) async {
    final filename = file.uri.pathSegments.last;
    final isPending = filename.endsWith('.pending');
    final base = isPending
        ? filename.substring(0, filename.length - '.pending'.length)
        : filename;
    if (!_validImageFilename.hasMatch(base)) return;
    try {
      final directory = await _managedDirectory();
      if (file.parent.absolute.path != directory.absolute.path) return;
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return;
      }
      await file.delete();
    } on FileSystemException {
      // Metadata is authoritative; a locked stale file is harmless.
    }
  }

  String _nextUniqueId() {
    for (var attempt = 0; attempt < 20; attempt++) {
      final id = _idGenerator();
      if (_validId.hasMatch(id) && !_tasks.any((task) => task.id == id)) {
        return id;
      }
    }
    throw StateError('无法创建唯一的生图任务编号。');
  }

  static String _newId() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0'));
    return 'img_${hex.join()}';
  }

  static String _requiredText(String value, String name, int maxLength) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > maxLength) {
      throw ArgumentError.value(value, name);
    }
    return normalized;
  }

  static String _boundedText(
    String? value, {
    required String fallback,
    required int maxLength,
  }) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return fallback;
    return normalized.length <= maxLength
        ? normalized
        : normalized.substring(0, maxLength);
  }

  static String? _optionalText(String? value, int maxLength) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return normalized.length <= maxLength
        ? normalized
        : normalized.substring(0, maxLength);
  }

  static String? _stringOrNull(Object? value) => value is String ? value : null;

  static String _safeErrorText(Object error) {
    var text = error.toString().replaceAll(
      RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f]'),
      ' ',
    );
    text = text.replaceAllMapped(
      RegExp(
        r'((?:authorization|api[-_]?key|x-goog-api-key|access[-_]?token|token)\s*[:=]\s*)(?:bearer\s+)?[^\s,;]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    text = text.replaceAllMapped(
      RegExp(
        r'([?&](?:key|api_key|access_token|token)=)[^&#\s]+',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}[REDACTED]',
    );
    text = text.replaceAll(
      RegExp(r'\bsk-[A-Za-z0-9_-]{8,}\b', caseSensitive: false),
      '[REDACTED]',
    );
    return _boundedText(text, fallback: '图片生成失败。', maxLength: _maxErrorLength);
  }

  static DateTime? _parseDate(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

  static ({String mimeType, String extension}) _detectImageType(
    Uint8List bytes, {
    String? declaredMimeType,
  }) {
    ({String mimeType, String extension})? detected;
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      detected = (mimeType: 'image/png', extension: 'png');
    } else if (bytes.length >= 4 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff &&
        bytes[bytes.length - 2] == 0xff &&
        bytes[bytes.length - 1] == 0xd9) {
      detected = (mimeType: 'image/jpeg', extension: 'jpg');
    } else if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      detected = (mimeType: 'image/webp', extension: 'webp');
    } else if (bytes.length >= 7) {
      final header = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
      if ((header == 'GIF87a' || header == 'GIF89a') && bytes.last == 0x3b) {
        detected = (mimeType: 'image/gif', extension: 'gif');
      }
    }
    if (detected == null && bytes.length >= 12) {
      final box = ascii.decode(bytes.sublist(4, 8), allowInvalid: true);
      final brand = ascii.decode(bytes.sublist(8, 12), allowInvalid: true);
      if (box == 'ftyp' && (brand == 'avif' || brand == 'avis')) {
        detected = (mimeType: 'image/avif', extension: 'avif');
      }
    }
    if (detected == null) {
      throw const FormatException('响应内容不是受支持的 PNG、JPEG、WebP、GIF 或 AVIF 图片。');
    }
    final declared = declaredMimeType
        ?.split(';')
        .first
        .trim()
        .toLowerCase()
        .replaceAll('image/jpg', 'image/jpeg');
    if (declared != null &&
        declared.isNotEmpty &&
        declared != 'application/octet-stream' &&
        declared != detected.mimeType) {
      throw const FormatException('图片 MIME 类型与文件内容不一致。');
    }
    return detected;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
