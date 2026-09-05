import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai_services.dart';
import 'app_controller.dart';
import 'app_localization.dart';
import 'chat_segments.dart';
import 'runtime_log.dart';
import 'platform_slider.dart';

String _activeTtsModel(AppController controller) =>
    switch (controller.ttsProvider) {
      TtsProvider.fishAudio => controller.fishAudioModel,
      TtsProvider.dashScope => controller.dashScopeTtsModel,
      TtsProvider.generic => controller.genericTtsModel,
    };

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
    final language = controller.interfaceLanguage;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: onMenuPressed,
          tooltip: language.text('菜单', 'Menu', 'メニュー'),
          icon: const Icon(Icons.menu),
        ),
        title: Text(language.text('设置', 'Settings', '設定')),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _SectionLabel(language.text('界面', 'Appearance', '表示')),
          ListTile(
            leading: const Icon(Icons.contrast_rounded),
            title: Text(language.text('主题', 'Theme', 'テーマ')),
            subtitle: Text(controller.themePreference.label(language)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showThemeSettings(context),
          ),
          ListTile(
            leading: const Icon(Icons.translate_rounded),
            title: Text(language.text('语言', 'Languages', '言語')),
            subtitle: Text(
              '${controller.interfaceLanguage.nativeLabel} · '
              '${language.text('莱莎', 'Ryza', 'ライザ')} '
              '${controller.characterReplyLanguage.nativeLabel}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showLanguageSettings(context),
          ),
          SwitchListTile(
            value: controller.liquidGlassChatUi,
            onChanged: controller.setLiquidGlassChatUi,
            secondary: const Icon(Icons.blur_on_rounded),
            title: Text(
              language.text('液态玻璃对话框', 'Liquid glass chat', 'リキッドガラス会話'),
            ),
            subtitle: Text(
              controller.liquidGlassChatUi
                  ? language.text(
                      '动态浮层启用背景模糊与玻璃高光',
                      'Blur and glass highlights enabled',
                      'ぼかしとガラスのハイライトを有効化',
                    )
                  : language.text(
                      '保留动态浮层，仅关闭模糊并使用普通半透明材质',
                      'Use the translucent panel without blur',
                      'ぼかしなしの半透明パネルを使用',
                    ),
            ),
          ),
          SwitchListTile(
            value: controller.showMicrophoneButton,
            onChanged: controller.setShowMicrophoneButton,
            secondary: const Icon(Icons.mic_none_rounded),
            title: Text(
              language.text('显示麦克风按钮', 'Show microphone button', 'マイクボタンを表示'),
            ),
            subtitle: Text(
              language.text(
                '语音输入尚未接入，默认隐藏',
                'Voice input is not available yet',
                '音声入力はまだ利用できません',
              ),
            ),
          ),
          SwitchListTile(
            value: controller.gazeTrackingEnabled,
            onChanged: controller.setGazeTrackingEnabled,
            secondary: const Icon(Icons.visibility_rounded),
            title: Text(language.text('视线追踪', 'Gaze tracking', '視線追跡')),
            subtitle: Text(
              language.text(
                '按住角色区域时，眼睛与高光跟随手指方向',
                'Eyes and highlights follow your finger while held',
                '押している間、目とハイライトが指を追跡',
              ),
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          _SectionLabel(language.text('场景', 'Scene', 'シーン')),
          SwitchListTile(
            value: controller.automaticSceneTime,
            onChanged: controller.setAutomaticSceneTime,
            secondary: const Icon(Icons.schedule_outlined),
            title: Text(
              language.text('根据时间自动切换', 'Follow time of day', '時刻に合わせて切り替え'),
            ),
            subtitle: Text(
              controller.automaticSceneTime
                  ? language.text(
                      '当前自动使用${controller.sceneTime.label}场景',
                      'Scene changes automatically',
                      'シーンを自動的に変更します',
                    )
                  : language.text(
                      '当前固定为${controller.sceneTime.label}场景',
                      'Scene time is fixed',
                      'シーンの時間は固定です',
                    ),
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          _SectionLabel(language.text('声音', 'Audio', 'サウンド')),
          SwitchListTile(
            value: controller.voiceEnabled,
            onChanged: controller.setVoiceEnabled,
            secondary: const Icon(Icons.record_voice_over_outlined),
            title: Text(language.text('点击语音', 'Tap voice', 'タップ音声')),
            subtitle: Text(
              language.text(
                '点击角色时播放对应语音',
                'Play a voice line when Ryza is tapped',
                'ライザをタップすると音声を再生します',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.volume_up_outlined),
            title: Text(language.text('语音音量', 'Voice volume', '音声音量')),
            subtitle: PlatformSlider(
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
            title: Text(language.text('背景音乐', 'Background music', 'BGM')),
            subtitle: Text(
              language.text(
                '循环播放工房主题音乐',
                'Loop the atelier theme',
                'アトリエのテーマをループ再生',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.music_note),
            title: Text(language.text('音乐音量', 'Music volume', 'BGM音量')),
            subtitle: PlatformSlider(
              value: controller.bgmVolume,
              onChanged: controller.bgmEnabled ? controller.setBgmVolume : null,
            ),
            trailing: Text('${(controller.bgmVolume * 100).round()}%'),
          ),
          SwitchListTile(
            value: controller.ambientEnabled,
            onChanged: controller.setAmbientEnabled,
            secondary: const Icon(Icons.forest_outlined),
            title: Text(language.text('环境音', 'Ambient sound', '環境音')),
            subtitle: Text(
              language.text(
                '根据白天或夜晚切换环境声',
                'Change ambience for day and night',
                '昼夜に合わせて環境音を変更',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.surround_sound_outlined),
            title: Text(language.text('环境音量', 'Ambient volume', '環境音量')),
            subtitle: PlatformSlider(
              value: controller.ambientVolume,
              onChanged: controller.ambientEnabled
                  ? controller.setAmbientVolume
                  : null,
            ),
            trailing: Text('${(controller.ambientVolume * 100).round()}%'),
          ),
          const Divider(indent: 16, endIndent: 16),
          _SectionLabel(language.text('用户设定', 'User profile', 'ユーザー設定')),
          Card(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text(
                language.text(
                  '称呼与自画像',
                  'Name and self-description',
                  '呼び方とプロフィール',
                ),
              ),
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
          _SectionLabel(language.text('AI 对话', 'AI chat', 'AI会話')),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(
              language.text(
                'OpenAI 兼容接口',
                'OpenAI-compatible API',
                'OpenAI互換API',
              ),
            ),
            subtitle: Text(
              controller.aiEnabled
                  ? '${controller.openAiModel}\n${controller.openAiBaseUrl}'
                  : language.text('未启用', 'Disabled', '無効'),
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
            title: Text(
              language.text(
                'GPT 推理与输出',
                'GPT reasoning and output',
                'GPT推論と出力',
              ),
            ),
            subtitle: Text(
              !controller.aiEnabled
                  ? language.text(
                      '启用真实 AI 对话后可配置',
                      'Enable AI chat to configure',
                      'AI会話を有効にすると設定できます',
                    )
                  : !controller.supportsOpenAiAdvancedControls
                  ? language.text(
                      '仅 GPT-5 系列模型可用',
                      'Available for GPT-5 models only',
                      'GPT-5シリーズのみ利用可能',
                    )
                  : controller.openAiAdvancedEnabled
                  ? '${controller.openAiReasoningEffort.label} · ${controller.openAiOutputMultiplier}x 输出'
                  : language.text('关闭', 'Off', 'オフ'),
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
            title: Text(language.text('联网 Agent', 'Web agent', 'ウェブエージェント')),
            subtitle: Text(
              language.text(
                '允许模型调用只读网页搜索工具，最多执行两轮',
                'Allow up to two rounds of read-only web search',
                '読み取り専用ウェブ検索を最大2回許可',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.psychology_alt_outlined),
            title: Text(language.text('长期记忆', 'Long-term memory', '長期記憶')),
            subtitle: Text(
              controller.memorySummary.isEmpty
                  ? language.text(
                      '暂无记忆 · 每 4 轮对话自动整理',
                      'No memory yet · summarized every 4 turns',
                      '記憶なし · 4ターンごとに要約',
                    )
                  : controller.memorySummary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: controller.longTermMemoryEnabled,
                  onChanged: controller.setLongTermMemoryEnabled,
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => _showLongTermMemorySettings(context),
          ),
          ListTile(
            leading: const Icon(Icons.favorite_border),
            title: Text(language.text('角色状态', 'Character status', 'キャラクター状態')),
            subtitle: Text(
              language.text(
                '${controller.characterMood.label} · 关系点数 ${controller.relationshipPoints}',
                '${controller.characterMood.label} · Bond ${controller.relationshipPoints}',
                '${controller.characterMood.label} · 親密度 ${controller.relationshipPoints}',
              ),
            ),
          ),
          const Divider(indent: 16, endIndent: 16),
          _SectionLabel(language.text('语音合成', 'Speech synthesis', '音声合成')),
          ListTile(
            leading: const Icon(Icons.graphic_eq_rounded),
            title: Text(language.text('AI 回复语音', 'AI reply voice', 'AI返答音声')),
            subtitle: Text(
              controller.fishTtsEnabled
                  ? '${controller.ttsProvider.label} · ${_activeTtsModel(controller)}'
                  : language.text('未启用', 'Disabled', '無効'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showTtsSettings(context),
          ),
          const Divider(indent: 16, endIndent: 16),
          _SectionLabel(language.text('数据', 'Data', 'データ')),
          ListTile(
            leading: const Icon(Icons.history_outlined),
            title: Text(language.text('聊天记录', 'Chat history', '会話履歴')),
            subtitle: Text(
              language.text(
                '本机保存 ${controller.messages.length} 条消息',
                '${controller.messages.length} messages stored locally',
                '${controller.messages.length}件のメッセージを端末に保存',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: Text(
              language.text('导出本地数据', 'Export local data', 'ローカルデータを書き出す'),
            ),
            subtitle: Text(
              language.text(
                '不包含任何 AI 或语音服务 API Key',
                'API keys are never included',
                'APIキーは含まれません',
              ),
            ),
            onTap: () => _exportData(context),
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: Text(
              language.text('导入本地数据', 'Import local data', 'ローカルデータを読み込む'),
            ),
            subtitle: Text(
              language.text(
                '从 Ryza Chat JSON 备份恢复',
                'Restore a Ryza Chat JSON backup',
                'Ryza ChatのJSONバックアップから復元',
              ),
            ),
            onTap: () => _importData(context),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(
              language.text('清除聊天记录', 'Clear chat history', '会話履歴を消去'),
            ),
            subtitle: Text(
              language.text(
                '任务和地图进度不会受到影响',
                'Mission and map progress are preserved',
                'ミッションとマップの進行状況は保持されます',
              ),
            ),
            onTap: () => _confirmClearHistory(context),
          ),
          const Divider(indent: 16, endIndent: 16),
          _SectionLabel(language.text('关于', 'About', 'このアプリについて')),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Ryza Chat Prototype'),
            subtitle: Text(
              language.text(
                '版本 0.5.0 · 主题与三语支持',
                'Version 0.5.0 · Themes and 3 languages',
                'バージョン 0.5.0 · テーマと3言語対応',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 24, 12),
            child: Text(
              language.text(
                '当前仅用于本地原型验证。角色、美术、语音资源请仅在合法授权范围内使用。',
                'Local prototype only. Use character, artwork, and voice assets only with proper authorization.',
                'ローカル試作版です。キャラクター、画像、音声素材は適切な許諾の範囲でのみ使用してください。',
              ),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showThemeSettings(BuildContext context) async {
    final selected = await showDialog<AppThemePreference>(
      context: context,
      builder: (context) => _ThemeSettingsDialog(
        initialValue: controller.themePreference,
        language: controller.interfaceLanguage,
      ),
    );
    if (selected != null) controller.setThemePreference(selected);
  }

  Future<void> _showLongTermMemorySettings(BuildContext context) async {
    final result = await showDialog<_LongTermMemoryDraft>(
      context: context,
      builder: (context) => _LongTermMemoryDialog(
        enabled: controller.longTermMemoryEnabled,
        summary: controller.memorySummary,
        language: controller.interfaceLanguage,
      ),
    );
    if (result == null) return;
    controller.configureLongTermMemory(
      enabled: result.enabled,
      summary: result.summary,
    );
  }

  Future<void> _showLanguageSettings(BuildContext context) async {
    final result = await showDialog<_LanguageSettingsDraft>(
      context: context,
      builder: (context) => _LanguageSettingsDialog(
        interfaceLanguage: controller.interfaceLanguage,
        narratorLanguage: controller.narratorLanguage,
        characterReplyLanguage: controller.characterReplyLanguage,
        translationLanguage: controller.translationLanguage,
      ),
    );
    if (result == null) return;
    controller.configureLanguages(
      interface: result.interfaceLanguage,
      narrator: result.narratorLanguage,
      characterReply: result.characterReplyLanguage,
      translation: result.translationLanguage,
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
    final result = await showDialog<_UserProfileDraft>(
      context: context,
      builder: (context) => _UserProfileDialog(
        address: controller.userAddress,
        portrait: controller.userPortrait,
        relationshipRole: controller.userRelationshipRole,
        interactionStyle: controller.userInteractionStyle,
        boundaries: controller.userInteractionBoundaries,
      ),
    );
    if (result == null) return;
    controller.configureUserProfile(
      address: result.address,
      portrait: result.portrait,
      relationshipRole: result.relationshipRole,
      interactionStyle: result.interactionStyle,
      boundaries: result.boundaries,
    );
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
            _DialogActionRow(
              children: [
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
            _DialogActionRow(
              children: [
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

  Future<void> _showTtsSettings(BuildContext context) async {
    final provider = await showModalBottomSheet<TtsProvider>(
      context: context,
      backgroundColor: const Color(0xFFF8F6F1),
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('选择语音服务'),
              subtitle: Text('API Key 分别保存在系统安全存储中'),
            ),
            for (final value in TtsProvider.values)
              ListTile(
                leading: Icon(
                  value == controller.ttsProvider
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(value.label),
                subtitle: Text(switch (value) {
                  TtsProvider.fishAudio => 'Fish Audio S2 Pro 与声音模型 ID',
                  TtsProvider.dashScope => '百炼 Qwen3-TTS 系统音色与指令控制',
                  TtsProvider.generic => '兼容 OpenAI /audio/speech 的自定义服务',
                }),
                onTap: () => Navigator.pop(context, value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || provider == null) return;
    switch (provider) {
      case TtsProvider.fishAudio:
        await _showFishSettings(context);
      case TtsProvider.dashScope:
        await _showDashScopeSettings(context);
      case TtsProvider.generic:
        await _showGenericTtsSettings(context);
    }
  }

  Future<void> _showFishSettings(BuildContext context) async {
    final referenceId = TextEditingController(
      text: controller.fishAudioReferenceId,
    );
    final asmrReferenceId = TextEditingController(
      text: controller.fishAudioAsmrReferenceId,
    );
    final apiKey = TextEditingController();
    final previewText = TextEditingController(text: controller.ttsPreviewText);
    final player = AudioPlayer();
    var enabled = controller.fishTtsEnabled;
    var model = controller.fishAudioModel;
    if (!const {'s2-pro', 's2.1-pro', 's2.1-pro-free'}.contains(model)) {
      model = 's2-pro';
    }
    var format = controller.fishAudioFormat;
    var latency = controller.fishAudioLatency;
    var speed = controller.fishAudioSpeed;
    var emotionIntensity = controller.ttsEmotionIntensity;
    var cueDensity = controller.ttsCueDensity;
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
                    _TtsEmotionSlider(
                      value: emotionIntensity,
                      onChanged: (value) =>
                          setDialogState(() => emotionIntensity = value),
                    ),
                    _TtsCueDensitySlider(
                      value: cueDensity,
                      onChanged: (value) =>
                          setDialogState(() => cueDensity = value),
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
                    TextField(
                      controller: asmrReferenceId,
                      decoration: const InputDecoration(
                        labelText: 'ASMR 模式 Voice model ID',
                        helperText: '可选；仅在主页开启 ASMR 模式时使用并校验',
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
                          child: PlatformSlider(
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
                    const SizedBox(height: 12),
                    _TtsPreviewEditor(
                      controller: previewText,
                      testing: isTesting,
                      onClearKey: () async {
                        await const SecretStore().writeFishAudioKey('');
                        if (context.mounted) Navigator.pop(context, false);
                      },
                      onTest: () async {
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
                            text: applyFishEmotionIntensityPerSentence(
                              ensureFishEmotionCue(
                                previewText.text.trim(),
                                CharacterMood.happy,
                              ),
                              emotionIntensity,
                              density: cueDensity,
                            ),
                            model: model,
                            format: format,
                            latency: latency,
                            speed: speed,
                            temperature: emotionIntensity.fishTemperature,
                          );
                          await player.stop();
                          await player.setVolume(controller.voiceVolume);
                          await player.play(DeviceFileSource(path));
                        } on Object catch (error) {
                          RuntimeLog.instance.error('Fish Audio 试音', error);
                          if (context.mounted) {
                            setDialogState(() => testError = error.toString());
                          }
                        } finally {
                          if (context.mounted) {
                            setDialogState(() => isTesting = false);
                          }
                        }
                      },
                      onCancel: () => Navigator.pop(context, false),
                      onSave: () => Navigator.pop(context, true),
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
            actions: const [],
          );
        },
      ),
    );
    await player.dispose();
    if (result != true) return;
    controller.setTtsProvider(TtsProvider.fishAudio);
    controller.setTtsPreviewText(previewText.text);
    controller.configureFishAudio(
      enabled: enabled,
      model: model,
      referenceId: referenceId.text,
      asmrReferenceId: asmrReferenceId.text,
      format: format,
      latency: latency,
      speed: speed,
      emotionIntensity: emotionIntensity,
    );
    controller.setTtsCueDensity(cueDensity);
    if (apiKey.text.trim().isNotEmpty) {
      await const SecretStore().writeFishAudioKey(apiKey.text);
    }
  }

  Future<void> _showDashScopeSettings(BuildContext context) async {
    final baseUrl = TextEditingController(text: controller.dashScopeTtsBaseUrl);
    final model = TextEditingController(text: controller.dashScopeTtsModel);
    final voice = TextEditingController(text: controller.dashScopeTtsVoice);
    final asmrVoice = TextEditingController(
      text: controller.dashScopeTtsAsmrVoice,
    );
    final instructions = TextEditingController(
      text: controller.dashScopeTtsInstructions,
    );
    final preview = TextEditingController(text: controller.ttsPreviewText);
    final key = TextEditingController();
    final player = AudioPlayer();
    var enabled = controller.fishTtsEnabled;
    var language = controller.dashScopeTtsLanguage;
    var emotionIntensity = controller.ttsEmotionIntensity;
    var cueDensity = controller.ttsCueDensity;
    var testing = false;
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('百炼 Qwen-TTS'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: enabled,
                    onChanged: (value) => setDialogState(() => enabled = value),
                    title: const Text('AI 回复后自动播放'),
                  ),
                  _TtsEmotionSlider(
                    value: emotionIntensity,
                    onChanged: (value) =>
                        setDialogState(() => emotionIntensity = value),
                  ),
                  _TtsCueDensitySlider(
                    value: cueDensity,
                    onChanged: (value) =>
                        setDialogState(() => cueDensity = value),
                  ),
                  TextField(
                    controller: baseUrl,
                    decoration: const InputDecoration(
                      labelText: '百炼 API 端点',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: model,
                    decoration: const InputDecoration(
                      labelText: '模型',
                      hintText: 'qwen3-tts-flash',
                      helperText: '指令控制可使用 qwen3-tts-instruct-flash',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: voice,
                    decoration: const InputDecoration(
                      labelText: '系统音色 / Voice ID',
                      hintText: 'Cherry',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: asmrVoice,
                    decoration: const InputDecoration(
                      labelText: 'ASMR 模式 Voice ID',
                      helperText: '可选；仅在主页开启 ASMR 模式时使用并校验',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: language,
                    decoration: const InputDecoration(
                      labelText: '语言',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'Chinese', child: Text('中文')),
                      DropdownMenuItem(value: 'English', child: Text('英文')),
                      DropdownMenuItem(value: 'Japanese', child: Text('日语')),
                      DropdownMenuItem(value: 'Korean', child: Text('韩语')),
                    ],
                    onChanged: (value) {
                      if (value != null) setDialogState(() => language = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: instructions,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '声音指令（Instruct 模型）',
                      hintText: '活泼、明亮、语速稍快，带自然的少女感',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final preset in const {
                          '活泼少女': '年轻活泼的女性声音，音调明亮，语速稍快，情绪自然外放。',
                          '温柔陪伴': '温柔亲近的年轻女性声音，语速适中，语调柔和而真诚。',
                          '兴奋发现': '充满好奇和惊喜，语速偏快，重音鲜明，带明显的上扬语调。',
                          '清晰讲解': '吐字清楚，节奏有层次，语气自信友好，适合解释步骤。',
                        }.entries)
                          ActionChip(
                            label: Text(preset.key),
                            onPressed: () {
                              instructions.text = preset.value;
                              instructions.selection = TextSelection.collapsed(
                                offset: instructions.text.length,
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: key,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'DashScope API Key',
                      hintText: '留空则保留当前 Key',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _TtsPreviewEditor(
                    controller: preview,
                    testing: testing,
                    onClearKey: () async {
                      await const SecretStore().writeDashScopeKey('');
                      if (context.mounted) Navigator.pop(context, false);
                    },
                    onTest: () async {
                      final apiKey = key.text.trim().isNotEmpty
                          ? key.text.trim()
                          : await const SecretStore().readDashScopeKey();
                      if (apiKey.isEmpty || preview.text.trim().isEmpty) {
                        setDialogState(() => error = '请填写 API Key 和试音文字');
                        return;
                      }
                      setDialogState(() {
                        testing = true;
                        error = null;
                      });
                      try {
                        final path = await DashScopeTtsClient().synthesize(
                          apiKey: apiKey,
                          baseUrl: baseUrl.text,
                          text: preview.text.trim(),
                          model: model.text.trim(),
                          voice: voice.text.trim(),
                          language: language,
                          instructions:
                              model.text.trim().toLowerCase().contains(
                                'instruct',
                              )
                              ? mergeTtsInstructions(
                                  instructions.text,
                                  emotionIntensity,
                                )
                              : instructions.text,
                        );
                        await player.play(DeviceFileSource(path));
                      } on Object catch (value) {
                        RuntimeLog.instance.error('Qwen-TTS 试音', value);
                        if (context.mounted) {
                          setDialogState(() => error = value.toString());
                        }
                      } finally {
                        if (context.mounted) {
                          setDialogState(() => testing = false);
                        }
                      }
                    },
                    onCancel: () => Navigator.pop(context, false),
                    onSave: () => Navigator.pop(context, true),
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
          actions: const [],
        ),
      ),
    );
    await player.dispose();
    if (saved != true) return;
    controller.configureTts(
      enabled: enabled,
      provider: TtsProvider.dashScope,
      fishModel: controller.fishAudioModel,
      fishReferenceId: controller.fishAudioReferenceId,
      fishAsmrReferenceId: controller.fishAudioAsmrReferenceId,
      format: controller.fishAudioFormat,
      latency: controller.fishAudioLatency,
      speed: controller.fishAudioSpeed,
      dashBaseUrl: baseUrl.text,
      dashScopeModel: model.text,
      dashScopeVoice: voice.text,
      dashScopeAsmrVoice: asmrVoice.text,
      dashScopeLanguage: language,
      dashInstructions: instructions.text,
      genericBaseUrl: controller.genericTtsBaseUrl,
      genericModel: controller.genericTtsModel,
      genericVoice: controller.genericTtsVoice,
      genericAsmrVoice: controller.genericTtsAsmrVoice,
      emotionIntensity: emotionIntensity,
      previewText: preview.text,
    );
    controller.setTtsCueDensity(cueDensity);
    if (key.text.trim().isNotEmpty) {
      await const SecretStore().writeDashScopeKey(key.text);
    }
  }

  Future<void> _showGenericTtsSettings(BuildContext context) async {
    final baseUrl = TextEditingController(text: controller.genericTtsBaseUrl);
    final model = TextEditingController(text: controller.genericTtsModel);
    final voice = TextEditingController(text: controller.genericTtsVoice);
    final asmrVoice = TextEditingController(
      text: controller.genericTtsAsmrVoice,
    );
    final preview = TextEditingController(text: controller.ttsPreviewText);
    final key = TextEditingController();
    final player = AudioPlayer();
    var enabled = controller.fishTtsEnabled;
    var format = controller.fishAudioFormat == 'opus'
        ? 'mp3'
        : controller.fishAudioFormat;
    var speed = controller.fishAudioSpeed;
    var emotionIntensity = controller.ttsEmotionIntensity;
    var cueDensity = controller.ttsCueDensity;
    var testing = false;
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('通用 OpenAI TTS'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: enabled,
                    onChanged: (value) => setDialogState(() => enabled = value),
                    title: const Text('AI 回复后自动播放'),
                  ),
                  _TtsEmotionSlider(
                    value: emotionIntensity,
                    onChanged: (value) =>
                        setDialogState(() => emotionIntensity = value),
                  ),
                  _TtsCueDensitySlider(
                    value: cueDensity,
                    onChanged: (value) =>
                        setDialogState(() => cueDensity = value),
                  ),
                  TextField(
                    controller: baseUrl,
                    decoration: const InputDecoration(
                      labelText: 'Base URL 或完整 /audio/speech 地址',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: model,
                    decoration: const InputDecoration(
                      labelText: '模型',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: voice,
                    decoration: const InputDecoration(
                      labelText: 'Voice ID / 音色',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: asmrVoice,
                    decoration: const InputDecoration(
                      labelText: 'ASMR 模式 Voice ID',
                      helperText: '可选；仅在主页开启 ASMR 模式时使用并校验',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: format,
                          decoration: const InputDecoration(
                            labelText: '格式',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'wav', child: Text('WAV')),
                            DropdownMenuItem(value: 'mp3', child: Text('MP3')),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => format = value);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PlatformSlider(
                          value: speed,
                          min: 0.5,
                          max: 2,
                          divisions: 15,
                          label: '${speed.toStringAsFixed(1)}x',
                          onChanged: (value) =>
                              setDialogState(() => speed = value),
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: key,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key',
                      hintText: '留空则保留当前 Key',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _TtsPreviewEditor(
                    controller: preview,
                    testing: testing,
                    onClearKey: () async {
                      await const SecretStore().writeGenericTtsKey('');
                      if (context.mounted) Navigator.pop(context, false);
                    },
                    onTest: () async {
                      final apiKey = key.text.trim().isNotEmpty
                          ? key.text.trim()
                          : await const SecretStore().readGenericTtsKey();
                      if (apiKey.isEmpty || preview.text.trim().isEmpty) {
                        setDialogState(() => error = '请填写 API Key 和试音文字');
                        return;
                      }
                      setDialogState(() {
                        testing = true;
                        error = null;
                      });
                      try {
                        final path = await GenericTtsClient().synthesize(
                          apiKey: apiKey,
                          baseUrl: baseUrl.text,
                          text: preview.text.trim(),
                          model: model.text.trim(),
                          voice: voice.text.trim(),
                          format: format,
                          speed: speed,
                          instructions:
                              model.text.trim().toLowerCase().contains(
                                'gpt-4o-mini-tts',
                              )
                              ? ttsEmotionInstruction(emotionIntensity)
                              : '',
                        );
                        await player.play(DeviceFileSource(path));
                      } on Object catch (value) {
                        RuntimeLog.instance.error('通用 TTS 试音', value);
                        if (context.mounted) {
                          setDialogState(() => error = value.toString());
                        }
                      } finally {
                        if (context.mounted) {
                          setDialogState(() => testing = false);
                        }
                      }
                    },
                    onCancel: () => Navigator.pop(context, false),
                    onSave: () => Navigator.pop(context, true),
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
          actions: const [],
        ),
      ),
    );
    await player.dispose();
    if (saved != true) return;
    controller.configureTts(
      enabled: enabled,
      provider: TtsProvider.generic,
      fishModel: controller.fishAudioModel,
      fishReferenceId: controller.fishAudioReferenceId,
      fishAsmrReferenceId: controller.fishAudioAsmrReferenceId,
      format: format,
      latency: controller.fishAudioLatency,
      speed: speed,
      dashBaseUrl: controller.dashScopeTtsBaseUrl,
      dashScopeModel: controller.dashScopeTtsModel,
      dashScopeVoice: controller.dashScopeTtsVoice,
      dashScopeAsmrVoice: controller.dashScopeTtsAsmrVoice,
      dashScopeLanguage: controller.dashScopeTtsLanguage,
      dashInstructions: controller.dashScopeTtsInstructions,
      genericBaseUrl: baseUrl.text,
      genericModel: model.text,
      genericVoice: voice.text,
      genericAsmrVoice: asmrVoice.text,
      emotionIntensity: emotionIntensity,
      previewText: preview.text,
    );
    controller.setTtsCueDensity(cueDensity);
    if (key.text.trim().isNotEmpty) {
      await const SecretStore().writeGenericTtsKey(key.text);
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
      RuntimeLog.instance.error('Data import', error);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$error')));
    }
  }
}

class _ThemeSettingsDialog extends StatelessWidget {
  const _ThemeSettingsDialog({
    required this.initialValue,
    required this.language,
  });

  final AppThemePreference initialValue;
  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(language.text('主题', 'Theme', 'テーマ')),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final value in AppThemePreference.values)
            ListTile(
              leading: Icon(
                value == initialValue
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(value.label(language)),
              onTap: () => Navigator.pop(context, value),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(language.text('取消', 'Cancel', 'キャンセル')),
        ),
      ],
    );
  }
}

class _LanguageSettingsDraft {
  const _LanguageSettingsDraft({
    required this.interfaceLanguage,
    required this.narratorLanguage,
    required this.characterReplyLanguage,
    required this.translationLanguage,
  });

  final AppLanguage interfaceLanguage;
  final AppLanguage narratorLanguage;
  final AppLanguage characterReplyLanguage;
  final TranslationLanguage translationLanguage;
}

class _LanguageSettingsDialog extends StatefulWidget {
  const _LanguageSettingsDialog({
    required this.interfaceLanguage,
    required this.narratorLanguage,
    required this.characterReplyLanguage,
    required this.translationLanguage,
  });

  final AppLanguage interfaceLanguage;
  final AppLanguage narratorLanguage;
  final AppLanguage characterReplyLanguage;
  final TranslationLanguage translationLanguage;

  @override
  State<_LanguageSettingsDialog> createState() =>
      _LanguageSettingsDialogState();
}

class _LanguageSettingsDialogState extends State<_LanguageSettingsDialog> {
  late AppLanguage _interfaceLanguage;
  late AppLanguage _narratorLanguage;
  late AppLanguage _characterReplyLanguage;
  late TranslationLanguage _translationLanguage;

  @override
  void initState() {
    super.initState();
    _interfaceLanguage = widget.interfaceLanguage;
    _narratorLanguage = widget.narratorLanguage;
    _characterReplyLanguage = widget.characterReplyLanguage;
    _translationLanguage = widget.translationLanguage;
  }

  @override
  Widget build(BuildContext context) {
    final language = _interfaceLanguage;
    return AlertDialog(
      title: Text(language.text('语言设置', 'Language settings', '言語設定')),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _languageDropdown(
                label: language.text('界面语言', 'Interface language', '表示言語'),
                value: _interfaceLanguage,
                onChanged: (value) =>
                    setState(() => _interfaceLanguage = value),
              ),
              const SizedBox(height: 14),
              _languageDropdown(
                label: language.text('旁白语言', 'Narrator language', 'ナレーション言語'),
                value: _narratorLanguage,
                onChanged: (value) => setState(() => _narratorLanguage = value),
              ),
              const SizedBox(height: 14),
              _languageDropdown(
                label: language.text(
                  '莱莎回复语言',
                  'Ryza reply language',
                  'ライザの返答言語',
                ),
                value: _characterReplyLanguage,
                onChanged: (value) =>
                    setState(() => _characterReplyLanguage = value),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<TranslationLanguage>(
                initialValue: _translationLanguage,
                decoration: InputDecoration(
                  labelText: language.text(
                    '翻译语言',
                    'Translation language',
                    '翻訳言語',
                  ),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final value in TranslationLanguage.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(value.label(language)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _translationLanguage = value);
                  }
                },
              ),
              const SizedBox(height: 7),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  language.text(
                    '选择是否将莱莎的回复额外翻译为指定语言；不影响原始回复语言。语言设置仅对保存后发送的新消息生效，历史消息不会重新翻译。',
                    'Optionally add a translation of Ryza\'s reply. The original reply language is unchanged. Language changes apply to new messages after saving; history is not translated again.',
                    'ライザの返答に指定言語の翻訳を追加します。元の返答言語は変わりません。保存後の新しいメッセージにのみ適用され、履歴は再翻訳されません。',
                  ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(language.text('取消', 'Cancel', 'キャンセル')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _LanguageSettingsDraft(
              interfaceLanguage: _interfaceLanguage,
              narratorLanguage: _narratorLanguage,
              characterReplyLanguage: _characterReplyLanguage,
              translationLanguage: _translationLanguage,
            ),
          ),
          child: Text(language.text('保存', 'Save', '保存')),
        ),
      ],
    );
  }

  Widget _languageDropdown({
    required String label,
    required AppLanguage value,
    required ValueChanged<AppLanguage> onChanged,
  }) {
    return DropdownButtonFormField<AppLanguage>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final language in AppLanguage.values)
          DropdownMenuItem(value: language, child: Text(language.nativeLabel)),
      ],
      onChanged: (selected) {
        if (selected != null) onChanged(selected);
      },
    );
  }
}

class _LongTermMemoryDraft {
  const _LongTermMemoryDraft({required this.enabled, required this.summary});

  final bool enabled;
  final String summary;
}

class _LongTermMemoryDialog extends StatefulWidget {
  const _LongTermMemoryDialog({
    required this.enabled,
    required this.summary,
    required this.language,
  });

  final bool enabled;
  final String summary;
  final AppLanguage language;

  @override
  State<_LongTermMemoryDialog> createState() => _LongTermMemoryDialogState();
}

class _LongTermMemoryDialogState extends State<_LongTermMemoryDialog> {
  late final TextEditingController _summary;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _summary = TextEditingController(text: widget.summary);
    _enabled = widget.enabled;
  }

  @override
  void dispose() {
    _summary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    return AlertDialog(
      title: Text(language.text('长期记忆', 'Long-term memory', '長期記憶')),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
              title: Text(
                language.text('启用长期记忆', 'Enable memory', '長期記憶を有効にする'),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _summary,
              minLines: 7,
              maxLines: 12,
              maxLength: 2000,
              decoration: InputDecoration(
                labelText: language.text('当前长期记忆', 'Current memory', '現在の長期記憶'),
                hintText: language.text(
                  '尚未生成长期记忆',
                  'No long-term memory yet',
                  '長期記憶はまだありません',
                ),
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(language.text('取消', 'Cancel', 'キャンセル')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _LongTermMemoryDraft(enabled: _enabled, summary: _summary.text),
          ),
          child: Text(language.text('保存', 'Save', '保存')),
        ),
      ],
    );
  }
}

class _UserProfileDraft {
  const _UserProfileDraft({
    required this.address,
    required this.portrait,
    required this.relationshipRole,
    required this.interactionStyle,
    required this.boundaries,
  });

  final String address;
  final String portrait;
  final UserRelationshipRole relationshipRole;
  final UserInteractionStyle interactionStyle;
  final String boundaries;
}

class _UserProfileDialog extends StatefulWidget {
  const _UserProfileDialog({
    required this.address,
    required this.portrait,
    required this.relationshipRole,
    required this.interactionStyle,
    required this.boundaries,
  });

  final String address;
  final String portrait;
  final UserRelationshipRole relationshipRole;
  final UserInteractionStyle interactionStyle;
  final String boundaries;

  @override
  State<_UserProfileDialog> createState() => _UserProfileDialogState();
}

class _UserProfileDialogState extends State<_UserProfileDialog> {
  late final TextEditingController _address;
  late final TextEditingController _portrait;
  late final TextEditingController _boundaries;
  late UserRelationshipRole _relationshipRole;
  late UserInteractionStyle _interactionStyle;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(text: widget.address);
    _portrait = TextEditingController(text: widget.portrait);
    _boundaries = TextEditingController(text: widget.boundaries);
    _relationshipRole = widget.relationshipRole;
    _interactionStyle = widget.interactionStyle;
  }

  @override
  void dispose() {
    _address.dispose();
    _portrait.dispose();
    _boundaries.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('用户设定'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _address,
                maxLength: 24,
                decoration: const InputDecoration(
                  labelText: '莱莎对你的称呼',
                  hintText: '伙伴',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _portrait,
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
                initialValue: _relationshipRole,
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
                  if (value != null) _relationshipRole = value;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<UserInteractionStyle>(
                initialValue: _interactionStyle,
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
                  if (value != null) _interactionStyle = value;
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _boundaries,
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
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _UserProfileDraft(
              address: _address.text,
              portrait: _portrait.text,
              relationshipRole: _relationshipRole,
              interactionStyle: _interactionStyle,
              boundaries: _boundaries.text,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class RuntimeLogScreen extends StatelessWidget {
  const RuntimeLogScreen({
    super.key,
    required this.language,
    required this.onMenuPressed,
  });

  final AppLanguage language;
  final VoidCallback onMenuPressed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          onPressed: onMenuPressed,
          tooltip: language.text('菜单', 'Menu', 'メニュー'),
          icon: const Icon(Icons.menu_rounded),
        ),
        title: Text(language.text('运行日志', 'Runtime logs', '実行ログ')),
        actions: [
          AnimatedBuilder(
            animation: RuntimeLog.instance,
            builder: (context, _) => IconButton(
              onPressed: RuntimeLog.instance.entries.isEmpty
                  ? null
                  : () => RuntimeLog.instance.clear(),
              tooltip: language.text('清空日志', 'Clear logs', 'ログを消去'),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
          AnimatedBuilder(
            animation: RuntimeLog.instance,
            builder: (context, _) => IconButton(
              onPressed: RuntimeLog.instance.entries.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(
                        ClipboardData(text: RuntimeLog.instance.formattedText),
                      );
                    },
              tooltip: language.text('复制日志', 'Copy logs', 'ログをコピー'),
              icon: const Icon(Icons.copy_outlined),
            ),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: RuntimeLog.instance,
        builder: (context, _) {
          final entries = RuntimeLog.instance.entries.reversed.toList();
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '记录 LLM/TTS 的结构化请求与响应；API Key、令牌和授权信息会自动脱敏，音频二进制不会记录。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(child: Text('暂无运行日志'))
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: entries.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 22),
                            itemBuilder: (context, index) => SelectableText(
                              entries[index].formatted,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TtsPreviewEditor extends StatelessWidget {
  const _TtsPreviewEditor({
    required this.controller,
    required this.testing,
    required this.onClearKey,
    required this.onTest,
    required this.onCancel,
    required this.onSave,
  });

  final TextEditingController controller;
  final bool testing;
  final VoidCallback onClearKey;
  final VoidCallback onTest;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: colors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            minLines: 2,
            maxLines: 4,
            maxLength: 300,
            decoration: const InputDecoration(
              labelText: '试音文字',
              border: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(12, 12, 12, 4),
            ),
          ),
          Divider(height: 1, color: colors.outlineVariant),
          SizedBox(
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: IconButton(
                    onPressed: onClearKey,
                    tooltip: '清除 Key',
                    icon: const Icon(Icons.key_off_outlined),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    onPressed: testing ? null : onTest,
                    tooltip: '试听',
                    icon: testing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded),
                  ),
                ),
                Expanded(
                  child: IconButton(
                    onPressed: onCancel,
                    tooltip: '取消',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
                Expanded(
                  child: IconButton.filled(
                    onPressed: onSave,
                    tooltip: '保存',
                    icon: const Icon(Icons.check_rounded),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogActionRow extends StatelessWidget {
  const _DialogActionRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0) const SizedBox(width: 4),
            children[index],
          ],
        ],
      ),
    );
  }
}

class _TtsEmotionSlider extends StatelessWidget {
  const _TtsEmotionSlider({required this.value, required this.onChanged});

  final TtsEmotionIntensity value;
  final ValueChanged<TtsEmotionIntensity> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('感情程度')),
              Text(
                value.label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          PlatformSlider(
            value: value.index.toDouble(),
            min: 0,
            max: (TtsEmotionIntensity.values.length - 1).toDouble(),
            divisions: TtsEmotionIntensity.values.length - 1,
            label: value.label,
            onChanged: (rawValue) =>
                onChanged(TtsEmotionIntensity.values[rawValue.round()]),
          ),
          const Text(
            '试听立即使用当前档位；点击保存后应用于正式对话。Fish 会按情绪展开音调、重音和节奏指令，并辅助调整生成参数。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _TtsCueDensitySlider extends StatelessWidget {
  const _TtsCueDensitySlider({required this.value, required this.onChanged});

  final TtsCueDensity value;
  final ValueChanged<TtsCueDensity> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('句内情绪演出密度')),
              Text(
                value.label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          PlatformSlider(
            value: value.index.toDouble(),
            min: 0,
            max: (TtsCueDensity.values.length - 1).toDouble(),
            divisions: TtsCueDensity.values.length - 1,
            label: value.label,
            onChanged: (raw) => onChanged(TtsCueDensity.values[raw.round()]),
          ),
          const Text(
            '控制主情绪标签的重复频率，以及 [emphasis]、[pause] 等句内标签数量；不改变情感强度和 temperature。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
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
