import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/swipe_collection_selection.dart';
import 'package:ryza_chat_mvp/src/conversation_collection_store.dart';

void main() {
  testWidgets('right swipe selects and left swipe deselects without checkbox', (
    tester,
  ) async {
    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SwipeCollectionSelection(
              selected: selected,
              onChanged: (value) => setState(() => selected = value),
              child: const SizedBox(
                height: 100,
                width: double.infinity,
                child: Text('Message'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Checkbox).hitTestable(), findsNothing);
    final originalSize = tester.getSize(find.text('Message'));
    final originalPosition = tester.getTopLeft(find.text('Message'));
    await tester.drag(find.text('Message'), const Offset(90, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text('Message')).width, originalSize.width - 54);
    expect(
      tester.getTopLeft(find.text('Message')).dx,
      originalPosition.dx + 64,
    );
    expect(find.text('已选择'), findsOneWidget);
    expect(selected, isTrue);
    await tester.drag(find.text('Message'), const Offset(-90, 0));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox).hitTestable(), findsNothing);
    expect(selected, isFalse);
    expect(tester.getSize(find.text('Message')), originalSize);
  });

  test('counts narration separately without counting translation twice', () {
    expect(collectionTextCounts('旁白：走进房间\n发言：你好\n旁白：挥挥手', true), (
      dialogue: 1,
      narration: 2,
    ));
    expect(collectionTextCounts('旁白：她笑了\n莱莎：你好！\n译文：Hello!\n旁白：她挥挥手', false), (
      dialogue: 1,
      narration: 2,
    ));
    expect(
      collectionCardCounts({
        'items': [
          {'text': 'hello', 'dialogueCount': 1, 'narrationCount': 2},
        ],
        'audio': ['a', 'b'],
      }),
      (dialogue: 1, voice: 2, narration: 2),
    );
  });
}
