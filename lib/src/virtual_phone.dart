import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'glass_ui.dart';
import 'virtual_phone_app_route.dart';
import 'virtual_phone_chrome.dart';
import 'virtual_phone_wallpaper_image.dart';
import 'virtual_phone_wallpapers.dart';

/// Small set of apps exposed by the in-scene virtual phone.
///
/// The phone deliberately owns only navigation and presentation. Callers can
/// provide a page builder for an existing screen, or a callback that opens the
/// existing route after the phone closes. This keeps the phone independent of
/// chat state and makes it safe to add more apps later.
enum VirtualPhoneApp {
  status,
  shop,
  outfit,
  motion,
  pcAgent,
  saves,
  worldMap,
  alchemy,
  missions,
  alarms,
  settings,
  runtimeLogs,
  phone,
  messages,
  wallpaper,
  shortcut,
}

extension VirtualPhoneAppData on VirtualPhoneApp {
  IconData get icon => switch (this) {
    VirtualPhoneApp.status => Icons.favorite_outline_rounded,
    VirtualPhoneApp.shop => Icons.storefront_outlined,
    VirtualPhoneApp.outfit => Icons.checkroom_outlined,
    VirtualPhoneApp.motion => Icons.animation_outlined,
    VirtualPhoneApp.pcAgent => Icons.forum_outlined,
    VirtualPhoneApp.saves => Icons.save_outlined,
    VirtualPhoneApp.worldMap => Icons.map_outlined,
    VirtualPhoneApp.alchemy => Icons.science_outlined,
    VirtualPhoneApp.missions => Icons.assignment_outlined,
    VirtualPhoneApp.alarms => Icons.alarm_outlined,
    VirtualPhoneApp.settings => Icons.settings_outlined,
    VirtualPhoneApp.runtimeLogs => Icons.bug_report_outlined,
    VirtualPhoneApp.phone => Icons.phone_rounded,
    VirtualPhoneApp.messages => Icons.message_rounded,
    VirtualPhoneApp.wallpaper => Icons.wallpaper_rounded,
    VirtualPhoneApp.shortcut => Icons.dashboard_customize_outlined,
  };

  String label(AppLanguage language) => switch (this) {
    VirtualPhoneApp.status => language.text('角色状态', 'Status', '状態'),
    VirtualPhoneApp.shop => language.text('商店', 'Shop', 'ショップ'),
    VirtualPhoneApp.outfit => language.text('服装', 'Outfits', '衣装'),
    VirtualPhoneApp.motion => language.text('组合动作', 'Motions', '組み合わせ動作'),
    VirtualPhoneApp.pcAgent => language.text(
      'PC Agent',
      'PC Agent',
      'PC Agent',
    ),
    VirtualPhoneApp.saves => language.text('存档', 'Saves', 'セーブ'),
    VirtualPhoneApp.worldMap => language.text('世界地图', 'World map', 'ワールドマップ'),
    VirtualPhoneApp.alchemy => language.text('炼金工房', 'Atelier', 'アトリエ'),
    VirtualPhoneApp.missions => language.text('任务', 'Quests', 'クエスト'),
    VirtualPhoneApp.alarms => language.text('语音闹钟', 'Voice alarms', 'ボイスアラーム'),
    VirtualPhoneApp.settings => language.text('设置', 'Settings', '設定'),
    VirtualPhoneApp.runtimeLogs => language.text(
      '运行日志',
      'Runtime logs',
      '実行ログ',
    ),
    VirtualPhoneApp.phone => language.text('电话', 'Phone', '電話'),
    VirtualPhoneApp.messages => language.text('信息', 'Messages', 'メッセージ'),
    VirtualPhoneApp.wallpaper => language.text('手机壁纸', 'Wallpaper', '壁紙'),
    VirtualPhoneApp.shortcut => language.text('自定义', 'Shortcut', 'カスタム'),
  };
}

typedef VirtualPhonePageBuilder = Widget Function(BuildContext context);

class _PhoneNavigatorObserver extends NavigatorObserver {
  _PhoneNavigatorObserver(this.onHomeChanged);
  final ValueChanged<bool> onHomeChanged;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    onHomeChanged(topRoute.isFirst);
  }
}

/// Navigation owned by the phone, including its forms and confirmation dialogs.
class VirtualPhoneScope extends InheritedWidget {
  const VirtualPhoneScope({
    super.key,
    required this.goHome,
    required super.child,
  });

  final VoidCallback goHome;

  static VirtualPhoneScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VirtualPhoneScope>()!;

  @override
  bool updateShouldNotify(VirtualPhoneScope oldWidget) => false;
}

