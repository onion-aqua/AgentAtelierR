import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'glass_ui.dart';
import 'settings_section.dart';

/// Chooses the single user-configurable app on the virtual phone's home screen.
class SettingsShortcutPicker extends StatefulWidget {
  const SettingsShortcutPicker({
    super.key,
    required this.controller,
    required this.onSelected,
    this.includePcAgent = false,
    this.liquidGlass = false,
  });

  final AppController controller;
  final ValueChanged<SettingsSection> onSelected;
  final bool includePcAgent;
  final bool liquidGlass;

  @override
  State<SettingsShortcutPicker> createState() => _SettingsShortcutPickerState();
}

class _SettingsShortcutPickerState extends State<SettingsShortcutPicker> {
  bool _saving = false;
  String? _error;

  Future<void> _select(SettingsSection section) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.setVirtualPhoneSettingsShortcut(section);
      if (mounted) widget.onSelected(section);
    } on Object {
      if (!mounted) return;
      setState(() {
        _error = widget.controller.interfaceLanguage.text(
          '快捷入口保存失败，请重试',
          'Could not save the shortcut. Please try again.',
          'ショートカットを保存できませんでした。もう一度お試しください。',
        );
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final language = widget.controller.interfaceLanguage;
      final selected = widget.controller.virtualPhoneSettingsShortcut;
      final liquidGlass = GlassStyleScope.resolve(
        context,
        fallback: widget.liquidGlass,
      );
      return GlassPageSurface(
        liquidGlass: liquidGlass,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            toolbarHeight: 56,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            flexibleSpace: GlassSurface(
              liquidGlass: liquidGlass,
              backdropBlur: false,
              borderRadius: BorderRadius.zero,
              tone: Theme.of(context).brightness == Brightness.dark
                  ? GlassTone.dark
                  : GlassTone.light,
              fallbackColor: glassPageHeaderColor(context),
              child: const SizedBox.expand(),
            ),
            automaticallyImplyLeading: false,
            title: Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Text(
                language.text('设置快捷入口', 'Choose a shortcut', 'ショートカットを選択'),
              ),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  language.text(
                    '选择设置首页的任意一项。以后点击手机快捷图标即可直接进入，长按图标可重新选择。',
                    'Choose any item from settings. Tap the phone shortcut to open it, or hold the icon to change it.',
                    '設定の項目を選択してください。スマホのアイコンをタップすると開き、長押しで変更できます。',
                  ),
                ),
              ),
              if (_saving) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              for (final section in SettingsSection.values)
                if (section != SettingsSection.pcAgent || widget.includePcAgent)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: GlassContentCard(
                      liquidGlass: liquidGlass,
                      child: ListTile(
                        key: ValueKey('settings-shortcut-${section.name}'),
                        leading: Icon(section.icon),
                        title: Text(section.title(language)),
                        subtitle: Text(section.description(language)),
                        trailing: selected == section
                            ? const Icon(Icons.check_circle_rounded)
                            : const Icon(Icons.chevron_right_rounded),
                        enabled: !_saving,
                        onTap: () => _select(section),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      );
    },
  );
}
