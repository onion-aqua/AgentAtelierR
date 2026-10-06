import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

typedef Json = Map<String, dynamic>;
Json object(Object? value) {
  if (value is! Map) throw const FormatException('协议对象格式无效');
  return Map<String, dynamic>.from(value);
}

List<Json> objects(Object? value) {
  if (value is! List) throw const FormatException('协议列表格式无效');
  return value.map(object).toList();
}

String field(Json data, String key) {
  final value = data[key];
  if (value is! String || value.isEmpty) throw FormatException('缺少协议字段 $key');
  return value;
}

final uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
String newUuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String newDeviceToken() {
  final random = Random.secure();
  return base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

/// Formats an outgoing protocol timestamp with millisecond precision.
///
/// Dart can include non-zero microseconds in `DateTime.toIso8601String()`;
/// relay-v1 timestamps intentionally accept at most three fractional digits.
/// Truncating (rather than rounding) keeps the value at or before the
/// requested deadline and makes retries reuse a server-acceptable body.
String relayTimestamp(DateTime value) {
  final utc = value.toUtc();
  // DateTime's ISO formatter emits the date/time fields correctly; rebuild
  // only the fractional part so microseconds cannot leak onto the wire.
  final base = utc.toIso8601String().split('.').first;
  final fraction = (utc.millisecond).toString().padLeft(3, '0');
  return '$base.${fraction}Z';
}

Future<String> tokenDigest(String token) async =>
    (await Sha256().hash(utf8.encode(token))).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
Uri secureOrigin(String input) {
  final uri = Uri.tryParse(input);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('服务器必须是 HTTPS origin，不得包含路径、账号、查询或片段');
  }
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

class PairingQr {
  PairingQr._(this.origin, this.pairingId, this.secret);
  final Uri origin;
  final String pairingId;
  final String secret;
  factory PairingQr.parse(String source) {
    if (source.length > 4096) throw const FormatException('二维码内容过长');
    final data = object(jsonDecode(source));
    if (data['type'] != 'agent-relay-pair' || data['v'] != 1) {
      throw const FormatException('不是 relay v1 配对二维码');
    }
    final id = field(data, 'pairing_id');
    final secret = field(data, 'pairing_secret');
    if (!uuidPattern.hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(secret)) {
      throw const FormatException('配对标识或密钥格式错误');
    }
    return PairingQr._(
      secureOrigin(field(data, 'server_base_url')),
      id,
      secret,
    );
  }
  @override
  String toString() => 'PairingQr(redacted)';
}

const eventTypes = {
  'question.created',
  'question.updated',
  'approval.created',
  'approval.updated',
  'task.updated',
  'pc.state.updated',
  'session.history.updated',
  'scope.redacted',
  'action.result',
  'pairing.updated',
  'device.revoked',
};
Json validateEvent(Object? raw) {
  final event = object(raw);
  if (!uuidPattern.hasMatch(field(event, 'event_id')) ||
      event['seq'] is! int ||
      (event['seq'] as int) < 1 ||
      !eventTypes.contains(event['type'])) {
    throw const FormatException('事件类型、ID 或序列无效');
  }
  object(event['payload']);
  return event;
}

List<String> relayCapabilities(Object? raw) {
  if (raw == null) return [];
  if (raw is! List || raw.any((value) => value is! String)) {
    throw const FormatException('设备权限格式无效');
  }
  return List<String>.from(raw).toSet().toList();
}

/// Original action requests are visible only to their target PC. The mobile
/// uses its own durable outbox and never imports this PC recovery field.
Json mobileActionSummary(Object? raw) => object(raw)..remove('request');

String requestKey(Json request) =>
    '${request['pc_id']}/${request['request_id']}';
bool isPending(Json request, DateTime now) {
  if (request['state'] != 'pending') return false;
  final raw = request['expires_at'];
  if (raw == null) return true;
  final expires = DateTime.tryParse(raw.toString());
  return expires != null && expires.isAfter(now);
}

/// Statuses accepted in action summaries and POST /v1/actions responses.
///
/// A retry can reach the relay after the original request was committed. In
/// that case the relay may return the current idempotent result instead of a
/// fresh `queued` response, so the mobile client must preserve that status.
const actionStatuses = {
  'queued',
  'delivered',
  'accepted',
  'rejected',
  'expired',
  'conflict',
  'unknown',
};

const actionTerminal = {
  'accepted',
  'rejected',
  'expired',
  'conflict',
  'unknown',
};
String relayLabel(Object? value) => switch (value) {
  'online' => '在线',
  'offline' => '离线',
  'connecting' => '正在连接',
  'pending_confirmation' => '等待 PC 确认',
  'confirmed' => '已绑定',
  'rejected' => '被拒绝',
  'expired' => '已过期',
  'revoked' => '已撤销',
  'queued' => '已排队，等待 PC',
  'delivered' => '已送达，等待 PC',
  'sending' => '发送中',
  'retry' => '发送结果未明，可幂等重试',
  'accepted' => 'PC 已接受',
  'conflict' => '冲突：已在其他端处理',
  'unknown' => '执行状态未知',
  'running' => '运行中',
  'succeeded' => '成功',
  'failed' => '失败',
  'cancelled' => '已取消',
  'resolved' => '已处理',
  'pending' => '待处理',
  'idle' => '空闲',
  'unavailable' => '尚未配置',
  'forbidden' => '无权限',
  _ => '状态待确认',
};

class RelayFailure implements Exception {
  const RelayFailure(this.code, {this.retryable = false});
  final String code;
  final bool retryable;
  // Never echo server messages or transport exceptions: they can contain secrets.
  @override
  String toString() => switch (code) {
    'PAIRING_EXPIRED' => '二维码已过期，请在 PC 重新生成',
    'PAIRING_USED' => '二维码已使用，请在 PC 重新生成',
    'PAIRING_NOT_FOUND' => '配对不存在，请重新扫码',
    'DEVICE_EXISTS' => '设备身份冲突，请重新配对',
    'DEVICE_REVOKED' => '设备已撤销',
    'UNAUTHORIZED' => '凭证失效，请重新配对',
    'FORBIDDEN' => 'PC 未授予此操作权限',
    'PC_OFFLINE' => 'PC 离线，请稍后重试',
    'REQUEST_EXPIRED' => '请求已过期',
    'REQUEST_RESOLVED' => '请求已被处理',
    'IDEMPOTENCY_CONFLICT' => '操作标识冲突，请刷新状态',
    'CURSOR_EXPIRED' => '事件游标过期，正在获取状态快照',
    'HISTORY_CHANGED' => '桌面历史已更新，正在重新读取',
    'HISTORY_NOT_READY' => '正在等待桌面同步聊天正文',
    'HISTORY_UNSUPPORTED' => '此桌面客户端尚未支持完整聊天历史',
    _ => '联动暂不可用，请检查网络、服务器配置后重试',
  };
}
