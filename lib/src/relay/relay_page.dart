import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../glass_ui.dart';
import 'relay_protocol.dart';
import 'relay_service.dart';

Color _relayDialogBackground(BuildContext context) =>
    Theme.of(context).colorScheme.surface
        .withValues(alpha: GlassStyleScope.resolve(context) ? .74 : .9);

class _RelayCard extends StatelessWidget {
  const _RelayCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: GlassContentCard(
      liquidGlass: GlassStyleScope.resolve(context),
      child: child,
    ),
  );
}

String safeRelayError(Object error) => error is RelayFailure
    ? error.toString()
    : error is FormatException
    ? error.message
    : '操作失败，请检查网络或配置后重试';

class RelayPage extends StatefulWidget {
  const RelayPage({super.key, required this.service, this.scanPairingCode});
  final RelayService service;

  /// A replaceable scanner entry point; production uses the camera below.
  final Future<String?> Function(BuildContext context)? scanPairingCode;
  @override
  State<RelayPage> createState() => _RelayPageState();
}

class _RelayPageState extends State<RelayPage> {
  bool busy = false;
  String? error;
  RelayService get service => widget.service;
  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on Object catch (e) {
      if (mounted) setState(() => error = safeRelayError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pair({bool camera = true}) async {
    if (busy || !service.initialized) return;
    if (!camera && service.serverConfig.isPinned) return;
    final source = camera
        ? await (widget.scanPairingCode?.call(context) ??
              Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => RelayScannerPage(
                    allowPasteFallback: !service.serverConfig.isPinned,
                  ),
                ),
              ))
        : await _textDialog(
            context,
            '粘贴配对二维码 JSON',
            '仅粘贴 PC 生成的配对数据',
            obscure: true,
          );
    if (source == null || !mounted) return;
    await run(() async {
      final PairingQr qr;
      try {
        qr = PairingQr.parse(source);
      } on FormatException {
        // JSON decoder diagnostics can echo the original QR, including secrets.
        throw const FormatException('配对二维码格式无效，请重新扫描 PC 生成的二维码。');
      }
      service.verifyPairingServer(qr);
      final pinned = service.serverConfig.isPinned;
      final trusted = await showDialog<bool>(
        useRootNavigator: false,
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _relayDialogBackground(context),
          surfaceTintColor: Colors.transparent,
          title: Text(pinned ? '确认配对此 PC' : '确认信任此联动服务器'),
          content: Text(
            pinned
                ? '通过内置联动服务配对。请确认二维码来自你自己的 PC；服务可以读取问答与任务正文。确认后提交手机配对申请，仍需 PC 批准。'
                : '${qr.origin}\n\n服务器可以读取问答与任务正文。请核对这是你自己的 PC 显示的 HTTPS 地址；确认后提交手机配对申请，仍需 PC 批准。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(pinned ? '申请配对' : '信任并申请配对'),
            ),
          ],
        ),
      );
      if (trusted != true || !mounted) return;
      final id = await service.pair(
        qr,
        'AgentAtelierR Android',
        trustedByUser: true,
      );
      await service.sync(id, snapshot: true);
    });
  }

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
        useRootNavigator: false,
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: _relayDialogBackground(context),
          surfaceTintColor: Colors.transparent,
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ==
      true;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: service,
    builder: (context, _) => GlassPageSurface(
      liquidGlass: GlassStyleScope.resolve(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: glassPageHeaderColor(context),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text(
            'PC Agent 联动',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: '同步',
              onPressed: busy
                  ? null
                  : () => run(() async {
                      for (final p in service.profiles) {
                        await service.sync(
                          p['device_id'] as String,
                          snapshot: true,
                        );
                      }
                    }),
              icon: const Icon(Icons.sync),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('通过你信任的 HTTPS 中继连接 PC。前台问答与任务控制不依赖角色聊天。后台提醒需要配置真实推送渠道。'),
            if (service.startupError != null) Text(service.startupError!),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (busy) const LinearProgressIndicator(),
            Wrap(
              spacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: busy || !service.initialized ? null : pair,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('扫码绑定 / 重新配对'),
                ),
                if (!service.serverConfig.isPinned)
                  TextButton(
                    onPressed: busy || !service.initialized
                        ? null
                        : () => pair(camera: false),
                    child: const Text('粘贴二维码数据'),
                  ),
              ],
            ),
            _RelayCard(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('远程通知'),
                    Text(service.pushStatus),
                    const Text(
                      '默认不展示完整问题正文。未配置厂商 SDK 或 FCM 项目时，后台、锁屏及进程被回收后的提醒不可用；回到应用会重新同步。',
                    ),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => run(service.enablePush),
                          child: const Text('启用推送 / 申请通知权限'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => run(service.disablePush),
                          child: const Text('停用推送'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (service.profiles.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('尚未绑定 PC。请在 PC 端生成配对二维码。'),
              ),
            for (final p in service.profiles) _profileCard(p),
          ],
        ),
      ),
    ),
  );
  Widget _profileCard(Json p) {
    final id = p['device_id'] as String;
    final active = p['state'] == 'confirmed';
    final requests = service.collection(p, 'requests');
    final tasks = service.collection(p, 'tasks');
    final outbox = service.collection(p, 'outbox');
    return _RelayCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              service.pcName(p),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              service.serverConfig.isPinned
                  ? '内置联动服务'
                  : p['server_base_url'] as String,
            ),
            Text(
              '${relayLabel(p['state'])} · ${relayLabel(service.connections[id])}',
            ),
            for (final pc
                in service
                    .collection(p, 'devices')
                    .where((d) => d['device_id'] == p['pc_id']))
              Text('PC ${relayLabel(pc['connection_state'])}'),
            if (p['state'] == 'pending_confirmation')
              const Text('请在 PC 上批准申请。重启应用仍可查询；请求未送达时请重新扫描同一个未过期二维码。'),
            if (service.errors[id] != null) Text(service.errors[id]!),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run(() => service.sync(id, snapshot: true)),
                  child: const Text('刷新状态'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          if (await confirm(
                            '解绑此 PC？',
                            '撤销此手机绑定。网络不可用时不会假称撤销成功；其他 PC 绑定不受影响。',
                          )) {
                            await run(() => service.unpair(id));
                          }
                        },
                  child: const Text('解绑'),
                ),
                FilledButton(
                  onPressed: busy || !active || !service.ready.contains(id)
                      ? null
                      : () => showDialog<void>(
                          useRootNavigator: false,
                          context: context,
                          builder: (_) =>
                              RelayTaskDialog(service: service, profileId: id),
                        ),
                  child: const Text('下发新任务'),
                ),
              ],
            ),
            const Divider(),
            const Text('问题与审批'),
            if (requests.isEmpty) const Text('暂无待办'),
            for (final request in requests)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  object(request['payload'])['title']?.toString() ??
                      (request['kind'] == 'approval' ? '审批' : '问题'),
                ),
                subtitle: Text(
                  '${service.sessionName(p, request['session_id'])} · ${relayLabel(request['state'] == 'pending' && !isPending(request, service.now()) ? 'expired' : request['state'])}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDialog<void>(
                  useRootNavigator: false,
                  context: context,
                  builder: (_) => RelayQuestionDialog(
                    service: service,
                    profileId: id,
                    requestId: request['request_id'] as String,
                  ),
                ),
              ),
            const Divider(),
            const Text('任务'),
            for (final task in tasks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  task['summary']?.toString() ?? task['task_id'].toString(),
                ),
                subtitle: Text(
                  '${relayLabel(task['status'])} · ${service.sessionName(p, task['session_id'])}',
                ),
                trailing: {'queued', 'running'}.contains(task['status'])
                    ? TextButton(
                        onPressed: busy
                            ? null
                            : () async {
                                if (await confirm(
                                  '取消任务？',
                                  'PC：${service.pcName(p)}\n任务：${task['summary'] ?? task['task_id']}',
                                )) {
                                  await run(() async {
                                    await service.cancelTask(
                                      id,
                                      task['task_id'] as String,
                                    );
                                  });
                                }
                              },
                        child: const Text('取消任务'),
                      )
                    : null,
              ),
            const Divider(),
            const Text('操作回执（送达不代表 PC 已接受）'),
            for (final action in outbox.reversed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${object(action['body'])['type']} · ${relayLabel(action['local_status'])}',
                ),
                subtitle: Text(
                  '会话：${service.sessionName(p, object(action['body'])['session_id'])}',
                ),
                trailing: action['local_status'] == 'retry'
                    ? TextButton(
                        onPressed: busy
                            ? null
                            : () => run(
                                () => service.retryAction(
                                  id,
                                  action['action_id'] as String,
                                ),
                              ),
                        child: const Text('重试原操作'),
                      )
                    : null,
              ),
            ExpansionTile(
              title: const Text('最近事件'),
              children: [
                for (final e
                    in service.collection(p, 'events').reversed.take(30))
                  ListTile(
                    title: Text(e['type'] as String),
                    subtitle: Text(
                      '${e['created_at']} · ${service.sessionName(p, e['session_id'])}',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> _textDialog(
  BuildContext context,
  String title,
  String hint, {
  bool obscure = false,
}) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    useRootNavigator: false,
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: _relayDialogBackground(context),
      surfaceTintColor: Colors.transparent,
      title: Text(title),
      content: TextField(
        controller: controller,
        obscureText: obscure,
        enableSuggestions: !obscure,
        autocorrect: !obscure,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('继续'),
        ),
      ],
    ),
  );
  // Controller disposal after the route's reverse animation has detached fields.
  await Future<void>.delayed(const Duration(milliseconds: 350));
  controller.dispose();
  return result;
}

