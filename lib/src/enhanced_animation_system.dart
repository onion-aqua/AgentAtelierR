// enhanced_animation_system.dart
// Ryza Chat 增强动画系统
// 直接集成到项目中以提升动画生动性和流畅度

import 'dart:async';
import 'dart:math';

import 'package:spine_flutter/spine_flutter.dart' hide Color;

// ============================================================================
// 1. 动态混合时间计算器
// ============================================================================

enum AnimationType { idle, action, expression, microMotion }

class AnimationBlendCalculator {
  /// 根据动画类型和情感强度计算最佳混合时间
  static double calculateBlendTime({
    required AnimationType fromType,
    required AnimationType toType,
    required double emotionalIntensity,
    String? currentExpression,
  }) {
    double baseBlend = 0.3;

    // 动画类型权重
    if (fromType == AnimationType.idle && toType == AnimationType.action) {
      baseBlend = 0.2; // 从idle到动作：快速响应
    } else if (fromType == AnimationType.action &&
        toType == AnimationType.idle) {
      baseBlend = 0.4; // 从动作到idle：自然放松
    } else if (fromType == AnimationType.action &&
        toType == AnimationType.action) {
      baseBlend = 0.15; // 动作到动作：流畅连接
    } else if (fromType == AnimationType.expression &&
        toType == AnimationType.expression) {
      baseBlend = 0.35; // 表情到表情：平滑过渡
    }

    // 情感强度调整（0.0-1.0）
    baseBlend *= (0.8 + emotionalIntensity * 0.4);

    // 表情影响
    if (currentExpression != null) {
      if (currentExpression.contains('excited') ||
          currentExpression.contains('laughing')) {
        baseBlend *= 0.85; // 兴奋状态：更快的过渡
      } else if (currentExpression.contains('sad') ||
          currentExpression.contains('crying')) {
        baseBlend *= 1.2; // 悲伤状态：更慢的过渡
      }
    }

    return baseBlend.clamp(0.1, 0.6);
  }
}

// ============================================================================
// 2. 缓动函数库
// ============================================================================

class AnimationEasing {
  /// 弹性缓动（适合表情变化）
  static double easeOutElastic(double t) {
    if (t == 0) return 0;
    if (t == 1) return 1;
    const c4 = (2 * pi) / 3;
    return pow(2, -10 * t).toDouble() * sin((t * 10 - 0.75) * c4) + 1;
  }

  /// 回弹缓动（适合动作结束）
  static double easeOutBack(double t) {
    const c1 = 1.70158;
    const c3 = c1 + 1;
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2);
  }

  /// 平滑缓动（适合平滑过渡）
  static double easeInOutCubic(double t) {
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2;
  }

  /// 快进慢出（适合大部分动作）
  static double easeOutQuad(double t) {
    return 1 - (1 - t) * (1 - t);
  }

  /// 快入慢出
  static double easeInOutQuad(double t) {
    return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2;
  }
}

// ============================================================================
// 3. 增强的说话头部运动
// ============================================================================

class EnhancedSpeechMotion {
  double _phraseIntensity = 0.5;
  final List<double> _recentEnergies = [];

