import 'package:flutter/material.dart';

import 'app_localization.dart';

/// The destinations offered on the first settings page.
enum SettingsSection {
  appearance,
  audio,
  profile,
  ai,
  roleplay,
  data,
  about,
  pcAgent;

  static SettingsSection? fromName(String? name) {
    for (final section in values) {
      if (section.name == name) return section;
    }
    return null;
  }
}

extension SettingsSectionDetails on SettingsSection {
  String title(AppLanguage language) => switch (this) {
    SettingsSection.appearance => language.text(
      '界面与场景',
      'Appearance & scene',
      '表示とシーン',
    ),
    SettingsSection.audio => language.text(
      '声音与语音',
      'Sound & speech',
      'サウンドと音声',
    ),
    SettingsSection.profile => language.text('用户设定', 'Your profile', 'ユーザー設定'),
    SettingsSection.ai => language.text('AI 接口', 'AI connections', 'AI接続'),
    SettingsSection.roleplay => language.text(
      '角色与世界',
      'Character & world',
      'キャラクターと世界',
    ),
    SettingsSection.data => language.text('数据管理', 'Local data', 'データ管理'),
    SettingsSection.about => language.text('关于', 'About', 'このアプリについて'),
    SettingsSection.pcAgent => language.text(
      'PC Agent 联动',
      'PC Agent link',
      'PC Agent 連携',
    ),
  };

  String description(AppLanguage language) => switch (this) {
    SettingsSection.appearance => language.text(
      '主题、语言、玻璃效果、视线与帧率',
      'Theme, languages, glass, gaze and frame rate',
      'テーマ、言語、ガラス、視線、フレームレート',
    ),
    SettingsSection.audio => language.text(
      '点击语音、背景音乐、环境音与 TTS',
      'Tap voice, music, ambience and TTS',
      'タップ音声、BGM、環境音、TTS',
    ),
    SettingsSection.profile => language.text(
      '称呼、自画像、关系与互动偏好',
      'Name, self-description and interaction preferences',
      '呼び方、プロフィール、関係、会話の好み',
    ),
    SettingsSection.ai => language.text(
      '模型服务、推理、上下文与 Agent',
      'Providers, reasoning, context and agent tools',
      'モデル、推論、コンテキスト、エージェント',
    ),
    SettingsSection.roleplay => language.text(
      '人物设定、世界书与 NPC',
      'Persona, world book and NPCs',
      '人物設定、ワールドブック、NPC',
    ),
    SettingsSection.data => language.text(
      '长期记忆、本地导入导出与聊天记录',
      'Memory, local import, export and chat history',
      '長期記憶、データの読み込み・書き出し、会話履歴',
    ),
    SettingsSection.about => 'AgentAtelierR · 1.0.4 beta1 26106',
    SettingsSection.pcAgent => language.text(
      '扫码绑定、前台问答、任务与通知',
      'Pairing, questions, tasks and notifications',
      'ペアリング、質問、タスク、通知',
    ),
  };

  IconData get icon => switch (this) {
    SettingsSection.appearance => Icons.palette_outlined,
    SettingsSection.audio => Icons.headphones_outlined,
    SettingsSection.profile => Icons.badge_outlined,
    SettingsSection.ai => Icons.hub_outlined,
    SettingsSection.roleplay => Icons.auto_stories_outlined,
    SettingsSection.data => Icons.inventory_2_outlined,
    SettingsSection.about => Icons.info_outline,
    SettingsSection.pcAgent => Icons.computer,
  };
}
