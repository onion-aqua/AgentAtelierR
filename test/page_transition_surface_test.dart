import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/page_transition_surface.dart';

void main() {
  Future<void> pumpSurface(
    WidgetTester tester, {
    required double collapse,
    required double reveal,
    required bool active,
    Widget? incoming,
    Widget? loadingIndicator,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PageTransitionSurface(
          outgoing: const Center(child: Text('Previous page')),
          incoming: incoming,
          collapseProgress: collapse,
          revealProgress: reveal,
          active: active,
          loadingIndicator: loadingIndicator,
        ),
      ),
    ),
  );

  T nearbyWidget<T extends Widget>(Finder anchor) {
    final self = anchor
        .evaluate()
        .map((element) => element.widget)
        .whereType<T>();
    if (self.isNotEmpty) return self.first;
    final ancestors = find
        .ancestor(of: anchor, matching: find.byType(T))
        .evaluate()
        .map((element) => element.widget)
        .whereType<T>();
    if (ancestors.isNotEmpty) return ancestors.last;
    return find
        .descendant(of: anchor, matching: find.byType(T))
        .evaluate()
        .map((element) => element.widget)
        .whereType<T>()
        .first;
  }

  testWidgets('collapsed page stays visible under a translucent dark scrim', (
    tester,
  ) async {
    await pumpSurface(tester, collapse: 1, reveal: 0, active: true);

    expect(find.text('Previous page'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('page-transition-incoming')),
      findsNothing,
    );
    final scrim = find.byKey(const ValueKey('page-transition-scrim'));
    expect(scrim, findsOneWidget);
    final color = nearbyWidget<ColoredBox>(scrim).color;
    expect(color.a, greaterThan(0));
    expect(color.a, lessThanOrEqualTo(0.38));
    expect(color.r, lessThan(0.2));
    expect(color.g, lessThan(0.2));
    expect(color.b, lessThan(0.2));

    final outgoing = find.text('Previous page');
    expect(
      find.ancestor(of: outgoing, matching: find.byType(ImageFiltered)),
      findsWidgets,
    );
    final transform = nearbyWidget<Transform>(outgoing).transform;
    expect(transform.storage[0], closeTo(0.98, 0.001));
    expect(transform.storage[5], closeTo(0.98, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('incoming page fades and grows from 98 percent to full size', (
    tester,
  ) async {
    const incoming = Center(child: Text('Next page'));
    final keyedIncoming = find.byKey(
      const ValueKey('page-transition-incoming'),
    );

    await pumpSurface(
      tester,
      collapse: 1,
      reveal: 0,
      active: true,
      incoming: incoming,
    );
    expect(find.text('Previous page'), findsOneWidget);
    expect(keyedIncoming, findsOneWidget);
    expect(nearbyWidget<Opacity>(keyedIncoming).opacity, 0);
    expect(
      nearbyWidget<Transform>(keyedIncoming).transform.storage[0],
      closeTo(0.98, 0.001),
    );

    await pumpSurface(
      tester,
      collapse: 1,
      reveal: 0.5,
      active: true,
      incoming: incoming,
    );
    final midOpacity = nearbyWidget<Opacity>(keyedIncoming).opacity;
    final midScale = nearbyWidget<Transform>(keyedIncoming)
        .transform
        .storage[0];
    expect(midOpacity, greaterThan(0));
    expect(midOpacity, lessThan(1));
    expect(midScale, greaterThan(0.98));
    expect(midScale, lessThan(1));

    await pumpSurface(
      tester,
      collapse: 1,
      reveal: 1,
      active: true,
      incoming: incoming,
    );
    expect(nearbyWidget<Opacity>(keyedIncoming).opacity, 1);
    expect(
      nearbyWidget<Transform>(keyedIncoming).transform.storage[0],
      closeTo(1, 0.001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('inactive surface exposes only the settled page', (tester) async {
    await pumpSurface(tester, collapse: 0, reveal: 0, active: false);

    expect(find.text('Previous page'), findsOneWidget);
    expect(find.byKey(const ValueKey('page-transition-scrim')), findsNothing);
    expect(
      find.byKey(const ValueKey('page-transition-incoming')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading animation follows the scrim and fades on reveal', (
    tester,
  ) async {
    const indicator = SizedBox(key: ValueKey('loading-animation'));
    final loading = find.byKey(const ValueKey('loading-animation'));

    await pumpSurface(
      tester,
      collapse: 1,
      reveal: 0,
      active: true,
      loadingIndicator: indicator,
    );
    expect(loading, findsOneWidget);
    expect(nearbyWidget<Opacity>(loading).opacity, 1);

    await pumpSurface(
      tester,
      collapse: 1,
      reveal: 0.5,
      active: true,
      loadingIndicator: indicator,
    );
    expect(nearbyWidget<Opacity>(loading).opacity, closeTo(0.5, 0.001));

    await pumpSurface(
      tester,
      collapse: 0,
      reveal: 0,
      active: false,
      loadingIndicator: indicator,
    );
    expect(loading, findsNothing);
  });
}