/// Information shown on the virtual phone home screen.
///
/// The phone does not fetch weather itself. The host screen supplies the
/// current story location and a local scene estimate so the launcher remains
/// independent from network services and can still be used in tests.
class VirtualPhoneHomeInfo {
  const VirtualPhoneHomeInfo({
    required this.dayLabel,
    required this.timeLabel,
    required this.locationLabel,
    required this.temperatureLabel,
    required this.weatherLabel,
    required this.weatherIcon,
    this.locationDetail,
    this.carrierLabel = '库肯岛移动',
  });

  final String dayLabel;
  final String timeLabel;
  final String locationLabel;
  final String temperatureLabel;
  final String weatherLabel;
  final IconData weatherIcon;
  final String? locationDetail;
  final String carrierLabel;

  static const fallback = VirtualPhoneHomeInfo(
    dayLabel: '第1天',
    timeLabel: '09:41',
    locationLabel: '库肯岛周边地域',
    locationDetail: '小妖精之森・隐居处前',
    temperatureLabel: '22°C',
    weatherLabel: '晴朗',
    weatherIcon: Icons.wb_sunny_rounded,
  );
}

/// A small deterministic scene weather table for the phone home screen.
///
/// World map data currently has no temperature or weather metadata. Keeping
/// this mapping local makes the result stable for a save and avoids implying
/// that a device GPS or an online weather provider was consulted.
class VirtualPhoneWeather {
  const VirtualPhoneWeather._();

  static VirtualPhoneWeatherInfo estimate({
    required String areaId,
    required String stageId,
    required String sceneTime,
  }) {
    final seed = <int>[
      ...areaId.codeUnits,
      ...stageId.codeUnits,
      ...sceneTime.codeUnits,
    ].fold<int>(0, (sum, value) => sum + value);
    final options = <VirtualPhoneWeatherInfo>[
      const VirtualPhoneWeatherInfo(
        temperatureCelsius: 22,
        condition: '晴朗',
        conditionEnglish: 'Clear',
        conditionJapanese: '晴れ',
        icon: Icons.wb_sunny_rounded,
      ),
      const VirtualPhoneWeatherInfo(
        temperatureCelsius: 19,
        condition: '多云',
        conditionEnglish: 'Cloudy',
        conditionJapanese: 'くもり',
        icon: Icons.cloud_outlined,
      ),
      const VirtualPhoneWeatherInfo(
        temperatureCelsius: 17,
        condition: '微风',
        conditionEnglish: 'Breezy',
        conditionJapanese: 'そよ風',
        icon: Icons.air_rounded,
      ),
      const VirtualPhoneWeatherInfo(
        temperatureCelsius: 16,
        condition: '小雨',
        conditionEnglish: 'Light rain',
        conditionJapanese: '小雨',
        icon: Icons.grain_rounded,
      ),
    ];
    return options[seed.abs() % options.length];
  }
}

class VirtualPhoneWeatherInfo {
  const VirtualPhoneWeatherInfo({
    required this.temperatureCelsius,
    required this.condition,
    required this.conditionEnglish,
    required this.conditionJapanese,
    required this.icon,
  });

  final int temperatureCelsius;
  final String condition;
  final String conditionEnglish;
  final String conditionJapanese;
  final IconData icon;

  String label(AppLanguage language) =>
      language.text(condition, conditionEnglish, conditionJapanese);
}

/// The phone's indicators describe app activity, rather than device hardware.
class VirtualPhoneStatusInfo {
  const VirtualPhoneStatusInfo({
    this.llmLatency,
    this.signalBars,
    this.satietyEnabled = false,
    this.satiety = 100,
  });

  final Duration? llmLatency;
  final int? signalBars;
  final bool satietyEnabled;
  final int satiety;

  int get batteryPercent => satietyEnabled ? satiety.clamp(0, 100) : 100;

  int get batteryLevel => switch (batteryPercent) {
    0 => 0,
    <= 10 => 1,
    <= 25 => 2,
    <= 50 => 3,
    <= 75 => 4,
    _ => 5,
  };
}

/// A modern phone shaped launcher for character utilities.
///
/// [pages] can render existing UI inside the phone. If a page is not supplied,
/// its [onAppPressed] callback is used as a compatibility bridge to the old
/// route. This lets migration happen one app at a time without changing the
/// underlying shop, outfit, motion, save, or relay implementations.
class VirtualPhoneLauncher extends StatelessWidget {
  const VirtualPhoneLauncher({
    super.key,
    required this.language,
    required this.liquidGlass,
    this.pages = const <VirtualPhoneApp, VirtualPhonePageBuilder>{},
    this.onStatusPressed,
    this.onShopPressed,
    this.onOutfitPressed,
    this.onMotionPressed,
    this.onPcAgentPressed,
    this.onSavesPressed,
    this.fullBleedApps = const <VirtualPhoneApp>{},
    this.pageManagedBackApps = const <VirtualPhoneApp>{},
    this.homeInfo = VirtualPhoneHomeInfo.fallback,
    this.size = 48,
    this.updates,
    this.homeInfoBuilder,
    this.shortcutLabel,
    this.shortcutIcon,
    this.shortcutPicker,
    this.statusInfo = const VirtualPhoneStatusInfo(),
    this.statusInfoBuilder,
    this.wallpapers,
    this.liquidGlassBuilder,
  });