  /// 应用增强的说话动作到骨骼
  void applySpeakingMotion({
    required SpineWidgetController controller,
    required double speechEnergy,
    required double seconds,
  }) {
    // 记录最近的能量水平
    _recentEnergies.add(speechEnergy);
    if (_recentEnergies.length > 10) _recentEnergies.removeAt(0);

    // 计算平均能量和变化率
    final avgEnergy = _recentEnergies.isEmpty
        ? 0.5
        : _recentEnergies.reduce((a, b) => a + b) / _recentEnergies.length;
    final energyVariation = _calculateVariation(_recentEnergies);

    // 短语包络：模拟人类说话的节奏感
    final phraseEnvelope = pow(sin(seconds * pi * 0.18).abs(), 1.4).toDouble();
    _phraseIntensity = phraseEnvelope;

    // 多频率叠加的头部运动
    final nodBase =
        sin(seconds * pi * 0.68 + 0.25) * (2.8 + speechEnergy * 5.2);
    final nodDetail = sin(seconds * pi * 1.92 + 0.7) * 1.4 * energyVariation;
    final nod = (nodBase + nodDetail) * (0.5 + phraseEnvelope * 0.5);

    // 左右摆动：低频主摆 + 高频细节
    final swayMain =
        sin(seconds * pi * 0.23 + 0.8) * (6.8 + speechEnergy * 4.2);
    final swayDetail = sin(seconds * pi * 0.87 + 1.3) * 2.1;
    final sway = swayMain + swayDetail;

    // 倾斜：根据情感强度调整
    final tiltFreq = 0.14 + _phraseIntensity * 0.08;
    final tilt =
        sin(seconds * pi * tiltFreq + 2.35) *
        (1.8 + phraseEnvelope * 4.2 + avgEnergy * 2.0);

    // 应用到骨骼
    final head =
        controller.skeleton.findBone('control_roll_head') ??
        controller.skeleton.findBone('head');
    final neck =
        controller.skeleton.findBone('control_roll_neck') ??
        controller.skeleton.findBone('neck');
    final body =
        controller.skeleton.findBone('control_roll_body_upper') ??
        controller.skeleton.findBone('body');

    if (head != null) {
      head.setRotation(nod + tilt * 0.4);
    }

    if (neck != null) {
      neck.setRotation(nod * 0.5 + tilt * 0.3);
    }

    if (body != null) {
      // 根据说话强度微调身体前倾
      final lean = avgEnergy * 1.5 + _phraseIntensity * 1.0;
      body.setRotation(sway * 0.15 + lean * 0.5);
    }

    // 肩膀的联动
    _applyShoulderMotion(controller, seconds, speechEnergy, phraseEnvelope);
  }

  void _applyShoulderMotion(
    SpineWidgetController controller,
    double seconds,
    double energy,
    double phraseEnvelope,
  ) {
    final shoulderL = controller.skeleton.findBone('shoulder_L');
    final shoulderR = controller.skeleton.findBone('shoulder_R');

    // 肩膀的异步运动（不同步增加自然感）
    if (shoulderL != null) {
      final motion = sin(seconds * pi * 0.31 + 0.5) * (0.8 + energy * 1.2);
      shoulderL.setRotation(motion * phraseEnvelope);
    }

    if (shoulderR != null) {
      final motion = sin(seconds * pi * 0.29 + 2.1) * (0.8 + energy * 1.2);
      shoulderR.setRotation(-motion * phraseEnvelope);
    }
  }

  double _calculateVariation(List<double> values) {
    if (values.length < 2) return 0.0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance =
        values.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) /
        values.length;
    return sqrt(variance);
  }
}

// ============================================================================
// 4. 程序化微动画系统
// ============================================================================

class ProceduralMicroMotion {
  final Random _random = Random();
  Timer? _breathingTimer;
  Timer? _microAdjustmentTimer;
  double _breathPhase = 0.0;

