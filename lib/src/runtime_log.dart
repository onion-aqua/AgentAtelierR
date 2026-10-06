import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RuntimeLogLevel { info, warning, error }

enum RuntimeLogModule {
  llm,
  tts,
  expression,
  action,
  speech,
  memory,
  translation,
  character,
  storage,
  system;

  static RuntimeLogModule forSource(String source) {
    final name = source.trim().toLowerCase();
    if (name == 'plan_character_expression') return expression;
    if (name == 'plan_character_action' || name == 'actionplanner') {
      return action;
    }
    if (name == 'speechplanner') return speech;
    if (name == 'memory') return memory;
    if (name == 'translation') return translation;
    if (name == 'llm' || name == 'ai' || name.startsWith('ai ')) return llm;
    if (name.contains('tts') || name.contains('fish audio')) return tts;
    if (name.startsWith('character') ||
        name == 'lipsync' ||
        name == 'skinimport') {
      return character;
    }
    if (name == 'persistence' ||
        name.contains('data import') ||
        name.contains('data conversion')) {
      return storage;
    }
    // New sources remain visible rather than silently disappearing.
    return system;
  }
}

extension RuntimeLogLevelLabel on RuntimeLogLevel {
  String get label => switch (this) {
    RuntimeLogLevel.info => 'INFO',
    RuntimeLogLevel.warning => 'WARN',
    RuntimeLogLevel.error => 'ERROR',
  };
}

class RuntimeLogEntry {
  static int _nextLegacyId = 0;

  const RuntimeLogEntry({
    this.id = '',
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
    this.repeatCount = 1,
    this.lastTimestamp,
  });

  factory RuntimeLogEntry.fromJson(Map<String, dynamic> json) {
    final timestamp =
        DateTime.tryParse(json['timestamp'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final storedId = json['id'] as String? ?? '';
    return RuntimeLogEntry(
      id: storedId.isEmpty
          ? 'legacy:${timestamp.microsecondsSinceEpoch}:${_nextLegacyId++}'
          : storedId,
      timestamp: timestamp,
      level: RuntimeLogLevel.values.firstWhere(
        (value) => value.name == json['level'],
        orElse: () => RuntimeLogLevel.info,
      ),
      source: json['source'] as String? ?? 'App',
      message: json['message'] as String? ?? '',
      repeatCount: switch (json['repeatCount']) {
        final int count when count > 0 => count,
        _ => 1,
      },
      lastTimestamp: DateTime.tryParse(json['lastTimestamp'] as String? ?? ''),
    );
  }

  final String id;
  final DateTime timestamp;
  final RuntimeLogLevel level;
  final String source;
  final String message;
  final int repeatCount;
  final DateTime? lastTimestamp;
  String get identity => id.isEmpty
      ? '${timestamp.microsecondsSinceEpoch}:${source.hashCode}:${level.index}:${message.hashCode}'
      : id;
  RuntimeLogModule get module => RuntimeLogModule.forSource(source);
  String get displayMessage => RuntimeLog.prettyMessage(message);

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'level': level.name,
    'source': source,
    'message': message,
    'repeatCount': repeatCount,
    if (lastTimestamp != null)
      'lastTimestamp': lastTimestamp!.toIso8601String(),
  };

  String get formatted {
    final local = timestamp.toLocal().toIso8601String().replaceFirst('T', ' ');
    final repeated = repeatCount > 1
        ? ' [重复 $repeatCount 次；最近发生=${lastTimestamp?.toLocal().toIso8601String()}]'
        : '';
    return '[$local] [${level.label}] [$source]$repeated\n$displayMessage';
  }
}

class RuntimeLog extends ChangeNotifier {
  RuntimeLog._();

  @visibleForTesting
  RuntimeLog.forTesting() : this._();

  static final RuntimeLog instance = RuntimeLog._();
  static const _storageKey = 'runtime_debug_logs_v1';
  static const maxEntries = 250;

  final List<RuntimeLogEntry> _entries = [];
  final Map<String, DateTime> _lastRateLimitedInfo = {};
  Future<void> _writeQueue = Future<void>.value();
  Future<void>? _initialization;
  SharedPreferences? _preferences;
  bool _initialized = false;
  bool _discardStoredOnInitialize = false;
  bool _notificationScheduled = false;
  bool _persistScheduled = false;
  bool _persistDirty = false;
  int _nextEntryId = 0;

