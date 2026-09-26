import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'glass_ui.dart';
import 'shop_catalog.dart';

class ShopScreen extends StatelessWidget {
  const ShopScreen({super.key, required this.controller});

  final AppController controller;

  void _showDetails(BuildContext context, ShopItem item, AppLanguage language) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 420,
            maxHeight: MediaQuery.sizeOf(context).height - 48,
          ),
          child: GlassContentCard(
            liquidGlass: controller.liquidGlassChatUi,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.name(language),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  Image.asset(
                    item.imageAsset,
                    key: ValueKey('shop-item-preview-${item.id}'),
                    height: 156,
                    cacheWidth: 512,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 16),
                  Text(item.description(language)),
                  if (item.effect(language).trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    Text(
                      language.text('效果', 'Effect', '効果'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(item.effect(language)),
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(language.text('关闭', 'Close', '閉じる')),
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

  void _buy(BuildContext context, ShopItem item, AppLanguage language) {
    final bought = controller.buyShopItem(item.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          bought
              ? language.text(
                  '已放入背包：${item.name(language)}',
                  'Added to inventory: ${item.name(language)}',
                  'バッグに追加：${item.name(language)}',
                )
              : language.text(
                  '关系点数不足或库存已满',
                  'Not enough relationship points or inventory is full',
                  '関係ポイント不足、または所持数が上限です',
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final language = controller.interfaceLanguage;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: glassPageHeaderColor(context),
        automaticallyImplyLeading: false,
        title: Padding(
          padding: const EdgeInsets.only(left: 58),
          child: Text(language.text('商店', 'Shop', 'ショップ')),
        ),
      ),
      body: GlassPageSurface(
        liquidGlass: controller.liquidGlassChatUi,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final horizontalPadding = width < 360 ? 10.0 : 16.0;
            final spacing = width < 360 ? 8.0 : 12.0;
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      16,
                      horizontalPadding,
                      14,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.favorite_outline),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            language.text(
                              '关系点数',
                              'Relationship points',
                              '関係ポイント',
                            ),
                          ),
                        ),
                        Text(
                          '${controller.relationshipPoints}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    0,
                    horizontalPadding,
                    24,
                  ),
                  sliver: SliverGrid.builder(
                    itemCount: ShopCatalog.items.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: spacing,
                      mainAxisSpacing: spacing,
                      mainAxisExtent: 244,
                    ),
                    itemBuilder: (context, index) {
                      final item = ShopCatalog.items[index];
                      return GlassContentCard(
                        liquidGlass: controller.liquidGlassChatUi,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Tooltip(
                                  message: language.text(
                                    '查看${item.name(language)}详情',
                                    'View details for ${item.name(language)}',
                                    '${item.name(language)}の詳細を見る',
                                  ),
                                  child: InkWell(
                                    key: ValueKey('shop-item-image-${item.id}'),
                                    onTap: () =>
                                        _showDetails(context, item, language),
                                    borderRadius: BorderRadius.circular(6),
                                    child: Image.asset(
                                      item.imageAsset,
                                      semanticLabel: item.name(language),
                                      cacheWidth: 512,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              SizedBox(
                                height: 42,
                                child: Text(
                                  item.name(language),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: Semantics(
                                      label: language.text(
                                        '${item.price} 关系点数',
                                        '${item.price} relationship points',
                                        '${item.price} 関係ポイント',
                                      ),
                                      excludeSemantics: true,
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.favorite_outline,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 4),
                                          Flexible(
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text('${item.price}'),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: FilledButton(
                                      onPressed: () =>
                                          _buy(context, item, language),
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                        ),
                                      ),
                                      child: Text(
                                        language.text('购买', 'Buy', '購入'),
                                        maxLines: 1,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
