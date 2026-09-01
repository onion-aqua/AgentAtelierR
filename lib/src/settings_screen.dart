import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'ai_services.dart';
import 'app_controller.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.onMenuPressed,
  });

  final AppController controller;
  final VoidCallback onMenuPressed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: onMenuPressed,
          tooltip: '菜单',
          icon: const Icon(Icons.menu),
        ),
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _SectionLabel('界面'),
          SwitchListTile(
            value: controller.liquidGlassChatUi,
            onChanged: controller.setLiquidGlassChatUi,
            secondary: const Icon(Icons.blur_on_rounded),
            title: const Text('液态玻璃对话框'),
            subtitle: Text(
              controller.liquidGlassChatUi
                  ? '半透明浮层，可拖动手柄调整高度'
                  : '使用固定回复卡和底部发送栏',
            ),
          ),
          SwitchListTile(
            value: controller.showMicrophoneButton,
            onChanged: controller.setShowMicrophoneButton,
            secondary: const Icon(Icons.mic_none_rounded),
            title: const Text('显示麦克风按钮'),
            subtitle: const Text('语音输入尚未接入，默认隐藏'),
          ),
          const Divider(indent: 16, endIndent: 16),
          const _SectionLabel('场景'),
          SwitchListTile(
            value: controller.automaticSceneTime,
            onChanged: controller.setAutomaticSceneTime,
            secondary: const Icon(Icons.schedule_outlined),
            title: const Text('根据时间自动切换'),
            subtitle: Text(
              controller.automaticSceneTime
                  ? '当前自动使用${controller.sceneTime.label}场景'
                  : '当前固定为${controller.sceneTime.label}场景',
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          const _SectionLabel('声音'),
          SwitchListTile(
            value: controller.voiceEnabled,
            onChanged: controller.setVoiceEnabled,
            secondary: const Icon(Icons.record_voice_over_outlined),
            title: const Text('点击语音'),
            subtitle: const Text('点击角色时播放对应语音'),
          ),
          ListTile(
            leading: const Icon(Icons.volume_up_outlined),
            title: const Text('语音音量'),
            subtitle: Slider(
              value: controller.voiceVolume,
              onChanged: controller.voiceEnabled
                  ? controller.setVoiceVolume
                  : null,
            ),
            trailing: SizedBox(
              width: 42,
              child: Text(
                '${(controller.voiceVolume * 100).round()}%',
                textAlign: TextAlign.end,
              ),
            ),
          ),
          SwitchListTile(
            value: controller.bgmEnabled,
            onChanged: controller.setBgmEnabled,
            secondary: const Icon(Icons.music_note_outlined),
            title: const Text('背景音乐'),
            subtitle: const Text('循环播放工房主题音乐'),
          ),
          ListTile(
            leading: const Icon(Icons.music_note),
            title: const Text('音乐音量'),
            subtitle: Slider(
              value: controller.bgmVolume,
              onChanged: controller.bgmEnabled ? controller.setBgmVolume : null,
            ),
            trailing: Text('${(controller.bgmVolume * 100).round()}%'),
          ),
          SwitchListTile(
            value: controller.ambientEnabled,
            onChanged: controller.setAmbientEnabled,
            secondary: const Icon(Icons.forest_outlined),
            title: const Text('环境音'),
            subtitle: const Text('根据白天或夜晚切换环境声'),
          ),
          ListTile(
            leading: const Icon(Icons.surround_sound_outlined),
            title: const Text('环境音量'),
            subtitle: Slider(
              value: controller.ambientVolume,
              onChanged: controller.ambientEnabled
                  ? controller.setAmbientVolume
                  : null,
            ),
            trailing: Text('${(controller.ambientVolume * 100).round()}%'),
          ),
          const Divider(indent: 16, endIndent: 16),
          const _SectionLabel('用户设定'),
          Card(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('称呼与自画像'),
              subtitle: Text(
                '${controller.userAddress} · ${controller.userRelationshipRole.label} · ${controller.userInteractionStyle.label}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showUserProfileSettings(context),
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          const _SectionLabel('AI 对话'),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('OpenAI 兼容接口'),
            subtitle: Text(
              controller.aiEnabled
                  ? '${controller.openAiModel}\n${controller.openAiBaseUrl}'
                  : '未启用',
            ),
            isThreeLine: controller.aiEnabled,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAiSettings(context),
          ),
          ListTile(
            enabled:
                controller.aiEnabled &&
                controller.supportsOpenAiAdvancedControls,
            leading: const Icon(Icons.tune_rounded),
            title: const Text('GPT 推理与输出'),
            subtitle: Text(
              !controller.aiEnabled
                  ? '启用真实 AI 对话后可配置'
                  : !controller.supportsOpenAiAdvancedControls
                  ? '仅 GPT-5 系列模型可用'
                  : controller.openAiAdvancedEnabled
                  ? '${controller.openAiReasoningEffort.label} · ${controller.openAiOutputMultiplier}x 输出'
                  : '关闭',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap:
                controller.aiEnabled &&
                    controller.supportsOpenAiAdvancedControls
                ? () => _showOpenAiAdvancedSettings(context)
                : null,
          ),
          SwitchListTile(
            value: controller.agentEnabled,
            onChanged: controller.aiEnabled ? controller.setAgentEnabled : null,
            secondary: const Icon(Icons.travel_explore_rounded),
            title: const Text('联网 Agent'),
            subtitle: const Text('允许模型调用只读网页搜索工具，最多执行两轮'),
          ),
          SwitchListTile(
            value: controller.longTermMemoryEnabled,
            onChanged: controller.setLongTermMemoryEnabled,
            secondary: const Icon(Icons.psychology_alt_outlined),
            title: const Text('长期记忆'),
            subtitle: Text(
              controller.memorySummary.isEmpty
                  ? '每 4 轮对话自动整理一次'
                  : controller.memorySummary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.favorite_border),
            title: const Text('角色状态'),
            subtitle: Text(
              '${controller.characterMood.label} · 关系点数 ${controller.relationshipPoints}',
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          const _SectionLabel('Fish Audio'),
          ListTile(
            leading: const Icon(Icons.graphic_eq_rounded),
            title: const Text('AI 回复语音'),
            subtitle: Text(
              controller.fishTtsEnabled
                  ? '${controller.fishAudioModel} · ${controller.fishAudioReferenceId.isEmpty ? '未填写 voice model ID' : '已配置 voice model'}'
                  : '未启用',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showFishSettings(context),
          ),
          const Divider(indent: 16, endIndent: 16),
          const _SectionLabel('数据'),
          ListTile(
            leading: const Icon(Icons.history_outlined),
            title: const Text('聊天记录'),
            subtitle: Text('本机保存 ${controller.messages.length} 条消息'),
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('导出本地数据'),
            subtitle: const Text('不包含 OpenAI 和 Fish Audio API Key'),
            onTap: () => _exportData(context),
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('导入本地数据'),
            subtitle: const Text('从 Ryza Chat JSON 备份恢复'),
            onTap: () => _importData(context),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('清除聊天记录'),
            subtitle: const Text('任务和地图进度不会受到影响'),
            onTap: () => _confirmClearHistory(context),
          ),
          const Divider(indent: 16, endIndent: 16),
          const _SectionLabel('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Ryza Chat Prototype'),
            subtitle: Text('版本 0.3.9 · 用户设定 + 动态说话演出 + Fish Audio'),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(72, 0, 24, 12),
            child: Text(
              '当前仅用于本地原型验证。角色、美术、语音',
              style: TextStyle(
                color: Colors.black54,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除聊天记录？'),
        content: const Text('该操作只清除本机的聊天内容，无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.clearChatHistory();
  }

  Future<void> _showUserProfileSettings(BuildContext context) async {
    final address = TextEditingController(text: controller.userAddress);
    final portrait = TextEditingController(text: controller.userPortrait);
    final boundaries = TextEditingController(
      text: controller.userInteractionBoundaries,
    );
    var relationshipRole = controller.userRelationshipRole;
    var interactionStyle = controller.userInteractionStyle;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('用户设定'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: address,
                    maxLength: 24,
                    decoration: const InputDecoration(
                      labelText: '莱莎对你的称呼',
                      hintText: '伙伴',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: portrait,
                    minLines: 3,
                    maxLines: 5,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: '用户自画像',
                      hintText: '性格、兴趣、外观或身份设定',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<UserRelationshipRole>(
                    initialValue: relationshipRole,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '关系定位',
                      border: OutlineInputBorder(),
                    ),
                    items: UserRelationshipRole.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => relationshipRole = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<UserInteractionStyle>(
                    initialValue: interactionStyle,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '互动偏好',
                      border: OutlineInputBorder(),
                    ),
                    items: UserInteractionStyle.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => interactionStyle = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: boundaries,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: 300,
                    decoration: const InputDecoration(
                      labelText: '需要避开的称呼或话题',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result == true) {
      controller.configureUserProfile(
        address: address.text,
        portrait: portrait.text,
        relationshipRole: relationshipRole,
        interactionStyle: interactionStyle,
        boundaries: boundaries.text,
      );
    }
    address.dispose();
    portrait.dispose();
    boundaries.dispose();
  }

  Future<void> _showAiSettings(BuildContext context) async {
    final baseUrl = TextEditingController(text: controller.openAiBaseUrl);
    final model = TextEditingController(text: controller.openAiModel);
    final apiKey = TextEditingController();
    var enabled = controller.aiEnabled;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('OpenAI 兼容接口'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: enabled,
                  onChanged: (value) => setDialogState(() => enabled = value),
                  title: const Text('启用真实 AI 对话'),
                ),
                TextField(
                  controller: baseUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://example.com/v1',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: model,
                  decoration: const InputDecoration(
                    labelText: '模型名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: apiKey,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API Key',
                    hintText: '留空则保留当前 Key',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '接口使用 /chat/completions 与 SSE 流式增量。Key 保存在系统安全存储。',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await const SecretStore().writeOpenAiKey('');
                if (context.mounted) Navigator.pop(context, false);
              },
              child: const Text('清除 Key'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    controller.configureAi(
      enabled: enabled,
      baseUrl: baseUrl.text,
      model: model.text,
    );
    if (apiKey.text.trim().isNotEmpty) {
      await const SecretStore().writeOpenAiKey(apiKey.text);
    }
  }

  Future<void> _showOpenAiAdvancedSettings(BuildContext context) async {
    var enabled = controller.openAiAdvancedEnabled;
    var reasoningEffort = controller.openAiReasoningEffort;
    var outputMultiplier = controller.openAiOutputMultiplier;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('GPT 推理与输出'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: enabled,
                onChanged: (value) => setDialogState(() => enabled = value),
                title: const Text('启用高级推理参数'),
                subtitle: const Text('默认关闭；关闭时不向接口发送额外参数'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ReasoningEffort>(
                initialValue: reasoningEffort,
                decoration: const InputDecoration(
                  labelText: '推理努力程度',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final effort in ReasoningEffort.values)
                    DropdownMenuItem(value: effort, child: Text(effort.label)),
                ],
                onChanged: enabled
                    ? (value) {
                        if (value != null) {
                          setDialogState(() => reasoningEffort = value);
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 16),
              const Text('最大输出倍率'),
              const SizedBox(height: 8),
              SegmentedButton<double>(
                segments: const [
                  ButtonSegment(value: 1.0, label: Text('1x')),
                  ButtonSegment(value: 1.5, label: Text('1.5x')),
                ],
                selected: {outputMultiplier},
                onSelectionChanged: enabled
                    ? (selection) => setDialogState(
                        () => outputMultiplier = selection.single,
                      )
                    : null,
              ),
              const SizedBox(height: 10),
              const Text(
                '倍率对应最大输出 token 预算。兼容接口必须支持 reasoning_effort 和 max_completion_tokens。',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    controller.configureOpenAiAdvanced(
      enabled: enabled,
      reasoningEffort: reasoningEffort,
      outputMultiplier: outputMultiplier,
    );
  }

  Future<void> _showFishSettings(BuildContext context) async {
    final referenceId = TextEditingController(
      text: controller.fishAudioReferenceId,
    );
    final apiKey = TextEditingController();
    final player = AudioPlayer();
    var enabled = controller.fishTtsEnabled;
    var model = controller.fishAudioModel;
    if (!const {'s2-pro', 's2.1-pro', 's2.1-pro-free'}.contains(model)) {
      model = 's2-pro';
    }
    var format = controller.fishAudioFormat;
    var latency = controller.fishAudioLatency;
    var speed = controller.fishAudioSpeed;
    var isTesting = false;
    String? testError;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final contentWidth = (MediaQuery.sizeOf(context).width - 128).clamp(
            240.0,
            420.0,
          );
          final stackedFields = contentWidth < 340;
          final fieldWidth = stackedFields
              ? contentWidth
              : (contentWidth - 12) / 2;
          return AlertDialog(
            title: const Text('Fish Audio TTS'),
            content: SizedBox(
              width: contentWidth,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: enabled,
                      onChanged: (value) =>
                          setDialogState(() => enabled = value),
                      title: const Text('AI 回复后自动播放'),
                      subtitle: const Text('只合成“莱莎：”台词，旁白不会发声'),
                    ),
                    const InputDecorator(
                      decoration: InputDecoration(
                        labelText: '官方 API 端点',
                        border: OutlineInputBorder(),
                      ),
                      child: SelectableText(FishAudioClient.endpoint),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: model,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'TTS 模型',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 's2-pro',
                          child: Text('s2-pro'),
                        ),
                        DropdownMenuItem(
                          value: 's2.1-pro',
                          child: Text('s2.1-pro'),
                        ),
                        DropdownMenuItem(
                          value: 's2.1-pro-free',
                          child: Text('s2.1-pro-free（开发者免费层）'),
                        ),
                      ],
                      selectedItemBuilder: (context) => const [
                        Text('s2-pro', overflow: TextOverflow.ellipsis),
                        Text('s2.1-pro', overflow: TextOverflow.ellipsis),
                        Text('s2.1-pro-free', overflow: TextOverflow.ellipsis),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => model = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: referenceId,
                      decoration: const InputDecoration(
                        labelText: 'Voice model ID / reference_id',
                        helperText: 'Fish Audio 声音库或自建声音模型的 ID',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: fieldWidth,
                          child: DropdownButtonFormField<String>(
                            initialValue: format,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '输出格式',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'mp3',
                                child: Text('MP3'),
                              ),
                              DropdownMenuItem(
                                value: 'wav',
                                child: Text('WAV'),
                              ),
                              DropdownMenuItem(
                                value: 'opus',
                                child: Text('Opus'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => format = value);
                              }
                            },
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: DropdownButtonFormField<String>(
                            initialValue: latency,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '延迟策略',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'normal',
                                child: Text('质量优先'),
                              ),
                              DropdownMenuItem(
                                value: 'balanced',
                                child: Text('平衡'),
                              ),
                              DropdownMenuItem(
                                value: 'low',
                                child: Text('低延迟'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => latency = value);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const SizedBox(width: 58, child: Text('语速')),
                        Expanded(
                          child: Slider(
                            value: speed,
                            min: 0.5,
                            max: 2.0,
                            divisions: 15,
                            label: '${speed.toStringAsFixed(1)}x',
                            onChanged: (value) =>
                                setDialogState(() => speed = value),
                          ),
                        ),
                        SizedBox(
                          width: 42,
                          child: Text('${speed.toStringAsFixed(1)}x'),
                        ),
                      ],
                    ),
                    TextField(
                      controller: apiKey,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Fish Audio API Key',
                        hintText: '留空则保留当前 Key',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (testError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        testError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await const SecretStore().writeFishAudioKey('');
                  if (context.mounted) Navigator.pop(context, false);
                },
                child: const Text('清除 Key'),
              ),
              TextButton.icon(
                onPressed: isTesting
                    ? null
                    : () async {
                        final key = apiKey.text.trim().isNotEmpty
                            ? apiKey.text.trim()
                            : await const SecretStore().readFishAudioKey();
                        if (key.isEmpty || referenceId.text.trim().isEmpty) {
                          setDialogState(
                            () => testError = '请先填写 API Key 和 reference_id',
                          );
                          return;
                        }
                        setDialogState(() {
                          isTesting = true;
                          testError = null;
                        });
                        try {
                          final path = await FishAudioClient().synthesize(
                            apiKey: key,
                            referenceId: referenceId.text.trim(),
                            text: '[curious] 这个素材的性质很特别呢。',
                            model: model,
                            format: format,
                            latency: latency,
                            speed: speed,
                          );
                          await player.stop();
                          await player.setVolume(controller.voiceVolume);
                          await player.play(DeviceFileSource(path));
                        } on Object catch (error) {
                          if (context.mounted) {
                            setDialogState(() => testError = error.toString());
                          }
                        } finally {
                          if (context.mounted) {
                            setDialogState(() => isTesting = false);
                          }
                        }
                      },
                icon: isTesting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: const Text('试音'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    await player.dispose();
    if (result != true) return;
    controller.configureFishAudio(
      enabled: enabled,
      model: model,
      referenceId: referenceId.text,
      format: format,
      latency: latency,
      speed: speed,
    );
    if (apiKey.text.trim().isNotEmpty) {
      await const SecretStore().writeFishAudioKey(apiKey.text);
    }
  }

  Future<void> _exportData(BuildContext context) async {
    final bytes = Uint8List.fromList(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert(controller.exportData()),
      ),
    );
    final uri = await FilePicker.saveFile(
      fileName:
          'ryza-chat-backup-${DateTime.now().millisecondsSinceEpoch}.json',
      bytes: bytes,
      mimeType: 'application/json',
    );
    if (!context.mounted || uri == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('本地数据已导出')));
  }

  Future<void> _importData(BuildContext context) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      controller.importData(decoded);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('本地数据已恢复，API Key 保持不变')));
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$error')));
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 7),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