  List<RuntimeLogEntry> get entries => List.unmodifiable(_entries);

  String get formattedText => _entries.isEmpty
      ? '暂无运行日志。'
      : _entries.reversed.map((entry) => entry.formatted).join('\n');

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initialization ??= _loadStoredEntries();
  }

  Future<void> _loadStoredEntries() async {
    try {
      _preferences ??= await SharedPreferences.getInstance();
      final stored = _discardStoredOnInitialize
          ? const <String>[]
          : _preferences!.getStringList(_storageKey) ?? const <String>[];
      final pending = List<RuntimeLogEntry>.of(_entries);
      final identities = pending.map((entry) => entry.identity).toSet();
      final restored = <RuntimeLogEntry>[];
      for (final value in stored) {
        try {
          final entry = RuntimeLogEntry.fromJson(
            jsonDecode(value) as Map<String, dynamic>,
          );
          if (identities.add(entry.identity)) restored.add(entry);
        } on Object {
          // A corrupt row must not hide valid rows or startup diagnostics.
        }
      }
      _entries
        ..clear()
        ..addAll(restored)
        ..addAll(pending);
      if (_entries.length > maxEntries) {
        _entries.removeRange(0, _entries.length - maxEntries);
      }
      _initialized = true;
      _queueNotification();
    } on Object {
      // Startup errors already in memory survive a failed storage read. A
      // later initialize/write can retry rather than reusing a failed future.
      _initialization = null;
      _preferences = null;
      rethrow;
    }
  }

  void info(String source, String message) =>
      add(RuntimeLogLevel.info, source, message);

  void infoRateLimited(
    String source,
    String category,
    String message, {
    Duration interval = const Duration(seconds: 15),
  }) {
    final key = '$source:$category';
    final now = DateTime.now();
    final last = _lastRateLimitedInfo[key];
    if (last != null && now.difference(last) < interval) return;
    _lastRateLimitedInfo[key] = now;
    info(source, message);
  }

  void warning(String source, String message) =>
      add(RuntimeLogLevel.warning, source, message);

  void error(String source, Object error, [StackTrace? stackTrace]) {
    final stack = stackTrace?.toString().split('\n').take(12).join(' | ');
    add(
      RuntimeLogLevel.error,
      source,
      stack == null || stack.isEmpty ? '$error' : '$error | $stack',
    );
  }

  void add(
    RuntimeLogLevel level,
    String source,
    String message, {
    bool preserveFormatting = false,
  }) {
    final timestamp = DateTime.now();
    final safeSource = sanitize(source, maxLength: 80);
    final safeMessage = preserveFormatting
        ? _sanitizeFormatted(message)
        : prettyMessage(message);
    final previous = _entries.isEmpty ? null : _entries.last;
    if (level == RuntimeLogLevel.error &&
        previous?.level == level &&
        previous?.source == safeSource &&
        previous?.message == safeMessage &&
        timestamp.difference(previous!.lastTimestamp ?? previous.timestamp) <
            const Duration(seconds: 5)) {
      _entries[_entries.length - 1] = RuntimeLogEntry(
        id: previous.identity,
        timestamp: previous.timestamp,
        level: previous.level,
        source: previous.source,
        message: previous.message,
        repeatCount: previous.repeatCount + 1,
        lastTimestamp: timestamp,
      );
    } else {
      _entries.add(
        RuntimeLogEntry(
          id: '${timestamp.microsecondsSinceEpoch}:${_nextEntryId++}',
          timestamp: timestamp,
          level: level,
          source: safeSource,
          message: safeMessage,
        ),
      );
    }
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    _queueNotification();
    _queuePersist();
  }

  /// Records an LLM/TTS HTTP exchange without credentials or binary payloads.
  void communication({
    required String source,
    required String direction,
    required String method,
    required String url,
    int? statusCode,
    required Object payload,
    Duration? duration,
  }) {
    final safeUrl = _safeUrl(url);
    final details = <String, Object?>{
      'direction': direction,
      'method': method,
      'url': safeUrl,
      ...statusCode == null ? const {} : {'status': statusCode},
      ...duration == null ? const {} : {'duration_ms': duration.inMilliseconds},
      'payload': payload,
    };
    final encoded = const JsonEncoder.withIndent('  ')
        .convert(_redactStructured(details));
    add(RuntimeLogLevel.info, source, encoded, preserveFormatting: true);
  }