  final AppLanguage language;
  final bool liquidGlass;
  final Map<VirtualPhoneApp, VirtualPhonePageBuilder> pages;
  final VoidCallback? onStatusPressed;
  final VoidCallback? onShopPressed;
  final VoidCallback? onOutfitPressed;
  final VoidCallback? onMotionPressed;
  final VoidCallback? onPcAgentPressed;
  final VoidCallback? onSavesPressed;
  final Set<VirtualPhoneApp> fullBleedApps;

  /// Apps that place the shared back control inside their own Scaffold.
  /// This lets drawers and their scrims cover it in the correct paint order.
  final Set<VirtualPhoneApp> pageManagedBackApps;
  final VirtualPhoneHomeInfo homeInfo;
  final double size;
  final Listenable? updates;
  final VirtualPhoneHomeInfo Function()? homeInfoBuilder;
  final String Function()? shortcutLabel;
  final IconData Function()? shortcutIcon;
  final VirtualPhonePageBuilder? shortcutPicker;
  final VirtualPhoneStatusInfo statusInfo;
  final VirtualPhoneStatusInfo Function()? statusInfoBuilder;
  final VirtualPhoneWallpaperStore? wallpapers;
  final bool Function()? liquidGlassBuilder;

  VoidCallback? _callbackFor(VirtualPhoneApp app) => switch (app) {
    VirtualPhoneApp.status => onStatusPressed,
    VirtualPhoneApp.shop => onShopPressed,
    VirtualPhoneApp.outfit => onOutfitPressed,
    VirtualPhoneApp.motion => onMotionPressed,
    VirtualPhoneApp.pcAgent => onPcAgentPressed,
    VirtualPhoneApp.saves => onSavesPressed,
    VirtualPhoneApp.worldMap ||
    VirtualPhoneApp.alchemy ||
    VirtualPhoneApp.missions ||
    VirtualPhoneApp.alarms ||
    VirtualPhoneApp.settings ||
    VirtualPhoneApp.runtimeLogs ||
    VirtualPhoneApp.phone ||
    VirtualPhoneApp.messages ||
    VirtualPhoneApp.wallpaper ||
    VirtualPhoneApp.shortcut => null,
  };

  Future<void> _open(BuildContext context) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: .72),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) => SafeArea(
        child: Center(
          child: _VirtualPhoneCard(
            language: language,
            liquidGlass: liquidGlass,
            pages: pages,
            callbackFor: _callbackFor,
            homeInfo: homeInfo,
            fullBleedApps: fullBleedApps,
            pageManagedBackApps: pageManagedBackApps,
            updates: updates,
            homeInfoBuilder: homeInfoBuilder,
            shortcutLabel: shortcutLabel,
            shortcutIcon: shortcutIcon,
            shortcutPicker: shortcutPicker,
            statusInfo: statusInfo,
            statusInfoBuilder: statusInfoBuilder,
            wallpapers: wallpapers,
            liquidGlassBuilder: liquidGlassBuilder,
          ),
        ),
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(
            scale: Tween<double>(begin: .94, end: 1).animate(curve),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassIconButton(
      liquidGlass: liquidGlass,
      size: size,
      icon: Icons.smartphone_rounded,
      tooltip: language.text('打开虚拟手机', 'Open virtual phone', '仮想スマホを開く'),
      onPressed: () => _open(context),
    );
  }
}

class _VirtualPhoneCard extends StatefulWidget {
  const _VirtualPhoneCard({
    required this.language,
    required this.liquidGlass,
    required this.pages,
    required this.callbackFor,
    required this.homeInfo,
    required this.fullBleedApps,
    required this.pageManagedBackApps,
    required this.updates,
    required this.homeInfoBuilder,
    required this.shortcutLabel,
    required this.shortcutIcon,
    required this.shortcutPicker,
    required this.statusInfo,
    required this.statusInfoBuilder,
    required this.wallpapers,
    required this.liquidGlassBuilder,
  });

  final AppLanguage language;
  final bool liquidGlass;
  final Map<VirtualPhoneApp, VirtualPhonePageBuilder> pages;
  final VoidCallback? Function(VirtualPhoneApp app) callbackFor;
  final VirtualPhoneHomeInfo homeInfo;
  final Set<VirtualPhoneApp> fullBleedApps;
  final Set<VirtualPhoneApp> pageManagedBackApps;
  final Listenable? updates;
  final VirtualPhoneHomeInfo Function()? homeInfoBuilder;
  final String Function()? shortcutLabel;
  final IconData Function()? shortcutIcon;
  final VirtualPhonePageBuilder? shortcutPicker;
  final VirtualPhoneStatusInfo statusInfo;
  final VirtualPhoneStatusInfo Function()? statusInfoBuilder;
  final VirtualPhoneWallpaperStore? wallpapers;
  final bool Function()? liquidGlassBuilder;

