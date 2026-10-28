import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/rag_memory_retriever.dart';

const _fixtures = <(String, String, List<String>)>[
  (
    'ribbon',
    '用户把蓝色缎带系在莱莎的笔记本上，作为旅行的纪念。',
    ['笔记本上的蓝色缎带是谁系的？', '旅行纪念用的是蓝色缎带吗？', '那条缎带还系在笔记本上吗？'],
  ),
  (
    'tea',
    '莱莎说自己喜欢蜂蜜红茶，糖只加半勺。',
    ['你喝蜂蜜红茶加多少糖？', '蜂蜜红茶的甜度怎么调？', '你说红茶的糖加半勺，对吗？'],
  ),
  (
    'forest',
    '两人约好周末去月影森林采集银叶草。',
    ['周末约好去月影森林做什么？', '银叶草要到哪里采集？', '我们去森林找银叶草的约定还在吗？'],
  ),
  (
    'biscuit',
    '用户送给科洛蒂娅一盒柠檬饼干，她说香味很好。',
    ['送科洛蒂娅的柠檬饼干怎么样？', '她觉得柠檬饼干的香味如何？', '那盒饼干为什么是柠檬味？'],
  ),
  (
    'shell',
    '海边捡到的螺旋贝壳放在工房窗台上。',
    ['海边捡的螺旋贝壳放哪里了？', '工房窗台上的贝壳从哪来？', '我们捡到的是螺旋贝壳吗？'],
  ),
  (
    'ticket',
    '用户将车票编号 A-172 写进旅行日记，目的地是晨星港。',
    ['A-172 车票去哪里？', '旅行日记里的车票编号是什么？', '晨星港对应哪张车票？'],
  ),
  (
    'library',
    '莱莎借了《风之炼金术》，答应下周二还给图书馆。',
    ['风之炼金术什么时候归还？', '下周二要还图书馆什么书？', '你借的风之炼金术还记得吗？'],
  ),
  (
    'flower',
    '用户种了一株紫罗兰，取名小紫，放在卧室。',
    ['卧室的小紫是什么植物？', '紫罗兰取了什么名字？', '小紫为什么放在卧室？'],
  ),
  (
    'soup',
    '两人做过南瓜浓汤，莱莎负责烤南瓜，用户负责搅拌。',
    ['南瓜浓汤是谁搅拌的？', '做浓汤时烤南瓜由谁负责？', '我们怎么分工做南瓜浓汤的？'],
  ),
  (
    'scarf',
    '莱莎给用户织了一条橙色围巾，边缘绣着星星。',
    ['橙色围巾上绣了什么？', '围巾边缘的星星是谁绣的？', '那条橙色围巾是你织的吗？'],
  ),
  (
    'birthday',
    '用户的生日是十月二十日，想吃栗子蛋糕。',
    ['我的生日想吃栗子蛋糕吗？', '栗子蛋糕是给谁的生日准备的？', '你记得十月二十日是什么日子吗？'],
  ),
  (
    'umbrella',
    '雨天共用的绿色雨伞后来留在码头仓库。',
    ['绿色雨伞最后放在哪里？', '码头仓库里留下了什么雨具？', '雨天共用的是绿色雨伞吗？'],
  ),
  ('key', '工房备用钥匙藏在门口花盆下面。', ['备用钥匙藏在哪里？', '门口花盆下面放了什么？', '工房的备用钥匙还在吗？']),
  (
    'puzzle',
    '解开古塔石门的密码是 4276，提示来自墙上的鸟群。',
    ['古塔石门的密码是多少？', '4276 是哪个地方的密码？', '墙上的鸟群给了什么提示？'],
  ),
  (
    'song',
    '用户最喜欢的曲子叫《纸飞机》，听到时会想到毕业旅行。',
    ['纸飞机让你想起什么旅行？', '毕业旅行和哪首曲子有关？', '我最喜欢的曲子叫纸飞机吗？'],
  ),
  (
    'meteor',
    '在山顶看流星时，用户许愿大家都能平安回家。',
    ['山顶看流星时我许了什么愿望？', '平安回家是在哪许下的愿望？', '你记得看流星时的愿望吗？'],
  ),
  (
    'bread',
    'Ryza bought cinnamon bread at Harbor Bakery for the picnic.',
    [
      'Which bakery sold the cinnamon bread?',
      'What did Ryza buy for the picnic?',
      'Did Harbor Bakery have bread?',
    ],
  ),
  (
    'letter',
    'The sealed letter was placed inside the oak drawer by the stairs.',
    [
      'Where is the sealed letter?',
      'What is inside the oak drawer?',
      'Which drawer is by the stairs?',
    ],
  ),
  (
    'book',
    'クラウディアは青い手帳を図書館に置いた。',
    ['青い手帳はどこに置いた？', '図書館に置いた手帳を覚えてる？', 'クラウディアの手帳について教えて。'],
  ),
  (
    'sakura',
    'ライザと桜の公園でお弁当を食べ、卵焼きを分けた。',
    ['桜の公園で何を食べた？', '一緒に分けた卵焼きを覚えている？', '公園のお弁当には何が入っていた？'],
  ),
];

