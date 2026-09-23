import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'ai_services.dart';
import 'app_controller.dart';
import 'settings_detail_page.dart';
import 'app_localization.dart';
import 'mimo_tts_client.dart';
import 'mimo_tts_config.dart';
import 'platform_slider.dart';

class MimoTtsSettingsDialog extends StatefulWidget {
  const MimoTtsSettingsDialog({super.key, required this.controller});
  final AppController controller;
  @override
  State<MimoTtsSettingsDialog> createState() => _MimoTtsSettingsDialogState();
}

class _MimoTtsSettingsDialogState extends State<MimoTtsSettingsDialog> {
  late final TextEditingController _url,
      _voice,
      _instructions,
      _asmrInstructions,
      _preview;
  final _key = TextEditingController();
  final _client = MimoTtsClient();
  final _player = AudioPlayer();
  final _files = <String>{};
  late String _model, _referencePath, _referenceName;
  late bool _enabled;
  late TtsEmotionIntensity _intensity;
  late TtsCueDensity _density;
  bool _busy = false, _previewAsmr = false;
  String? _error;

  String t(String zh, String en, String ja) =>
      widget.controller.interfaceLanguage.text(zh, en, ja);

  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    final config = controller.mimoTts;
    _url = TextEditingController(text: config.baseUrl);
    _voice = TextEditingController(text: config.voice);
    _instructions = TextEditingController(text: config.instructions);
    _asmrInstructions = TextEditingController(text: config.asmrInstructions);
    _preview = TextEditingController(text: controller.ttsPreviewText);
    _model = config.model;
    _referencePath = config.referencePath;
    _referenceName = config.referenceName;
    _enabled = controller.fishTtsEnabled;
    _intensity = controller.ttsEmotionIntensity;
    _density = controller.ttsCueDensity;
    _previewAsmr = controller.asmrModeEnabled;
  }

  MimoTtsConfig get _config => MimoTtsConfig(
    baseUrl: _url.text.trim(),
    model: _model,
    voice: _voice.text.trim(),
    referencePath: _referencePath,
    referenceName: _referenceName,
    instructions: _instructions.text.trim(),
    asmrInstructions: _asmrInstructions.text.trim(),
  );

  Future<void> _delete(String path) async {
    try {
      if (await File(path).exists()) await File(path).delete();
    } on FileSystemException {
      /* A decoder may still hold a preview file. */
    }
  }

  Future<void> _pickReference() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['mp3', 'wav'],
      );
      if (file == null || !mounted) return;
      if (mimoEncodedLength(await file.length()) > mimoMaxEncodedAudioBytes) {
        throw const AiServiceException('参考音频编码后超过 10 MB，原文件请控制在 7.5 MB 以内');
      }
      final bytes = await file.readAsBytes();
      mimoReferenceDataUri(
        bytes,
        file.name,
      ); // Validate content before copying.
      final dir = await getApplicationSupportDirectory();
      final refs = Directory('${dir.path}/mimo_references');
      await refs.create(recursive: true);
      final extension = file.name.toLowerCase().split('.').last;
      final local = File(
        '${refs.path}/reference_${DateTime.now().microsecondsSinceEpoch}.$extension',
      );
      await local.writeAsBytes(bytes, flush: true);
      if (!mounted) {
        await _delete(local.path);
        return;
      }
      _files.add(local.path);
      setState(() {
        _referencePath = local.path;
        _referenceName = file.name;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final apiKey = _key.text.trim().isEmpty
          ? await const SecretStore().readMimoTtsKey()
          : _key.text.trim();
      if (!mounted) return;
      await _player.stop();
      final path = await _client.synthesize(
        config: _config,
        language: widget.controller.characterReplyLanguage,
        apiKey: apiKey,
        text: _preview.text,
        intensity: _intensity,
        density: _density,
        asmr: _previewAsmr,
      );
      if (!mounted) {
        await _delete(path);
        return;
      }
      _files.add(path);
      await _player.play(DeviceFileSource(path));
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final config = _config;
    final error = config.validationError;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (config.isClone && !await File(config.referencePath).exists()) {
        throw const AiServiceException('参考音频不存在，请重新选择');
      }
      if (_key.text.trim().isNotEmpty) {
        await const SecretStore().writeMimoTtsKey(_key.text);
      }
      if (!mounted) return;
      widget.controller.configureMimoTts(
        config: config,
        enabled: _enabled,
        emotionIntensity: _intensity,
        cueDensity: _density,
        previewText: _preview.text,
      );
      _files.remove(_referencePath);
      Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _client.close();
    final paths = _files.toList();
    unawaited(
      _player.dispose().whenComplete(() async {
        for (final path in paths) {
          await _delete(path);
        }
      }),
    );
    for (final editor in [
      _url,
      _voice,
      _instructions,
      _asmrInstructions,
      _preview,
      _key,
    ]) {
      editor.dispose();
    }
    super.dispose();
  }

  Widget _field(
    TextEditingController editor,
    String label, {
    String? hint,
    int lines = 1,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: editor,
      enabled: !_busy,
      obscureText: secret,
      minLines: lines,
      maxLines: lines == 1 ? 1 : 5,
      decoration: InputDecoration(
        labelText: label,
        helperText: hint,
        helperMaxLines: 4,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SettingsDetailPage(
      controller: widget.controller,
      title: const Text('MiMo TTS'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsOptionCard(
                child: SwitchListTile(
                  value: _enabled,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _enabled = value),
                  title: Text(
                    t('AI 回复后自动播放', 'Play replies automatically', '返信を自動再生'),
                  ),
                ),
              ),
              _field(
                _url,
                t('API 地址', 'API URL', 'API アドレス'),
                hint: t(
                  'Base URL 或完整 /chat/completions 地址',
                  'Base URL or full /chat/completions URL',
                  'Base URL または /chat/completions の完全 URL',
                ),
              ),
              _field(
                _key,
                'API Key',
                secret: true,
                hint: t(
                  '留空保留已保存的密钥；密钥不进入导出文件',
                  'Leave blank to keep the saved key; excluded from backups',
                  '空欄で保存済みキーを使用。バックアップには含まれません',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: _model,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: t('合成模式', 'Synthesis mode', '合成モード'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: MimoTtsConfig.cloneModel,
                    child: Text(
                      t('参考音频克隆', 'Reference voice cloning', '音声サンプルのクローン'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: MimoTtsConfig.presetModel,
                    child: Text(t('预置音色', 'Preset voice', 'プリセット音声')),
                  ),
                  DropdownMenuItem(
                    value: MimoTtsConfig.designModel,
                    child: Text(t('文字设计音色', 'Voice design', 'テキストで音声を設計')),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) setState(() => _model = value);
                      },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _model,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (_config.isClone) ...[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickReference,
                  icon: const Icon(Icons.audio_file_outlined),
                  label: Text(t('选择参考音频', 'Choose reference audio', '参考音声を選択')),
                ),
                Text(
                  _referencePath.isEmpty
                      ? t('尚未选择参考音频', 'No reference selected', '未選択')
                      : _referenceName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    t(
                      'MP3 / WAV；Base64 编码后 ≤ 10 MB（原文件建议 < 7.5 MB）。每次合成会将音频发送到上述 API。音频保存在本机，导入备份后需重新选择。',
                      'MP3 / WAV; ≤ 10 MB after Base64 (source < 7.5 MB recommended). Sent to this API for each synthesis. Stored locally; reselect after importing a backup.',
                      'MP3 / WAV、Base64 後 10 MB 以下（元ファイル 7.5 MB 未満推奨）。合成ごとに上記 API に送信。端末に保存され、バックアップ読込後は再選択が必要です。',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
              if (_model == MimoTtsConfig.presetModel)
                _field(
                  _voice,
                  t('预置音色', 'Preset voice', 'プリセット音声'),
                  hint: 'mimo_default / 冰糖 / 茉莉 / Mia / Chloe',
                ),
              _field(
                _instructions,
                _config.isDesign
                    ? t('音色描述（必填）', 'Voice description (required)', '音声の説明（必須）')
                    : t(
                        '演绎指令（可选）',
                        'Delivery instructions (optional)',
                        '演技指示（任意）',
                      ),
                lines: 2,
              ),
              _field(
                _asmrInstructions,
                t('ASMR 演绎指令', 'ASMR instructions', 'ASMR 指示'),
                lines: 2,
                hint: t(
                  '主页 ASMR 开关沿用同一参考音色，切换轻声演绎',
                  'Home ASMR mode uses the same voice with softer delivery',
                  'ホームの ASMR モードは同じ音声で静かに話します',
                ),
              ),
              Text(
                '${t('感情程度', 'Emotion intensity', '感情の強さ')}：${_intensity.label}',
              ),
              PlatformSlider(
                value: _intensity.index.toDouble(),
                min: 0,
                max: 4,
                divisions: 4,
                onChanged: _busy
                    ? null
                    : (v) => setState(
                        () =>
                            _intensity = TtsEmotionIntensity.values[v.round()],
                      ),
              ),
              Text(
                '${t('句内情绪演出密度', 'Inline cue density', '文内演出の密度')}：${_density.label}',
              ),
              PlatformSlider(
                value: _density.index.toDouble(),
                min: 0,
                max: 4,
                divisions: 4,
                onChanged: _busy
                    ? null
                    : (v) => setState(
                        () => _density = TtsCueDensity.values[v.round()],
                      ),
              ),
              SettingsOptionCard(
                child: SwitchListTile(
                  value: _previewAsmr,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _previewAsmr = v),
                  title: Text(
                    t('以 ASMR 模式试音', 'Preview in ASMR mode', 'ASMR で試聴'),
                  ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outline),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    TextField(
                      controller: _preview,
                      enabled: !_busy,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: 500,
                      decoration: InputDecoration(
                        labelText: t('试音文字', 'Preview text', '試聴テキスト'),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _busy ? null : _test,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.play_arrow_rounded),
                        label: Text(t('试音', 'Preview', '試聴')),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: colors.error)),
                ),
              const SizedBox(height: 8),
              Text(
                t(
                  '克隆和音色设计目前先生成完整片段再播放。',
                  'Cloning and voice design generate each full segment before playback.',
                  'クローン・音声設計は各セグメントの生成完了後に再生します。',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        try {
                          await const SecretStore().writeMimoTtsKey('');
                          if (mounted) {
                            setState(() {
                              _key.clear();
                              _error = t(
                                '已清除保存的 API Key',
                                'Saved key cleared',
                                '保存済みキーを削除しました',
                              );
                            });
                          }
                        } on Object catch (error) {
                          if (mounted) {
                            setState(() => _error = error.toString());
                          }
                        }
                      },
                child: FittedBox(child: Text(t('清除密钥', 'Clear key', 'キー削除'))),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('取消', 'Cancel', 'キャンセル')),
              ),
            ),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: Text(t('保存', 'Save', '保存')),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