  @override
  State<_VirtualPhoneCard> createState() => _VirtualPhoneCardState();
}

class _VirtualPhoneCardState extends State<_VirtualPhoneCard> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _iconKeys = <VirtualPhoneApp, GlobalKey>{
    for (final app in VirtualPhoneApp.values)
      app: GlobalKey(debugLabel: 'virtual-phone-icon-${app.name}'),
  };
  bool _navOpening = false;
  VirtualPhoneAppRoute? _activeAppRoute;
  double _dragOffset = 0;
  bool _dragging = false;
  bool _closing = false;
  final _homeVisible = ValueNotifier(true);
  late final _PhoneNavigatorObserver _navigationObserver =
      _PhoneNavigatorObserver((home) {
        if (mounted) _homeVisible.value = home;
      });
  late bool _lastGlass;

  bool get _liquidGlass =>
      widget.liquidGlassBuilder?.call() ?? widget.liquidGlass;

  @override
  void initState() {
    super.initState();
    _lastGlass = _liquidGlass;
    widget.updates?.addListener(_handleStyleUpdate);
  }

  void _handleStyleUpdate() {
    final next = _liquidGlass;
    if (mounted && next != _lastGlass) {
      setState(() => _lastGlass = next);
    }
  }

  @override
  void didUpdateWidget(_VirtualPhoneCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updates != widget.updates) {
      oldWidget.updates?.removeListener(_handleStyleUpdate);
      widget.updates?.addListener(_handleStyleUpdate);
    }
    _lastGlass = _liquidGlass;
  }

  @override
  void dispose() {
    widget.updates?.removeListener(_handleStyleUpdate);
    _homeVisible.dispose();
    super.dispose();
  }

  static const _apps = <VirtualPhoneApp>[
    VirtualPhoneApp.status,
    VirtualPhoneApp.shop,
    VirtualPhoneApp.outfit,
    VirtualPhoneApp.motion,
    VirtualPhoneApp.pcAgent,
    VirtualPhoneApp.saves,
    VirtualPhoneApp.worldMap,
    VirtualPhoneApp.alchemy,
    VirtualPhoneApp.missions,
    VirtualPhoneApp.alarms,
    VirtualPhoneApp.settings,
    VirtualPhoneApp.runtimeLogs,
  ];
  static const _dockApps = <VirtualPhoneApp>[
    VirtualPhoneApp.phone,
    VirtualPhoneApp.messages,
    VirtualPhoneApp.wallpaper,
    VirtualPhoneApp.shortcut,
  ];

  VirtualPhoneHomeInfo get _homeInfo =>
      widget.homeInfoBuilder?.call() ?? widget.homeInfo;

  VirtualPhoneStatusInfo get _statusInfo =>
      widget.statusInfoBuilder?.call() ?? widget.statusInfo;

  void _goHome() {
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  Rect _iconRect(VirtualPhoneApp app, {Rect? fallback}) {
    final icon = _iconKeys[app]?.currentContext?.findRenderObject();
    final navigator = _navigatorKey.currentContext?.findRenderObject();
    if (icon is RenderBox &&
        navigator is RenderBox &&
        icon.attached &&
        navigator.attached &&
        icon.hasSize &&
        navigator.hasSize) {
      // Both corners go through global space because the home surface and
      // pressed icon can be scaled. A RenderBox size alone misses transforms.
      final topLeft = navigator.globalToLocal(icon.localToGlobal(Offset.zero));
      final bottomRight = navigator.globalToLocal(
        icon.localToGlobal(icon.size.bottomRight(Offset.zero)),
      );
      final rect = Rect.fromPoints(topLeft, bottomRight);
      if (rect.isFinite && !rect.isEmpty) return rect;
    }
    return fallback ?? const Rect.fromLTWH(0, 0, 58, 58);
  }

  void _openApp(VirtualPhoneApp app, {VirtualPhonePageBuilder? builder}) {
    final navigator = _navigatorKey.currentState;
    if (_closing || _navOpening || navigator == null || navigator.canPop()) {
      return;
    }
    final callback = widget.callbackFor(app);
    if (builder == null && !widget.pages.containsKey(app) && callback != null) {
      _navOpening = true;
      Navigator.of(context).pop();
      WidgetsBinding.instance.addPostFrameCallback((_) => callback());
      return;
    }
    final origin = _iconRect(app);
    final route = VirtualPhoneAppRoute(
      settings: RouteSettings(name: '/virtual-phone/${app.name}'),
      originRect: origin,
      originRectResolver: () => _iconRect(app, fallback: origin),
      icon: app == VirtualPhoneApp.shortcut
          ? widget.shortcutIcon?.call() ?? app.icon
          : app.icon,
      iconBackground: const Color(0xFF26292D),
      iconForeground: Colors.white,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      canHandleBackGesture: () =>
          mounted && (ModalRoute.of(context)?.isCurrent ?? false),
      builder: (context) => _buildAppPage(context, app, builder),
    );
    _activeAppRoute = route;
    _navOpening = true;
    navigator.push<void>(route);
    final animation = route.animation;
    void handleStatus(AnimationStatus status) {
      if (!identical(_activeAppRoute, route)) return;
      _navOpening =
          status == AnimationStatus.forward ||
          status == AnimationStatus.reverse;
    }

    animation?.addStatusListener(handleStatus);
    if (animation != null) handleStatus(animation.status);
    route.completed.then((_) {
      animation?.removeStatusListener(handleStatus);
      if (identical(_activeAppRoute, route)) {
        _activeAppRoute = null;
        _navOpening = false;
      }
    });
  }

  void _handlePullUpdate(DragUpdateDetails details) {
    if (_closing) return;
    final next = _dragOffset + details.primaryDelta!;
    if (next >= 150) {
      _closeFromPull();
      return;
    }
    setState(() {
      _dragging = true;
      _dragOffset = next.clamp(0.0, 520.0);
    });
  }

  void _closeFromPull() {
    if (_closing) return;
    final phoneRoute = ModalRoute.of(context);
    final phoneNavigator = Navigator.of(context);
    setState(() {
      _closing = true;
      _dragging = false;
      _dragOffset = 560;
    });
    Future<void>.delayed(const Duration(milliseconds: 170), () {
      if (!mounted ||
          !phoneNavigator.mounted ||
          phoneRoute == null ||
          !phoneRoute.isActive) {
        return;
      }
      if (phoneRoute.isCurrent) {
        phoneNavigator.pop();
      } else {
        // A root dialog may have appeared during the pull animation. Remove
        // only this phone route instead of popping that newly opened dialog.
        phoneNavigator.removeRoute(phoneRoute);
      }
    });
  }

  void _handlePullEnd(DragEndDetails details) {
    if (_closing) return;
    final velocity = details.primaryVelocity ?? 0;
    if (_dragOffset > 150 || velocity > 950) {
      _closeFromPull();
      return;
    }
    setState(() {
      _dragging = false;
      _dragOffset = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final phoneWidth = size.width.clamp(0.0, 390.0).toDouble();
    final availableHeight = size.height - media.viewPadding.vertical;
    final phoneHeight = availableHeight.clamp(0.0, 760.0).toDouble();
    final dragFraction = phoneHeight <= 0 ? 0.0 : _dragOffset / phoneHeight;
    return NavigatorPopHandler<Object?>(
      onPopWithResult: (_) => _navigatorKey.currentState?.maybePop(),
      child: AnimatedSlide(
        offset: Offset(0, dragFraction),
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        child: Material(
          color: Colors.transparent,
          child: Container(
            key: const ValueKey('virtual-phone-screen'),
            width: phoneWidth,
            height: phoneHeight,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(42),
              border: Border.all(color: Colors.white.withValues(alpha: .35)),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black87,
                  blurRadius: 34,
                  spreadRadius: 2,
                  offset: Offset(0, 18),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(42),
              child: MediaQuery(
                data: media.copyWith(
                  size: Size(phoneWidth, phoneHeight),
                  padding: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                ),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    appBarTheme: Theme.of(context).appBarTheme
                        .copyWith(toolbarHeight: 56),
                  ),
                  child: GlassStyleScope(
                    enabled: GlassStyleScope.resolve(
                      context,
                      fallback: _liquidGlass,
                    ),
                    child: VirtualPhoneScope(
                      goHome: _goHome,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildLiveWallpaper(),
                          Column(
                            children: [
                              _buildLiveStatusBar(),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) => MediaQuery(
                                    data: MediaQuery.of(context)
                                        .copyWith(size: constraints.biggest),
                                    child: ScaffoldMessenger(
                                      child: Navigator(
                                        key: _navigatorKey,
                                        observers: [_navigationObserver],
                                        onGenerateRoute: (_) =>
                                            PageRouteBuilder<void>(
                                              settings: const RouteSettings(
                                                name: '/virtual-phone',
                                              ),
                                              transitionDuration: Duration.zero,
                                              maintainState: true,
                                              pageBuilder: (context, _, _) =>
                                                  _buildLiveHome(context),
                                              transitionsBuilder:
                                                  (
                                                    context,
                                                    _,
                                                    secondaryAnimation,
                                                    child,
                                                  ) {
                                                    if (MediaQuery.disableAnimationsOf(
                                                      context,
                                                    )) {
                                                      return child;
                                                    }
                                                    final progress =
                                                        secondaryAnimation.drive(
                                                          CurveTween(
                                                            curve: Curves
                                                                .easeOutCubic,
                                                          ),
                                                        );
                                                    return FadeTransition(
                                                      opacity: progress.drive(
                                                        Tween<double>(
                                                          begin: 1,
                                                          end: .88,
                                                        ),
                                                      ),
                                                      child: ScaleTransition(
                                                        scale: progress.drive(
                                                          Tween<double>(
                                                            begin: 1,
                                                            end: .97,
                                                          ),
                                                        ),
                                                        child: child,
                                                      ),
                                                    );
                                                  },
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLiveWallpaper() {
    final wallpapers = widget.wallpapers;
    return wallpapers == null
        ? _buildWallpaper(context)
        : AnimatedBuilder(
            animation: wallpapers,
            builder: (context, _) => _buildWallpaper(context),
          );
  }

  Widget _buildWallpaper(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wallpaper = widget.wallpapers?.selected;
      final path = wallpaper?.filePath;
      final ImageProvider provider = path == null
          ? AssetImage(
              wallpaper?.assetPath ?? 'assets/images/virtual_phone/bg1.png',
            )
          : virtualPhoneWallpaperFileImage(path);
      final ratio = MediaQuery.devicePixelRatioOf(context);
      return RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(
              key: const ValueKey('virtual-phone-wallpaper'),
              image: ResizeImage(
                provider,
                width: (constraints.maxWidth * ratio).ceil().clamp(1, 1440),
                height: (constraints.maxHeight * ratio).ceil().clamp(1, 2560),
                policy: ResizeImagePolicy.fit,
                allowUpscaling: false,
              ),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              excludeFromSemantics: true,
              errorBuilder: (context, _, _) => Image.asset(
                'assets/images/virtual_phone/bg1.png',
                fit: BoxFit.cover,
                cacheWidth: 941,
                excludeFromSemantics: true,
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x59000000),
                    Color(0x0D000000),
                    Color(0x66000000),
                  ],
                  stops: [0, .55, 1],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _buildLiveHome(BuildContext context) {
    return widget.updates == null
        ? _buildHome(context)
        : AnimatedBuilder(
            animation: widget.updates!,
            builder: (_, _) => _buildHome(context),
          );
  }

  Widget _buildLiveStatusBar() => AnimatedBuilder(
    animation: Listenable.merge([
      _homeVisible,
      if (widget.updates != null) widget.updates!,
    ]),
    builder: (context, _) => _buildStatusBar(context),
  );

  Widget _buildStatusBar(BuildContext context) {
    final home = _homeVisible.value;
    // Apps use a solid surface matching their page header, rather than the
    // wallpaper underneath. Tint monochrome assets while retaining alpha.
    final background = home
        ? Colors.transparent
        : glassPageHeaderColor(context).withValues(alpha: 1);
    final foreground =
        home ||
            ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black;
    final info = _statusInfo;
    final bars = (info.signalBars ?? 0).clamp(0, 4);
    final seconds = info.llmLatency == null
        ? null
        : (info.llmLatency!.inMilliseconds / 1000).toStringAsFixed(1);
    final signalLabel = seconds == null
        ? widget.language.text(
            'LLM 信号：尚未采样，每 10 轮对话采集一次',
            'LLM signal: not sampled yet; sampled every 10 turns',
            'LLM電波：未測定、10ターンごとに測定',
          )
        : widget.language.text(
            'LLM 信号：$bars/4 格，首次回复延迟 $seconds 秒',
            'LLM signal: $bars/4 bars, first response in $seconds s',
            'LLM電波：$bars/4、最初の応答まで$seconds秒',
          );
    final batteryLabel = info.satietyEnabled
        ? widget.language.text(
            '饱食度：${info.batteryPercent}%',
            'Satiety: ${info.batteryPercent}%',
            '満腹度：${info.batteryPercent}%',
          )
        : widget.language.text(
            '饱食度未启用，显示满电',
            'Satiety disabled; showing full battery',
            '満腹度は無効、満充電を表示',
          );
    return GestureDetector(
      key: const ValueKey('virtual-phone-pull-handle'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _handlePullUpdate,
      onVerticalDragEnd: _handlePullEnd,
      child: Container(
        key: const ValueKey('virtual-phone-status-bar'),
        height: 44,
        color: background,
        child: Stack(
          children: [
            Positioned(
              left: 16,
              top: 0,
              bottom: 0,
              right: MediaQuery.sizeOf(context).width / 2 + 53,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _homeVisible.value
                      ? _homeInfo.carrierLabel
                      : _homeInfo.timeLabel,
                  key: const ValueKey('virtual-phone-status-time'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12,
                    height: 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Container(
                  width: 94,
                  height: 30,
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: foreground.withValues(alpha: .16),
                      width: .7,
                    ),
                  ),
                  child: Image.asset(
                    'assets/images/virtual_phone/dynamic_island.png',
                    key: const ValueKey('virtual-phone-dynamic-island'),
                    fit: BoxFit.fill,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 20,
              top: 13,
              child: Row(
                children: [
                  Semantics(
                    container: true,
                    child: Tooltip(
                      message: signalLabel,
                      child: Image.asset(
                        'assets/images/virtual_phone/signal_$bars.png',
                        key: const ValueKey('virtual-phone-signal'),
                        color: foreground,
                        colorBlendMode: BlendMode.srcIn,
                        width: 22,
                        height: 18,
                        fit: BoxFit.contain,
                        semanticLabel: signalLabel,
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Semantics(
                    container: true,
                    child: Tooltip(
                      message: batteryLabel,
                      child: Image.asset(
                        'assets/images/virtual_phone/battery_${info.batteryLevel}.png',
                        key: const ValueKey('virtual-phone-battery'),
                        color: foreground,
                        colorBlendMode: BlendMode.srcIn,
                        width: 30,
                        height: 18,
                        fit: BoxFit.contain,
                        semanticLabel: batteryLabel,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHome(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final iconSize = ((constraints.maxWidth - 36 - 30) / 4).clamp(
          0.0,
          58.0,
        );
        final labelHeight = MediaQuery.textScalerOf(context).scale(11) * 1.4;
        final rowHeight = (iconSize + 9 + labelHeight).clamp(
          84.0,
          double.infinity,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _PhoneHomeClock(info: _homeInfo),
                      const SizedBox(height: 12),
                      _PhoneHomeInfoRow(
                        language: widget.language,
                        info: _homeInfo,
                      ),
                      const SizedBox(height: 16),
                      GridView.builder(
                        shrinkWrap: true,
                        primary: false,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        itemCount: _apps.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 18,
                          mainAxisExtent: rowHeight,
                        ),
                        itemBuilder: (context, index) {
                          final app = _apps[index];
                          final callback = widget.callbackFor(app);
                          final hasPage =
                              widget.pages.containsKey(app) || callback != null;
                          return _PhoneAppIcon(
                            key: ValueKey('virtual-phone-app-${app.name}'),
                            app: app,
                            iconKey: _iconKeys[app]!,
                            icon: app.icon,
                            size: iconSize,
                            liquidGlass: _liquidGlass,
                            label: app.label(widget.language),
                            enabled: hasPage,
                            onPressed: hasPage ? () => _openApp(app) : null,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              GlassSurface(
                key: const ValueKey('virtual-phone-dock'),
                liquidGlass: _liquidGlass,
                backdropBlur: false,
                borderRadius: BorderRadius.circular(28),
                fallbackColor: const Color(0xB33B3F45),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 2,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      for (final app in _dockApps)
                        Expanded(
                          child: _PhoneAppIcon(
                            key: ValueKey('virtual-phone-app-${app.name}'),
                            app: app,
                            iconKey: _iconKeys[app]!,
                            size: iconSize,
                            liquidGlass: _liquidGlass,
                            icon: app == VirtualPhoneApp.shortcut
                                ? widget.shortcutIcon?.call() ?? app.icon
                                : app.icon,
                            label: app == VirtualPhoneApp.shortcut
                                ? widget.shortcutLabel?.call() ??
                                      app.label(widget.language)
                                : app.label(widget.language),
                            enabled: true,
                            showLabel: false,
                            onPressed: () => _openApp(app),
                            onLongPress:
                                app == VirtualPhoneApp.shortcut &&
                                    widget.shortcutPicker != null
                                ? () => _openApp(
                                    app,
                                    builder: widget.shortcutPicker,
                                  )
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAppPage(
    BuildContext context,
    VirtualPhoneApp app,
    VirtualPhonePageBuilder? overrideBuilder,
  ) {
    final builder = overrideBuilder ?? widget.pages[app];
    Widget page(BuildContext context) => Stack(
      fit: StackFit.expand,
      children: [
        if (builder != null)
          builder(context)
        else
          _VirtualPhoneFallbackPage(language: widget.language, app: app),
        if (builder == null || !widget.pageManagedBackApps.contains(app))
          Positioned(
            left: 6,
            top: 4,
            child: VirtualPhoneBackButton(
              tooltip: widget.language.text('返回', 'Back', '戻る'),
              onPressed: () => _navigatorKey.currentState?.maybePop(),
            ),
          ),
      ],
    );
    return widget.updates == null
        ? Builder(builder: page)
        : AnimatedBuilder(
            animation: widget.updates!,
            builder: (context, _) => page(context),
          );
  }
}

/// Large, translucent display digits inspired by the phone reference image.
/// Fitting the glyphs keeps the clock on one line at narrow widths and large
/// accessibility text scales, without changing the story or status-bar time.
class _PhoneHomeClock extends StatelessWidget {
  const _PhoneHomeClock({required this.info});

  final VirtualPhoneHomeInfo info;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final fontSize = (constraints.maxWidth * .32).clamp(82.0, 112.0);
      final displayTime = info.timeLabel.replaceFirst(RegExp(r'^0(?=\d:)'), '');
      return Column(
        key: const ValueKey('virtual-phone-home-clock'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            info.dayLabel,
            key: const ValueKey('virtual-phone-home-day'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xCCE0EEFF),
              fontSize: 17,
              height: 1.25,
              fontWeight: FontWeight.w500,
              letterSpacing: .2,
              shadows: [Shadow(color: Color(0x26000000), blurRadius: 3)],
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [
                  Color(0xF2E7F6FF),
                  Color(0xD1C8DEFF),
                  Color(0xB3A0C2FF),
                ],
                stops: [0, .55, 1],
              ).createShader(bounds),
              child: Text(
                displayTime,
                key: const ValueKey('virtual-phone-home-time'),
                semanticsLabel: info.timeLabel,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize,
                  height: 1.02,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -fontSize * .045,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  shadows: const [
                    Shadow(
                      color: Color(0x24B3D4FF),
                      blurRadius: 12,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _PhoneHomeInfoRow extends StatelessWidget {
  const _PhoneHomeInfoRow({required this.language, required this.info});

  final AppLanguage language;
  final VirtualPhoneHomeInfo info;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 6,
          child: _PhoneHomeTile(
            icon: Icons.location_on_outlined,
            title: language.text('当前位置', 'Location', '現在地'),
            value: info.locationLabel,
            detail: info.locationDetail,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 4,
          child: _PhoneHomeTile(
            icon: info.weatherIcon,
            title: language.text('场景天气', 'Scene weather', '天気'),
            value: info.temperatureLabel,
            detail: info.weatherLabel,
          ),
        ),
      ],
    );
  }
}

class _PhoneHomeTile extends StatelessWidget {
  const _PhoneHomeTile({
    required this.icon,
    required this.title,
    required this.value,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      liquidGlass: GlassStyleScope.resolve(context),
      backdropBlur: false,
      fallbackColor: const Color(0xB33B3F45),
      borderRadius: BorderRadius.circular(15),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.white70, size: 15),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 2),
              Text(
                detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PhoneAppIcon extends StatefulWidget {
  const _PhoneAppIcon({
    super.key,
    required this.app,
    required this.iconKey,
    required this.icon,
    required this.liquidGlass,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.onLongPress,
    this.showLabel = true,
    this.size = 58,
  });

  final IconData icon;
  final bool liquidGlass;
  final VirtualPhoneApp app;
  final GlobalKey iconKey;
  final String label;
  final bool enabled;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final bool showLabel;
  final double size;

  @override
  State<_PhoneAppIcon> createState() => _PhoneAppIconState();
}

class _PhoneAppIconState extends State<_PhoneAppIcon> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (mounted && value != _pressed) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final foreground = widget.enabled ? Colors.white : Colors.white24;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.onPressed,
        onLongPress: widget.onLongPress,
        onHighlightChanged: _setPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: _pressed ? .94 : 1,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 90),
              curve: Curves.easeOutCubic,
              child: KeyedSubtree(
                key: ValueKey('virtual-phone-glyph-${widget.app.name}'),
                child: SizedBox(
                  key: widget.iconKey,
                  width: widget.size,
                  height: widget.size,
                  child: GlassSurface(
                    liquidGlass: widget.liquidGlass,
                    backdropBlur: false,
                    fallbackColor: widget.enabled
                        ? const Color(0xFF26292D)
                        : const Color(0xFF111214),
                    borderRadius: BorderRadius.circular(16),
                    child: Icon(widget.icon, color: foreground, size: 29),
                  ),
                ),
              ),
            ),
            if (widget.showLabel) ...[
              const SizedBox(height: 7),
              Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  shadows: const [
                    Shadow(
                      color: Colors.black54,
                      offset: Offset(0, 1),
                      blurRadius: 3,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VirtualPhoneFallbackPage extends StatelessWidget {
  const _VirtualPhoneFallbackPage({required this.language, required this.app});

  final AppLanguage language;
  final VirtualPhoneApp app;

  @override
  Widget build(BuildContext context) {
    final label = app.label(language);
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassPageSurface(
        liquidGlass: GlassStyleScope.resolve(context),
        child: Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(app.icon, color: colors.onSurface, size: 52),
                  const SizedBox(height: 18),
                  Text(
                    label,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    language.text('功能待设置', 'Coming soon', '機能は準備中です'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 13,
                    ),
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