  static String _sanitizeFormatted(String value) {
    final lines = value.split(RegExp(r'\r?\n'));
    return lines.map((line) => sanitize(line, maxLength: 12000)).join('\n');
  }

  static String prettyMessage(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map || decoded is List) {
        return const JsonEncoder.withIndent('  ')
            .convert(_redactStructured(decoded));
      }
    } on FormatException {
      // Text, truncated JSON and streaming fragments remain readable.
    }
    return _sanitizeFormatted(message);
  }

  static Object? _redactStructured(Object? value, [int depth = 0]) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          '${entry.key}': _isSensitiveField('${entry.key}')
              ? '[REDACTED]'
              : _redactStructured(entry.value, depth + 1),
      };
    }
    if (value is Iterable) {
      return value
          .map((item) => _redactStructured(item, depth + 1))
          .toList(growable: false);
    }
    if (value is String) {
      if (depth < 12 &&
          (value.trimLeft().startsWith('{') ||
              value.trimLeft().startsWith('['))) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is Map || decoded is List) {
            return _redactStructured(decoded, depth + 1);
          }
        } on FormatException {
          /* Plain text is retained below. */
        }
      }
      return _sanitizeFormatted(value);
    }
    return value;
  }

  static bool _isSensitiveField(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    return normalized.contains('apikey') ||
        normalized.contains('accesstoken') ||
        normalized.contains('refreshtoken') ||
        normalized == 'token' ||
        normalized.contains('authorization') ||
        normalized.contains('secret');
  }

  static String _safeUrl(String value) {
    try {
      final uri = Uri.parse(value);
      return uri.replace(queryParameters: const {}).toString();
    } on Object {
      return sanitize(value, maxLength: 500);
    }
  }

  Future<void> clear() async {
    if (!_initialized) _discardStoredOnInitialize = true;
    _entries.clear();
    _lastRateLimitedInfo.clear();
    _queueNotification();
    _queuePersist();
    await _writeQueue;
  }

  static String sanitize(String value, {int maxLength = 2000}) {
    var result = value
        .replaceAll(
          RegExp(r'Bearer\s+[A-Za-z0-9._~+\-/=]+', caseSensitive: false),
          'Bearer [REDACTED]',
        )
        .replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]{8,}\b'), 'sk-[REDACTED]')
        .replaceAll(
          RegExp(
            r'((?:api[_ -]?key|token|authorization)\s*[:=]\s*)[^\s,;]+',
            caseSensitive: false,
          ),
          r'$1[REDACTED]',
        );
    if (result.length > maxLength) {
      result = '${result.substring(0, maxLength)}…';
    }
    return result.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  }

  void _queuePersist() {
    _persistDirty = true;
    if (_persistScheduled) return;
    _persistScheduled = true;
    _writeQueue = _writeQueue.then((_) async {
      try {
        do {
          _persistDirty = false;
          await _persistSnapshot();
        } while (_persistDirty);
      } finally {
        _persistScheduled = false;
      }
    });
  }

  Future<void> _persistSnapshot() async {
    try {
      // Reads and writes share the same startup load. Logging before main's
      // explicit initialize cannot overwrite old diagnostics before reading
      // them, and startup errors are merged into the loaded history.
      await initialize();
      final preferences = _preferences!;
      if (_entries.isEmpty) {
        await preferences.remove(_storageKey);
        return;
      }
      final encoded = _entries
          .map((entry) => jsonEncode(entry.toJson()))
          .toList(growable: false);
      await preferences.setStringList(_storageKey, encoded);
    } on Object catch (error) {
      // A failed diagnostic write must not poison the chain and prevent all
      // later logs from being saved. Do not log this through RuntimeLog,
      // which would recursively request another failing storage write.
      debugPrint('Runtime log persistence failed (${error.runtimeType}).');
    }
  }

  void _queueNotification() {
    if (_notificationScheduled) return;
    _notificationScheduled = true;
    // FlutterError can reach this logger while layout or semantics is being
    // flushed. Rebuilding the log viewer inside that operation creates a
    // second framework error. Keep entries immediate, but refresh listeners
    // once the current synchronous framework operation has finished.
    scheduleMicrotask(() {
      try {
        notifyListeners();
      } finally {
        // A failing listener may itself be reported through FlutterError and
        // logged here. Keep that diagnostic, without starting an endless
        // notification/error loop from inside this notification.
        _notificationScheduled = false;
      }
    });
  }
}
