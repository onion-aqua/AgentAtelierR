import 'dart:ui';

import 'package:alarm/alarm.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'src/app_controller.dart';
import 'src/app_localization.dart';
import 'src/app_theme.dart';
import 'src/app_shell.dart';
import 'src/runtime_log.dart';
import 'src/local_skin_store.dart';
import 'src/character_appearance.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Atlas shaders capture this value when loaded, so configure it before
  // any built-in or imported Spine textures are created.
  Atlas.filterQuality = FilterQuality.high;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['ryza-ai-revive'],
      await rootBundle.loadString(
        'docs/third_party/ryza-ai-revive-LICENSE.txt',
      ),
    );
  });
  FlutterError.onError = (details) {
    RuntimeLog.instance.error(
      'Flutter',
      details.exception,
      details.stack ?? StackTrace.current,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    RuntimeLog.instance.error('Platform', error, stackTrace);
    return false;
  };
  runApp(const _BootstrapApp());
}

class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp();

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<_BootstrapApp> {
  AppController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await RuntimeLog.instance.initialize();
      RuntimeLog.instance.info('App', '应用启动，版本 1.0.0 正式版（构建 20）');
      await initSpineFlutter(enableMemoryDebugging: false);
      await Alarm.init();
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            audioFocus: AndroidAudioFocus.none,
          ),
          iOS: AudioContextIOS(
            options: const {AVAudioSessionOptions.mixWithOthers},
          ),
        ),
      );
      await LocalSkinStore.instance.initialize();
      registerLocalSkinAppearances();
      final controller = await AppController.load();
      if (mounted) setState(() => _controller = controller);
    } on Object catch (error, stackTrace) {
      RuntimeLog.instance.error('Startup', error, stackTrace);
      if (mounted) setState(() => _error = error);
    }
  }

  String _startupErrorMessage(Object error) {
    final details = error.toString();
    final asset = RegExp(r'''Unable to load asset:\s*["']?([^"'\s]+)''')
        .firstMatch(details)
        ?.group(1);
    if (asset != null) {
      return '必要资源缺失：$asset\n请按资源说明补齐文件后重新构建。';
    }
    return '初始化失败，请查看运行日志后重试。';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) return AgentAtelierRApp(controller: controller);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(
        color: Colors.white,
        child: SizedBox.expand(
          child: _error == null
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    // Keep the logo above the startup backdrop while the app
                    // finishes initializing in the background.
                    const ColoredBox(color: Colors.white),
                    const IgnorePointer(
                      child: Center(
                        child: FractionallySizedBox(
                          widthFactor: 0.85,
                          child: Image(
                            image: AssetImage(
                              'assets/branding/agent_atelier_logo.png',
                            ),
                            fit: BoxFit.contain,
                            semanticLabel: 'AgentAtelierR',
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          size: 40,
                          color: Color(0xFF8A3F38),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _startupErrorMessage(_error!),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFF3E3834)),
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: () {
                            setState(() => _error = null);
                            _initialize();
                          },
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class AgentAtelierRApp extends StatelessWidget {
  const AgentAtelierRApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'AgentAtelierR',
        theme: withDialogueAppearance(
          atelierTheme(controller.accentTheme, Brightness.light),
          controller.textColorTheme,
          controller.translationOnly &&
              controller.translationLanguage.name != 'none',
        ),
        darkTheme: withDialogueAppearance(
          atelierTheme(controller.accentTheme, Brightness.dark),
          controller.textColorTheme,
          controller.translationOnly &&
              controller.translationLanguage.name != 'none',
        ),
        themeMode: switch (controller.themePreference) {
          AppThemePreference.system => ThemeMode.system,
          AppThemePreference.light => ThemeMode.light,
          AppThemePreference.dark => ThemeMode.dark,
        },
        home: AppShell(controller: controller),
      ),
    );
  }
}
