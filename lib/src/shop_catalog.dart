import 'app_localization.dart';

class ShopItem {
  const ShopItem({
    required this.id,
    required this.price,
    required this.imageAsset,
    required this.nameZh,
    required this.nameEn,
    required this.nameJa,
    required this.descriptionZh,
    required this.descriptionEn,
    required this.descriptionJa,
    required this.effectZh,
    required this.effectEn,
    required this.effectJa,
    required this.statChanges,
    this.resetNegativeStats = false,
  });

  final String id;
  final int price;
  final String imageAsset;
  final String nameZh;
  final String nameEn;
  final String nameJa;
  final String descriptionZh;
  final String descriptionEn;
  final String descriptionJa;
  final String effectZh;
  final String effectEn;
  final String effectJa;
  final Map<String, int> statChanges;
  final bool resetNegativeStats;

  String name(AppLanguage language) => language.text(nameZh, nameEn, nameJa);
  String description(AppLanguage language) =>
      language.text(descriptionZh, descriptionEn, descriptionJa);
  String effect(AppLanguage language) =>
      language.text(effectZh, effectEn, effectJa);
}

class ShopCatalog {
  static const items = <ShopItem>[
    ShopItem(
      id: 'ryza_gift',
      price: 200,
      imageAsset: 'assets/images/shop/gift-box.png',
      nameZh: '给莱莎的礼物',
      nameEn: 'A Gift for Ryza',
      nameJa: 'ライザへの贈り物',
      descriptionZh: '你精心为莱莎挑选的礼物。\n从挑选到包装都花了不少心思，只希望她打开礼物的那一刻，能露出惊喜又开心的笑容。\n光是想象莱莎一边好奇地拆开包装，一边期待里面是什么的样子，就已经让人忍不住开始期待了。',
      descriptionEn: 'A gift you chose for Ryza with care. You spent time selecting and wrapping it, hoping she smiles when she opens it. Just imagining her curious anticipation makes you excited too.',
      descriptionJa: 'ライザのために心を込めて選んだ贈り物。選ぶところから包むところまで手間をかけたのは、開けた瞬間の驚いた笑顔が見たいから。中身を気にしながら包みをほどく姿を想像するだけで、こちらまで楽しみになる。',
      effectZh: '心情 +10 · 精力 +5 · 亲近感 +10 · 好奇心 +5',
      effectEn: 'Mood +10 · Energy +5 · Closeness +10 · Curiosity +5',
      effectJa: '気分 +10 · 元気 +5 · 親しみ +10 · 好奇心 +5',
      statChanges: {'mood': 10, 'energy': 5, 'closeness': 10, 'curiosity': 5},
    ),
    ShopItem(
      id: 'advanced_energy_tonic',
      price: 300,
      imageAsset: 'assets/images/shop/energy-potion.png',
      nameZh: '高级精力剂',
      nameEn: 'Advanced Energy Tonic',
      nameJa: '高級活力剤',
      descriptionZh: '根据在遗迹深处发现的古老配方制作而成的高级精力剂。\n所需素材不仅稀有，收集起来也十分困难，就连炼制过程本身都有很高的失败概率。由于成功制作出的数量一直很少，莱莎对每一瓶都格外珍惜，平时绝不会轻易使用。',
      descriptionEn: 'An advanced energy tonic made from an ancient recipe found deep in the ruins. Its rare ingredients are difficult to collect, and even the synthesis has a high failure rate. Ryza treasures every scarce bottle and would never use one casually.',
      descriptionJa: '遺跡の奥で見つかった古いレシピから作られた高級活力剤。素材は希少で集めるのも難しく、調合そのものも失敗しやすい。完成品は少ないため、ライザは一本一本を大切にし、普段は決して気軽に使わない。',
      effectZh: '精力 +50 · 心情 -30 · 亲近感 -30（最低为 0）',
      effectEn: 'Energy +50 · Mood -30 · Closeness -30 (minimum 0)',
      effectJa: '元気 +50 · 気分 -30 · 親しみ -30（最低 0）',
      statChanges: {'energy': 50, 'mood': -30, 'closeness': -30},
    ),
    ShopItem(
      id: 'reconciliation_voucher',
      price: 500,
      imageAsset: 'assets/images/shop/reconciliation-voucher.png',
      nameZh: '和好券',
      nameEn: 'Make-Up Voucher',
      nameJa: '仲直り券',
      descriptionZh: '「如果以后我们吵架了，就用这个吧。」\n凭此券，可以兑换一次：不计较谁先道歉的和好。\n使用条件：双方其实都还在乎对方。\n不可转让 / 不可退款 / 永久有效',
      descriptionEn: '“If we ever argue, use this.” Redeem it once to make up without keeping score of who apologizes first. Valid when both of you still care. Non-transferable / Non-refundable / Never expires.',
      descriptionJa: '「もし喧嘩したら、これを使おう。」先に謝るのがどちらかを気にせず、仲直りを一度だけお願いできる券。条件は、お互いをまだ大切に思っていること。譲渡不可 / 返金不可 / 有効期限なし。',
      effectZh: '所有负值归零',
      effectEn: 'Reset negative stats to zero',
      effectJa: 'マイナスの数値をすべて 0 に戻す',
      statChanges: {},
      resetNegativeStats: true,
    ),
  ];

  static ShopItem? byId(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }
}
