import 'app_localization.dart';

enum ThinkingAvailability { switchable, alwaysOn, alwaysOff, unknown }

enum ThinkingWireFormat {
  none,
  effort,
  enabledType,
  adaptiveType,
  enableThinking,
  chatTemplate,
  claudeBudget,
  openRouter,
  geminiInteractions,
}

/// Names describe capabilities; known endpoints override the wire protocol.
/// Unknown names are deliberately not treated as OpenAI reasoning models.
class ModelThinking {
  const ModelThinking(
    this.family,
    this.availability,
    this.format, {
    this.efforts = const [],
    this.minimumEffort = 'low',
    this.separateReasoning = false,
  });

  final String family;
  final ThinkingAvailability availability;
  final ThinkingWireFormat format;
  final List<String> efforts;
  final String minimumEffort;
  final bool separateReasoning;

  bool get canToggle => availability == ThinkingAvailability.switchable;
  bool get alwaysOn => availability == ThinkingAvailability.alwaysOn;
  bool get hasControl => canToggle || efforts.isNotEmpty;
  bool isEnabled(bool preference) => alwaysOn || (canToggle && preference);

  String normalizeEffort(String? effort) {
    if (efforts.isEmpty) return 'medium';
    if (efforts.contains(effort)) return effort!;
    if (effort == 'minimal' || effort == 'low') return efforts.first;
    if (effort == 'high') return efforts.last;
    return efforts.contains('medium') ? 'medium' : efforts.first;
  }

  String description(AppLanguage language) {
    final status = switch (availability) {
      ThinkingAvailability.switchable => language.text(
        '可开启或关闭思考',
        'Thinking can be enabled or disabled',
        '推論のオン・オフに対応',
      ),
      ThinkingAvailability.alwaysOn => language.text(
        '始终思考，不能关闭',
        'Always reasons; cannot be disabled',
        '常に推論します。無効化できません',
      ),
      ThinkingAvailability.alwaysOff => language.text(
        '该型号不支持思考开关',
        'This model has no thinking switch',
        'このモデルは推論切替に非対応',
      ),
      ThinkingAvailability.unknown => language.text(
        '未识别能力，使用服务默认行为，不发送思考参数',
        'Unrecognized capability; use provider defaults without thinking parameters',
        '能力未確認。推論パラメーターを送信せずサービス既定値を使用',
      ),
    };
    return '$family · $status';
  }

  Map<String, dynamic> requestFields({bool? enabled, String? effort}) {
    // Null means the caller did not opt into this feature. Preserve old clients.
    if (enabled == null && effort == null) return const {};
    if (availability == ThinkingAvailability.unknown ||
        availability == ThinkingAvailability.alwaysOff) {
      return const {};
    }
    final on = alwaysOn || (enabled ?? true);
    final level = normalizeEffort(effort);
    final fields = <String, dynamic>{};
    switch (format) {
      case ThinkingWireFormat.none:
        break;
      case ThinkingWireFormat.effort:
        fields['reasoning_effort'] = on ? level : 'none';
      case ThinkingWireFormat.enabledType:
        fields['thinking'] = {'type': on ? 'enabled' : 'disabled'};
      case ThinkingWireFormat.adaptiveType:
        fields['thinking'] = {'type': on ? 'adaptive' : 'disabled'};
      case ThinkingWireFormat.enableThinking:
        fields['enable_thinking'] = on;
      case ThinkingWireFormat.chatTemplate:
        fields['chat_template_kwargs'] = {'enable_thinking': on};
      case ThinkingWireFormat.claudeBudget:
        final budget = switch (level) {
          'minimal' => 1024,
          'low' => 2048,
          'high' => 8192,
          _ => 4096,
        };
        fields['thinking'] = {
          'type': on ? 'enabled' : 'disabled',
          if (on) 'budget_tokens': budget,
        };
        // Claude requires an output budget greater than its thinking budget.
        if (on) fields['max_tokens'] = budget + 8192;
      case ThinkingWireFormat.openRouter:
        fields['reasoning'] = {
          'enabled': on,
          if (on && efforts.isNotEmpty) 'effort': level,
        };
      case ThinkingWireFormat.geminiInteractions:
        fields['generation_config'] = {
          'thinking_level': on ? level : minimumEffort,
        };
    }
    if (separateReasoning) fields['reasoning_split'] = true;
    return fields;
  }
}

