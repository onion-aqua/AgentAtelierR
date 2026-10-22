import 'package:flutter/material.dart';

import 'alchemy_models.dart';
import 'app_controller.dart';
import 'app_localization.dart';
import 'glass_ui.dart';
import 'shop_catalog.dart';

class AlchemyScreen extends StatefulWidget {
  const AlchemyScreen({
    super.key,
    required this.controller,
    this.embedded = false,
  });

  final AppController controller;
  final bool embedded;

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
      useRootNavigator: false,
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
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
      useRootNavigator: false,
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
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

  Future<void> _loseRing(AppLanguage language) async {
    final revision = widget.controller.dataRevision;
    final confirmed = await showDialog<bool>(
      useRootNavigator: false,
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          language.text(
            '确认丢失誓约之戒？',
            'Confirm the ring is lost?',
            '指輪の紛失を確定しますか？',
          ),
        ),
        content: Text(
          language.text(
            '将从「珍贵的东西」中移除 1 枚誓约之戒，莱莎的心情降低 500。心情恢复到 −250（含）以上前，不能购买和好券。此操作不可撤销。',
            'One Ring of Vows will be removed from Precious things and Ryza’s mood will decrease by 500. Make-Up Vouchers cannot be purchased until mood reaches −250 or higher. This cannot be undone.',
            '「大切なもの」から指輪を1個失い、ライザの気分が500下がります。−250以上に回復するまで仲直り券は購入できません。この操作は取り消せません。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(language.text('取消', 'Cancel', 'キャンセル')),
          ),
          FilledButton(
            key: const ValueKey('confirm-lose-oath-ring'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(language.text('确认丢失', 'Confirm loss', '紛失を確定')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final lost = widget.controller.loseOathRing(expectedRevision: revision);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          lost
              ? language.text(
                  '誓约之戒已丢失，心情 −500',
                  'Ring lost. Mood −500',
                  '指輪を失いました。気分 −500',
                )
              : language.text(
                  '存档或库存已变化，请重新查看',
                  'Save or inventory changed. Please check again.',
                  'セーブまたは所持品が変更されました。確認してください。',
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
            padding: EdgeInsets.only(left: widget.embedded ? 40 : 58),
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
              key: ValueKey('precious-item-action-${item.id}'),
              tooltip: item.isKeepsake
                  ? language.text('丢失誓约之戒', 'Lost Ring of Vows', '指輪の紛失')
                  : language.text('使用', 'Use', '使う'),
              icon: Icon(
                item.isKeepsake
                    ? Icons.remove_circle_outline
                    : Icons.play_circle_outline,
              ),
              onPressed: () => item.isKeepsake
                  ? _loseRing(language)
                  : _usePreciousItem(item, language),
            ),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(language.text('当前库存', 'Inventory', 'コンテナ')),
          subtitle: Text(
            language.text(
              '开启Agent后，可在聊天中让莱莎把食物、书本或生活用品放入背包，也可根据库存调合。',
              'With Agent enabled, ask Ryza to store food, books or everyday items in chat, or synthesize from real inventory.',
              'Agentを有効にすると、チャットで食べ物や本、日用品を入れたり、実際の在庫から調合できます。',
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

  List<String> _tagNames(AlchemyItem item) => {
    ...item.tagIds
        .map((id) => AlchemyCatalog.tags[id]?.name)
        .whereType<String>(),
    ...item.customTags,
  }.toList(growable: false);

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
                '背包是空的。开启Agent后，可说“把一个苹果放入背包”；也可进入地图场景采集素材，再让莱莎调合。',
                'The inventory is empty. Enable Agent and ask to put an apple in the bag, or enter a map location to gather materials for synthesis.',
                'コンテナは空です。Agentを有効にして「リンゴを入れて」と頼むか、マップで素材を採取してライザに調合してもらえます。',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
