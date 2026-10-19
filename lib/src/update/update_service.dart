import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'release_source.dart';
import 'update_manifest.dart';
import 'update_models.dart';

enum UpdateCheckStatus {
  updateAvailable,
  suppressed,
  upToDate,
  disabled,
  throttled,
  failed,
}

final class UpdateCheckResult {
  const UpdateCheckResult._(
    this.status, {
    this.plan,
    this.origin,
    this.errorCode,
  });

  const UpdateCheckResult.available(UpdatePlan plan, UpdateReleaseOrigin origin)
    : this._(UpdateCheckStatus.updateAvailable, plan: plan, origin: origin);

  const UpdateCheckResult.suppressed(
    UpdatePlan plan,
    UpdateReleaseOrigin origin,
  ) : this._(UpdateCheckStatus.suppressed, plan: plan, origin: origin);

  const UpdateCheckResult.upToDate(UpdatePlan plan, UpdateReleaseOrigin origin)
    : this._(UpdateCheckStatus.upToDate, plan: plan, origin: origin);

  const UpdateCheckResult.disabled() : this._(UpdateCheckStatus.disabled);

  const UpdateCheckResult.throttled() : this._(UpdateCheckStatus.throttled);

  const UpdateCheckResult.failed(String code)
    : this._(UpdateCheckStatus.failed, errorCode: code);

  final UpdateCheckStatus status;
  final UpdatePlan? plan;
  final UpdateReleaseOrigin? origin;
  final String? errorCode;
}

final class UpdatePreferences {
  const UpdatePreferences({
    this.autoCheck = true,
    this.sourcePreference = UpdateSourcePreference.automatic,
    this.lastCheckAt,
    this.lastSuccessfulCheckAt,
    this.dismissedReleaseId,
    this.dismissedAt,
    this.highestSeenReleaseSeq = 0,
    this.highestSeenReleaseId,
    this.highestSeenPayloadSha256,
  });

  final bool autoCheck;
  final UpdateSourcePreference sourcePreference;
  final DateTime? lastCheckAt;
  final DateTime? lastSuccessfulCheckAt;
  final String? dismissedReleaseId;
  final DateTime? dismissedAt;
  final int highestSeenReleaseSeq;
  final String? highestSeenReleaseId;
  final String? highestSeenPayloadSha256;

  UpdatePreferences copyWith({
    bool? autoCheck,
    UpdateSourcePreference? sourcePreference,
    DateTime? lastCheckAt,
    DateTime? lastSuccessfulCheckAt,
    String? dismissedReleaseId,
    DateTime? dismissedAt,
    int? highestSeenReleaseSeq,
    String? highestSeenReleaseId,
    String? highestSeenPayloadSha256,
    bool clearDismissed = false,
  }) => UpdatePreferences(
    autoCheck: autoCheck ?? this.autoCheck,
    sourcePreference: sourcePreference ?? this.sourcePreference,
    lastCheckAt: lastCheckAt ?? this.lastCheckAt,
    lastSuccessfulCheckAt: lastSuccessfulCheckAt ?? this.lastSuccessfulCheckAt,
    dismissedReleaseId: clearDismissed
        ? null
        : dismissedReleaseId ?? this.dismissedReleaseId,
    dismissedAt: clearDismissed ? null : dismissedAt ?? this.dismissedAt,
    highestSeenReleaseSeq: highestSeenReleaseSeq ?? this.highestSeenReleaseSeq,
    highestSeenReleaseId: highestSeenReleaseId ?? this.highestSeenReleaseId,
    highestSeenPayloadSha256:
        highestSeenPayloadSha256 ?? this.highestSeenPayloadSha256,
  );

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'auto_check': autoCheck,
    'source_preference': sourcePreference.name,
    'last_check_at': lastCheckAt?.toUtc().toIso8601String(),
    'last_successful_check_at': lastSuccessfulCheckAt
        ?.toUtc()
        .toIso8601String(),
    'dismissed_release_id': dismissedReleaseId,
    'dismissed_at': dismissedAt?.toUtc().toIso8601String(),
    'highest_seen_release_seq': highestSeenReleaseSeq,
    'highest_seen_release_id': highestSeenReleaseId,
    'highest_seen_payload_sha256': highestSeenPayloadSha256,
  };

  factory UpdatePreferences.fromJson(Object? value) {
    if (value is! Map || value['schema_version'] != 1) {
      return const UpdatePreferences();
    }
    final sourceName = value['source_preference'];
    final source = UpdateSourcePreference.values.where(
      (candidate) => candidate.name == sourceName,
    );
    final highest = value['highest_seen_release_seq'];
    return UpdatePreferences(
      autoCheck: value['auto_check'] is bool
          ? value['auto_check'] as bool
          : true,
      sourcePreference: source.isEmpty
          ? UpdateSourcePreference.automatic
          : source.first,
      lastCheckAt: storedDate(value['last_check_at']),
      lastSuccessfulCheckAt: storedDate(value['last_successful_check_at']),
      dismissedReleaseId: value['dismissed_release_id'] is String
          ? value['dismissed_release_id'] as String
          : null,
      dismissedAt: storedDate(value['dismissed_at']),
      highestSeenReleaseSeq: highest is int && highest >= 0 ? highest : 0,
      highestSeenReleaseId: value['highest_seen_release_id'] is String
          ? value['highest_seen_release_id'] as String
          : null,
      highestSeenPayloadSha256: value['highest_seen_payload_sha256'] is String
          ? value['highest_seen_payload_sha256'] as String
          : null,
    );
  }
}

