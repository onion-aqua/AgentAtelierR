import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_localization.dart';
import 'glass_ui.dart';
import 'runtime_log.dart';

class RuntimeLogScreen extends StatefulWidget {
  const RuntimeLogScreen({
    super.key,
    required this.language,
    this.liquidGlass = false,
    required this.onMenuPressed,
  });
  final AppLanguage language;
  final bool liquidGlass;
  final VoidCallback onMenuPressed;
  @override
  State<RuntimeLogScreen> createState() => _RuntimeLogScreenState();
}

class _RuntimeLogScreenState extends State<RuntimeLogScreen> {
  RuntimeLogModule? _module;
  RuntimeLogLevel? _level;
  String label(RuntimeLogModule module) => switch (module) {
    RuntimeLogModule.llm => 'LLM',
    RuntimeLogModule.tts => 'TTS',
    RuntimeLogModule.expression => widget.language.text(
      '表情规划',
      'Expression',
      '表情計画',
    ),
    RuntimeLogModule.action => widget.language.text('动作规划', 'Action', '動作計画'),
    RuntimeLogModule.speech => widget.language.text(
      '语音规划',
      'Speech planning',
      '音声計画',
    ),
    RuntimeLogModule.memory => widget.language.text('记忆', 'Memory', '記憶'),
    RuntimeLogModule.translation => widget.language.text(
      '翻译',
      'Translation',
      '翻訳',
    ),
    RuntimeLogModule.character => widget.language.text(
      '角色',
      'Character',
      'キャラクター',
    ),
    RuntimeLogModule.storage => widget.language.text('数据', 'Data', 'データ'),
    RuntimeLogModule.system => widget.language.text(
      '系统 / 其他',
      'System / Other',
      'システム / その他',
    ),
  };
  Color color(RuntimeLogModule module) {
    const hues = [
      210.0,
      150.0,
      290.0,
      30.0,
      330.0,
      180.0,
      250.0,
      70.0,
      10.0,
      0.0,
    ];
    return HSLColor.fromAHSL(
      1,
      hues[module.index],
      module == RuntimeLogModule.system ? 0 : .65,
      Theme.of(context).brightness == Brightness.dark ? .72 : .32,
    ).toColor();
  }

  List<RuntimeLogEntry> get filtered => RuntimeLog.instance.entries.reversed
      .where(
        (e) =>
            (_module == null || e.module == _module) &&
            (_level == null || e.level == _level),
      )
      .toList();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: RuntimeLog.instance,
    builder: (context, _) {
      final entries = filtered;
      final language = widget.language;
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Padding(
            padding: const EdgeInsets.only(left: 58),
            child: Text(language.text('运行日志', 'Runtime logs', '実行ログ')),
          ),
          actions: [
            IconButton(
              onPressed: RuntimeLog.instance.entries.isEmpty
                  ? null
                  : () => RuntimeLog.instance.clear(),
              tooltip: language.text('清空全部日志', 'Clear all logs', '全ログを消去'),
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              onPressed: entries.isEmpty
                  ? null
                  : () => Clipboard.setData(
                      ClipboardData(
                        text: entries.map((e) => e.formatted).join('\n\n'),
                      ),
                    ),
              tooltip: language.text(
                '复制筛选结果',
                'Copy filtered logs',
                '絞り込み結果をコピー',
              ),
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
        ),
        body: GlassSurface(
          liquidGlass: widget.liquidGlass,
          tone: Theme.of(context).brightness == Brightness.dark
              ? GlassTone.dark
              : GlassTone.light,
          borderRadius: BorderRadius.zero,
          child: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    ChoiceChip(
                      label: Text(language.text('全部', 'All', 'すべて')),
                      selected: _module == null,
                      onSelected: (_) => setState(() => _module = null),
                    ),
                    for (final module in RuntimeLogModule.values)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ChoiceChip(
                          avatar: Icon(
                            Icons.circle,
                            size: 10,
                            color: color(module),
                          ),
                          label: Text(label(module)),
                          selected: _module == module,
                          onSelected: (_) => setState(() => _module = module),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButton<RuntimeLogLevel>(
                        isExpanded: true,
                        value: _level,
                        hint: Text(language.text('全部级别', 'All levels', '全レベル')),
                        items: [
                          DropdownMenuItem(
                            value: null,
                            child: Text(
                              language.text('全部级别', 'All levels', '全レベル'),
                            ),
                          ),
                          for (final level in RuntimeLogLevel.values)
                            DropdownMenuItem(
                              value: level,
                              child: Text(level.label),
                            ),
                        ],
                        onChanged: (value) => setState(() => _level = value),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '${entries.length} / ${RuntimeLog.instance.entries.length}',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          language.text('暂无匹配日志', 'No matching logs', '該当ログなし'),
                        ),
                      )
                    : ListView.builder(
                        key: ValueKey('${_module?.name}:${_level?.name}'),
                        padding: const EdgeInsets.all(12),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          final text = entry.displayMessage;
                          final long =
                              text.length > 500 ||
                              '\n'.allMatches(text).length > 8;
                          final severity = switch (entry.level) {
                            RuntimeLogLevel.info => color(entry.module),
                            RuntimeLogLevel.warning =>
                              Theme.of(context).brightness == Brightness.dark
                                  ? Colors.amber.shade200
                                  : Colors.brown.shade700,
                            RuntimeLogLevel.error => Theme.of(
                              context,
                            ).colorScheme.error,
                          };
                          return Card(
                            key: ValueKey(
                              '${entry.timestamp.toIso8601String()}:${entry.source}:$index',
                            ),
                            color: color(entry.module).withValues(alpha: .07),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 4,
                                    children: [
                                      Text(
                                        '${label(entry.module)} · ${entry.source}',
                                        style: TextStyle(
                                          color: color(entry.module),
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        entry.level.label,
                                        style: TextStyle(
                                          color: severity,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        entry.timestamp
                                            .toLocal()
                                            .toIso8601String()
                                            .replaceFirst('T', ' '),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (long)
                                    ExpansionTile(
                                      tilePadding: EdgeInsets.zero,
                                      title: Text(
                                        text.split('\n').take(3).join(' '),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      children: [
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: SelectableText(
                                            text,
                                            style: const TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  else
                                    SelectableText(
                                      text,
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        height: 1.5,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