  /// 启动自然呼吸系统
  void startNaturalBreathing(SpineWidgetController controller) {
    _breathingTimer?.cancel();

    _breathPhase = 0.0;
    const breathCycleDuration = 4.5; // 4.5秒一个呼吸周期

    _breathingTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      _breathPhase += 0.05 / breathCycleDuration;
      if (_breathPhase > 1.0) _breathPhase -= 1.0;

      // 使用正弦创造自然的呼吸曲线
      final inhale = sin(_breathPhase * 2 * pi);
      final breathDepth = pow(max(0, inhale), 0.7).toDouble() * 0.6 + 0.4;

      // 应用到胸部和肩膀骨骼
      final chest =
          controller.skeleton.findBone('chest') ??
          controller.skeleton.findBone('body2');

      if (chest != null) {
        chest.setScaleY(1.0 + breathDepth * 0.02);
      }
    });
  }

  /// 启动微调整系统：模拟人类的小幅度姿态调整
  void startMicroAdjustments(SpineWidgetController controller) {
    _microAdjustmentTimer?.cancel();

    void schedulenext() {
      final delay = 3 + _random.nextInt(4);
      _microAdjustmentTimer = Timer(Duration(seconds: delay), () {
        _performRandomMicroAdjustment(controller);
        schedulenext();
      });
    }

    schedulenext();
  }

  void _performRandomMicroAdjustment(SpineWidgetController controller) {
    final adjustments = [
      () => _applyHeadTilt(controller),
      () => _applyShoulderRoll(controller),
      () => _applyWeightShift(controller),
    ];

    // 随机选择一个微调整动作
    if (adjustments.isNotEmpty) {
      adjustments[_random.nextInt(adjustments.length)]();
    }
  }

  void _applyHeadTilt(SpineWidgetController controller) {
    final head =
        controller.skeleton.findBone('control_roll_head') ??
        controller.skeleton.findBone('head');
    if (head == null) return;

    final targetRotation = (_random.nextDouble() - 0.5) * 4; // ±2度
    final currentRotation = head.getRotation();

    // 简单的渐变效果
    var progress = 0.0;
    const steps = 30;
    Timer.periodic(const Duration(milliseconds: 30), (timer) {
      progress += 1.0 / steps;
      if (progress >= 1.0) {
        head.setRotation(targetRotation);
        timer.cancel();
        return;
      }

      final eased = AnimationEasing.easeInOutCubic(progress);
      head.setRotation(
        currentRotation + (targetRotation - currentRotation) * eased,
      );
    });
  }

  void _applyShoulderRoll(SpineWidgetController controller) {
    final shoulderL = controller.skeleton.findBone('shoulder_L');
    final shoulderR = controller.skeleton.findBone('shoulder_R');

    if (shoulderL != null) {
      final roll = (_random.nextDouble() - 0.5) * 3;
      shoulderL.setRotation(roll);
    }

    if (shoulderR != null) {
      final roll = (_random.nextDouble() - 0.5) * 3;
      shoulderR.setRotation(roll);
    }
  }

  void _applyWeightShift(SpineWidgetController controller) {
    final body =
        controller.skeleton.findBone('control_roll_body_upper') ??
        controller.skeleton.findBone('body');
    if (body == null) return;

    final lean = (_random.nextDouble() - 0.5) * 2;
    body.setRotation(lean);
  }

  void dispose() {
    _breathingTimer?.cancel();
    _microAdjustmentTimer?.cancel();
  }
}

// ============================================================================
// 5. LLM语义分析器（简化版）
// ============================================================================

class LLMSemanticAnalyzer {
  /// 从响应中分析情感强度
  static double analyzeEmotionalIntensity(String response) {
    double intensity = 0.5;

    // 检测感叹号密度
    final exclamations = '!！'.allMatches(response).length;
    intensity += exclamations * 0.1;

    // 检测强情感词汇
    final strongEmotions = [
      '非常',
      '特别',
      '极其',
      '太',
      '超级',
      'really',
      'very',
      'extremely',
      '绝对',
      '必须',
      '一定',
      'absolutely',
      'definitely',
      'must',
      '哇',
      '啊',
      'wow',
      'oh',
      '天啊',
      '真的',
    ];

    for (final word in strongEmotions) {
      if (response.toLowerCase().contains(word.toLowerCase())) {
        intensity += 0.05;
      }
    }

    // 检测重复标点
    if (response.contains('!!') || response.contains('！！')) {
      intensity += 0.15;
    }

    return intensity.clamp(0.0, 1.0);
  }

  /// 分析语速节奏
  static double analyzeSpeechSpeed(String response) {
    final sentences = response
        .split(RegExp(r'[。！？!?.]'))
        .where((s) => s.trim().isNotEmpty)
        .length;
    final words = response.split(RegExp(r'\s+')).length;

    if (sentences == 0) return 1.0;

    final avgWordsPerSentence = words / sentences;

    // 短句：快节奏
    if (avgWordsPerSentence < 5) {
      return 1.12;
    }
    // 长句：慢节奏
    else if (avgWordsPerSentence > 12) {
      return 0.90;
    }

    return 1.0;
  }

