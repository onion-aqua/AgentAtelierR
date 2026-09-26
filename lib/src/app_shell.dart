import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'alarm_screen.dart';
import 'alchemy_screen.dart';
import 'chat_screen.dart';
import 'frame_rate_controller.dart';
import 'folding_button_group.dart';
import 'glass_ui.dart';
import 'mission_screen.dart';
import 'page_navigation.dart';
import 'page_transition_surface.dart';
import 'runtime_log.dart';
import 'ryza_loading_indicator.dart';
import 'settings_screen.dart';
import 'shop_catalog.dart';
import 'shop_screen.dart';
import 'soundscape_controller.dart';
import 'world_map_screen.dart';

enum AppDestination {
  chat,
  worldMap,
  alchemy,
  missions,
  alarms,
  settings,
  runtimeLogs,
  shop,
}

extension AppDestinationData on AppDestination {
  String label(AppLanguage language) => switch (this) {
    AppDestination.chat => language.text('角色聊天', 'Character chat', 'キャラクター会話'),
    AppDestination.worldMap => language.text('世界地图', 'World map', 'ワールドマップ'),
    AppDestination.alchemy => language.text('炼金工房', 'Atelier', 'アトリエ'),
    AppDestination.missions => language.text('任务', 'Quests', 'クエスト'),
    AppDestination.alarms => language.text('语音闹钟', 'Voice alarms', 'ボイスアラーム'),
    AppDestination.settings => language.text('设置', 'Settings', '設定'),
    AppDestination.runtimeLogs => language.text('运行日志', 'Runtime logs', '実行ログ'),
    AppDestination.shop => language.text('商店', 'Shop', 'ショップ'),
  };

