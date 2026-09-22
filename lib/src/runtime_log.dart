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
  RuntimeLogModule get module => RuntimeLogModule.forSource(source);
  String get displayMessage => RuntimeLog.prettyMessage(message);

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.name,
    'source': source,
    'message': message,
  };

  String get formatted {
    final local = timestamp.toLocal().toIso8601String().replaceFirst('T', ' ');
    return '[$local] [${level.label}] [$source]\n$displayMessage';
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
        stored.map((value) {
          try {
            return RuntimeLogEntry.fromJson(
              jsonDecode(value) as Map<String, dynamic>,
            );
          } on Object {
            return null;
          }
        }).whereType<RuntimeLogEntry>(),
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
    _entries.add(
      RuntimeLogEntry(
        timestamp: DateTime.now(),
        level: level,
        source: sanitize(source, maxLength: 80),
        message: preserveFormatting
            ? _sanitizeFormatted(message)
            : prettyMessage(message),
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
    _entries.clear();
    notifyListeners();
    _writeQueue = _writeQueue.then((_) async {
      await (_preferences ??= await SharedPreferences.getInstance()).remove(
        _storageKey,
      );
    });
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