ModelThinking identifyModelThinking(
  String model, {
  String baseUrl = '',
  bool geminiNative = false,
}) {
  final name = model.trim().toLowerCase().split('/').last;
  final host = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
  final port = Uri.tryParse(baseUrl)?.port;
  bool hostIs(String domain) => host == domain || host.endsWith('.$domain');
  final local = host == 'localhost' || host == '127.0.0.1' || host == '::1';
  final ollama = hostIs('ollama.com') || (local && port == 11434);
  final router = hostIs('openrouter.ai');
  const levels = ['minimal', 'low', 'medium', 'high'];
  const standard = ['low', 'medium', 'high'];
  ModelThinking result = const ModelThinking(
    'Unknown',
    ThinkingAvailability.unknown,
    ThinkingWireFormat.none,
  );
  ModelThinking toggle(
    String family,
    ThinkingWireFormat format, {
    List<String> efforts = const [],
    bool separate = false,
  }) => ModelThinking(
    family,
    ThinkingAvailability.switchable,
    format,
    efforts: efforts,
    separateReasoning: separate,
  );
  ModelThinking fixed(
    String family, {
    List<String> efforts = const [],
    bool separate = false,
  }) => ModelThinking(
    family,
    ThinkingAvailability.alwaysOn,
    efforts.isEmpty ? ThinkingWireFormat.none : ThinkingWireFormat.effort,
    efforts: efforts,
    separateReasoning: separate,
  );
  ModelThinking ordinary(String family) => ModelThinking(
    family,
    ThinkingAvailability.alwaysOff,
    ThinkingWireFormat.none,
  );

  if (RegExp(r'^gpt-(?:5|6)(?:[.:-]|$)').hasMatch(name)) {
    if (name.contains('chat') || name.contains('instant')) {
      result = ordinary('GPT Chat');
    } else if (name.contains('pro')) {
      result = fixed('GPT Pro', efforts: const ['high']);
    } else if (name.startsWith('gpt-6') || name.contains('codex')) {
      result = fixed('GPT Reasoning', efforts: standard);
    } else if (RegExp(r'^gpt-5\.\d+').hasMatch(name)) {
      result = toggle('GPT-5.x', ThinkingWireFormat.effort, efforts: standard);
    } else {
      result = fixed('GPT-5', efforts: levels);
    }
  } else if (RegExp(r'^o[134](?:-|:|$)').hasMatch(name) ||
      name.startsWith('gpt-oss')) {
    result = fixed('OpenAI Reasoning', efforts: standard);
  } else if (name.startsWith('gpt-') || name.startsWith('chatgpt-')) {
    result = ordinary('GPT');
  } else if (name.startsWith('gemini-')) {
    if (RegExp(r'^gemini-3(?:[.:-]|$)').hasMatch(name)) {
      final geminiLevels = name.startsWith('gemini-3-pro')
          ? const ['low', 'high']
          : (name.contains('flash') &&
                !RegExp(r'^gemini-3\.[78]').hasMatch(name))
          ? levels
          : standard;
      result = fixed('Gemini 3', efforts: geminiLevels);
      if (geminiNative) {
        result = ModelThinking(
          result.family,
          result.availability,
          ThinkingWireFormat.geminiInteractions,
          efforts: geminiLevels,
        );
      }
    } else if (name.startsWith('gemini-2.5') && !geminiNative) {
      result = name.contains('pro')
          ? fixed('Gemini 2.5 Pro', efforts: standard)
          : toggle(
              'Gemini 2.5 Flash',
              ThinkingWireFormat.effort,
              efforts: levels,
            );
    }
  } else if (name.startsWith('deepseek-')) {
    if (name.contains('reasoner') || RegExp(r'^deepseek-r1').hasMatch(name)) {
      result = fixed('DeepSeek Reasoner');
    } else if (RegExp(
      r'^deepseek-(?:chat|flash|pro|v3\.[12]|v4-(?:flash|pro))(?:-|:|$)',
    ).hasMatch(name)) {
      result = toggle(
        'DeepSeek',
        host.contains('dashscope')
            ? ThinkingWireFormat.enableThinking
            : ThinkingWireFormat.enabledType,
      );
    }
  } else if (name.startsWith('qwq')) {
    result = fixed('QwQ');
  } else if (name.startsWith('qwen')) {
    if (name.contains('thinking')) {
      result = fixed('Qwen Thinking');
    } else if (name.contains('coder') || name.contains('instruct')) {
      result = ordinary('Qwen Instruct / Coder');
    } else if (RegExp(r'^qwen(?:3|-(?:plus|turbo|flash|max-latest))')
        .hasMatch(name)) {
      result = toggle(
        'Qwen',
        local && !ollama
            ? ThinkingWireFormat.chatTemplate
            : ThinkingWireFormat.enableThinking,
      );
    } else {
      result = ordinary('Qwen');
    }
  } else if (name.startsWith('mimo-v2-flash') && local) {
    result = toggle('MiMo V2 Flash (local)', ThinkingWireFormat.chatTemplate);
  } else if (name.startsWith('hunyuan-a13b') && local) {
    result = toggle('Hunyuan A13B (local)', ThinkingWireFormat.chatTemplate);
  } else if (name.startsWith('glm-')) {
    if (name.startsWith('glm-5.3')) {
      result = fixed('GLM-5.3');
    } else if (RegExp(r'^glm-(?:4\.[567]|5)(?:[.:-]|$)').hasMatch(name)) {
      result = toggle('GLM', ThinkingWireFormat.enabledType);
    } else if (name.startsWith('glm-z1')) {
      result = fixed('GLM-Z1');
    }
  } else if (name.startsWith('kimi-')) {
    if (name.startsWith('kimi-k3')) {
      result = fixed('Kimi K3', efforts: const ['low', 'high']);
    } else if (name.contains('thinking') || name.startsWith('kimi-k2.7-code')) {
      result = fixed('Kimi Thinking');
    } else if (RegExp(r'^kimi-k2[.-][56]').hasMatch(name)) {
      result = toggle('Kimi K2.5 / K2.6', ThinkingWireFormat.enabledType);
    } else {
      result = ordinary('Kimi');
    }
  } else if (name.startsWith('minimax-')) {
    if (name.startsWith('minimax-m3')) {
      result = toggle(
        'MiniMax M3',
        ThinkingWireFormat.adaptiveType,
        separate: true,
      );
    } else if (RegExp(r'^minimax-m[12]').hasMatch(name)) {
      result = fixed('MiniMax Reasoning', separate: true);
    }
  } else if (name.startsWith('claude-')) {
    if (RegExp(
      r'^claude-(?:3[.-]7|(?:sonnet|opus|haiku)-4|4-(?:sonnet|opus|haiku))',
    ).hasMatch(name)) {
      result = toggle(
        'Claude Extended Thinking',
        ThinkingWireFormat.claudeBudget,
        efforts: levels,
      );
    } else {
      result = ordinary('Claude');
    }
  } else if (name.startsWith('grok-')) {
    if (name.contains('non-reasoning')) {
      result = ordinary('Grok Non-reasoning');
    } else if (name.startsWith('grok-3-mini')) {
      result = fixed('Grok 3 Mini', efforts: const ['low', 'high']);
    } else if (RegExp(r'^grok-4\.[56]').hasMatch(name)) {
      result = fixed('Grok 4.5 / 4.6', efforts: standard);
    } else if (name.startsWith('grok-4') || name.contains('reasoning')) {
      result = fixed('Grok Reasoning');
    } else {
      result = ordinary('Grok');
    }
  }

  // The selected native API is not interchangeable with Chat Completions.
  if (geminiNative) {
    return result.format == ThinkingWireFormat.geminiInteractions
        ? result
        : const ModelThinking(
            'Gemini Interactions',
            ThinkingAvailability.unknown,
            ThinkingWireFormat.none,
          );
  }
  if (result.availability == ThinkingAvailability.unknown ||
      result.availability == ThinkingAvailability.alwaysOff) {
    return result;
  }
  if (router) {
    return ModelThinking(
      result.family,
      result.availability,
      ThinkingWireFormat.openRouter,
      efforts: result.efforts.isEmpty && result.canToggle
          ? standard
          : result.efforts,
    );
  }
  if (ollama) {
    return ModelThinking(
      result.family,
      result.availability,
      ThinkingWireFormat.effort,
      efforts: result.efforts.isEmpty ? standard : result.efforts,
    );
  }
  return result;
}
