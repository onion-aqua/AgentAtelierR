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
        child: GlassContentCard(
          liquidGlass: controller.liquidGlassChatUi,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  item.imageAsset,
                  height: 112,
                  cacheWidth: 512,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 8),
                Text(
                  item.name(language),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(item.description(language)),
                  ),
                ),
                const SizedBox(height: 12),
                Text(item.effect(language)),
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
                      mainAxisExtent: 288,
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
                                child: InkWell(
                                  onTap: () =>
                                      _showDetails(context, item, language),
                                  child: Image.asset(
                                    item.imageAsset,
                                    cacheWidth: 512,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                item.name(language),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                height: 48,
                                child: Text(
                                  item.effect(language),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextButton(
                                      onPressed: () =>
                                          _showDetails(context, item, language),
                                      child: Text(
                                        language.text('详情', 'Details', '詳細'),
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
                                      child: Text('${item.price}', maxLines: 1),
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
