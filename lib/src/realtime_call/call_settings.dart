import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'local_call_asr_config.dart';
import 'call_model_download.dart';

class CallSettings {
  CallSettings({
    this.asr = const LocalCallAsrConfig(
      modelPath: '',
      tokensPath: '',
      vadModelPath: '',
    ),
    this.fishModel = 'drama-3',
    Map<String, String> voiceOverrides = const {},
  }) : voiceOverrides = Map.unmodifiable(voiceOverrides);

  factory CallSettings.fromJson(Map<String, dynamic> json) {
    final voices = json['voiceOverrides'];
    return CallSettings(
      asr: LocalCallAsrConfig.fromJson(
        json['asr'] is Map
            ? Map<String, dynamic>.from(json['asr'] as Map)
            : const {},
      ),
      fishModel: json['fishModel'] as String? ?? 'drama-3',
      voiceOverrides: voices is Map
          ? {
              for (final entry in voices.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: (entry.value as String).trim(),
            }
          : const {},
    );
  }

  final LocalCallAsrConfig asr;
  final String fishModel;
  final Map<String, String> voiceOverrides;

  CallSettings copyWith({
    LocalCallAsrConfig? asr,
    String? fishModel,
    Map<String, String>? voiceOverrides,
  }) => CallSettings(
    asr: asr ?? this.asr,
    fishModel: fishModel ?? this.fishModel,
    voiceOverrides: voiceOverrides ?? this.voiceOverrides,
  );

  Map<String, dynamic> toJson() => {
    'asr': asr.toJson(),
    'fishModel': fishModel,
    'voiceOverrides': voiceOverrides,
  };

  String voiceFor(
    String contactId, {
    bool isMainCharacter = false,
    String mainCharacterVoice = '',
  }) {
    final override = voiceOverrides[contactId]?.trim() ?? '';
    if (override.isNotEmpty) return override;
    return isMainCharacter ? mainCharacterVoice.trim() : '';
  }
}

/// Only local paths and public model/voice IDs live here; API keys stay in the
/// app's existing SecretStore and are never duplicated in these preferences.
class CallSettingsStore {
  CallSettingsStore({this.preferences});

  static const preferenceKey = 'realtime_call_settings_v1';
  final SharedPreferences? preferences;

  Future<CallSettings> load() async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final raw = prefs.getString(preferenceKey);
    if (raw == null) return CallSettings();
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return CallSettings();
      return CallSettings.fromJson(Map<String, dynamic>.from(json));
    } on Object {
      return CallSettings();
    }
  }

  Future<void> save(CallSettings settings) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final stored = await prefs.setString(
      preferenceKey,
      jsonEncode(settings.toJson()),
    );
    if (!stored) throw StateError('无法保存通话设置，请稍后重试。');
  }
}

class CallContactOption {
  const CallContactOption({
    required this.id,
    required this.name,
    this.isMainCharacter = false,
  });
  final String id;
  final String name;
  final bool isMainCharacter;
}

enum CallAsrModelFile { senseVoice, tokens, sileroVad }

