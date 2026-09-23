import 'package:flutter/material.dart';

import 'alchemy_models.dart';
import 'app_controller.dart';
import 'app_localization.dart';
import 'glass_ui.dart';
import 'shop_catalog.dart';

class AlchemyScreen extends StatefulWidget {
  const AlchemyScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<AlchemyScreen> createState() => _AlchemyScreenState();
}

class _AlchemyScreenState extends State<AlchemyScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant AlchemyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _useItem(AlchemyItem item, AppLanguage language) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(language.text('使用物品', 'Use item', 'アイテムを使う')),
        content: Text(
          language.text(
            '消耗 1 份「${item.displayNameFor(language)}」？此操作只扣除库存，不自动增加角色属性。',
            'Consume 1 ${item.displayNameFor(language)}? This reduces inventory only; character stats will not change.',
            '「${item.displayNameFor(language)}」を1個消費しますか？在庫のみ減り、キャラクターの能力値は変わりません。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(language.text('取消', 'Cancel', 'キャンセル')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(language.text('使用', 'Use', '使う')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      widget.controller.consumeAlchemyItem(item.instanceId);
    } on FormatException {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            language.text(
              '库存已变化，请重新选择',
              'Inventory changed. Select again.',
              '在庫が変わりました。選び直してください。',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _usePreciousItem(ShopItem item, AppLanguage language) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.name(language)),
        content: Text(
          '${item.description(language)}\n\n${item.effect(language)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(language.text('取消', 'Cancel', 'キャンセル')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(language.text('使用', 'Use', '使う')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final used = widget.controller.useShopItem(item.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          used
              ? language.text(
                  '已使用 ${item.name(language)}',
                  'Used ${item.name(language)}',
                  '${item.name(language)}を使用しました',
                )
              : language.text(
                  '无法使用：库存已变化，或没有需要归零的负值',
                  'Cannot use: inventory changed or there are no negative stats',
                  '使用できません：所持数が変わったか、マイナスの数値がありません',
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.controller.interfaceLanguage;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: glassPageHeaderColor(context),
          automaticallyImplyLeading: false,
          title: Padding(
            padding: const EdgeInsets.only(left: 58),
            child: Text(language.text('炼金工房', 'Atelier', 'アトリエ')),
          ),
          bottom: TabBar(
            tabs: [
              Tab(text: language.text('背包', 'Inventory', 'コンテナ')),
              Tab(text: language.text('记录', 'History', '履歴')),
            ],
          ),
        ),
        body: GlassPageSurface(
          liquidGlass: widget.controller.liquidGlassChatUi,
          child: TabBarView(
            children: [_buildInventory(language), _buildHistory(language)],
          ),
        ),
      ),
    );
  }

  Widget _buildInventory(AppLanguage language) {
    final items = widget.controller.alchemyState.inventory.toList()
      ..sort((a, b) => b.acquiredAt.compareTo(a.acquiredAt));
    final precious = ShopCatalog.items
        .where((item) => (widget.controller.preciousItems[item.id] ?? 0) > 0)
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        ListTile(
          leading: const Icon(Icons.auto_awesome_outlined),
          title: Text(language.text('珍贵的东西', 'Precious things', '大切なもの')),
          trailing: Text(
            '${precious.fold<int>(0, (sum, item) => sum + widget.controller.preciousItems[item.id]!)}',
          ),
        ),
        if (precious.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              language.text(
                '还没有珍贵物品',
                'No precious items yet',
                '大切なものはまだありません',
              ),
            ),
          ),
        for (final item in precious)
          ListTile(
            leading: Image.asset(
              item.imageAsset,
              width: 48,
              height: 48,
              cacheWidth: 192,
            ),
            title: Text(
              '${item.name(language)} × ${widget.controller.preciousItems[item.id]}',
            ),
            subtitle: Text(item.effect(language)),
            trailing: IconButton(
              tooltip: language.text('使用', 'Use', '使う'),
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () => _usePreciousItem(item, language),
            ),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(language.text('当前库存', 'Inventory', 'コンテナ')),
          subtitle: Text(
            language.text(
              '在聊天中告诉莱莎想制作什么，配方与选材由她根据真实库存决定。',
              'Tell Ryza what to make in chat. She decides the recipe and ingredients from the real inventory.',
              'チャットで作りたい物を伝えると、ライザが実際の在庫からレシピと素材を決めます。',
            ),
          ),
          trailing: Text(
            '${items.fold<int>(0, (sum, item) => sum + item.quantity)}',
          ),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: _EmptyInventoryNotice(
              language: language,
              liquidGlass: widget.controller.liquidGlassChatUi,
            ),
          ),
        for (final item in items)
          ListTile(
            title: Text('${item.displayNameFor(language)} × ${item.quantity}'),
            trailing: IconButton(
              tooltip: language.text('使用 1 份', 'Use one', '1個使う'),
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: () => _useItem(item, language),
            ),
            subtitle: Text(
              '${language.text('品质', 'Quality', '品質')} '
              '${item.qualityRank}（${item.quality}）\n'
              '${language.text('标签', 'Traits', '特性')}：'
              '${_tagNames(item).isEmpty ? language.text('无', 'None', 'なし') : _tagNames(item).join('、')}'
              '${item.descriptionFor(language).isEmpty ? '' : '\n${item.descriptionFor(language)}'}',
            ),
            isThreeLine: true,
          ),
      ],
    );
  }

  Widget _buildHistory(AppLanguage language) {
    final history = widget.controller.alchemyState.history;
    if (history.isEmpty) {
      return Center(
        child: Text(
          language.text('还没有调合记录', 'No synthesis history', '調合履歴はありません'),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: history.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = history[index];
        return ListTile(
          leading: const Icon(Icons.history_rounded),
          title: Text(
            '${entry.recipeId == 'custom_failed' ? language.text('失败 · ', 'Failed · ', '失敗 · ') : ''}${entry.result.displayNameFor(language)}',
          ),
          subtitle: Text(
            '${language.text('品质', 'Quality', '品質')} '
            '${entry.result.qualityRank}（${entry.result.quality}） · '
            '${_tagNames(entry.result).join('、')}\n${_formatTime(entry.createdAt)}',
          ),
          isThreeLine: true,
        );
      },
    );
  }

  List<String> _tagNames(AlchemyItem item) => item.tagIds
      .map((id) => AlchemyCatalog.tags[id]?.name)
      .whereType<String>()
      .toList(growable: false);

  String _formatTime(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class _EmptyInventoryNotice extends StatelessWidget {
  const _EmptyInventoryNotice({
    required this.language,
    required this.liquidGlass,
  });

  final AppLanguage language;
  final bool liquidGlass;

  @override
  Widget build(BuildContext context) => GlassContentCard(
    liquidGlass: liquidGlass,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(Icons.map_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              language.text(
                '背包是空的。请先在世界地图进入具体场景，再回到对话中和莱莎一起采集；调合配方由莱莎根据实际素材决定。',
                'The inventory is empty. Enter a location from the world map, then gather through conversation with Ryza. She will design recipes from the materials you actually collect.',
                'コンテナは空です。ワールドマップから場所に入り、ライザとの会話で採取してください。調合レシピは集めた素材からライザが考えます。',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
