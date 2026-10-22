import 'settings_form.dart';

import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'glass_ui.dart';
import 'image_generation_config.dart';

/// Edits the public image-generation settings and its independently stored key.
///
/// This page intentionally does not send a test generation request. Some image
/// services bill as soon as a request is accepted, so protocol detection is
/// performed by the real generation service when the user actually asks for an
/// image.
class ImageGenerationSettingsPage extends StatefulWidget {
  const ImageGenerationSettingsPage({
    super.key,
    required this.initialConfig,
    required this.initialApiKey,
    required this.onSave,
    this.language = AppLanguage.chinese,
    this.liquidGlass = false,
  });

  final ImageGenerationConfig initialConfig;
  final String initialApiKey;
  final Future<void> Function(ImageGenerationConfig config, String apiKey)
  onSave;
  final AppLanguage language;
  final bool liquidGlass;

  @override
  State<ImageGenerationSettingsPage> createState() =>
      _ImageGenerationSettingsPageState();
}

class _ImageGenerationSettingsPageState
    extends State<ImageGenerationSettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late final TextEditingController _width;
  late final TextEditingController _height;
  late final TextEditingController _aspectRatio;
  late final TextEditingController _endpointPath;
  late final TextEditingController _statusEndpointTemplate;
  late final TextEditingController _pollIntervalSeconds;
  late final TextEditingController _maxPollAttempts;
  late ImageGenerationProtocol _protocol;
  late String _outputFormat;
  late bool _enabled;
  bool _obscureKey = true;
  bool _saving = false;
  String? _error;

  AppLanguage get _language => widget.language;
  bool get _liquidGlass =>
      GlassStyleScope.resolve(context, fallback: widget.liquidGlass);

  String _t(String zh, String en, String ja) => _language.text(zh, en, ja);

  @override
  void initState() {
    super.initState();
    final config = widget.initialConfig;
    _enabled = config.enabled;
    _protocol = config.protocol;
    _outputFormat = _normalizedFormat(config.outputFormat);
    _baseUrl = TextEditingController(text: config.baseUrl);
    _model = TextEditingController(text: config.model);
    _apiKey = TextEditingController(text: widget.initialApiKey);
    _width = TextEditingController(text: '${config.width}');
    _height = TextEditingController(text: '${config.height}');
    _aspectRatio = TextEditingController(text: config.aspectRatio);
    _endpointPath = TextEditingController(text: config.endpointPath);
    _statusEndpointTemplate = TextEditingController(
      text: config.statusEndpointTemplate,
    );
    _pollIntervalSeconds = TextEditingController(
      text: '${config.pollIntervalSeconds}',
    );
    _maxPollAttempts = TextEditingController(text: '${config.maxPollAttempts}');
    _baseUrl.addListener(_refreshProtocolPreview);
    _model.addListener(_refreshProtocolPreview);
    _endpointPath.addListener(_refreshProtocolPreview);
  }

  @override
  void dispose() {
    _baseUrl.removeListener(_refreshProtocolPreview);
    _model.removeListener(_refreshProtocolPreview);
    _endpointPath.removeListener(_refreshProtocolPreview);
    for (final controller in [
      _baseUrl,
      _model,
      _apiKey,
      _width,
      _height,
      _aspectRatio,
      _endpointPath,
      _statusEndpointTemplate,
      _pollIntervalSeconds,
      _maxPollAttempts,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _refreshProtocolPreview() {
    if (mounted && _protocol == ImageGenerationProtocol.auto) setState(() {});
  }

  String _normalizedFormat(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'jpeg') return 'jpg';
    return const {'png', 'jpg', 'webp', 'gif', 'avif'}.contains(normalized)
        ? normalized
        : 'png';
  }

  ImageGenerationConfig _draftConfig() => ImageGenerationConfig(
    enabled: _enabled,
    baseUrl: _baseUrl.text.trim(),
    model: _model.text.trim(),
    protocol: _protocol,
    width: int.tryParse(_width.text.trim()) ?? 0,
    height: int.tryParse(_height.text.trim()) ?? 0,
    aspectRatio: _aspectRatio.text.trim(),
    outputFormat: _outputFormat,
    endpointPath: _endpointPath.text.trim(),
    statusEndpointTemplate: _statusEndpointTemplate.text.trim(),
    pollIntervalSeconds: int.tryParse(_pollIntervalSeconds.text.trim()) ?? 0,
    maxPollAttempts: int.tryParse(_maxPollAttempts.text.trim()) ?? 0,
  );

  String _validationMessage(String token) => switch (token) {
    'invalid_base_url' => _t(
      '请输入完整的接口地址。',
      'Enter a complete endpoint URL.',
      '完全なエンドポイント URL を入力してください。',
    ),
    'https_required' => _t(
      '公网接口必须使用 HTTPS；HTTP 只允许 localhost。',
      'Public endpoints must use HTTPS; HTTP is allowed only for localhost.',
      '公開エンドポイントは HTTPS 必須です。HTTP は localhost のみ使用できます。',
    ),
    'url_contains_credentials' => _t(
      '请移除地址中的用户名、密码或 Key/Token 参数，并将密钥填写在 API Key 中。',
      'Remove credentials and key/token parameters from the URL; use the API Key field.',
      'URL の認証情報と key/token を削除し、API Key 欄に入力してください。',
    ),
    'invalid_dimensions' => _t(
      '宽度和高度必须是 64 至 8192 之间的整数。',
      'Width and height must be integers from 64 to 8192.',
      '幅と高さは 64～8192 の整数にしてください。',
    ),
    'invalid_aspect_ratio' => _t(
      '画面比例格式应类似 1:1、16:9 或 9:16。',
      'Use an aspect ratio such as 1:1, 16:9, or 9:16.',
      '比率は 1:1、16:9、9:16 のように入力してください。',
    ),
    'unsupported_output_format' => _t(
      '请选择受支持的图片格式。',
      'Choose a supported image format.',
      '対応している画像形式を選んでください。',
    ),
    'invalid_polling' => _t(
      '轮询间隔应为 1 至 60 秒，最大次数应为 1 至 600。',
      'Polling must use an interval of 1–60 seconds and 1–600 attempts.',
      'ポーリング間隔は 1～60 秒、最大回数は 1～600 にしてください。',
    ),
    _ => _t('配置无效。', 'The configuration is invalid.', '設定が正しくありません。'),
  };

  Future<void> _save() async {
    final config = _draftConfig();
    final validationError = config.validationError;
    if (validationError != null) {
      setState(() => _error = _validationMessage(validationError));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(config, _apiKey.text.trim());
      if (!mounted) return;
      final popped = await Navigator.of(context).maybePop();
      if (mounted && !popped) setState(() => _saving = false);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _t(
          '保存失败：$error',
          'Could not save: $error',
          '保存できませんでした：$error',
        );
      });
    }
  }

  ImageGenerationProtocol get _previewProtocol =>
      _draftConfig().resolvedProtocol;

  String _protocolLabel(ImageGenerationProtocol protocol) => switch (protocol) {
    ImageGenerationProtocol.auto => _t('自动识别', 'Auto detect', '自動判別'),
    ImageGenerationProtocol.openAiImages => 'OpenAI Images API',
    ImageGenerationProtocol.openAiResponses => 'OpenAI Responses API',
    ImageGenerationProtocol.gemini => 'Google Gemini',
    ImageGenerationProtocol.syncJson => _t(
      '通用同步 JSON',
      'Generic synchronous JSON',
      '汎用同期 JSON',
    ),
    ImageGenerationProtocol.asyncTask => _t(
      '通用异步任务',
      'Generic asynchronous task',
      '汎用非同期タスク',
    ),
    ImageGenerationProtocol.comfyUi => 'ComfyUI',
  };

  String _submissionEndpoint({String? openAiTarget}) {
    final baseText = _baseUrl.text.trim();
    final base = Uri.tryParse(baseText);
    if (base == null) return baseText;
    final configured = _endpointPath.text.trim();
    if (configured.isNotEmpty) {
      final endpoint = Uri.tryParse(configured);
      if (endpoint == null || endpoint.hasScheme) return configured;
      return base
          .replace(
            path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/',
            query: '',
            fragment: '',
          )
          .resolveUri(endpoint)
          .toString();
    }
    if (openAiTarget == null) return baseText;
    final path = base.path.replaceAll(RegExp(r'/+$'), '');
    final known = RegExp(
      r'/(?:images/generations|responses|chat/completions)$',
    );
    if (path.endsWith('/$openAiTarget')) {
      return base.replace(path: path).toString();
    }
    if (known.hasMatch(path)) {
      return base
          .replace(path: path.replaceFirst(known, '/$openAiTarget'))
          .toString();
    }
    return base
        .replace(
          path: path.isEmpty ? '/v1/$openAiTarget' : '$path/$openAiTarget',
        )
        .toString();
  }

  String _endpointSummary() {
    final base = _baseUrl.text.trim().replaceFirst(RegExp(r'/+$'), '');
    final protocol = _previewProtocol;
    final configuredEndpoint = _endpointPath.text.trim();
    if (_protocol == ImageGenerationProtocol.auto &&
        protocol == ImageGenerationProtocol.auto) {
      final endpoint = _submissionEndpoint();
      return _t(
        '实际提交地址：$endpoint。未知服务不会自动补全路径；若填写的是 API 基础地址，请改填完整生图端点，或手动选择 OpenAI Images API。首次生成只提交一次，再识别同一次响应。',
        'Actual submit URL: $endpoint. Unknown services keep this exact path. If this is an API base URL, enter the full generation endpoint or select OpenAI Images API. Detection inspects the same response without an extra submission.',
        '実際の送信先：$endpoint。未知のサービスではパスを補完しません。API のベース URL の場合は完全な生成 URL を入力するか、OpenAI Images API を選択してください。同じ応答から判別し、追加送信は行いません。',
      );
    }
    if (configuredEndpoint.isNotEmpty) {
      final endpoint = _submissionEndpoint();
      return _t(
        '实际提交地址：$endpoint。异步任务优先使用响应中的状态地址，再使用下方状态模板。',
        'Actual submit URL: $endpoint. Asynchronous tasks prefer a status URL from the response, then the status template below.',
        '実際の送信先：$endpoint。非同期タスクは応答内の状態 URL を優先し、次に下欄の状態テンプレートを使用します。',
      );
    }
    final endpoint = switch (protocol) {
      ImageGenerationProtocol.openAiImages => _submissionEndpoint(
        openAiTarget: 'images/generations',
      ),
      ImageGenerationProtocol.openAiResponses => _submissionEndpoint(
        openAiTarget: 'responses',
      ),
      ImageGenerationProtocol.gemini => _t(
        '使用 Gemini generateContent 端点；完整端点也可直接填写在上方。',
        'Uses the Gemini generateContent endpoint; a complete endpoint may also be entered above.',
        'Gemini generateContent エンドポイントを使用します。完全な URL も上欄に入力できます。',
      ),
      ImageGenerationProtocol.comfyUi => '$base/prompt → /history → /view',
      ImageGenerationProtocol.asyncTask => _t(
        '提交至上方地址，再按返回的任务 ID 有限轮询。结果未明时不会自动重复提交。',
        'Submits to the URL above, then polls a returned task ID for a limited time. An unknown outcome is never resubmitted automatically.',
        '上記 URL に送信し、返されたタスク ID を有限回ポーリングします。結果不明時に自動再送信しません。',
      ),
      ImageGenerationProtocol.syncJson => _t(
        '提交至上方地址，并从同一次 JSON 响应读取 URL 或 Base64 图片。',
        'Submits to the URL above and reads a URL or Base64 image from the same JSON response.',
        '上記 URL に送信し、同じ JSON 応答から URL または Base64 画像を読み取ります。',
      ),
      ImageGenerationProtocol.auto => '',
    };
    return endpoint;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_saving,
      child: SettingsFormTheme(
        child: GlassPageSurface(
          liquidGlass: _liquidGlass,
          child: Scaffold(
            key: const ValueKey('image-generation-settings-page'),
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: glassPageHeaderColor(context),
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: IconButton(
                key: const ValueKey('image-generation-settings-back'),
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).maybePop(),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              title: Text(
                _t('生图接口', 'Image generation', '画像生成'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            body: SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                          children: [
                            GlassContentCard(
                              liquidGlass: _liquidGlass,
                              child: SwitchListTile(
                                key: const ValueKey('image-generation-enabled'),
                                value: _enabled,
                                onChanged: _saving
                                    ? null
                                    : (value) =>
                                          setState(() => _enabled = value),
                                title: Text(
                                  _t(
                                    '启用主对话生图',
                                    'Enable chat image generation',
                                    'チャット画像生成を有効にする',
                                  ),
                                ),
                                subtitle: Text(
                                  _t(
                                    '识别到明确的生图请求后才会调用此接口。',
                                    'This endpoint is called only for an explicit image request.',
                                    '明確な画像生成依頼を検出した場合のみ、この API を呼び出します。',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            _sectionTitle(
                              _t('连接', 'Connection', '接続'),
                              Icons.link_rounded,
                            ),
                            _field(
                              key: const ValueKey('image-generation-base-url'),
                              controller: _baseUrl,
                              label: _t('接口地址', 'Endpoint URL', 'エンドポイント URL'),
                              hint: 'https://api.openai.com/v1',
                              keyboardType: TextInputType.url,
                            ),
                            _field(
                              key: const ValueKey('image-generation-api-key'),
                              controller: _apiKey,
                              label: 'API Key',
                              obscureText: _obscureKey,
                              enableSuggestions: false,
                              autocorrect: false,
                              suffixIcon: IconButton(
                                key: const ValueKey(
                                  'image-generation-key-visibility',
                                ),
                                tooltip: _obscureKey
                                    ? _t('显示 Key', 'Show key', 'キーを表示')
                                    : _t('隐藏 Key', 'Hide key', 'キーを隠す'),
                                onPressed: _saving
                                    ? null
                                    : () => setState(
                                        () => _obscureKey = !_obscureKey,
                                      ),
                                icon: Icon(
                                  _obscureKey
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                              helper: _t(
                                '独立保存在系统安全存储中。清空后保存会删除已保存的生图 Key。',
                                'Stored independently in secure storage. Save an empty value to delete the image-generation key.',
                                'システムの安全なストレージに個別保存します。空欄で保存すると画像生成キーを削除します。',
                              ),
                            ),
                            _field(
                              key: const ValueKey('image-generation-model'),
                              controller: _model,
                              label: _t('模型', 'Model', 'モデル'),
                              hint: 'gpt-image-1',
                            ),
                            const SizedBox(height: 4),
                            DropdownButtonFormField<ImageGenerationProtocol>(
                              key: const ValueKey('image-generation-protocol'),
                              initialValue: _protocol,
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText: _t('协议格式', 'Protocol', 'プロトコル'),
                                border: const OutlineInputBorder(),
                              ),
                              items: [
                                for (final protocol
                                    in ImageGenerationProtocol.values)
                                  DropdownMenuItem(
                                    value: protocol,
                                    child: Text(_protocolLabel(protocol)),
                                  ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (value) {
                                      if (value != null) {
                                        setState(() => _protocol = value);
                                      }
                                    },
                            ),
                            const SizedBox(height: 10),
                            GlassContentCard(
                              liquidGlass: _liquidGlass,
                              borderRadius: BorderRadius.circular(14),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.route_outlined,
                                      size: 20,
                                      color: colors.primary,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _protocol ==
                                                    ImageGenerationProtocol.auto
                                                ? _t(
                                                    '当前识别：${_protocolLabel(_previewProtocol)}',
                                                    'Detected: ${_protocolLabel(_previewProtocol)}',
                                                    '現在の判別：${_protocolLabel(_previewProtocol)}',
                                                  )
                                                : _protocolLabel(_protocol),
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleSmall,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            _endpointSummary(),
                                            style: TextStyle(
                                              color: colors.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            GlassContentCard(
                              liquidGlass: _liquidGlass,
                              borderRadius: BorderRadius.circular(14),
                              child: ExpansionTile(
                                key: const ValueKey(
                                  'image-generation-endpoint-advanced',
                                ),
                                initiallyExpanded:
                                    _endpointPath.text.trim().isNotEmpty ||
                                    _statusEndpointTemplate.text
                                        .trim()
                                        .isNotEmpty,
                                title: Text(
                                  _t(
                                    '端点与轮询（高级）',
                                    'Endpoints and polling (advanced)',
                                    'エンドポイントとポーリング（詳細）',
                                  ),
                                ),
                                subtitle: Text(
                                  _t(
                                    '留空时按所选协议使用安全默认值',
                                    'Leave blank to use safe protocol defaults',
                                    '空欄の場合は安全な既定値を使用します',
                                  ),
                                ),
                                childrenPadding: const EdgeInsets.fromLTRB(
                                  12,
                                  2,
                                  12,
                                  12,
                                ),
                                children: [
                                  _field(
                                    key: const ValueKey(
                                      'image-generation-endpoint-path',
                                    ),
                                    controller: _endpointPath,
                                    label: _t(
                                      '提交端点路径',
                                      'Submit endpoint path',
                                      '送信エンドポイントのパス',
                                    ),
                                    hint: '/v1/images/generations',
                                    helper: _t(
                                      '可填相对路径或完整 HTTPS 地址。留空时由协议自动补全。',
                                      'Enter a relative path or complete HTTPS URL. Leave blank for protocol defaults.',
                                      '相対パスまたは完全な HTTPS URL。空欄ならプロトコル既定値を使用します。',
                                    ),
                                  ),
                                  _field(
                                    key: const ValueKey(
                                      'image-generation-status-endpoint',
                                    ),
                                    controller: _statusEndpointTemplate,
                                    label: _t(
                                      '任务状态端点模板',
                                      'Task status endpoint template',
                                      'タスク状態 URL テンプレート',
                                    ),
                                    hint: '/v1/tasks/{task_id}',
                                    helper: _t(
                                      '异步接口可用 {task_id} 作为任务编号占位符。响应自带 status_url 或 Location 时优先使用响应地址。',
                                      'Use {task_id} as the asynchronous task placeholder. A status_url or Location returned by the service takes priority.',
                                      '非同期タスク ID は {task_id} で指定します。応答に status_url または Location があれば、そちらを優先します。',
                                    ),
                                  ),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: _field(
                                          key: const ValueKey(
                                            'image-generation-poll-interval',
                                          ),
                                          controller: _pollIntervalSeconds,
                                          label: _t(
                                            '轮询间隔',
                                            'Poll interval',
                                            '確認間隔',
                                          ),
                                          keyboardType: TextInputType.number,
                                          suffixText: _t('秒', 'sec', '秒'),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: _field(
                                          key: const ValueKey(
                                            'image-generation-poll-attempts',
                                          ),
                                          controller: _maxPollAttempts,
                                          label: _t(
                                            '最大次数',
                                            'Max attempts',
                                            '最大回数',
                                          ),
                                          keyboardType: TextInputType.number,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      _t(
                                        '只轮询已经提交的任务；超时或结果未知时不会换协议重新提交，以免重复计费。',
                                        'Only an already submitted task is polled. A timeout or unknown outcome is never resubmitted through another protocol.',
                                        '送信済みタスクだけを確認します。タイムアウトや結果不明時に別プロトコルで再送信しません。',
                                      ),
                                      style: TextStyle(
                                        color: colors.onSurfaceVariant,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            _sectionTitle(
                              _t('输出', 'Output', '出力'),
                              Icons.aspect_ratio_rounded,
                            ),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: _field(
                                    key: const ValueKey(
                                      'image-generation-width',
                                    ),
                                    controller: _width,
                                    label: _t('宽度', 'Width', '幅'),
                                    keyboardType: TextInputType.number,
                                    suffixText: 'px',
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _field(
                                    key: const ValueKey(
                                      'image-generation-height',
                                    ),
                                    controller: _height,
                                    label: _t('高度', 'Height', '高さ'),
                                    keyboardType: TextInputType.number,
                                    suffixText: 'px',
                                  ),
                                ),
                              ],
                            ),
                            _field(
                              key: const ValueKey(
                                'image-generation-aspect-ratio',
                              ),
                              controller: _aspectRatio,
                              label: _t('画面比例', 'Aspect ratio', 'アスペクト比'),
                              hint: '1:1',
                              helper: _t(
                                '部分服务优先使用比例，部分服务优先使用像素尺寸。',
                                'Some services prefer an aspect ratio; others prefer pixel dimensions.',
                                'サービスにより、比率またはピクセル寸法が優先されます。',
                              ),
                            ),
                            DropdownButtonFormField<String>(
                              key: const ValueKey(
                                'image-generation-output-format',
                              ),
                              initialValue: _outputFormat,
                              decoration: InputDecoration(
                                labelText: _t('图片格式', 'Image format', '画像形式'),
                                border: const OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'png',
                                  child: Text('PNG'),
                                ),
                                DropdownMenuItem(
                                  value: 'jpg',
                                  child: Text('JPEG'),
                                ),
                                DropdownMenuItem(
                                  value: 'webp',
                                  child: Text('WebP'),
                                ),
                                DropdownMenuItem(
                                  value: 'gif',
                                  child: Text('GIF'),
                                ),
                                DropdownMenuItem(
                                  value: 'avif',
                                  child: Text('AVIF'),
                                ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (value) {
                                      if (value != null) {
                                        setState(() => _outputFormat = value);
                                      }
                                    },
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 14),
                              _errorBanner(colors),
                            ],
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: _saving
                                  ? null
                                  : () => Navigator.of(context).maybePop(),
                              child: Text(_t('取消', 'Cancel', 'キャンセル')),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              key: const ValueKey(
                                'image-generation-settings-save',
                              ),
                              onPressed: _saving ? null : _save,
                              icon: _saving
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.save_outlined),
                              label: Text(
                                _saving
                                    ? _t('保存中…', 'Saving…', '保存中…')
                                    : _t('保存', 'Save', '保存'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Icon(icon, size: 19),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String label,
    String? hint,
    String? helper,
    String? suffixText,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    bool obscureText = false,
    bool enableSuggestions = true,
    bool autocorrect = true,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: key,
      controller: controller,
      enabled: !_saving,
      keyboardType: keyboardType,
      obscureText: obscureText,
      enableSuggestions: enableSuggestions,
      autocorrect: autocorrect,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        suffixText: suffixText,
        suffixIcon: suffixIcon,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _errorBanner(ColorScheme colors) => Material(
    key: const ValueKey('image-generation-settings-error'),
    color: colors.errorContainer.withValues(alpha: .82),
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    ),
  );
}