/// Copies picked files out of Android's temporary provider cache. A failed
/// copy never overwrites a configured model, and imports do not access URLs.
class CallAsrModelImporter {
  CallAsrModelImporter({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const maximumFileBytes = 500 * 1024 * 1024;
  final Future<Directory> Function() _directoryProvider;

  Future<Directory> _managedDirectory() async {
    final support = await _directoryProvider();
    return Directory('${support.path}/realtime_call/asr');
  }

  Future<String> importFile(String sourcePath, CallAsrModelFile kind) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw const FormatException('所选文件不可读取。');
    return _import(
      name: sourcePath,
      length: await source.length(),
      stream: source.openRead(),
      kind: kind,
    );
  }

  Future<String> importPickedFile(
    PlatformFile file,
    CallAsrModelFile kind,
  ) async => _import(
    name: file.name,
    length: await file.length(),
    stream: file.readAsByteStream(),
    kind: kind,
  );

  Future<String> _import({
    required String name,
    required int length,
    required Stream<List<int>> stream,
    required CallAsrModelFile kind,
  }) async {
    if (length == 0 || length > maximumFileBytes) {
      throw const FormatException('模型文件不能为空，单个文件最多 500 MB。');
    }
    final extension = kind == CallAsrModelFile.tokens ? '.txt' : '.onnx';
    if (!name.toLowerCase().endsWith(extension)) {
      throw FormatException('请选择 $extension 文件。');
    }
    final directory = await _managedDirectory();
    await directory.create(recursive: true);
    final storedName =
        '${kind.name}-${DateTime.now().microsecondsSinceEpoch}$extension';
    final destination = File('${directory.path}/$storedName');
    final temporary = File('${destination.path}.part');
    try {
      await _boundedStream(stream, length).pipe(temporary.openWrite());
      if (await temporary.length() != length) {
        throw const FormatException('文件复制不完整，请重新选择。');
      }
      await temporary.rename(destination.path);
      return destination.path;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// Deletes only regular files whose resolved target remains inside the
  /// app-owned model directory. Imported paths from old or malformed settings
  /// can never make cleanup remove an arbitrary external file.
  Future<bool> deleteManagedFile(String path) async {
    if (path.trim().isEmpty) return false;
    try {
      final directory = await _managedDirectory();
      if (!await directory.exists()) return false;
      final file = File(path);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final root = _withSeparator(
        (await directory.resolveSymbolicLinks()).toLowerCase(),
      );
      final resolved = (await file.resolveSymbolicLinks()).toLowerCase();
      if (!resolved.startsWith(root)) return false;
      await file.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static String _withSeparator(String path) =>
      path.endsWith(Platform.pathSeparator)
      ? path
      : '$path${Platform.pathSeparator}';

  Stream<List<int>> _boundedStream(
    Stream<List<int>> stream,
    int expected,
  ) async* {
    var copied = 0;
    await for (final chunk in stream) {
      copied += chunk.length;
      if (copied > expected || copied > maximumFileBytes) {
        throw const FormatException('文件大小在复制时变化，请重新选择。');
      }
      yield chunk;
    }
  }
}

class RealtimeCallSettingsPage extends StatefulWidget {
  const RealtimeCallSettingsPage({
    super.key,
    required this.contacts,
    required this.defaultFishModel,
    required this.defaultVoice,
    this.store,
    this.downloader,
  });

  final List<CallContactOption> contacts;
  final String defaultFishModel;
  final String defaultVoice;
  final CallSettingsStore? store;
  final CallAsrModelDownloader? downloader;

  @override
  State<RealtimeCallSettingsPage> createState() =>
      _RealtimeCallSettingsPageState();
}

class _RealtimeCallSettingsPageState extends State<RealtimeCallSettingsPage> {
  final _model = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _voices = <String, TextEditingController>{};
  final _importer = CallAsrModelImporter();
  final _uncommittedFiles = <String>{};
  final _loadedModelFiles = <String>{};
  late final CallAsrModelDownloader _downloader;
  late final CallSettingsStore _store;
  CallSettings _settings = CallSettings();
  bool _loading = true;
  bool _busy = false;
  bool _downloading = false;
  bool _cancelling = false;
  CallModelDownloadProgress? _downloadProgress;
  String? _error;
  String? _readyMessage;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? CallSettingsStore();
    _downloader = widget.downloader ?? CallAsrModelDownloader();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await _store.load();
      if (!mounted) return;
      _settings = settings;
      _loadedModelFiles
        ..clear()
        ..addAll(
          {
            settings.asr.modelPath,
            settings.asr.tokensPath,
            settings.asr.vadModelPath,
          }.where((path) => path.isNotEmpty),
        );
      _model.text = settings.fishModel.isEmpty
          ? widget.defaultFishModel
          : settings.fishModel;
    } on Object catch (error) {
      if (!mounted) return;
      _error = '读取通话设置失败：$error';
      _model.text = widget.defaultFishModel;
    }
    for (final contact in widget.contacts) {
      _voices[contact.id] = TextEditingController(
        text: _settings.voiceOverrides[contact.id] ?? '',
      );
    }
    setState(() => _loading = false);
    await _checkReady();
  }

  Future<void> _checkReady() async {
    String message;
    try {
      await _settings.asr.validateFiles();
      message = '三个本地模型文件已就绪；首次拨打时会验证能否加载。';
    } on Object catch (error) {
      message = '尚未就绪：$error';
    }
    if (mounted) setState(() => _readyMessage = message);
  }

  Future<void> _pick(CallAsrModelFile kind) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: [kind == CallAsrModelFile.tokens ? 'txt' : 'onnx'],
      );
      if (file == null) return;
      final imported = await _importer.importPickedFile(file, kind);
      _uncommittedFiles.add(imported);
      if (!mounted) {
        await File(imported).delete();
        return;
      }
      final old = _settings.asr;
      _settings = _settings.copyWith(
        asr: LocalCallAsrConfig(
          modelPath: kind == CallAsrModelFile.senseVoice
              ? imported
              : old.modelPath,
          tokensPath: kind == CallAsrModelFile.tokens
              ? imported
              : old.tokensPath,
          vadModelPath: kind == CallAsrModelFile.sileroVad
              ? imported
              : old.vadModelPath,
          language: old.language,
          silenceSeconds: old.silenceSeconds,
        ),
      );
      await _checkReady();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadModels() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _downloading = true;
      _cancelling = false;
      _error = null;
      _downloadProgress = null;
    });
    try {
      final installed = await _downloader.install(
        previous: _settings.asr,
        onProgress: (progress) {
          if (mounted && !_cancelling) {
            setState(() => _downloadProgress = progress);
          }
        },
      );
      final paths = {
        installed.modelPath,
        installed.tokensPath,
        installed.vadModelPath,
      };
      if (!mounted) {
        for (final path in paths) {
          await _importer.deleteManagedFile(path);
        }
        return;
      }
      _uncommittedFiles.addAll(paths);
      _settings = _settings.copyWith(asr: installed);
      await _checkReady();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _downloadProgress = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloading = false;
          _cancelling = false;
        });
      }
    }
  }

  void _cancelDownload() {
    _downloader.cancel();
    setState(() {
      _cancelling = true;
      _downloadProgress = const CallModelDownloadProgress(
        '正在取消；若正在解压，将在当前解压结束后清理临时文件。',
      );
    });
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final voices = Map<String, String>.from(_settings.voiceOverrides);
      for (final entry in _voices.entries) {
        if (entry.value.text.trim().isEmpty) {
          voices.remove(entry.key);
        } else {
          voices[entry.key] = entry.value.text.trim();
        }
      }
      final nextSettings = _settings.copyWith(
        fishModel: _model.text.trim(),
        voiceOverrides: voices,
      );
      await _store.save(nextSettings);
      final retained = {
        nextSettings.asr.modelPath,
        nextSettings.asr.tokensPath,
        nextSettings.asr.vadModelPath,
      };
      final obsolete = {
        ..._loadedModelFiles,
        ..._uncommittedFiles,
      }.difference(retained);
      for (final unused in obsolete) {
        await _importer.deleteManagedFile(unused);
      }
      _settings = nextSettings;
      _loadedModelFiles
        ..clear()
        ..addAll(retained.where((path) => path.isNotEmpty));
      _uncommittedFiles.clear();
      if (mounted) {
        setState(() => _busy = false);
        Navigator.of(context).pop(true);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _downloader.cancel();
    _model.dispose();
    for (final controller in _voices.values) {
      controller.dispose();
    }
    for (final path in _uncommittedFiles) {
      _importer.deleteManagedFile(path).ignore();
    }
    super.dispose();
  }

  Widget _fileTile(String title, String path, CallAsrModelFile kind) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: Text(
          path.isEmpty ? '尚未导入' : path.replaceAll('\\', '/').split('/').last,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: OutlinedButton(
          onPressed: _busy ? null : () => _pick(kind),
          child: const Text('导入'),
        ),
      );

  Future<void> _openDocumentation() async {
    final opened = await launchUrl(
      Uri.parse('https://k2-fsa.github.io/sherpa/onnx/sense-voice/index.html'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) setState(() => _error = '无法打开浏览器，请复制下方官方地址。');
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('实时通话设置'),
        actions: [
          TextButton(
            onPressed: _loading || _busy ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    '本地语音识别',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '麦克风 → 本地 Silero VAD 断句 → Sherpa-ONNX SenseVoice 识别。只将识别文字发送给聊天模型，不上传录音。',
                  ),
                  _fileTile(
                    'SenseVoice 模型（推荐 model.int8.onnx）',
                    _settings.asr.modelPath,
                    CallAsrModelFile.senseVoice,
                  ),
                  _fileTile(
                    '配套 tokens.txt',
                    _settings.asr.tokensPath,
                    CallAsrModelFile.tokens,
                  ),
                  _fileTile(
                    'Silero VAD（silero_vad.onnx）',
                    _settings.asr.vadModelPath,
                    CallAsrModelFile.sileroVad,
                  ),
                  if (_busy)
                    LinearProgressIndicator(value: _downloadProgress?.fraction),
                  if (_downloadProgress != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(_downloadProgress!.message),
                    ),
                  if (_readyMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(_readyMessage!),
                    ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue:
                        LocalCallAsrConfig.supportedLanguages.contains(
                          _settings.asr.language,
                        )
                        ? _settings.asr.language
                        : 'auto',
                    decoration: const InputDecoration(labelText: '识别语言'),
                    items: const [
                      DropdownMenuItem(value: 'auto', child: Text('自动识别')),
                      DropdownMenuItem(value: 'zh', child: Text('中文')),
                      DropdownMenuItem(value: 'ja', child: Text('日文')),
                      DropdownMenuItem(value: 'en', child: Text('英文')),
                      DropdownMenuItem(value: 'ko', child: Text('韩文')),
                      DropdownMenuItem(value: 'yue', child: Text('粤语')),
                    ],
                    onChanged: _busy
                        ? null
                        : (language) {
                            final old = _settings.asr;
                            setState(
                              () => _settings = _settings.copyWith(
                                asr: LocalCallAsrConfig(
                                  modelPath: old.modelPath,
                                  tokensPath: old.tokensPath,
                                  vadModelPath: old.vadModelPath,
                                  language: language ?? 'auto',
                                  silenceSeconds: old.silenceSeconds,
                                ),
                              ),
                            );
                          },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '停顿 ${_settings.asr.silenceSeconds.toStringAsFixed(2)} 秒后发送',
                  ),
                  Slider(
                    value: _settings.asr.silenceSeconds.clamp(.3, 2),
                    min: .3,
                    max: 2,
                    divisions: 34,
                    onChanged: _busy
                        ? null
                        : (value) {
                            final old = _settings.asr;
                            setState(
                              () => _settings = _settings.copyWith(
                                asr: LocalCallAsrConfig(
                                  modelPath: old.modelPath,
                                  tokensPath: old.tokensPath,
                                  vadModelPath: old.vadModelPath,
                                  language: old.language,
                                  silenceSeconds: value,
                                ),
                              ),
                            );
                          },
                  ),
                  const Text(
                    '推荐：SenseVoice INT8（2024-07-17）与 Silero VAD。约 156 MB，优先 Gitee，未托管或不可用时自动切换官方 GitHub；自动解压和校验，也可分别导入文件。',
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('call-download-models'),
                    onPressed: _downloading
                        ? _cancelling
                              ? null
                              : _cancelDownload
                        : _busy
                        ? null
                        : _downloadModels,
                    icon: Icon(
                      _downloading ? Icons.close : Icons.download_outlined,
                    ),
                    label: Text(
                      _downloading
                          ? _cancelling
                                ? '正在取消…'
                                : '取消下载'
                          : '下载并安装本地模型',
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _openDocumentation,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Sherpa-ONNX 官方模型说明'),
                  ),
                  const SelectableText(
                    'https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models',
                    style: TextStyle(fontSize: 12),
                  ),
                  const Divider(height: 36),
                  const Text(
                    '通话语音',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '通话复用现有聊天 LLM 配置和 Fish Audio REST API 密钥。请在原来的 AI 接口和 TTS 设置填写；MCP OAuth 不能代替 REST 密钥。每段回复会产生正常 API 用量。',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _model,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Fish Audio 通话模型',
                      helperText: '可填写服务支持的模型 ID',
                    ),
                    validator: (value) =>
                        RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]{0,95}$')
                            .hasMatch(value?.trim() ?? '')
                        ? null
                        : '请输入有效的模型 ID',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final model in ['s2-pro', 'drama-3'])
                        ActionChip(
                          label: Text(model),
                          onPressed: _busy
                              ? null
                              : () => setState(() => _model.text = model),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '联系人音色',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    '莱莎留空时跟随普通模式音色；科洛蒂娅留空时使用应用内置音色。两位联系人也可分别填写音色 ID 覆盖默认设置。',
                  ),
                  for (final contact in widget.contacts)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: TextFormField(
                        key: ValueKey('call-voice-${contact.id}'),
                        controller: _voices[contact.id],
                        enabled: !_busy,
                        decoration: InputDecoration(
                          labelText: '${contact.name} · Fish 音色 ID',
                          helperText: contact.isMainCharacter
                              ? '留空跟随主角设置${widget.defaultVoice.isEmpty ? '（当前未配置）' : ''}'
                              : contact.id == 'claudia'
                              ? '留空使用应用内置的科洛蒂娅音色'
                              : '此 NPC 需要独立音色',
                        ),
                        validator: (value) =>
                            (value?.trim().contains(RegExp(r'[\r\n]')) ?? false)
                            ? '音色 ID 不能包含换行'
                            : null,
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
    ),
  );
}