class RelayScannerPage extends StatefulWidget {
  const RelayScannerPage({super.key, this.allowPasteFallback = true});
  final bool allowPasteFallback;
  @override
  State<RelayScannerPage> createState() => _RelayScannerPageState();
}

class _RelayScannerPageState extends State<RelayScannerPage> {
  final scanner = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool captured = false;
  @override
  void dispose() {
    unawaited(scanner.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(
      backgroundColor: glassPageHeaderColor(context),
      surfaceTintColor: Colors.transparent,
      title: const Text(
        '扫描 PC 配对二维码',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: MobileScanner(
      controller: scanner,
      onDetect: (capture) {
        final raw = capture.barcodes
            .map((b) => b.rawValue)
            .whereType<String>()
            .firstOrNull;
        if (raw == null || captured) return;
        captured = true;
        unawaited(scanner.stop());
        Navigator.pop(context, raw);
      },
      errorBuilder: (context, error) => Center(
        child: Text(
          widget.allowPasteFallback
              ? '相机不可用，请检查相机权限，或返回粘贴二维码数据。'
              : '相机不可用，请检查相机权限后重新扫描。',
        ),
      ),
    ),
  );
}

class RelayQuestionDialog extends StatefulWidget {
  const RelayQuestionDialog({
    super.key,
    required this.service,
    required this.profileId,
    required this.requestId,
  });
  final RelayService service;
  final String profileId, requestId;
  @override
  State<RelayQuestionDialog> createState() => _RelayQuestionDialogState();
}

class _RelayQuestionDialogState extends State<RelayQuestionDialog> {
  final text = TextEditingController();
  final selected = <String>{};
  bool sending = false;
  String? error;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> send({String? decision}) async {
    if (sending) return;
    setState(() => sending = true);
    try {
      await widget.service.answer(
        widget.profileId,
        widget.requestId,
        selected: selected.toList(),
        text: text.text,
        decision: decision,
      );
    } on Object catch (e) {
      if (mounted) setState(() => error = safeRelayError(e));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.service,
    builder: (context, _) {
      final s = widget.service;
      final p = s.profile(widget.profileId);
      final request = p == null
          ? null
          : s
                .collection(p, 'requests')
                .where((r) => r['request_id'] == widget.requestId)
                .firstOrNull;
      final payload = request == null
          ? <String, dynamic>{}
          : object(request['payload']);
      final approval = request?['kind'] == 'approval';
      final input = payload['input'] is Map
          ? object(payload['input'])
          : <String, dynamic>{};
      final enabled =
          p != null &&
          request != null &&
          s.foreground &&
          !sending &&
          s.requestCanSend(p, request);
      final action = p == null ? null : s.actionForRequest(p, widget.requestId);
      return AlertDialog(
        backgroundColor: _relayDialogBackground(context),
        surfaceTintColor: Colors.transparent,
        title: Text(payload['title']?.toString() ?? 'PC 请求已结束'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (p != null)
                  Text(
                    'PC：${s.pcName(p)}\n会话：${s.sessionName(p, request?['session_id'])}',
                  ),
                if (request != null)
                  Text(
                    '期限：${request['expires_at'] ?? '未指定'}\n${relayLabel(isPending(request, s.now())
                        ? 'pending'
                        : request['state'] == 'pending'
                        ? 'expired'
                        : request['state'])}',
                  ),
                if (p != null && !s.ready.contains(widget.profileId))
                  const Text('正在校准服务器状态，暂不能提交'),
                const SizedBox(height: 12),
                Text(
                  (approval ? payload['description'] : payload['body'])
                          ?.toString() ??
                      '',
                ),
                if (approval) ...[
                  const SizedBox(height: 8),
                  Text('操作摘要：${payload['operation_summary'] ?? ''}'),
                  const Text('批准将授权 PC 按其原有安全规则执行此操作。'),
                ],
                if (!approval) ...[
                  for (final option in objects(input['options'] ?? []))
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(option['label']?.toString() ?? ''),
                      value: selected.contains(option['id']),
                      onChanged: !enabled
                          ? null
                          : (checked) => setState(() {
                              if (input['kind'] == 'single_choice') {
                                selected.clear();
                              }
                              if (checked == true) {
                                selected.add(option['id'] as String);
                              } else {
                                selected.remove(option['id']);
                              }
                            }),
                    ),
                  if (input['kind'] == 'text' || input['allow_text'] == true)
                    TextField(
                      controller: text,
                      enabled: enabled,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: 20000,
                      decoration: const InputDecoration(labelText: '回答'),
                    ),
                ],
                if (action != null)
                  Text('操作：${relayLabel(action['local_status'])}'),
                if (action?['local_status'] == 'retry')
                  TextButton(
                    onPressed: sending
                        ? null
                        : () async {
                            setState(() => sending = true);
                            try {
                              await s.retryAction(
                                widget.profileId,
                                action!['action_id'] as String,
                              );
                            } finally {
                              if (mounted) setState(() => sending = false);
                            }
                          },
                    child: const Text('幂等重试原回答'),
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后 / 关闭'),
          ),
          if (approval) ...[
            for (final decision in ['reject', 'approve'])
              if ((payload['allowed_decisions'] as List? ?? []).contains(
                decision,
              ))
                FilledButton(
                  onPressed: enabled ? () => send(decision: decision) : null,
                  child: Text(decision == 'approve' ? '明确批准' : '拒绝'),
                ),
          ] else
            FilledButton(
              onPressed: enabled ? send : null,
              child: const Text('提交回答'),
            ),
        ],
      );
    },
  );
}

class RelayTaskDialog extends StatefulWidget {
  const RelayTaskDialog({
    super.key,
    required this.service,
    required this.profileId,
  });
  final RelayService service;
  final String profileId;
  @override
  State<RelayTaskDialog> createState() => _RelayTaskDialogState();
}

class _RelayTaskDialogState extends State<RelayTaskDialog> {
  final prompt = TextEditingController();
  String? workspace, session, error;
  bool busy = false;
  @override
  void dispose() {
    prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.service.profile(widget.profileId);
    if (p == null) {
      return AlertDialog(
        backgroundColor: _relayDialogBackground(context),
        surfaceTintColor: Colors.transparent,
        content: const Text('绑定已失效'),
      );
    }
    final workspaces = widget.service
        .collection(p, 'workspaces')
        .where((w) => w['pc_id'] == p['pc_id']);
    final sessions = widget.service
        .collection(p, 'sessions')
        .where((s) => s['pc_id'] == p['pc_id']);
    return AlertDialog(
      backgroundColor: _relayDialogBackground(context),
      surfaceTintColor: Colors.transparent,
      title: const Text('向 PC 下发新任务'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('目标 PC：${widget.service.pcName(p)}'),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: '',
                decoration: const InputDecoration(labelText: '会话'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('新建会话')),
                  for (final s in sessions)
                    DropdownMenuItem(
                      value: s['session_id'] as String,
                      child: Text(
                        s['title']?.toString() ?? s['session_id'].toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() {
                        session = value == '' ? null : value;
                        workspace = null;
                      }),
              ),
              if (session == null)
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: workspace,
                  decoration: const InputDecoration(labelText: 'PC 授权工作区'),
                  items: [
                    for (final w in workspaces)
                      DropdownMenuItem(
                        value: w['workspace_id'] as String,
                        child: Text(
                          w['label']?.toString() ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy ? null : (v) => setState(() => workspace = v),
                ),
              TextField(
                controller: prompt,
                enabled: !busy,
                minLines: 3,
                maxLines: 6,
                maxLength: 20000,
                decoration: const InputDecoration(labelText: '任务内容'),
              ),
              const Text('仅点击下方确认后发送。角色对话和语音不会自动控制 PC。'),
              if (error != null) Text(error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('返回'),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    await widget.service.startTask(
                      widget.profileId,
                      prompt: prompt.text,
                      sessionId: session,
                      workspaceId: workspace,
                    );
                    if (context.mounted) Navigator.pop(context);
                  } on Object catch (e) {
                    if (mounted) setState(() => error = safeRelayError(e));
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: const Text('确认下发任务'),
        ),
      ],
    );
  }
}

/// Mounted once by AppShell, so requests can appear above every app page.
class RelayForegroundHost extends StatefulWidget {
  const RelayForegroundHost({super.key, required this.service});
  final RelayService service;
  @override
  State<RelayForegroundHost> createState() => _RelayForegroundHostState();
}

class _RelayForegroundHostState extends State<RelayForegroundHost> {
  DialogRoute<void>? route;
  String? currentProfile, currentRequest;
  bool scheduled = false, opening = false;
  @override
  void initState() {
    super.initState();
    widget.service.addListener(changed);
    changed();
  }

  @override
  void dispose() {
    widget.service.removeListener(changed);
    super.dispose();
  }

  void changed() {
    if (!mounted || scheduled) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (mounted) unawaited(pump());
    });
    // A ChangeNotifier update can happen while no frame is scheduled (for
    // example, after a background REST sync). Ensure the post-frame callback
    // runs so a newly pending request is presented promptly.
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> pump() async {
    final s = widget.service;
    if (route != null) {
      final p = s.profile(currentProfile!);
      final request = p == null
          ? null
          : s
                .collection(p, 'requests')
                .where((r) => r['request_id'] == currentRequest)
                .firstOrNull;
      if (!s.foreground ||
          p == null ||
          request == null ||
          !isPending(request, s.now())) {
        final old = route!;
        route = null;
        if (old.isActive) {
          Navigator.of(context, rootNavigator: true).removeRoute(old);
        }
      }
      return;
    }
    if (opening || !s.foreground) return;
    for (final p in s.profiles) {
      final id = p['device_id'] as String;
      if (!s.ready.contains(id)) continue;
      final presented = object(p['cache'])['presented'] as List;
      final all = s.collection(p, 'requests');
      final focus = s.focusProfile == id ? s.focusRequest : null;
      final request = all
          .where(
            (r) =>
                isPending(r, s.now()) &&
                s.requestCanSend(p, r) &&
                (r['request_id'] == focus ||
                    !presented.contains(requestKey(r))),
          )
          .firstOrNull;
      if (request == null) {
        if (s.focusProfile == id) {
          s.clearFocus();
          if (mounted) {
            unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => RelayPage(service: s)),
              ),
            );
          }
        }
        continue;
      }
      opening = true;
      try {
        await s.markPresented(id, requestKey(request));
        if (!mounted || !s.foreground) return;
        currentProfile = id;
        currentRequest = request['request_id'] as String;
        s.clearFocus();
        final next = DialogRoute<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => RelayQuestionDialog(
            service: s,
            profileId: id,
            requestId: currentRequest!,
          ),
        );
        route = next;
        unawaited(
          Navigator.of(context, rootNavigator: true).push(next).then((_) {
            if (route == next) route = null;
            changed();
          }),
        );
      } on Object {
        /* Secure storage failed: never display an untracked prompt. */
      } finally {
        opening = false;
      }
      break;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
