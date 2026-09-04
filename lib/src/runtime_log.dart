import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RuntimeLogLevel { info, warning, error }

extension RuntimeLogLevelLabel on RuntimeLogLevel {
  String get label => switch (this) {
    RuntimeLogLevel.info => 'INFO',
    RuntimeLogLevel.warning => 'WARN',
    RuntimeLogLevel.error => 'ERROR',
  };
}

class RuntimeLogEntry {
  const RuntimeLogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
  });

  factory RuntimeLogEntry.fromJson(Map<String, dynamic> json) {
    return RuntimeLogEntry(
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      level: RuntimeLogLevel.values.firstWhere(
        (value) => value.name == json['level'],
        orElse: () => RuntimeLogLevel.info,
      ),
      source: json['source'] as String? ?? 'App',
      message: json['message'] as String? ?? '',
    );
  }

  final DateTime timestamp;
  final RuntimeLogLevel level;
  final String source;
  final String message;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.name,
    'source': source,
    'message': message,
  };

  String get formatted {
    final local = timestamp.toLocal().toIso8601String().replaceFirst('T', ' ');
    return '[$local] [${level.label}] [$source] $message';
  }
}

class RuntimeLog extends ChangeNotifier {
  RuntimeLog._();

  static final RuntimeLog instance = RuntimeLog._();
  static const _storageKey = 'runtime_debug_logs_v1';
  static const maxEntries = 250;

  final List<RuntimeLogEntry> _entries = [];
  Future<void> _writeQueue = Future<void>.value();
  SharedPreferences? _preferences;

  List<RuntimeLogEntry> get entries => List.unmodifiable(_entries);

  String get formattedText => _entries.isEmpty
      ? '暂无运行日志。'
      : _entries.reversed.map((entry) => entry.formatted).join('\n');

  Future<void> initialize() async {
    _preferences ??= await SharedPreferences.getInstance();
    final stored = _preferences?.getStringList(_storageKey) ?? const [];
    _entries
      ..clear()
      ..addAll(
        stored
            .map((value) {
              try {
                return RuntimeLogEntry.fromJson(
                  jsonDecode(value) as Map<String, dynamic>,
                );
              } on Object {
                return null;
              }
            })
            .whereType<RuntimeLogEntry>()
            .where((entry) => _isRelevantSource(entry.source)),
      );
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  void info(String source, String message) =>
      add(RuntimeLogLevel.info, source, message);

  void warning(String source, String message) =>
      add(RuntimeLogLevel.warning, source, message);

  void error(String source, Object error, [StackTrace? stackTrace]) {
    final stack = stackTrace?.toString().split('\n').take(5).join(' | ');
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
    if (!_isRelevantSource(source)) return;
    _entries.add(
      RuntimeLogEntry(
        timestamp: DateTime.now(),
        level: level,
        source: sanitize(source, maxLength: 80),
        message: preserveFormatting
            ? _sanitizeFormatted(message)
            : sanitize(message),
      ),
    );
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    notifyListeners();
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

  static bool _isRelevantSource(String source) {
    final normalized = source.trim().toLowerCase();
    return normalized == 'llm' ||
        normalized == 'tts' ||
        normalized == 'ai' ||
        normalized.contains('fish audio') ||
        normalized.contains('qwen-tts') ||
        normalized.contains('通用 tts') ||
        normalized == 'test';
  }

  static Object? _redactStructured(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          '${entry.key}': _isSensitiveField('${entry.key}')
              ? '[REDACTED]'
              : _redactStructured(entry.value),
      };
    }
    if (value is Iterable) {
      return value.map(_redactStructured).toList(growable: false);
    }
    if (value is String) return sanitize(value, maxLength: 12000);
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
    _entries.clear();
    notifyListeners();
    await (_preferences ??= await SharedPreferences.getInstance()).remove(
      _storageKey,
    );
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
    _writeQueue = _writeQueue.then((_) async {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final encoded = _entries
          .map((entry) => jsonEncode(entry.toJson()))
          .toList(growable: false);
      await preferences.setStringList(_storageKey, encoded);
    });
  }
}