  IconData get icon => switch (this) {
    AppDestination.chat => Icons.chat_bubble_outline,
    AppDestination.worldMap => Icons.map_outlined,
    AppDestination.alchemy => Icons.science_outlined,
    AppDestination.missions => Icons.assignment_outlined,
    AppDestination.alarms => Icons.alarm_outlined,
    AppDestination.settings => Icons.settings_outlined,
    AppDestination.runtimeLogs => Icons.bug_report_outlined,
    AppDestination.shop => Icons.storefront_outlined,
  };
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    this.onCharacterReady,
    this.onCharacterLoadFailed,
  });

  final AppController controller;
  final VoidCallback? onCharacterReady;
  final VoidCallback? onCharacterLoadFailed;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _soundscape = SoundscapeController();
  final _navigation = PageNavigation(AppDestination.chat);
  AppDestination get _destination => _navigation.current;
  final _settingsKey = GlobalKey<SettingsScreenState>();
  final _worldMapKey = GlobalKey<WorldMapScreenState>();
  final _alchemyKey = GlobalKey();
  final _missionsKey = GlobalKey();
  final _alarmsKey = GlobalKey();
  final _runtimeLogsKey = GlobalKey();
  final _shopKey = GlobalKey();
  bool _menuOpen = false;
  bool _chatUiHidden = false;
  bool _chatFullscreen = false;
  bool _alwaysOnTop = false;
  bool _borderless = false;
  late final AnimationController _pageTransition;
  late final AnimationController _pageReveal;
  bool _pageTransitionActive = false;
  bool _revealingPage = false;
  AppDestination? _outgoingDestination;
  final Set<int> _activePointers = <int>{};

  @override
  void initState() {
    super.initState();
    _pageTransition = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _pageReveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _activePointers.clear();
      widget.controller.frameRate.setActivity(FrameRateActivity.touch, false);
      return;
    }
    widget.controller.frameRate.setMode(
      widget.controller.frameRateMode,
      force: true,
    );
    widget.controller.frameRate.boost(FrameRateActivity.interfaceAnimation);
    _soundscape.invalidate();
    unawaited(
      _soundscape.sync(
        widget.controller,
        worldMapVisible: _destination == AppDestination.worldMap,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageTransition.dispose();
    _pageReveal.dispose();
    widget.controller.frameRate.setActivity(FrameRateActivity.touch, false);
    unawaited(_soundscape.dispose());
    super.dispose();
  }

  void _openMenu() {
    if (_pageTransitionActive) return;
    widget.controller.frameRate.boost(FrameRateActivity.interfaceAnimation);
    setState(() => _menuOpen = !_menuOpen);
  }

  void _toggleChatUiVisibility() {
    setState(() {
      _chatUiHidden = !_chatUiHidden;
      if (_chatUiHidden) _menuOpen = false;
    });
  }

  void _selectDestination(AppDestination value) {
    if (_pageTransitionActive) return;
    if (value == _destination) {
      if (_menuOpen) setState(() => _menuOpen = false);
      return;
    }
    unawaited(
      _transitionTo(value, () {
        if (value == AppDestination.worldMap) {
          widget.controller.recordMapVisit();
        }
        _navigation.select(value);
      }),
    );
  }

  Future<void> _prepareDestination(AppDestination destination) async {
    if (destination == AppDestination.worldMap) {
      await WorldMapScreen.preload(context, widget.controller);
    } else if (destination == AppDestination.settings) {
      await Future.wait([
        for (final character in ['ryza', 'sophie'])
          precacheImage(
            AssetImage('assets/images/character_switch/$character.png'),
            context,
          ),
      ]);
    } else if (destination == AppDestination.shop ||
        destination == AppDestination.alchemy) {
      final items = destination == AppDestination.shop
          ? ShopCatalog.items
          : ShopCatalog.items
                .where(
                  (item) => (widget.controller.preciousItems[item.id] ?? 0) > 0,
                )
                .toList();
      await Future.wait([
        for (final item in items)
          precacheImage(
            ResizeImage(
              AssetImage(item.imageAsset),
              width: destination == AppDestination.shop ? 512 : 192,
            ),
            context,
          ),
      ]);
    }
  }

  Future<void> _transitionTo(
    AppDestination destination,
    VoidCallback changePage,
  ) async {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    setState(() {
      _pageTransitionActive = true;
      _menuOpen = false;
    });
    widget.controller.frameRate.boost(FrameRateActivity.interfaceAnimation);
    try {
      if (!reduceMotion) await _pageTransition.forward();
      if (!mounted) return;
      try {
        await _prepareDestination(destination);
      } on Object catch (error, stackTrace) {
        RuntimeLog.instance.error('Navigation', error, stackTrace);
      }
      if (!mounted) return;
      final previous = _destination;
      setState(() {
        _outgoingDestination = previous;
        changePage();
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      setState(() => _revealingPage = true);
      if (!reduceMotion) await _pageReveal.forward();
    } finally {
      if (mounted) {
        _pageTransition.reset();
        _pageReveal.reset();
        setState(() {
          _outgoingDestination = null;
          _revealingPage = false;
          _pageTransitionActive = false;
        });
      }
    }
  }

  void _handleBack() {
    if (_pageTransitionActive) return;
    // One owner handles root back events. Nested PopScopes on the same route
    // would all be notified, potentially closing two levels in one gesture.
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    if (_destination == AppDestination.settings &&
        (_settingsKey.currentState?.handleBack() ?? false)) {
      return;
    }
    if (_destination == AppDestination.worldMap &&
        (_worldMapKey.currentState?.handleBack() ?? false)) {
      return;
    }
    if (_chatUiHidden) {
      setState(() => _chatUiHidden = false);
      return;
    }
    if (_navigation.canGoBack) {
      unawaited(_transitionTo(_navigation.previous!, _navigation.goBack));
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    widget.controller.lastUiInteraction = DateTime.now();
    _activePointers.add(event.pointer);
    widget.controller.frameRate.setActivity(FrameRateActivity.touch, true);
  }

  void _handlePointerEnd(PointerEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isNotEmpty) return;
    widget.controller.frameRate.setActivity(FrameRateActivity.touch, false);
    widget.controller.frameRate.boost(FrameRateActivity.interfaceAnimation);
  }

  Widget _buildDestinationPage(AppDestination destination) =>
      switch (destination) {
        AppDestination.chat => const SizedBox.shrink(),
        AppDestination.worldMap => WorldMapScreen(
          key: _worldMapKey,
          controller: widget.controller,
          onMenuPressed: _openMenu,
          onClose: () => _selectDestination(AppDestination.chat),
        ),
        AppDestination.alarms => AlarmScreen(
          key: _alarmsKey,
          controller: widget.controller,
          onMenuPressed: _openMenu,
        ),
        AppDestination.runtimeLogs => RuntimeLogScreen(
          key: _runtimeLogsKey,
          language: widget.controller.interfaceLanguage,
          liquidGlass: widget.controller.liquidGlassChatUi,
          onMenuPressed: _openMenu,
        ),
        AppDestination.settings => SettingsScreen(
          key: _settingsKey,
          backHandledByShell: true,
          controller: widget.controller,
          onMenuPressed: _openMenu,
        ),
        AppDestination.alchemy => AlchemyScreen(
          key: _alchemyKey,
          controller: widget.controller,
        ),
        AppDestination.missions => MissionScreen(
          key: _missionsKey,
          controller: widget.controller,
        ),
        AppDestination.shop => ShopScreen(
          key: _shopKey,
          controller: widget.controller,
        ),
      };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _soundscape.sync(
            widget.controller,
            worldMapVisible: _destination == AppDestination.worldMap,
          );
        });
        final displayedDestination = _outgoingDestination ?? _destination;
        final chatDestination = _revealingPage
            ? _destination
            : displayedDestination;
        final overlayDestination = switch (chatDestination) {
          AppDestination.settings ||
          AppDestination.alchemy ||
          AppDestination.missions => true,
          AppDestination.shop => true,
          _ => false,
        };
        final pauseCharacterAnimation =
            widget.controller.pauseCharacterAnimationOnFullscreenPages &&
            (chatDestination != AppDestination.chat ||
                _chatFullscreen ||
                ModalRoute.isCurrentOf(context) == false);
        // Keep chat at a stable tree location so switching pages never
        // disposes its draft, replayable audio, or active performance state.
        final chat = ChatScreen(
          pageActive: chatDestination == AppDestination.chat,
          pauseCharacterAnimation: pauseCharacterAnimation,
          controller: widget.controller,
          onMenuPressed: _openMenu,
          onShopPressed: () => _selectDestination(AppDestination.shop),
          onCharacterReady: widget.onCharacterReady,
          onCharacterLoadFailed: widget.onCharacterLoadFailed,
          hideUi: _chatUiHidden || overlayDestination,
          onFullscreenChanged: (value) => setState(() {
            _chatFullscreen = value;
            if (value) _menuOpen = false;
          }),
        );
        final page = _buildDestinationPage(displayedDestination);
        final incomingPage =
            _outgoingDestination != null && _destination != AppDestination.chat
            ? _buildDestinationPage(_destination)
            : null;
        final content = Stack(
          children: [
            chat,
            if (displayedDestination != AppDestination.chat)
              Positioned.fill(
                child: _outgoingDestination != null
                    ? AnimatedBuilder(
                        animation: _pageReveal,
                        child: page,
                        builder: (context, child) => Opacity(
                          opacity: 1 - _pageReveal.value,
                          child: child,
                        ),
                      )
                    : page,
              ),
          ],
        );
        final safeTop = MediaQuery.paddingOf(context).top;
        return TickerMode(
          enabled: !widget.controller.continuousAsmr,
          child: PopScope(
            canPop:
                !_pageTransitionActive &&
                !_navigation.canGoBack &&
                !_menuOpen &&
                !_chatUiHidden,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _handleBack();
            },
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              key: _scaffoldKey,
              body: AnimatedBuilder(
                animation: Listenable.merge([_pageTransition, _pageReveal]),
                child: Column(
                  children: [
                    if (Platform.isWindows && _borderless)
                      _buildWindowControls(),
                    Expanded(
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: _handlePointerDown,
                        onPointerUp: _handlePointerEnd,
                        onPointerCancel: _handlePointerEnd,
                        child: Stack(
                          children: [
                            content,
                            if (!_chatUiHidden &&
                                !(_chatFullscreen &&
                                    displayedDestination ==
                                        AppDestination.chat))
                              Positioned(
                                left: 16,
                                top: safeTop + 8,
                                child: GlassIconButton(
                                  liquidGlass:
                                      widget.controller.liquidGlassChatUi,
                                  size: 48,
                                  icon: _menuOpen
                                      ? Icons.close_rounded
                                      : Icons.menu_rounded,
                                  tooltip: widget.controller.interfaceLanguage
                                      .text(
                                        _menuOpen ? '关闭菜单' : '打开菜单',
                                        _menuOpen ? 'Close menu' : 'Open menu',
                                        _menuOpen ? 'メニューを閉じる' : 'メニューを開く',
                                      ),
                                  onPressed: _openMenu,
                                ),
                              ),
                            if (displayedDestination == AppDestination.chat &&
                                !_chatFullscreen)
                              Positioned(
                                left: 72,
                                top: safeTop + 8,
                                child: GlassIconButton(
                                  liquidGlass:
                                      widget.controller.liquidGlassChatUi,
                                  size: 48,
                                  icon: _chatUiHidden
                                      ? Icons.visibility_rounded
                                      : Icons.visibility_off_rounded,
                                  tooltip: widget.controller.interfaceLanguage
                                      .text(
                                        _chatUiHidden ? '恢复界面' : '隐藏界面',
                                        _chatUiHidden
                                            ? 'Restore interface'
                                            : 'Hide interface',
                                        _chatUiHidden ? 'UIを表示' : 'UIを隠す',
                                      ),
                                  onPressed: _toggleChatUiVisibility,
                                ),
                              ),
                            _buildFoldMenu(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                builder: (context, outgoing) => AbsorbPointer(
                  absorbing: _pageTransitionActive,
                  child: PageTransitionSurface(
                    outgoing: outgoing!,
                    incoming: incomingPage == null
                        ? null
                        : Padding(
                            padding: EdgeInsets.only(
                              top: Platform.isWindows && _borderless ? 32 : 0,
                            ),
                            child: incomingPage,
                          ),
                    collapseProgress: _pageTransition.value,
                    revealProgress: _pageReveal.value,
                    active: _pageTransitionActive,
                    loadingIndicator: TickerMode(
                      enabled: true,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: RyzaLoadingIndicator(
                          size: 76,
                          semanticsLabel: widget.controller.interfaceLanguage
                              .text('正在加载', 'Loading', '読み込み中'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleAlwaysOnTop() async {
    if (!Platform.isWindows) return;
    final next = !_alwaysOnTop;
    try {
      const channel = MethodChannel('agentatelier/window');
      await channel.invokeMethod<void>('setAlwaysOnTop', next);
      if (mounted) setState(() => _alwaysOnTop = next);
    } catch (_) {
      // The control is only available on the Windows runner.
    }
  }

  Future<void> _windowCommand(String method, [Object? argument]) async {
    try {
      await const MethodChannel('agentatelier/window')
          .invokeMethod<void>(method, argument);
      if (mounted && method == 'setBorderless') {
        setState(() => _borderless = argument as bool);
      }
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message ?? error.code)));
      }
    }
  }

  Widget _buildWindowControls() {
    final language = widget.controller.interfaceLanguage;
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => _windowCommand('startDrag'),
              child: const Center(
                child: Text('AgentAtelierR', style: TextStyle(fontSize: 12)),
              ),
            ),
          ),
          IconButton(
            iconSize: 16,
            tooltip: language.text('调整大小', 'Resize', 'サイズ変更'),
            onPressed: () => _windowCommand('startResize'),
            icon: const Icon(Icons.open_in_full),
          ),
          IconButton(
            iconSize: 16,
            tooltip: language.text('恢复窗口边框', 'Restore frame', 'ウィンドウ枠を戻す'),
            onPressed: () => _windowCommand('setBorderless', false),
            icon: const Icon(Icons.web_asset),
          ),
          IconButton(
            iconSize: 16,
            tooltip: language.text('最小化', 'Minimize', '最小化'),
            onPressed: () => _windowCommand('minimize'),
            icon: const Icon(Icons.remove),
          ),
          IconButton(
            iconSize: 16,
            tooltip: language.text('关闭', 'Close', '閉じる'),
            onPressed: () => _windowCommand('close'),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildFoldMenu() {
    final language = widget.controller.interfaceLanguage;
    final liquidGlass = widget.controller.liquidGlassChatUi;
    return Positioned(
      left: 16,
      top: MediaQuery.paddingOf(context).top + 64,
      child: Material(
        color: Colors.transparent,
        child: FoldingButtonGroup(
          fromRight: false,
          expanded: _menuOpen && !_chatUiHidden,
          children: [
            if (Platform.isWindows)
              GlassIconButton(
                liquidGlass: liquidGlass,
                size: 48,
                icon: _borderless ? Icons.web_asset : Icons.web_asset_off,
                tooltip: language.text(
                  '切换无边框窗口',
                  'Toggle borderless window',
                  'ウィンドウ枠の切替',
                ),
                onPressed: () => _windowCommand('setBorderless', !_borderless),
              ),
            if (Platform.isWindows)
              GlassIconButton(
                liquidGlass: liquidGlass,
                size: 48,
                icon: _alwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
                tooltip: language.text(
                  _alwaysOnTop ? '取消置顶' : '窗口置顶',
                  _alwaysOnTop ? 'Unpin window' : 'Always on top',
                  _alwaysOnTop ? '最前面を解除' : '最前面に固定',
                ),
                onPressed: _toggleAlwaysOnTop,
              ),
            for (final destination in AppDestination.values)
              if (destination != AppDestination.shop)
                GlassIconButton(
                  liquidGlass: liquidGlass,
                  size: 48,
                  icon: destination.icon,
                  tooltip: destination.label(language),
                  onPressed: () => _selectDestination(destination),
                ),
          ],
        ),
      ),
    );
  }
}
