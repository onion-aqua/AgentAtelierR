import 'dart:async';
import 'dart:ui';

import 'package:app_links/app_links.dart';
import 'package:alarm/alarm.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;
import 'package:spine_flutter/spine_flutter.dart' hide Color;

import 'src/app_controller.dart';
import 'src/app_localization.dart';
import 'src/alarm_ringing_overlay.dart';
import 'src/app_theme.dart';
import 'src/app_shell.dart';
import 'src/runtime_log.dart';
import 'src/android_companion_runtime.dart';
import 'src/companion_notification_permission.dart';
import 'src/platform_capabilities.dart';
import 'src/local_skin_store.dart';
import 'src/character_appearance.dart';
import 'src/character_runtime_profile.dart';
import 'src/ryza_loading_indicator.dart';
import 'src/glass_ui.dart';
import 'src/fish_mcp_service.dart';
import 'src/update/update_runtime.dart';
import 'src/update/resource_resolver.dart';

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
      [
        if (details.library != null) 'library: ${details.library}',
        if (details.context != null)
          'context: ${details.context!.toDescription()}',
        '${details.exception}',
      ].join('\n'),
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
  UpdateRuntime? _updates;
  final _resourceBundle = ResourceOverlayAssetBundle();
  Object? _error;
  Timer? _logoTimer;
  StreamSubscription<Uri>? _appLinksSubscription;
  bool _showLogo = true;
  bool _characterReady = false;
  final _bootstrapClock = Stopwatch();

  @override
  void initState() {
    super.initState();
    _logoTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showLogo = false);
    });
    _appLinksSubscription = AppLinks().uriLinkStream.listen(
      (uri) => unawaited(FishMcpService.instance.handleRedirectUri(uri)),
      onError: (Object error, StackTrace stack) {
        RuntimeLog.instance.warning('Fish MCP', 'OAuth 回调监听失败：$error');
      },
    );
    _initialize();
  }

  @override
  void dispose() {
    _logoTimer?.cancel();
    _appLinksSubscription?.cancel();
    _controller?.removeListener(_handleControllerChanged);
    _updates?.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  void _handleCharacterReady() {
    if (!_characterReady && mounted) {
      RuntimeLog.instance.info(
        'Startup',
        '角色加载回调：初始化后 ${_bootstrapClock.elapsedMilliseconds}ms',
      );
      setState(() => _characterReady = true);
    }
  }

  void _handleCharacterLoadFailed() {
    // The chat page owns the actionable skin error; reveal it instead of
    // leaving the startup loader over it indefinitely.
    _handleCharacterReady();
  }

  Future<void> _initialize() async {
    _bootstrapClock
      ..reset()
      ..start();
    try {
      await RuntimeLog.instance.initialize();
      RuntimeLog.instance.info('App', '应用启动，版本 1.0.4.4');
      await initSpineFlutter(enableMemoryDebugging: false);
      if (AppPlatformCapabilities.supportsVoiceAlarms) await Alarm.init();
      await AndroidCompanionRuntime.instance.initialize();
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            // A single native owner coordinates focus for every app player.
            audioFocus: AndroidAudioFocus.none,
          ),
          iOS: AudioContextIOS(
            options: const {AVAudioSessionOptions.mixWithOthers},
          ),
        ),
      );
      // Recover/activate verified resources before catalogues and prompts are
      // read. This avoids mixing old startup data with the new snapshot.
      final resourceStart = _bootstrapClock.elapsedMilliseconds;
      final updates = await UpdateRuntime.production();
      RuntimeLog.instance.info(
        'Startup',
        '资源更新检查：${_bootstrapClock.elapsedMilliseconds - resourceStart}ms',
      );
      if (!mounted) {
        updates.dispose();
        return;
      }
      _updates?.dispose();
      _updates = updates;
      final controller = await AppController.load();
      RuntimeLog.instance.info(
        'Startup',
        '控制器恢复完成：累计 ${_bootstrapClock.elapsedMilliseconds}ms',
      );
      controller.startColdLaunchGreeting();
      await controller.initializeAlarmRuntime();
      if (controller.activeCharacterId == CharacterRuntimeIds.ryza) {
        await LocalSkinStore.instance.initialize();
        registerLocalSkinAppearances();
      }
      if (mounted) {
        _controller?.removeListener(_handleControllerChanged);
        controller.addListener(_handleControllerChanged);
        setState(() => _controller = controller);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(requestCompanionNotificationPermissionOnce());
        });
      }
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AgentAtelierR',
      builder: (context, child) => DefaultAssetBundle(
        bundle: _resourceBundle,
        child: GlassStyleScope(
          enabled: controller?.liquidGlassChatUi ?? false,
          child: AlarmRingingOverlay(
            enabled: AppPlatformCapabilities.supportsVoiceAlarms,
            language: controller?.interfaceLanguage ?? AppLanguage.chinese,
            child: child!,
          ),
        ),
      ),
      theme: controller == null
          ? ThemeData.light()
          : withDialogueAppearance(
              atelierTheme(controller.accentTheme, Brightness.light),
              controller.textColorTheme,
              controller.translationOnly &&
                  controller.translationLanguage.name != 'none',
              controller.dialogueFontScale,
              controller.textColorChoice,
            ),
      darkTheme: controller == null
          ? null
          : withDialogueAppearance(
              atelierTheme(controller.accentTheme, Brightness.dark),
              controller.textColorTheme,
              controller.translationOnly &&
                  controller.translationLanguage.name != 'none',
              controller.dialogueFontScale,
              controller.textColorChoice,
            ),
      themeMode: switch (controller?.themePreference) {
        AppThemePreference.system || null => ThemeMode.system,
        AppThemePreference.light => ThemeMode.light,
        AppThemePreference.dark => ThemeMode.dark,
      },
      home: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null)
            AppShell(
              controller: controller,
              updateRuntime: _updates,
              startupUpdateCheckReady: _characterReady && !_showLogo,
              onCharacterReady: _handleCharacterReady,
              onCharacterLoadFailed: _handleCharacterLoadFailed,
            )
          else
            const ColoredBox(color: Colors.black),
          if (_error == null && !_characterReady)
            Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child:
                        controller?.activeCharacterId ==
                            CharacterRuntimeIds.sophie
                        ? const CircularProgressIndicator.adaptive()
                        : RyzaLoadingPanel(
                            language:
                                controller?.interfaceLanguage ??
                                AppLanguage.chinese,
                          ),
                  ),
                ),
              ),
            ),
          if (_error == null && _showLogo)
            const Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(
                  color: Colors.white,
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
              ),
            ),
          if (_error != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.white,
                child: Center(
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
        ],
      ),
    );
  }
}
