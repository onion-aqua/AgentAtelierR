import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'glass_ui.dart';

/// Non-opaque routes keep the character scene mounted and animating behind
/// settings. The caller hides its category surface to avoid stacking glass.
Future<T?> pushSettingsPage<T>({
  required BuildContext context,
  required AppController controller,
  required WidgetBuilder builder,
}) => Navigator.of(context).push<T>(
  PageRouteBuilder<T>(
    opaque: false,
    settings: const RouteSettings(name: '/settings/detail'),
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) => _SettingsPageScope(
      controller: controller,
      child: Builder(builder: builder),
    ),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, .035),
            end: Offset.zero,
          ).animate(curve),
          child: child,
        ),
      );
    },
  ),
);

class _SettingsPageScope extends InheritedNotifier<AppController> {
  const _SettingsPageScope({
    required AppController controller,
    required super.child,
  }) : super(notifier: controller);
}

/// Shared full-page layout for settings forms, including keyboard-safe actions.
class SettingsDetailPage extends StatelessWidget {
  const SettingsDetailPage({
    super.key,
    this.controller,
    required this.title,
    required this.content,
    this.actions = const [],
    this.headerActions = const [],
    this.contentPadding = const EdgeInsets.all(16),
    this.scrollable = true,
  });

  final AppController? controller;
  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final List<Widget> headerActions;
  final EdgeInsetsGeometry contentPadding;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final state =
        controller ??
        context
            .dependOnInheritedWidgetOfExactType<_SettingsPageScope>()!
            .notifier!;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return GlassSurface(
          key: const ValueKey('settings-detail-glass'),
          liquidGlass: state.liquidGlassChatUi,
          tone: dark ? GlassTone.dark : GlassTone.light,
          borderRadius: BorderRadius.zero,
          fallbackColor: dark
              ? const Color(0xD91C2222)
              : const Color(0xB8EEF2F0),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: IconButton(
                key: const ValueKey('settings-detail-back'),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              title: title,
              actions: headerActions,
            ),
            body: SafeArea(
              top: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: scrollable
                            ? SingleChildScrollView(
                                padding: contentPadding,
                                child: SizedBox(
                                  width: double.infinity,
                                  child: content,
                                ),
                              )
                            : Padding(padding: contentPadding, child: content),
                      ),
                      if (actions.isNotEmpty) ...[
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 4,
                            children: actions,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