DateTime? storedDate(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

abstract interface class UpdatePreferencesStore {
  Future<UpdatePreferences> load();
  Future<void> save(UpdatePreferences preferences);
}

final class SharedPreferencesUpdateStore implements UpdatePreferencesStore {
  SharedPreferencesUpdateStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  static const storageKey = 'self_hosted_update.preferences.v1';

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<UpdatePreferences> load() async {
    final preferences = await _preferences();
    final stored = preferences.getString(storageKey);
    if (stored == null) return const UpdatePreferences();
    try {
      return UpdatePreferences.fromJson(jsonDecode(stored));
    } on FormatException {
      return const UpdatePreferences();
    }
  }

  @override
  Future<void> save(UpdatePreferences value) async {
    final preferences = await _preferences();
    if (!await preferences.setString(storageKey, jsonEncode(value.toJson()))) {
      throw StateError('更新设置保存失败');
    }
  }
}

typedef UpdateClock = DateTime Function();

/// Coordinates checks and durable prompt policy. It does not download or
/// install files, so UI dismissal and lifecycle checks remain independently
/// testable from Android installation behavior.
final class UpdateService {
  UpdateService({
    required this.source,
    required this.verifier,
    required this.store,
    this.planner = const UpdatePlanner(),
    UpdateClock? clock,
    this.foregroundThrottle = const Duration(minutes: 15),
    this.dismissDuration = const Duration(hours: 24),
  }) : _clock = clock ?? DateTime.now;

  final ReleaseSource source;
  final UpdateManifestVerifier verifier;
  final UpdatePreferencesStore store;
  final UpdatePlanner planner;
  final UpdateClock _clock;
  final Duration foregroundThrottle;
  final Duration dismissDuration;

  Future<UpdateCheckResult>? _inFlight;
  final Set<String> _dismissedThisSession = {};

  Future<UpdatePreferences> preferences() => store.load();

  Future<void> setAutoCheck(bool enabled) async {
    final current = await store.load();
    await store.save(current.copyWith(autoCheck: enabled));
  }

  Future<void> setSourcePreference(UpdateSourcePreference preference) async {
    final current = await store.load();
    await store.save(current.copyWith(sourcePreference: preference));
  }

  Future<void> dismissRelease(String releaseId) async {
    _dismissedThisSession.add(releaseId);
    final current = await store.load();
    await store.save(
      current.copyWith(dismissedReleaseId: releaseId, dismissedAt: _now()),
    );
  }

  Future<UpdateCheckResult> check(
    InstalledUpdateState current, {
    UpdateCheckTrigger trigger = UpdateCheckTrigger.startup,
    bool manual = false,
  }) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final operation = _check(
      current,
      trigger: manual ? UpdateCheckTrigger.manual : trigger,
    );
    _inFlight = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
  }

  Future<UpdateCheckResult> _check(
    InstalledUpdateState current, {
    required UpdateCheckTrigger trigger,
  }) async {
    final now = _now();
    var settings = await store.load();
    final manual = trigger == UpdateCheckTrigger.manual;
    if (!manual && !settings.autoCheck) {
      return const UpdateCheckResult.disabled();
    }
    if (!manual &&
        trigger == UpdateCheckTrigger.foreground &&
        settings.lastCheckAt != null &&
        !now.isBefore(settings.lastCheckAt!) &&
        now.difference(settings.lastCheckAt!) < foregroundThrottle) {
      return const UpdateCheckResult.throttled();
    }
    settings = settings.copyWith(lastCheckAt: now);
    await store.save(settings);

    try {
      final fetched = await source.fetchLatest(
        preference: settings.sourcePreference,
      );
      final manifest = await verifier.verify(fetched.envelope);
      // Sequence numbers are scoped to the configured platform/channel. A
      // correctly signed manifest from another feed must not advance this
      // installation's replay checkpoint.
      if (manifest.platform != current.platform) {
        return const UpdateCheckResult.failed('platform_mismatch');
      }
      if (manifest.channel != current.channel) {
        return const UpdateCheckResult.failed('channel_mismatch');
      }
      final digest = await Sha256().hash(
        canonicalJsonBytes(fetched.envelope.payload),
      );
      final payloadSha256 = digest.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (manifest.releaseSeq < settings.highestSeenReleaseSeq) {
        return const UpdateCheckResult.failed('release_replay');
      }
      if (manifest.releaseSeq == settings.highestSeenReleaseSeq &&
          ((settings.highestSeenReleaseId != null &&
                  settings.highestSeenReleaseId != manifest.releaseId) ||
              (settings.highestSeenPayloadSha256 != null &&
                  settings.highestSeenPayloadSha256 != payloadSha256))) {
        return const UpdateCheckResult.failed('release_identity_conflict');
      }
      settings = settings.copyWith(
        lastSuccessfulCheckAt: now,
        highestSeenReleaseSeq:
            manifest.releaseSeq > settings.highestSeenReleaseSeq
            ? manifest.releaseSeq
            : settings.highestSeenReleaseSeq,
        highestSeenReleaseId:
            manifest.releaseSeq > settings.highestSeenReleaseSeq ||
                settings.highestSeenReleaseId == null
            ? manifest.releaseId
            : settings.highestSeenReleaseId,
        highestSeenPayloadSha256:
            manifest.releaseSeq > settings.highestSeenReleaseSeq ||
                settings.highestSeenPayloadSha256 == null
            ? payloadSha256
            : settings.highestSeenPayloadSha256,
      );
      await store.save(settings);
      final plan = planner.plan(current, manifest);
      if (!plan.isAvailable) {
        return UpdateCheckResult.failed(
          plan.unavailableReason ?? 'update_incompatible',
        );
      }
      if (!plan.hasUpdate) {
        return UpdateCheckResult.upToDate(plan, fetched.origin);
      }
      if (!manual && _isSuppressed(manifest.releaseId, settings, now)) {
        return UpdateCheckResult.suppressed(plan, fetched.origin);
      }
      return UpdateCheckResult.available(plan, fetched.origin);
    } on UpdateVerificationException catch (error) {
      return UpdateCheckResult.failed(error.code);
    } on ReleaseSourceException catch (error) {
      return UpdateCheckResult.failed(error.code);
    } on FormatException {
      return const UpdateCheckResult.failed('invalid_manifest');
    } on TimeoutException {
      return const UpdateCheckResult.failed('network_timeout');
    } on Object {
      return const UpdateCheckResult.failed('check_failed');
    }
  }

  bool _isSuppressed(
    String releaseId,
    UpdatePreferences settings,
    DateTime now,
  ) {
    if (_dismissedThisSession.contains(releaseId)) return true;
    final dismissedAt = settings.dismissedAt;
    return settings.dismissedReleaseId == releaseId &&
        dismissedAt != null &&
        !now.isBefore(dismissedAt) &&
        now.difference(dismissedAt) < dismissDuration;
  }

  DateTime _now() => _clock().toUtc();
}