List<RagMemoryDocument> _corpus() => [
  for (var i = 0; i < _fixtures.length; i++)
    RagMemoryDocument(id: _fixtures[i].$1, text: _fixtures[i].$2, sequence: i),
];

void main() {
  // Sixty authored lexical-recall questions cover names, objects, locations,
  // identifiers and Chinese / English / Japanese. These are not an embedding
  // quality benchmark; encoder quality is separately measured with the model.
  for (final (id, _, queries) in _fixtures) {
    for (final query in queries) {
      test('lexical evaluation $id: $query', () {
        final hits = RagMemoryRetriever.retrieve(
          query: query,
          documents: _corpus(),
        );
        expect(hits, isNotEmpty);
        expect(hits.first.document.id, id);
      });
    }
  }

  test('a distant exact fact beats many newer unrelated important events', () {
    final docs = [
      const RagMemoryDocument(id: 'old', text: '备用钥匙藏在门口花盆下面。', sequence: 1),
      for (var i = 0; i < 90; i++)
        RagMemoryDocument(
          id: 'event-$i',
          text: '夕阳下做出永不分离的重要约定第$i次。',
          sequence: i + 20,
          metadata: const {'importance': 5},
        ),
    ];
    expect(
      RagMemoryRetriever.retrieve(
        query: '备用钥匙放哪了',
        documents: docs,
      ).single.document.id,
      'old',
    );
  });

  test(
    'unrelated questions return no fabricated memory even with importance',
    () {
      final hits = RagMemoryRetriever.retrieve(
        query: '量子计算机的纠错原理是什么？',
        documents: const [
          RagMemoryDocument(
            id: 'promise',
            text: '两人承诺永远陪伴彼此。',
            metadata: {'importance': 5},
          ),
        ],
      );
      expect(hits, isEmpty);
    },
  );

  test('empty generic query does not pull an arbitrary protected memory', () {
    for (final query in [
      '',
      '   ',
      'remember what we said before',
      '我们之前的事情',
    ]) {
      expect(
        RagMemoryRetriever.retrieve(query: query, documents: _corpus()),
        isEmpty,
      );
    }
  });

  test('cross-language encoder results can recall with zero keyword overlap', () {
    // Controlled vectors test the retrieval contract only. They are not a fake
    // sentence encoder and are never provided by production retrieval itself.
    const docs = [
      RagMemoryDocument(id: 'tea', text: '用户喝红茶不加糖。'),
      RagMemoryDocument(id: 'tower', text: '塔顶的钟坏了。'),
    ];
    final hits = RagMemoryRetriever.retrieve(
      query: 'How do I prefer my tea?',
      documents: docs,
      queryEmbedding: const [.9, .1, .05],
      embeddings: const {
        'tea': [1, 0, 0],
        'tower': [0, 1, 0],
      },
    );
    expect(hits.single.document.id, 'tea');
    expect(hits.single.score.isFinite, isTrue);
  });

  test(
    'semantic score promotes paraphrase over superficial lexical overlap',
    () {
      const docs = [
        RagMemoryDocument(id: 'promise', text: '两人约好周末去森林寻找炼金素材。'),
        RagMemoryDocument(id: 'distractor', text: '指南书里介绍找材料的检索方法。'),
      ];
      final hits = RagMemoryRetriever.retrieve(
        query: '上次说好去哪找材料？',
        documents: docs,
        queryEmbedding: const [1, 0],
        embeddings: const {
          'promise': [.98, .1],
          'distractor': [.05, .98],
        },
      );
      expect(hits.first.document.id, 'promise');
    },
  );

  test(
    'zero, NaN, infinite and mismatched vectors degrade to lexical safely',
    () {
      for (final vector in <List<double>>[
        [0, 0],
        [double.nan, 0],
        [double.infinity, 0],
        [1],
        [],
      ]) {
        final hits = RagMemoryRetriever.retrieve(
          query: '绿色雨伞在哪里',
          documents: _corpus(),
          queryEmbedding: const [1, 0],
          embeddings: {'umbrella': vector},
        );
        expect(hits.first.document.id, 'umbrella');
        expect(hits.every((hit) => hit.score.isFinite), isTrue);
      }
      final hits = RagMemoryRetriever.retrieve(
        query: '绿色雨伞在哪里',
        documents: _corpus(),
        queryEmbedding: const [double.nan, 0],
      );
      expect(hits.first.document.id, 'umbrella');
    },
  );

  test('low similarity without lexical evidence is rejected', () {
    expect(
      RagMemoryRetriever.retrieve(
        query: 'What is the space station launch date?',
        documents: const [RagMemoryDocument(id: 'tea', text: '我喜欢蜂蜜红茶。')],
        embeddings: const {
          'tea': [0, 1],
        },
        queryEmbedding: const [1, 0],
      ),
      isEmpty,
    );
  });

  test(
    'moderate question-to-record cosine passes the calibrated threshold',
    () {
      final hits = RagMemoryRetriever.retrieve(
        query: 'How should the evening feel?',
        documents: const [RagMemoryDocument(id: 'walk', text: '两人决定沿着海岸静静散步。')],
        queryEmbedding: const [1, 0],
        embeddings: const {
          'walk': [.4, .916515138991168],
        },
      );
      expect(hits.single.document.id, 'walk');
      expect(hits.single.score, greaterThan(.1));
    },
  );

  test(
    'weak semantic association alone remains below the calibrated threshold',
    () {
      final hits = RagMemoryRetriever.retrieve(
        query: 'What color was the holiday suitcase?',
        documents: const [RagMemoryDocument(id: 'walk', text: '两人决定沿着海岸静静散步。')],
        queryEmbedding: const [1, 0],
        embeddings: const {
          'walk': [.3, .953939201416946],
        },
      );
      expect(hits, isEmpty);
    },
  );

  test(
    'whole evidence respects Unicode budget and skips oversized candidates',
    () {
      const docs = [
        RagMemoryDocument(id: 'big', text: '绿色雨伞🌂绿色雨伞🌂绿色雨伞🌂'),
        RagMemoryDocument(id: 'small', text: '绿色雨伞🌂在门口。'),
      ];
      final hits = RagMemoryRetriever.retrieve(
        query: '绿色雨伞',
        documents: docs,
        maxChars: 10,
      );
      expect(hits.single.document.id, 'small');
      expect(hits.single.document.text, docs.last.text);
      expect(hits.single.document.text.runes.length, lessThanOrEqualTo(10));
    },
  );

  test('exact repeated evidence and reused ids are returned only once', () {
    const docs = [
      RagMemoryDocument(id: 'a', text: '绿色雨伞在门口。'),
      RagMemoryDocument(id: 'b', text: '绿色雨伞在门口！'),
      RagMemoryDocument(id: 'a', text: '绿色雨伞在门口。'),
    ];
    expect(
      RagMemoryRetriever.retrieve(query: '绿色雨伞在哪里', documents: docs),
      hasLength(1),
    );
  });

  test('query-side identifiers are exact tokens and not substring matches', () {
    const docs = [
      RagMemoryDocument(id: 'right', text: 'A-172 是去晨星港的车票。'),
      RagMemoryDocument(id: 'wrong', text: 'A-1720 是废弃车票。'),
    ];
    final hits = RagMemoryRetriever.retrieve(query: 'A-172', documents: docs);
    expect(hits.single.document.id, 'right');
  });

  test(
    'metadata keywords help lexical recall but cannot override evidence text',
    () {
      final hits = RagMemoryRetriever.retrieve(
        query: '库肯岛',
        documents: const [
          RagMemoryDocument(
            id: 'local',
            text: '在家乡海岸拾起蓝色石头。',
            metadata: {
              'keywords': ['库肯岛', '海岸'],
            },
          ),
        ],
      );
      expect(hits.single.document.text, '在家乡海岸拾起蓝色石头。');
    },
  );

  test(
    'superseded history keeps its status while deleted memories never return',
    () {
      const docs = [
        RagMemoryDocument(id: 'old', text: '用户以前喜欢咖啡。', status: 'superseded'),
        RagMemoryDocument(id: 'gone', text: '用户以前喜欢咖啡。', status: 'deleted'),
        RagMemoryDocument(
          id: 'withdrawn',
          text: '用户以前喜欢咖啡。',
          status: 'withdrawn',
        ),
      ];
      final hits = RagMemoryRetriever.retrieve(
        query: '以前喜欢咖啡',
        documents: docs,
      );
      expect(hits.single.document.id, 'old');
      expect(hits.single.document.status, 'superseded');
    },
  );

  test('selection is stable across input ordering for equal scores', () {
    const a = RagMemoryDocument(id: 'a', text: '梨子果酱放在罐子里。', sequence: 1);
    const b = RagMemoryDocument(id: 'b', text: '梨子果酱放在冰箱里。', sequence: 2);
    final first = RagMemoryRetriever.retrieve(
      query: '梨子果酱',
      documents: const [a, b],
    );
    final reversed = RagMemoryRetriever.retrieve(
      query: '梨子果酱',
      documents: const [b, a],
    );
    expect(first.map((e) => e.document.id), reversed.map((e) => e.document.id));
    expect(first.first.document.id, 'b');
  });

  test('caller supplied count limit and nonpositive limits are honored', () {
    expect(
      RagMemoryRetriever.retrieve(
        query: '绿色雨伞',
        documents: _corpus(),
        limit: 0,
      ),
      isEmpty,
    );
    expect(
      RagMemoryRetriever.retrieve(
        query: '绿色雨伞',
        documents: _corpus(),
        maxChars: 0,
      ),
      isEmpty,
    );
    expect(
      RagMemoryRetriever.retrieve(query: '绿色雨伞', documents: const []),
      isEmpty,
    );
  });
}