  /// 检测是否包含问题
  static bool containsQuestion(String response) {
    return response.contains('?') ||
        response.contains('？') ||
        response.contains('吗') ||
        response.contains('呢');
  }
}

// ============================================================================
// 6. 情感权重系统
// ============================================================================

class EmotionalWeights {
  /// 根据表情获取动画权重调整系数
  static double getAnimationWeight(String expression) {
    final expressionLower = expression.toLowerCase();

    if (expressionLower.contains('happy') ||
        expressionLower.contains('laughing')) {
      return 1.15; // 开心时动作更明显
    } else if (expressionLower.contains('sad') ||
        expressionLower.contains('crying')) {
      return 0.85; // 悲伤时动作更含蓄
    } else if (expressionLower.contains('excited')) {
      return 1.30; // 兴奋时动作最夸张
    } else if (expressionLower.contains('angry')) {
      return 1.10; // 愤怒时动作有力
    } else if (expressionLower.contains('shy')) {
      return 0.70; // 害羞时动作收敛
    }

    return 1.0;
  }

  /// 根据表情获取时间缩放
  static double getTimeScale(String expression) {
    final expressionLower = expression.toLowerCase();

    if (expressionLower.contains('excited') ||
        expressionLower.contains('happy')) {
      return 1.08; // 快8%
    } else if (expressionLower.contains('sad') ||
        expressionLower.contains('crying')) {
      return 0.92; // 慢8%
    } else if (expressionLower.contains('angry')) {
      return 1.05; // 稍快
    } else if (expressionLower.contains('shy')) {
      return 0.95; // 稍慢
    }

    return 1.0;
  }
}

// ============================================================================
// 7. 使用示例和集成辅助
// ============================================================================

/// 集成辅助类 - 提供便捷的方法来使用增强动画系统
class EnhancedAnimationHelper {
  final SpineWidgetController spineController;
  final EnhancedSpeechMotion speechMotion = EnhancedSpeechMotion();
  final ProceduralMicroMotion microMotion = ProceduralMicroMotion();

  double _currentEmotionalIntensity = 0.5;
  String _currentExpression = 'neutral';

  EnhancedAnimationHelper(this.spineController);

  /// 初始化增强系统
  void initialize() {
    microMotion.startNaturalBreathing(spineController);
    microMotion.startMicroAdjustments(spineController);
  }

  /// 播放动画（带增强效果）
  TrackEntry playAnimationEnhanced({
    required int track,
    required String animationName,
    bool loop = false,
    AnimationType type = AnimationType.action,
    AnimationType? fromType,
    double? customBlendTime,
  }) {
    // 计算动态混合时间
    final blendTime =
        customBlendTime ??
        AnimationBlendCalculator.calculateBlendTime(
          fromType: fromType ?? AnimationType.idle,
          toType: type,
          emotionalIntensity: _currentEmotionalIntensity,
          currentExpression: _currentExpression,
        );

    final entry = spineController.animationState.setAnimationByName(
      track,
      animationName,
      loop,
    )..setMixDuration(blendTime);

    // 应用情感权重
    final weight = EmotionalWeights.getAnimationWeight(_currentExpression);
    entry.setAlpha(weight);

    // 应用时间缩放
    final timeScale = EmotionalWeights.getTimeScale(_currentExpression);
    entry.setTimeScale(timeScale);

    return entry;
  }

  /// 更新当前表情（影响后续动画）
  void updateExpression(String expression) {
    _currentExpression = expression;
  }

  /// 从LLM响应分析并更新情感强度
  void updateFromResponse(String response) {
    _currentEmotionalIntensity = LLMSemanticAnalyzer.analyzeEmotionalIntensity(
      response,
    );
  }

  /// 应用说话动作
  void applySpeakingMotion(double speechEnergy, double seconds) {
    speechMotion.applySpeakingMotion(
      controller: spineController,
      speechEnergy: speechEnergy,
      seconds: seconds,
    );
  }

  /// 清理资源
  void dispose() {
    microMotion.dispose();
  }
}
