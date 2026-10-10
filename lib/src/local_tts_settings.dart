import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'local_tts_client.dart';
import 'local_tts_models.dart';
import 'settings_detail_page.dart';
import 'speech_loudness.dart';

class LocalTtsSettingsPage extends StatefulWidget {
  const LocalTtsSettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<LocalTtsSettingsPage> createState() => _LocalTtsSettingsPageState();
}

class _LocalTtsSettingsPageState extends State<LocalTtsSettingsPage> {
  final _player = AudioPlayer();
  final _preview = TextEditingController(text: '你好，今天也一起去冒险吧。');
  final _voiceName = TextEditingController();
  final _promptText = TextEditingController();
  final _start = TextEditingController(text: '0');
  final _end = TextEditingController(text: '5');
  final _previewFiles = <String>{};
  StreamSubscription<LocalTtsProgress>? _progressSubscription;
  Future<void>? _enrollmentOperation;
  LocalTtsStatus? _status;
  String? _referencePath;
  String? _referenceName;
  double? _referenceDuration;
  String? _error;
  LocalTtsProgress? _progress;
  bool _loading = true;
  bool _busy = false;
  late bool _enabled;

  String t(String zh, String en, String ja) =>
      widget.controller.interfaceLanguage.text(zh, en, ja);

  String get _selectedVoiceId {
    final assigned = widget.controller.localTtsVoiceProfileId;
    if (assigned.isNotEmpty) return assigned;
    for (final voice in _status?.voices ?? const <LocalTtsVoice>[]) {
      if (voice.builtIn) return voice.id;
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    if (widget.controller.characterReplyLanguage == AppLanguage.japanese) {
      _preview.text = '錬金術って結構奥が深いんだよ。';
    }
    _enabled = widget.controller.ttsProvider == TtsProvider.local
        ? widget.controller.fishTtsEnabled
        : true;
    if (defaultTargetPlatform != TargetPlatform.android) {
      _loading = false;
      return;
    }
    _progressSubscription = LocalTtsModelStore.instance.progress.listen(
      (event) {
        if (mounted) setState(() => _progress = event);
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = error.toString());
      },
    );
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final status = await LocalTtsModelStore.instance.status();
      final assigned = widget.controller.localTtsVoiceProfileId;
      if (status.modelReady &&
          assigned.isNotEmpty &&
          !status.voices.any((voice) => voice.id == assigned)) {
        widget.controller.setLocalTtsVoiceProfileId('');
      }
      if (mounted) setState(() => _status = status);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
    });
    try {
      await action();
      await _refresh();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('取消', 'Cancel', 'キャンセル')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('删除', 'Delete', '削除')),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _importZip({required bool enrollment}) async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      if (file == null || !mounted) return;
      final path = file.path;
      if (path == null) throw const FormatException('无法读取所选 ZIP 文件');
      await _run(
        () => enrollment
            ? LocalTtsModelStore.instance.importEnrollment(path)
            : LocalTtsModelStore.instance.importModel(path),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _pickReference() async {
    if (_busy) return;
    setState(() => _error = null);
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['wav'],
      );
      if (picked == null || !mounted) return;
      final path = picked.path;
      if (path == null) throw const FormatException('无法读取所选 WAV 文件');
      final source = File(path);
      if (await source.length() > 50 * 1000 * 1000) {
        throw const FormatException('参考音频请控制在 50 MB 以内');
      }
      final duration = await _wavDuration(source);
      if (duration < 3) {
        throw const FormatException('参考音频不足 3 秒');
      }
      final support = await getApplicationSupportDirectory();
      final imports = Directory('${support.path}/cosyvoice3_imports');
      await imports.create(recursive: true);
      final local = File(
        '${imports.path}/reference_${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      await source.copy(local.path);
      if (!mounted) {
        await local.delete();
        return;
      }
      final previous = _referencePath;
      setState(() {
        _referencePath = local.path;
        _referenceName = picked.name;
        _referenceDuration = duration;
        _start.text = '0';
        _end.text = (duration < 5 ? duration : 5).toStringAsFixed(1);
      });
      if (previous != null) await _deleteFile(previous);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _enroll() async {
    final reference = _referencePath;
    final start = double.tryParse(_start.text.trim());
    final end = double.tryParse(_end.text.trim());
    if (reference == null || start == null || end == null) {
      setState(
        () => _error = t(
          '请选择 WAV 并填写片段时间',
          'Choose a WAV and enter segment times',
          'WAV と区間の時間を指定してください',
        ),
      );
      return;
    }
    if (!start.isFinite ||
        !end.isFinite ||
        start < 0 ||
        end > (_referenceDuration ?? 0) + 0.01 ||
        end - start < 3 ||
        end - start > 5) {
      setState(
        () => _error = t(
          '请选择音频内连续的 3–5 秒片段',
          'Select a continuous 3–5 second segment within the audio',
          '音声内の連続した 3～5 秒を選択してください',
        ),
      );
      return;
    }
    final operation = _run(() async {
      final voice = await LocalTtsModelStore.instance.enroll(
        audioPath: reference,
        startSeconds: start,
        endSeconds: end,
        promptText: _promptText.text,
        name: _voiceName.text,
        preferredLanguage: widget.controller.characterReplyLanguage,
      );
      await LocalTtsModelStore.instance.selectVoice(voice.id);
      widget.controller.setLocalTtsVoiceProfileId(voice.id);
      await _deleteFile(reference);
      _referencePath = null;
      _referenceName = null;
      _referenceDuration = null;
    });
    _enrollmentOperation = operation;
    try {
      await operation;
    } finally {
      _enrollmentOperation = null;
    }
  }

  Future<void> _selectVoice(String id) => _run(() async {
    await LocalTtsModelStore.instance.selectVoice(id);
    widget.controller.setLocalTtsVoiceProfileId(id);
  });

  Future<void> _deleteVoice(LocalTtsVoice voice) async {
    if (!await _confirm(
      t('删除克隆音色？', 'Delete cloned voice?', '複製音声を削除しますか？'),
      voice.name,
    )) {
      return;
    }
    await _run(() async {
      await LocalTtsModelStore.instance.deleteVoice(voice.id);
      if (widget.controller.localTtsVoiceProfileId == voice.id) {
        widget.controller.setLocalTtsVoiceProfileId('');
      }
    });
  }

  Future<void> _deleteModel() async {
    if (!await _confirm(
      t(
        '删除 CosyVoice 3 模型？',
        'Delete CosyVoice 3 model?',
        'CosyVoice 3 モデルを削除しますか？',
      ),
      t(
        '删除后需重新下载或导入才能合成语音。',
        'Synthesis will require another download or import.',
        '再生には再ダウンロードまたは再インポートが必要です。',
      ),
    )) {
      return;
    }
    await _run(() async {
      await LocalTtsModelStore.instance.deleteModel();
      if (widget.controller.ttsProvider == TtsProvider.local) {
        widget.controller.configureLocalTts(enabled: false);
      }
    });
  }

  Future<void> _deleteEnrollment() async {
    if (!await _confirm(
      t('删除音色克隆扩展包？', 'Delete voice enrollment extension?', '音声複製拡張を削除しますか？'),
      t(
        '扩展包删除后将无法创建新音色。',
        'You will need it again to create new voices.',
        '新しい音声を作成するには再取得が必要です。',
      ),
    )) {
      return;
    }
    await _run(LocalTtsModelStore.instance.deleteEnrollment);
  }

  Future<void> _previewVoice() => _run(() async {
    final asmr = widget.controller.asmrModeEnabled;
    final stereoEnabled = widget.controller.ttsStereoEnabled;
    final stereoPosition = widget.controller.ttsStereoPosition;
    await _player.stop();
    final path = await LocalTtsClient.instance.synthesize(
      text: _preview.text.trim(),
      preferredLanguage: widget.controller.characterReplyLanguage,
      voiceProfileId: _selectedVoiceId,
    );
    if (!mounted) {
      await _deleteFile(path);
      return;
    }
    final playbackPath = await balanceSpeechLoudness(
      path,
      asmr: asmr,
      stereoEnabled: stereoEnabled,
      stereoPosition: stereoPosition,
    );
    if (playbackPath != path) await _deleteFile(path);
    if (!mounted) {
      await _deleteFile(playbackPath);
      return;
    }
    _previewFiles.add(playbackPath);
    await _player.play(DeviceFileSource(playbackPath));
  });

  void _save() {
    if (_enabled && _status?.modelReady != true) {
      setState(
        () => _error = t(
          '请先下载或导入基础模型',
          'Download or import the base model first',
          '先に基本モデルを取得またはインポートしてください',
        ),
      );
      return;
    }
    widget.controller.configureLocalTts(enabled: _enabled);
    Navigator.pop(context);
  }

  Future<void> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The audio player may hold a temporary file briefly.
    }
  }

  @override
  void dispose() {
    unawaited(_progressSubscription?.cancel());
    final previewFiles = _previewFiles.toList();
    final reference = _referencePath;
    final enrollment = _enrollmentOperation;
    unawaited(
      _player.dispose().whenComplete(() async {
        for (final path in previewFiles) {
          await _deleteFile(path);
        }
        if (enrollment != null) await enrollment;
        if (reference != null) await _deleteFile(reference);
      }),
    );
    for (final editor in [_preview, _voiceName, _promptText, _start, _end]) {
      editor.dispose();
    }
    super.dispose();
  }

  Widget _modelControls({required bool enrollment}) {
    final ready = enrollment
        ? _status?.enrollmentReady == true
        : _status?.modelReady == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsOptionCard(
          child: ListTile(
            title: Text(
              enrollment
                  ? t('音色克隆扩展包', 'Voice enrollment extension', '音声複製拡張')
                  : 'CosyVoice 3',
            ),
            subtitle: Text(
              ready
                  ? t('已安装', 'Installed', 'インストール済み')
                  : enrollment
                  ? t('约 1.0 GB', 'About 1.0 GB', '約 1.0 GB')
                  : t('约 1.4 GB', 'About 1.4 GB', '約 1.4 GB'),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (!ready) ...[
              FilledButton.icon(
                onPressed: _busy || _loading || _status?.supported == false
                    ? null
                    : () => _run(
                        enrollment
                            ? LocalTtsModelStore.instance.downloadEnrollment
                            : LocalTtsModelStore.instance.downloadModel,
                      ),
                icon: const Icon(Icons.download_rounded),
                label: Text(t('下载', 'Download', 'ダウンロード')),
              ),
              OutlinedButton.icon(
                onPressed: _busy || _loading || _status?.supported == false
                    ? null
                    : () => _importZip(enrollment: enrollment),
                icon: const Icon(Icons.folder_open_rounded),
                label: Text(t('导入 ZIP', 'Import ZIP', 'ZIP を読み込む')),
              ),
            ] else
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : enrollment
                    ? _deleteEnrollment
                    : _deleteModel,
                icon: const Icon(Icons.delete_outline),
                label: Text(t('删除', 'Delete', '削除')),
              ),
          ],
        ),
      ],
    );
  }

  Widget _voiceList() {
    final voices = _status?.voices ?? const <LocalTtsVoice>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('音色', 'Voices', '音声'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        for (final voice in voices) ...[
          SettingsOptionCard(
            child: ListTile(
              key: ValueKey('cosyvoice3-voice-${voice.id}'),
              leading: Icon(
                voice.id == _selectedVoiceId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(voice.name),
              subtitle: voice.builtIn
                  ? Text(t('内置', 'Built in', '内蔵'))
                  : Text(t('克隆', 'Cloned', '複製')),
              onTap: _busy ? null : () => _selectVoice(voice.id),
              trailing: voice.builtIn
                  ? null
                  : IconButton(
                      tooltip: t('删除音色', 'Delete voice', '音声を削除'),
                      onPressed: _busy ? null : () => _deleteVoice(voice),
                      icon: const Icon(Icons.delete_outline),
                    ),
            ),
          ),
          const SizedBox(height: 6),
        ],
        if (voices.isEmpty)
          Text(t('暂无可用音色', 'No voices available', '利用できる音声がありません')),
        const SizedBox(height: 8),
        TextField(
          controller: _preview,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: t('试听文本', 'Preview text', '試聴テキスト'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy || voices.isEmpty ? null : _previewVoice,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(t('试听当前音色', 'Preview selected voice', '選択中の音声を試聴')),
          ),
        ),
      ],
    );
  }

  Widget _enrollmentForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        t('创建克隆音色', 'Create cloned voice', '複製音声を作成'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : _pickReference,
        icon: const Icon(Icons.audio_file_outlined),
        label: Text(t('选择 WAV 参考音频', 'Choose reference WAV', '参考 WAV を選択')),
      ),
      if (_referenceName != null) ...[
        const SizedBox(height: 6),
        Text(
          '$_referenceName · ${_referenceDuration!.toStringAsFixed(1)} s',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _start,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t('起点（秒）', 'Start (s)', '開始（秒）'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _end,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t('终点（秒）', 'End (s)', '終了（秒）'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _promptText,
        maxLines: 3,
        decoration: InputDecoration(
          labelText: t(
            '该片段逐字文本',
            'Exact transcript of the segment',
            '区間の正確な文字起こし',
          ),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _voiceName,
        maxLength: 40,
        decoration: InputDecoration(
          labelText: t('音色名称', 'Voice name', '音声名'),
          border: const OutlineInputBorder(),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: _busy || _referencePath == null ? null : _enroll,
          icon: const Icon(Icons.add_rounded),
          label: Text(t('创建音色', 'Create voice', '音声を作成')),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final android = defaultTargetPlatform == TargetPlatform.android;
    return SettingsDetailPage(
      controller: widget.controller,
      title: const Text('CosyVoice 3'),
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!android)
              Text(
                t(
                  'CosyVoice 3 当前仅支持 Android。',
                  'CosyVoice 3 is currently available on Android only.',
                  'CosyVoice 3 は現在 Android のみ対応しています。',
                ),
              )
            else ...[
              SettingsOptionCard(
                child: SwitchListTile(
                  value: _enabled,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _enabled = value),
                  title: Text(
                    t('自动朗读 AI 回复', 'Read AI replies', 'AI の返信を読み上げる'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _modelControls(enrollment: false),
              const SizedBox(height: 16),
              _modelControls(enrollment: true),
              if (_loading) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_status?.supported == false) ...[
                const SizedBox(height: 12),
                Text(
                  t(
                    '需要 Android 8.0 及以上的 arm64 设备。',
                    'Requires an arm64 device running Android 8.0 or later.',
                    'Android 8.0 以降の arm64 端末が必要です。',
                  ),
                ),
              ],
              if (_progress case final progress?) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress.progress),
                const SizedBox(height: 4),
                Text(
                  '${_progressLabel(progress.stage)} · ${(progress.progress * 100).round()}%',
                ),
              ],
              if (_status?.modelReady == true) ...[
                const SizedBox(height: 22),
                _voiceList(),
              ],
              if (_status?.enrollmentReady == true) ...[
                const SizedBox(height: 22),
                _enrollmentForm(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: android
          ? [
              FilledButton(
                onPressed: _busy || _loading ? null : _save,
                child: Text(t('启用本地语音', 'Use local voice', 'ローカル音声を使用')),
              ),
            ]
          : const [],
    );
  }

  String _progressLabel(String stage) => switch (stage) {
    'downloadModel' => t('下载基础模型', 'Downloading base model', '基本モデルをダウンロード中'),
    'downloadEnrollment' => t(
      '下载克隆扩展包',
      'Downloading enrollment extension',
      '複製拡張をダウンロード中',
    ),
    'importModel' => t('导入基础模型', 'Importing base model', '基本モデルをインポート中'),
    'importEnrollment' => t(
      '导入克隆扩展包',
      'Importing enrollment extension',
      '複製拡張をインポート中',
    ),
    'verify' => t('校验文件', 'Verifying files', 'ファイルを検証中'),
    'extract' => t('解压文件', 'Extracting files', 'ファイルを展開中'),
    _ => stage,
  };
}

Future<double> _wavDuration(File wav) async {
  final handle = await wav.open();
  try {
    final length = await handle.length();
    if (length < 44) throw const FormatException('WAV 文件不完整');
    final header = await handle.read(12);
    if (String.fromCharCodes(header.take(4)) != 'RIFF' ||
        String.fromCharCodes(header.skip(8)) != 'WAVE') {
      throw const FormatException('请选择标准 WAV 音频');
    }
    int? byteRate;
    int? dataBytes;
    var offset = 12;
    while (offset + 8 <= length) {
      await handle.setPosition(offset);
      final chunk = await handle.read(8);
      if (chunk.length != 8) break;
      final data = ByteData.sublistView(Uint8List.fromList(chunk));
      final size = data.getUint32(4, Endian.little);
      final next = offset + 8 + size + (size.isOdd ? 1 : 0);
      if (next > length + 1) throw const FormatException('WAV 数据长度不正确');
      final id = String.fromCharCodes(chunk.take(4));
      if (id == 'fmt ' && size >= 16) {
        final format = await handle.read(16);
        if (format.length < 16) throw const FormatException('WAV 格式信息不完整');
        byteRate = ByteData.sublistView(Uint8List.fromList(format))
            .getUint32(8, Endian.little);
      } else if (id == 'data') {
        dataBytes = size;
      }
      if (byteRate != null && dataBytes != null) break;
      offset = next;
    }
    if (byteRate == null ||
        byteRate <= 0 ||
        dataBytes == null ||
        dataBytes == 0) {
      throw const FormatException('WAV 缺少有效音频数据');
    }
    return dataBytes / byteRate;
  } finally {
    await handle.close();
  }
}
