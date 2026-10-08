import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/motion_candidate_search.dart';

void main() {
  test('prepared large immutable indexes retrieve the right catalogue after replacement', () async {
    final first = Map<String, String>.unmodifiable({
      for (var i = 0; i < 300; i++) 'grp_fg_$i': '安静等待$i',
      'grp_fg_first': '双手拥抱',
      'grp_fg_second': '挥手告别',
    });
    final replacement = Map<String, String>.unmodifiable({
      for (var i = 0; i < 300; i++) 'grp_fg_$i': '安静等待$i',
      // Keep the same map size and keys so this catches a cache that compares
      // length alone instead of the immutable snapshot identity.
      'grp_fg_first': '挥手告别',
      'grp_fg_second': '双手拥抱',
    });

    await prepareMotionCandidateIndex(first);
    expect(
      selectMotionCandidates(first, '双手拥抱', limit: 1).keys.single,
      'grp_fg_first',
    );

    await prepareMotionCandidateIndex(replacement);
    expect(
      selectMotionCandidates(replacement, '双手拥抱', limit: 1).keys.single,
      'grp_fg_second',
    );

    // Reusing a prior snapshot after replacement must rebuild or retrieve
    // its own index, rather than returning the newer snapshot's result.
    await prepareMotionCandidateIndex(first);
    expect(
      selectMotionCandidates(first, '双手拥抱', limit: 1).keys.single,
      'grp_fg_first',
    );
  });
}
